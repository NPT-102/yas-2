# Hướng dẫn: Triển khai tối ưu — chỉ 13 service thiết yếu (từ đầu đến cuối)

> **Dùng khi:** Cluster hoàn toàn mới (`minikube delete` xong), muốn tiết kiệm RAM bằng cách chỉ deploy 13 services cần thiết.
> **Thời gian tổng:** ~30-40 phút (phần lớn là chờ pods khởi động).
> **Yêu cầu máy:** Tối thiểu 4 CPU + 8GB RAM. Khuyến nghị 6 CPU + 12GB RAM.

**13 services được deploy:**

| Service | Vai trò |
|---------|---------|
| product | Sản phẩm — trung tâm của shop |
| cart | Giỏ hàng — demo flow mua hàng |
| order | Đơn hàng — demo flow đặt hàng, test retry policy |
| customer | Thông tin khách hàng |
| inventory | Kho hàng — order phụ thuộc |
| tax | Thuế — order phụ thuộc, demo VirtualService retry |
| media | Upload hình ảnh sản phẩm |
| search | Tìm kiếm — phụ thuộc product, demo AuthorizationPolicy |
| storefront-bff | BFF cho giao diện người dùng |
| storefront-ui | Giao diện cửa hàng — demo cho giảng viên |
| backoffice-bff | BFF cho quản trị |
| backoffice-ui | Giao diện quản trị |
| swagger-ui | API docs |

**Bỏ qua (không deploy):** location, payment, payment-paypal, promotion, rating, recommendation, webhook, sampledata.

**File script mới:** `k8s/deploy/deploy-yas-minimal.sh` — dùng thay `deploy-yas-applications.sh`.

---

## Mục lục

