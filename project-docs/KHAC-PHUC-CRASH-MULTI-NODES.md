# Khắc phục lỗi CrashLoopBackOff hàng loạt sau khi worker node mất kết nối

> **Ngày:** 13/05/2026  
> **Môi trường:** K3s v1.32.5+k3s1, 2 node (fedora control-plane + quoctan worker)  
> **Triệu chứng ban đầu:** 15+ pod CrashLoopBackOff sau khi worker node `quoctan` mất kết nối (NotReady)

---

## Mục lục

1. [Tóm tắt vấn đề](#1-tóm-tắt-vấn-đề)
2. [Lỗi 1 — PV nodeAffinity sai (storefront.yas.local.com)](#2-lỗi-1--pv-nodeaffinity-sai)
3. [Lỗi 2 — identity.yas.local.com → Connection refused](#3-lỗi-2--identityyaslocalcom--connection-refused)
4. [Lỗi 3 — Elasticsearch / Kafka / Redis / Zookeeper Pending](#4-lỗi-3--elasticsearch--kafka--redis--zookeeper-pending)
5. [Script tổng hợp fix PV nodeAffinity](#5-script-tổng-hợp-fix-pv-nodeaffinity)
6. [Kết quả sau khi fix](#6-kết-quả-sau-khi-fix)
7. [Phòng tránh trong tương lai](#7-phòng-tránh-trong-tương-lai)

---

## 1. Tóm tắt vấn đề

Khi worker node `quoctan` (172.16.1.169, Ubuntu 24.04 WSL2) mất kết nối → `NotReady`, toàn bộ pod đang chạy trên quoctan bị terminate và K3s cố reschedule lên fedora. Tuy nhiên **3 lỗi độc lập** ngăn các pod khởi động:

| # | Vấn đề | Ảnh hưởng |
|---|--------|-----------|
| 1 | 10 PV có nodeAffinity = `storefront.yas.local.com` (hostname không tồn tại) | ES, Kafka, Redis, Zookeeper Pending vĩnh viễn |
| 2 | `identity.yas.local.com` → 172.16.0.240:80 → Connection refused (Istio chiếm port 80) | 15+ Spring Boot app crash khi startup |
| 3 | CoreDNS pod trước đó chạy trên quoctan → DNS lookup fail | Tất cả pod crash |

---

## 2. Lỗi 1 — PV nodeAffinity sai

### Triệu chứng

```
Warning  FailedScheduling  pod/kafka-cluster-dual-role-0
0/2 nodes are available: 1 node(s) had volume node affinity conflict
```

### Nguyên nhân

K3s `local-path` provisioner tạo PV với nodeAffinity = hostname của node tại thời điểm tạo. Vì một lý do nào đó (có thể lúc cài cluster DNS chưa ổn định), 10 PV được tạo với node = `storefront.yas.local.com` thay vì `fedora`.

```bash
# Kiểm tra PV bị lỗi
kubectl get pv --no-headers \
  -o custom-columns="NAME:.metadata.name,NODE:.spec.nodeAffinity.required.nodeSelectorTerms[0].matchExpressions[0].values[0]" \
  | grep -v "^$\|fedora\|quoctan"
```

### Cách fix

**Bước 1:** Lưu metadata của tất cả PV bị lỗi

```bash
rm -f /tmp/pv-info.txt
for PV in $(kubectl get pv --no-headers \
  -o custom-columns="NAME:.metadata.name,NODE:.spec.nodeAffinity.required.nodeSelectorTerms[0].matchExpressions[0].values[0]" \
  | grep -v "fedora\|quoctan" | awk '{print $1}'); do
  PATH_VAL=$(kubectl get pv $PV -o jsonpath='{.spec.local.path}')
  CAP=$(kubectl get pv $PV -o jsonpath='{.spec.capacity.storage}')
  NS=$(kubectl get pv $PV -o jsonpath='{.spec.claimRef.namespace}')
  NAME=$(kubectl get pv $PV -o jsonpath='{.spec.claimRef.name}')
  echo "$PV|$PATH_VAL|$CAP|$NS|$NAME" >> /tmp/pv-info.txt
done
cat /tmp/pv-info.txt
```

**Bước 2:** Xóa finalizers để có thể delete PV/PVC

```bash
while IFS='|' read -r PV PATH_VAL CAP NS NAME; do
  kubectl patch pv $PV --type=json -p='[{"op":"remove","path":"/metadata/finalizers"}]' 2>/dev/null || true
  kubectl patch pvc $NAME -n $NS --type=json -p='[{"op":"remove","path":"/metadata/finalizers"}]' 2>/dev/null || true
done < /tmp/pv-info.txt
```

**Bước 3:** Xóa PV và PVC cũ

```bash
while IFS='|' read -r PV PATH_VAL CAP NS NAME; do
  kubectl delete pv $PV --force --grace-period=0 2>/dev/null || true
  kubectl delete pvc $NAME -n $NS --force --grace-period=0 2>/dev/null || true
done < /tmp/pv-info.txt
```

**Bước 4:** Tạo lại PV với `fedora` nodeAffinity, trỏ đến đúng path cũ (data không mất)

```bash
while IFS='|' read -r PV PATH_VAL CAP NS NAME; do
  kubectl apply -f - <<EOF
apiVersion: v1
kind: PersistentVolume
metadata:
  annotations:
    local.path.provisioner/selected-node: fedora
    pv.kubernetes.io/provisioned-by: rancher.io/local-path
  name: $PV
spec:
  accessModes:
  - ReadWriteOnce
  capacity:
    storage: $CAP
  claimRef:
    apiVersion: v1
    kind: PersistentVolumeClaim
    name: $NAME
    namespace: $NS
  local:
    path: $PATH_VAL
  nodeAffinity:
    required:
      nodeSelectorTerms:
      - matchExpressions:
        - key: kubernetes.io/hostname
          operator: In
          values:
          - fedora
  persistentVolumeReclaimPolicy: Retain
  storageClassName: local-path
  volumeMode: Filesystem
EOF
done < /tmp/pv-info.txt
```

> **Quan trọng:** Data vẫn còn nguyên trên disk tại `$PATH_VAL` trên fedora. PV mới trỏ đến đúng path đó nên không mất data.

---

## 3. Lỗi 2 — identity.yas.local.com → Connection refused

### Triệu chứng

```
Caused by: java.net.ConnectException: Connection refused
  GET http://identity.yas.local.com/realms/Yas/.well-known/openid-configuration
```

Toàn bộ Spring Boot app (backoffice-bff, storefront-bff, cart, customer, v.v.) crash khi startup vì OAuth2 autoconfiguration gọi Keycloak endpoint ngay lúc khởi động.

### Nguyên nhân

Chuỗi lỗi:
1. CoreDNS ConfigMap: `identity.yas.local.com → 172.16.0.240` (IP của fedora)
2. Fedora port 80 bị **Istio svclb** chiếm (hostPort 80 → istio-ingressgateway)
3. nginx-ingress **không thể** bind port 80 (đã bị Istio chiếm) → `svclb-ingress-nginx` Pending
4. Keycloak Ingress trỏ qua nginx-ingress → không hoạt động
5. Kết quả: `curl http://identity.yas.local.com` → Connection refused

### Cách fix: Trỏ CoreDNS thẳng đến Keycloak ClusterIP

```bash
# Lấy ClusterIP của keycloak-service
KEYCLOAK_IP=$(kubectl get svc keycloak-service -n keycloak -o jsonpath='{.spec.clusterIP}')
echo "Keycloak ClusterIP: $KEYCLOAK_IP"

# Cập nhật CoreDNS ConfigMap
kubectl patch configmap coredns -n kube-system --type=merge -p "{\"data\":{
  \"Corefile\": \".:53 {\n    errors\n    health\n    ready\n    kubernetes cluster.local in-addr.arpa ip6.arpa {\n      pods insecure\n      fallthrough in-addr.arpa ip6.arpa\n    }\n    hosts /etc/coredns/NodeHosts {\n      ${KEYCLOAK_IP} identity.yas.local.com\n      172.16.0.240 api.yas.local.com\n      172.16.0.240 storefront.yas.local.com\n      172.16.0.240 backoffice.yas.local.com\n      172.16.0.240 yas.local.com\n      ttl 60\n      reload 15s\n      fallthrough\n    }\n    prometheus :9153\n    forward . /etc/resolv.conf\n    cache 30\n    loop\n    reload\n    loadbalance\n    import /etc/coredns/custom/*.override\n}\nimport /etc/coredns/custom/*.server\n\",
  \"NodeHosts\": \"${KEYCLOAK_IP} identity.yas.local.com\n172.16.0.240 api.yas.local.com\n172.16.0.240 storefront.yas.local.com\n172.16.0.240 backoffice.yas.local.com\n172.16.0.240 yas.local.com\n\"
}}"

# Restart CoreDNS
kubectl rollout restart deployment coredns -n kube-system
sleep 10

# Verify
kubectl run dns-test --image=busybox:1.28 --restart=Never --rm -it -- \
  sh -c "nslookup identity.yas.local.com"
# → Address: <ClusterIP của keycloak> ✅
```

> **Tại sao không fix nginx-ingress?**  
> Istio svclb đang bind hostPort 80/443 trên fedora. nginx-ingress cần cùng hostPort → conflict. Giải pháp đơn giản nhất là bypass ingress cho Keycloak bằng cách trỏ DNS thẳng đến ClusterIP.

> **Lưu ý:** Nếu keycloak-service bị xóa/tạo lại, ClusterIP có thể thay đổi → phải update CoreDNS lại. Để ổn định hơn, có thể gán IP tĩnh cho keycloak-service.

### CoreDNS cần pin vào fedora

Nếu CoreDNS pod chạy trên worker node mất kết nối → DNS fail toàn cluster:

```bash
# Pin CoreDNS lên control plane
kubectl patch deployment coredns -n kube-system --type=merge -p '{
  "spec": {
    "template": {
      "spec": {
        "nodeSelector": {"kubernetes.io/hostname": "fedora"}
      }
    }
  }
}'
kubectl rollout restart deployment coredns -n kube-system
```

---

## 4. Lỗi 3 — Elasticsearch / Kafka / Redis / Zookeeper Pending

### Triệu chứng

```
search: Connect to http://elasticsearch-es-http.elasticsearch:9200 failed: Connection refused
webhook: No resolvable bootstrap urls given in bootstrap.servers
recommendation: Failed to start bean kafka listener registry
```

### Nguyên nhân

ES, Kafka, Redis, Zookeeper đều Pending vì PV nodeAffinity sai (xem Lỗi 1).

### Cách fix

Đã giải quyết ở [Lỗi 1](#2-lỗi-1--pv-nodeaffinity-sai). Sau khi fix PV:

```bash
# Kafka pod cần force delete để reschedule (StatefulSet cache scheduling failure)
kubectl delete pod kafka-cluster-dual-role-0 -n kafka --force --grace-period=0

# Đợi tất cả ready
kubectl wait pod elasticsearch-standalone-0 -n elasticsearch --for=condition=Ready --timeout=120s
kubectl wait pod kafka-cluster-dual-role-0 -n kafka --for=condition=Ready --timeout=120s

# Restart search, webhook, recommendation
kubectl delete pod -n yas -l app.kubernetes.io/name=search
kubectl delete pod -n yas -l app.kubernetes.io/name=webhook
kubectl delete pod -n yas -l app.kubernetes.io/name=recommendation
```

---

## 5. Script tổng hợp fix PV nodeAffinity

Lưu tại `/tmp/fix-pv-nodeaffinity.sh` để dùng lại sau khi reboot nếu cần:

```bash
#!/bin/bash
# Fix tất cả PV có nodeAffinity sai (không phải fedora hoặc quoctan)
set -euo pipefail

TARGET_NODE="${1:-fedora}"
echo "Target node: $TARGET_NODE"

rm -f /tmp/pv-info.txt

# Thu thập PV bị lỗi
while IFS= read -r line; do
  PV=$(echo "$line" | awk '{print $1}')
  NODE=$(echo "$line" | awk '{print $2}')
  if [[ "$NODE" != "fedora" && "$NODE" != "quoctan" && -n "$NODE" ]]; then
    PATH_VAL=$(kubectl get pv $PV -o jsonpath='{.spec.local.path}')
    CAP=$(kubectl get pv $PV -o jsonpath='{.spec.capacity.storage}')
    NS=$(kubectl get pv $PV -o jsonpath='{.spec.claimRef.namespace}')
    NAME=$(kubectl get pv $PV -o jsonpath='{.spec.claimRef.name}')
    echo "$PV|$PATH_VAL|$CAP|$NS|$NAME" >> /tmp/pv-info.txt
    echo "Found broken PV: $PV ($NS/$NAME) → node=$NODE"
  fi
done < <(kubectl get pv --no-headers \
  -o custom-columns="NAME:.metadata.name,NODE:.spec.nodeAffinity.required.nodeSelectorTerms[0].matchExpressions[0].values[0]")

if [[ ! -f /tmp/pv-info.txt ]]; then
  echo "No broken PVs found."
  exit 0
fi

echo "=== Removing finalizers ==="
while IFS='|' read -r PV PATH_VAL CAP NS NAME; do
  kubectl patch pv $PV --type=json -p='[{"op":"remove","path":"/metadata/finalizers"}]' 2>/dev/null || true
  kubectl patch pvc $NAME -n $NS --type=json -p='[{"op":"remove","path":"/metadata/finalizers"}]' 2>/dev/null || true
done < /tmp/pv-info.txt

echo "=== Deleting old PVs and PVCs ==="
while IFS='|' read -r PV PATH_VAL CAP NS NAME; do
  kubectl delete pv $PV --force --grace-period=0 2>/dev/null || true
  kubectl delete pvc $NAME -n $NS --force --grace-period=0 2>/dev/null || true
done < /tmp/pv-info.txt

sleep 3

echo "=== Recreating PVs with correct nodeAffinity ($TARGET_NODE) ==="
while IFS='|' read -r PV PATH_VAL CAP NS NAME; do
  echo "Creating $PV → $NS/$NAME"
  kubectl apply -f - <<EOF
apiVersion: v1
kind: PersistentVolume
metadata:
  annotations:
    local.path.provisioner/selected-node: $TARGET_NODE
    pv.kubernetes.io/provisioned-by: rancher.io/local-path
  name: $PV
spec:
  accessModes:
  - ReadWriteOnce
  capacity:
    storage: $CAP
  claimRef:
    apiVersion: v1
    kind: PersistentVolumeClaim
    name: $NAME
    namespace: $NS
  local:
    path: $PATH_VAL
  nodeAffinity:
    required:
      nodeSelectorTerms:
      - matchExpressions:
        - key: kubernetes.io/hostname
          operator: In
          values:
          - $TARGET_NODE
  persistentVolumeReclaimPolicy: Retain
  storageClassName: local-path
  volumeMode: Filesystem
EOF
done < /tmp/pv-info.txt

echo "=== Done. Verifying PVC bindings ==="
while IFS='|' read -r PV PATH_VAL CAP NS NAME; do
  STATUS=$(kubectl get pvc $NAME -n $NS -o jsonpath='{.status.phase}' 2>/dev/null || echo "NotFound")
  echo "$NS/$NAME: $STATUS"
done < /tmp/pv-info.txt
```

Sử dụng:

```bash
chmod +x /tmp/fix-pv-nodeaffinity.sh
bash /tmp/fix-pv-nodeaffinity.sh fedora
```

---

## 6. Kết quả sau khi fix

```
=== YAS namespace (20/20 Running) ===
backoffice-bff    Running
backoffice-ui     Running
cart              Running
customer          Running
inventory         Running
location          Running
media             Running
order             Running
product           Running
promotion         Running
rating            Running
recommendation    Running  ← trước CrashLoopBackOff (Kafka)
search            Running  ← trước CrashLoopBackOff (ES)
storefront-bff    Running
storefront-ui     Running
swagger-ui        Running
tax               Running
webhook           Running  ← trước CrashLoopBackOff (Kafka)
yas-reloader      Running
sampledata        Running

=== Infrastructure ===
elasticsearch-standalone-0   Running  ← trước Pending
elasticsearch-es-node-0      Running  ← trước Pending
kafka-cluster-dual-role-0    Running  ← trước Pending
redis-master-0               Running
redis-replicas-0/1/2         Running
zookeeper-0                  Running
keycloak-0                   Running
postgresql-0                 Running
pgadmin                      Running
```

---

## 7. Phòng tránh trong tương lai

### 7.1 Pin CoreDNS lên control plane

```bash
kubectl patch deployment coredns -n kube-system --type=merge -p '{
  "spec": {"template": {"spec": {"nodeSelector": {"kubernetes.io/hostname": "fedora"}}}}
}'
```

Đảm bảo DNS không bị ảnh hưởng khi worker mất kết nối.

### 7.2 Pin Keycloak lên control plane

```bash
kubectl patch statefulset keycloak -n keycloak --type=merge -p '{
  "spec": {"template": {"spec": {"nodeSelector": {"kubernetes.io/hostname": "fedora"}}}}
}'
```

Keycloak là critical dependency của tất cả app — phải luôn chạy trên fedora.

### 7.3 Pin PostgreSQL lên control plane

Tương tự Keycloak, PostgreSQL dùng local-path PV trên fedora → không thể reschedule sang worker dù muốn.

### 7.4 Dùng taint/toleration để kiểm soát scheduling

```bash
# Worker chỉ nhận pod có toleration
kubectl taint node quoctan dedicated=worker:NoSchedule

# Bỏ master taint để fedora nhận pod thường
kubectl taint node fedora node-role.kubernetes.io/master- 2>/dev/null || true
```

### 7.5 Kiểm tra PV nodeAffinity sau khi deploy lần đầu

```bash
# Phát hiện sớm PV có nodeAffinity sai
kubectl get pv --no-headers \
  -o custom-columns="NAME:.metadata.name,NODE:.spec.nodeAffinity.required.nodeSelectorTerms[0].matchExpressions[0].values[0]" \
  | grep -v "fedora\|quoctan\|<none>"
# → Không có output = OK
```

### 7.6 Backup CoreDNS ConfigMap

```bash
kubectl get configmap coredns -n kube-system -o yaml > /tmp/coredns-backup.yaml
```

Lưu lại sau mỗi lần sửa để khôi phục nhanh nếu cần.