1. [Bước 1: Cài công cụ cần thiết](#bước-1-cài-công-cụ-cần-thiết)
2. [Bước 2: Tạo cluster Minikube](#bước-2-tạo-cluster-minikube)
3. [Bước 3: Tăng giới hạn inotify](#bước-3-tăng-giới-hạn-inotify)
4. [Bước 4: Cài Ingress Controller](#bước-4-cài-ingress-controller)
5. [Bước 5: Chạy setup-cluster.sh (Infrastructure)](#bước-5-chạy-setup-clustersh-infrastructure)
6. [Bước 6: Chờ infrastructure pods Ready](#bước-6-chờ-infrastructure-pods-ready)
7. [Bước 7: Fix Kafka broker (nếu cần)](#bước-7-fix-kafka-broker-nếu-cần)
8. [Bước 8: Deploy Elasticsearch standalone](#bước-8-deploy-elasticsearch-standalone)
9. [Bước 9: Cài Keycloak](#bước-9-cài-keycloak)
10. [Bước 10: Kiểm tra Keycloak Realm](#bước-10-kiểm-tra-keycloak-realm)
11. [Bước 11: Cài Redis](#bước-11-cài-redis)
12. [Bước 12: Deploy YAS Configuration](#bước-12-deploy-yas-configuration)
13. [Bước 13: Deploy 13 services (Minimal)](#bước-13-deploy-13-services-minimal)
14. [Bước 14: Cấu hình /etc/hosts](#bước-14-cấu-hình-etchosts)
15. [Bước 15: Kiểm tra tổng thể](#bước-15-kiểm-tra-tổng-thể)
16. [Bước 16: (Tùy chọn) Cài Istio Service Mesh](#bước-16-tùy-chọn-cài-istio-service-mesh)
17. [Bước 17: (Tùy chọn) Cài ArgoCD](#bước-17-tùy-chọn-cài-argocd)
18. [Troubleshooting](#troubleshooting)
19. [Tổng kết thứ tự chạy (Quick Reference)](#tổng-kết-thứ-tự-chạy-quick-reference)

---

## Bước 1: Cài công cụ cần thiết

Script `setup-cluster.sh` cần `helm` và `yq`. Kiểm tra:

```bash
helm version && yq --version
```

**Nếu thiếu `helm`:**
```bash
curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
```

**Nếu thiếu `yq`:**
```bash
sudo wget -qO /usr/local/bin/yq https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64
sudo chmod +x /usr/local/bin/yq
```

**✅ Kết quả đúng:**
```
version.BuildInfo{Version:"v3.x.x", ...}
yq (https://github.com/mikefarah/yq/) version v4.x.x
```

---

## Bước 2: Tạo cluster Minikube

> **Bỏ qua nếu đã có cluster đang chạy** (kiểm tra: `minikube status`).

```bash
minikube start --nodes=2 --driver=docker --cpus=4 --memory=8192
```

**Chờ ~1-2 phút.** Kiểm tra:

```bash
kubectl get nodes
```

**✅ Kết quả đúng:**
```
NAME           STATUS   ROLES           AGE   VERSION
minikube       Ready    control-plane   2m    v1.35.1
minikube-m02   Ready    <none>          1m    v1.35.1
```

**❌ Nếu minikube-m02 không hiện:** `docker start minikube-m02 && sleep 10 && kubectl get nodes`.

---

## Bước 3: Tăng giới hạn inotify

```bash
docker exec minikube sysctl -w fs.inotify.max_user_watches=524288 fs.inotify.max_user_instances=512
docker exec minikube-m02 sysctl -w fs.inotify.max_user_watches=524288 fs.inotify.max_user_instances=512
```

**✅ Kết quả đúng:**
```
fs.inotify.max_user_watches = 524288
fs.inotify.max_user_instances = 512
```

> ⚠️ Cấu hình này **không persist** qua minikube stop/start. Phải chạy lại mỗi lần bật cluster.

---

## Bước 4: Cài Ingress Controller

```bash
minikube addons enable ingress
```

Chờ controller Ready (~1 phút):

```bash
kubectl get pods -n ingress-nginx -w
```

**✅ Kết quả đúng** (nhấn Ctrl+C khi thấy):
```
ingress-nginx-controller-xxxxx   1/1   Running   0   1m
```

---

## Bước 5: Chạy setup-cluster.sh (Infrastructure)

Script cài: Istio, PostgreSQL, Kafka, Elasticsearch operator, Zookeeper.

```bash
cd /home/npt102/gcp/Devops2/yas/k8s/deploy
./setup-cluster.sh
```

> ⏱ **Mất ~5-10 phút.** Script yêu cầu `sudo` cho sysctl.

**Sau khi xong, kiểm tra namespaces:**

```bash
kubectl get ns
```

**✅ Phải thấy TẤT CẢ:**
```
elasticsearch     Active
ingress-nginx     Active
istio-system      Active
kafka             Active
postgres          Active
zookeeper         Active
```

---

## Bước 6: Chờ infrastructure pods Ready

```bash
echo "=== postgres ===" && kubectl get pods -n postgres
echo "=== kafka ===" && kubectl get pods -n kafka
echo "=== elasticsearch ===" && kubectl get pods -n elasticsearch
echo "=== istio-system ===" && kubectl get pods -n istio-system
```

**✅ Mong đợi:**
```
=== postgres ===
pgadmin-xxxxx            1/1   Running   0   10m
postgres-operator-xxxxx  1/1   Running   0   12m
postgresql-0             1/1   Running   0   10m

=== kafka ===
akhq-xxxxx                                    1/1   Running   0   8m
kafka-cluster-dual-role-0                     1/1   Running   0   8m
kafka-cluster-entity-operator-xxxxx           2/2   Running   0   5m
strimzi-cluster-operator-xxxxx                1/1   Running   0   10m

=== elasticsearch ===
elastic-operator-0   1/1   Running   0   8m

=== istio-system ===
istio-egressgateway-xxxxx    1/1   Running   0   10m
istio-ingressgateway-xxxxx   1/1   Running   0   10m
istiod-xxxxx                 1/1   Running   0   10m
```

> Nếu pods vẫn ContainerCreating → chờ thêm 2-3 phút (đang pull image).

---

## Bước 7: Fix Kafka broker (nếu cần)

> **Bỏ qua nếu `kafka-cluster-dual-role-0` đã 1/1 Running.**

```bash
kubectl logs kafka-cluster-dual-role-0 -n kafka --tail=20
```

**Nếu thấy `Permission denied`:**

```bash
bash /home/npt102/gcp/Devops2/yas/k8s/deploy/fix-kafka-permissions.sh
kubectl delete pod kafka-cluster-dual-role-0 -n kafka
kubectl get pods -n kafka -w
```

**Tắt Debezium Connect** (lỗi đã biết — Kafka 3.x client vs 4.x server):

```bash
kubectl scale kafkaconnect/debezium-connect-cluster --replicas=0 -n kafka 2>/dev/null || true
```

---

## Bước 8: Deploy Elasticsearch standalone

ECK operator không tương thích ES 9.x. Dùng standalone StatefulSet:

```bash
cd /home/npt102/gcp/Devops2/yas/k8s/deploy
kubectl apply -f elasticsearch/es-standalone.yaml -n elasticsearch
```

Chờ pod Ready (~1-2 phút):

```bash
kubectl get pods -n elasticsearch -w
```

**✅ Kết quả đúng:**
```
elastic-operator-0           1/1   Running   0   15m
elasticsearch-standalone-0   1/1   Running   0   1m
```

**Kiểm tra ES hoạt động:**

```bash
kubectl exec -n elasticsearch elasticsearch-standalone-0 -- \
  curl -s http://localhost:9200/_cluster/health
```

**✅** `status` phải là `green` hoặc `yellow`.

---

## Bước 9: Cài Keycloak

> **Cần PostgreSQL Running trước!** Kiểm tra: `kubectl get pods -n postgres | grep postgresql-0` — phải 1/1 Running.

```bash
cd /home/npt102/gcp/Devops2/yas/k8s/deploy
./setup-keycloak.sh
```

Chờ Keycloak Ready (~3-5 phút):

```bash
kubectl get pods -n keycloak -w
```

**✅ Kết quả đúng:**
```
keycloak-0               1/1   Running   0   3m
keycloak-operator-xxxxx  1/1   Running   0   3m
```

> **❌ Nếu keycloak-0 CrashLoopBackOff:** PostgreSQL chưa sẵn sàng. Fix: `kubectl delete pod keycloak-0 -n keycloak` và chờ.

---

## Bước 10: Kiểm tra Keycloak Realm

Helm chart tự import realm `Yas`. Kiểm tra:

```bash
kubectl logs -n keycloak -l app=keycloak-realm-import --tail=5
```

**✅ Kết quả đúng:**
```
... Realm 'Yas' imported
```

**Nếu realm chưa import tự động:**

```bash
# Copy file realm vào pod
cat /home/npt102/gcp/Devops2/yas/identity/realm-export.json | \
  kubectl exec -i -n keycloak keycloak-0 -- sh -c "cat > /tmp/realm-export.json"

# Login admin
kubectl exec -n keycloak keycloak-0 -- /opt/keycloak/bin/kcadm.sh config credentials \
  --server http://localhost:8080 --realm master --user admin --password admin

# Tạo realm rồi import
kubectl exec -n keycloak keycloak-0 -- /opt/keycloak/bin/kcadm.sh create realms \
  -s realm=Yas -s enabled=true
kubectl exec -n keycloak keycloak-0 -- /opt/keycloak/bin/kcadm.sh create partialImport \
  -r Yas -s ifResourceExists=SKIP -f /tmp/realm-export.json
```

---

## Bước 11: Cài Redis

```bash
cd /home/npt102/gcp/Devops2/yas/k8s/deploy
./setup-redis.sh
```

Chờ Redis Ready (~1-2 phút):

```bash
kubectl get pods -n redis -w
```

**✅ Kết quả đúng:**
```
redis-master-0     1/1   Running   0   1m
redis-replicas-0   1/1   Running   0   1m
```

> **❌ Nếu Redis bị `CrashLoopBackOff` (Permission denied: appendonlydir):**
>
> Fix permissions bằng pod tạm:
> ```bash
> cat <<'EOF' | kubectl apply -f -
> apiVersion: v1
> kind: Pod
> metadata:
>   name: fix-redis-permissions
>   namespace: redis
> spec:
>   restartPolicy: Never
>   securityContext:
>     runAsUser: 0
>   containers:
>     - name: fix-perms
>       image: registry-1.docker.io/bitnami/redis:latest
>       command: ["/bin/bash","-c"]
>       args:
>         - |
>           chown -R 1001:0 /data-master; chmod -R 775 /data-master;
>           chown -R 1001:0 /data-replicas; chmod -R 775 /data-replicas;
>           echo "Done"
>       volumeMounts:
>         - name: master
>           mountPath: /data-master
>         - name: replicas
>           mountPath: /data-replicas
>   volumes:
>     - name: master
>       persistentVolumeClaim:
>         claimName: redis-data-redis-master-0
>     - name: replicas
>       persistentVolumeClaim:
>         claimName: redis-data-redis-replicas-0
> EOF
>
> kubectl wait --for=jsonpath='{.status.phase}'=Succeeded \
>   pod/fix-redis-permissions -n redis --timeout=60s || true
> kubectl delete pod fix-redis-permissions -n redis --ignore-not-found
> kubectl delete pod redis-master-0 redis-replicas-0 -n redis --ignore-not-found
> kubectl get pods -n redis -w
> ```

---

## Bước 12: Deploy YAS Configuration

Deploy ConfigMaps và Secrets cho tất cả microservices:

```bash
cd /home/npt102/gcp/Devops2/yas/k8s/deploy
./deploy-yas-configuration.sh
```

**✅ Kết quả đúng:**
```
Release "yas-configuration" does not exist. Installing it now.
NAME: yas-configuration
NAMESPACE: yas
STATUS: deployed
```

Kiểm tra:

```bash
kubectl get cm -n yas --no-headers | wc -l
kubectl get secret -n yas --no-headers | wc -l
```

**✅** ConfigMaps: >10, Secrets: >5.

---

## Bước 13: Deploy 13 services (Minimal)

**Đây là bước khác biệt chính so với `CAI-DAT-TU-DAU.md`.**

Dùng script `deploy-yas-minimal.sh` thay vì `deploy-yas-applications.sh`:

```bash
cd /home/npt102/gcp/Devops2/yas/k8s/deploy
./deploy-yas-minimal.sh
```

> ⏱ **Mất ~15-20 phút** (ít hơn ~10 phút so với deploy đầy đủ 21 services).
>
> Script deploy theo thứ tự:
> 1. backoffice-bff + backoffice-ui (chờ 60s)
> 2. storefront-bff + storefront-ui (chờ 60s)
> 3. swagger-ui (chờ 20s)
> 4. 8 backend services: product, cart, order, customer, inventory, tax, media, search (mỗi service chờ 60s)

**Theo dõi tiến trình (terminal khác):**

```bash
watch -n 10 'echo "Running:" && kubectl get pods -n yas --no-headers | grep -c Running && echo "Total:" && kubectl get pods -n yas --no-headers | wc -l && echo "" && kubectl get pods -n yas --no-headers | grep -Ev Running'
```

**✅ Kết quả đúng khi script chạy xong:**

```bash
kubectl get pods -n yas
```

```
NAME                              READY   STATUS    RESTARTS   AGE
backoffice-bff-xxxxx              1/1     Running   0          15m
backoffice-ui-xxxxx               1/1     Running   0          15m
cart-xxxxx                        1/1     Running   0          10m
customer-xxxxx                    1/1     Running   0          9m
inventory-xxxxx                   1/1     Running   0          8m
media-xxxxx                       1/1     Running   0          6m
order-xxxxx                       1/1     Running   0          7m
product-xxxxx                     1/1     Running   0          12m
search-xxxxx                      1/1     Running   0          3m
storefront-bff-xxxxx              1/1     Running   0          14m
storefront-ui-xxxxx               1/1     Running   0          14m
swagger-ui-xxxxx                  1/1     Running   0          12m
tax-xxxxx                         1/1     Running   0          5m
```

**Tổng: 13 pods Running.** So sánh: deploy đầy đủ có 21 pods → tiết kiệm ~40% RAM.

**⚠️ Fix lỗi storefront 500 (bắt buộc):**

Storefront-bff hardcode hostname `storefront-nextjs` trong source code, nhưng Helm chart tạo service tên `storefront-ui`. Tạo ExternalName service alias:

```bash
cat <<'EOF' | kubectl apply -f -
apiVersion: v1
kind: Service
metadata:
  name: storefront-nextjs
  namespace: yas
spec:
  type: ExternalName
  externalName: storefront-ui.yas.svc.cluster.local
EOF
```

**✅** Không cần restart pod. Truy cập `http://storefront.yas.local.com` sẽ hoạt động ngay.

---

## Bước 14: Cấu hình /etc/hosts

```bash
MINIKUBE_IP=$(minikube ip)
echo "Minikube IP: $MINIKUBE_IP"

sudo sed -i '/yas\.local\.com/d' /etc/hosts
sudo bash -c "cat >> /etc/hosts << EOF
$MINIKUBE_IP yas.local.com api.yas.local.com backoffice.yas.local.com storefront.yas.local.com
$MINIKUBE_IP identity.yas.local.com pgadmin.yas.local.com
$MINIKUBE_IP kibana.yas.local.com akhq.yas.local.com
EOF"
```

Kiểm tra:

```bash
grep yas /etc/hosts
```

---

## Bước 15: Kiểm tra tổng thể

### 15a. Script kiểm tra cluster

```bash
echo "========== NODES =========="
kubectl get nodes
echo ""

echo "========== INFRASTRUCTURE =========="
for ns in postgres kafka elasticsearch keycloak redis ingress-nginx istio-system; do
  running=$(kubectl get pods -n $ns --no-headers 2>/dev/null | grep -c Running || echo 0)
  total=$(kubectl get pods -n $ns --no-headers 2>/dev/null | wc -l || echo 0)
  printf "  %-20s %s/%s Running\n" "$ns" "$running" "$total"
done
echo ""

echo "========== YAS (13 services minimal) =========="
running=$(kubectl get pods -n yas --no-headers | grep -c Running)
total=$(kubectl get pods -n yas --no-headers | wc -l)
echo "  yas: $running/$total Running"
echo ""

echo "========== PROBLEM PODS =========="
problems=$(kubectl get pods -A --no-headers | grep -Ev "Running|Completed" | head -10)
if [ -z "$problems" ]; then
  echo "  Không có pod nào bị lỗi!"
else
  echo "$problems"
fi
```

**✅ Kết quả mong đợi:**
```
========== INFRASTRUCTURE ==========
  postgres             3/3 Running
  kafka                3/4 Running       (Debezium Error — đã tắt)
  elasticsearch        2/2 Running
  keycloak             2/2 Running
  redis                2/2 Running
  ingress-nginx        1/3 Running       (2 Completed admission jobs)
  istio-system         3/3 Running

========== YAS (13 services minimal) ==========
  yas: 13/13 Running
```

### 15b. Truy cập web kiểm tra

| URL | Mong đợi |
|-----|----------|
| http://storefront.yas.local.com | Trang storefront |
| http://backoffice.yas.local.com | Trang admin |
| http://identity.yas.local.com | Keycloak login (admin / admin) |
| http://pgadmin.yas.local.com | pgAdmin |
| http://akhq.yas.local.com | AKHQ Kafka |
| http://api.yas.local.com/swagger-ui | Swagger API docs |

---

## Bước 16: (Tùy chọn) Cài Istio Service Mesh

> Istio đã được cài tự động bởi `setup-cluster.sh`. Bước này chỉ cần nếu muốn bật sidecar injection và apply policies.

### 16a. Enable sidecar injection

```bash
kubectl label namespace yas istio-injection=enabled --overwrite
kubectl rollout restart deployment -n yas
```

> ⏱ **Chờ 3-5 phút** cho pods restart. Sau đó kiểm tra:

```bash
kubectl get pods -n yas | head -5
```

```
cart-xxxxx     2/2   Running   ← 2/2 = có sidecar (app + istio-proxy)
```

### 16b. Apply Istio policies

```bash
cd /home/npt102/gcp/Devops2/yas

# mTLS STRICT
kubectl apply -f istio/peer-authentication.yaml

# DestinationRule
kubectl apply -f istio/destination-rule.yaml

# Authorization Policies
kubectl apply -f istio/authorization-policy.yaml

# VirtualService Retry
kubectl apply -f istio/virtual-service-retry.yaml
```

**Kiểm tra:**

```bash
echo "PeerAuth:" && kubectl get peerauthentication -n yas
echo "DestRule:" && kubectl get destinationrule -n yas
echo "AuthPolicy:" && kubectl get authorizationpolicy -n yas
echo "VirtualSvc:" && kubectl get virtualservice -n yas
```

---

## Bước 17: (Tùy chọn) Cài ArgoCD

> Chỉ cần nếu muốn dùng GitOps. **Không bắt buộc** cho flow minimal.

### 17a. Cài đặt ArgoCD

```bash
kubectl create namespace argocd
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

# Chờ ArgoCD khởi động
kubectl wait -n argocd --for=condition=Available deployment/argocd-server --timeout=5m || true

# Lấy mật khẩu admin
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d && echo
```

### 17b. Tạo Ingress để truy cập ArgoCD qua browser

ArgoCD server mặc định là ClusterIP — không expose ra ngoài. Cần tạo Ingress:

```bash
cat <<'EOF' | kubectl apply -f -
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: argocd-server-ingress
  namespace: argocd
  annotations:
    nginx.ingress.kubernetes.io/ssl-passthrough: "true"
    nginx.ingress.kubernetes.io/backend-protocol: "HTTPS"
spec:
  ingressClassName: nginx
  rules:
  - host: argocd.yas.local.com
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: argocd-server
            port:
              number: 443
EOF
```

Thêm domain vào `/etc/hosts`:

```bash
MINIKUBE_IP=$(minikube ip)
sudo bash -c "echo '$MINIKUBE_IP argocd.yas.local.com' >> /etc/hosts"
```

**✅** Truy cập: **https://argocd.yas.local.com** (accept self-signed cert warning).
- User: `admin`
- Password: lấy từ lệnh ở bước 17a

### 17c. Tạo AppProject `yas`

Application manifests tham chiếu `project: yas` — cần tạo trước khi apply:

```bash
cat <<'EOF' | kubectl apply -f -
apiVersion: argoproj.io/v1alpha1
kind: AppProject
metadata:
  name: yas
  namespace: argocd
spec:
  description: YAS microservices project
  sourceRepos:
    - '*'
  destinations:
    - namespace: '*'
      server: https://kubernetes.default.svc
  clusterResourceWhitelist:
    - group: '*'
      kind: '*'
EOF
```

### 17d. (Tùy) Apply Application manifests

```bash
kubectl apply -n argocd -f argocd/applications/dev-app.yaml
kubectl apply -n argocd -f argocd/applications/staging-app.yaml
```

---

## Troubleshooting

### Redis bị Permission Denied (appendonlydir)

Log: `Can't open or create append-only dir appendonlydir: Permission denied`

Fix: Xem hướng dẫn chi tiết tại [Bước 11](#bước-11-cài-redis).

### Kafka broker CrashLoopBackOff

Log: `Permission denied` hoặc `cannot write`

Fix: Chạy `bash k8s/deploy/fix-kafka-permissions.sh` → xóa pod. Xem [Bước 7](#bước-7-fix-kafka-broker-nếu-cần).

### Debezium Connect crash

Lỗi đã biết (Kafka 3.x client vs 4.x server). Tắt: `kubectl scale kafkaconnect/debezium-connect-cluster --replicas=0 -n kafka`

### Elasticsearch service mất

```bash
kubectl apply -f k8s/deploy/elasticsearch/es-standalone.yaml -n elasticsearch
```

### Pods CrashLoopBackOff sau khi bật Istio

Startup storm — chờ 3-5 phút tự recovery. Nếu quá 10 phút:

```bash
kubectl delete pod keycloak-0 -n keycloak   # Restart Keycloak trước
sleep 60
kubectl rollout restart deployment/storefront-bff deployment/backoffice-bff -n yas
```

### Storefront 500 — Whitelabel Error Page

Log: `java.net.UnknownHostException: Failed to resolve 'storefront-nextjs'`

Nguyên nhân: storefront-bff hardcode hostname `storefront-nextjs` nhưng Helm chart tạo service tên `storefront-ui`.

Fix: Tạo ExternalName service alias. Xem [Bước 13](#bước-13-deploy-13-services-minimal).

### Muốn thêm service sau

Nếu sau này cần thêm service đã bỏ (ví dụ `promotion`):

```bash
cd /home/npt102/gcp/Devops2/yas/k8s/deploy
DOMAIN=$(yq -r '.domain' ./cluster-config.yaml)
helm dependency build ../charts/promotion
helm upgrade --install promotion ../charts/promotion \
  --namespace yas --set backend.ingress.host="api.$DOMAIN"
```

### Muốn deploy đầy đủ 21 services

Chạy script gốc:

```bash
cd /home/npt102/gcp/Devops2/yas/k8s/deploy
./deploy-yas-applications.sh
```

---

## Tổng kết thứ tự chạy (Quick Reference)

```
 1. helm version && yq --version           ← Kiểm tra tools
 2. minikube start --nodes=2               ← Cluster
 3. docker exec ... sysctl inotify         ← Fix limits
 4. minikube addons enable ingress         ← Ingress
 5. ./setup-cluster.sh                     ← Infrastructure (~10 phút)
 6. (chờ pods Ready)                       ← ~5 phút
 7. fix-kafka-permissions.sh (nếu cần)     ← Fix Kafka
 8. kubectl apply -f es-standalone.yaml    ← Elasticsearch
 9. ./setup-keycloak.sh                    ← Keycloak (~3 phút)
10. Kiểm tra Keycloak realm                ← Verify
11. ./setup-redis.sh                       ← Redis
12. ./deploy-yas-configuration.sh          ← ConfigMaps + Secrets
13. ./deploy-yas-minimal.sh                ← 13 services (~15 phút)
14. Sửa /etc/hosts                         ← Domain mapping
15. Kiểm tra tổng thể                      ← Verify
16. (Tùy) Istio sidecar + policies         ← Service mesh
17. (Tùy) ArgoCD                           ← GitOps
```

**Tổng thời gian: ~30-40 phút.**

---

## File tham khảo

| File | Mô tả |
|------|-------|
| `project-docs/HUONG-DAN-TRIEN-KHAI-TOI-UU.md` | Hướng dẫn này |
| `project-docs/CAI-DAT-TU-DAU.md` | Hướng dẫn đầy đủ (21 services) |
| `k8s/deploy/deploy-yas-minimal.sh` | Script deploy 13 services |
| `k8s/deploy/deploy-yas-applications.sh` | Script deploy đầy đủ 21 services |
| `k8s/deploy/setup-cluster.sh` | Script cài infrastructure |
| `k8s/deploy/setup-keycloak.sh` | Script cài Keycloak |
| `k8s/deploy/setup-redis.sh` | Script cài Redis |
| `k8s/deploy/deploy-yas-configuration.sh` | Script deploy ConfigMaps/Secrets |
| `k8s/deploy/fix-kafka-permissions.sh` | Fix Kafka volume permissions |
| `k8s/deploy/elasticsearch/es-standalone.yaml` | ES standalone StatefulSet |
