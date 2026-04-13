# Hướng dẫn Khôi phục / Khởi động lại Cluster

> **Thông tin cluster:** Minikube v1.38.1 · K8s v1.35.1 · Docker driver · 2 nodes (minikube + minikube-m02)  
> **IP:** Control plane `192.168.49.2` · Worker `192.168.49.3`  
> **Tài nguyên ước tính:** Cluster chạy đầy đủ cần ~20GB RAM. Khi tắt minikube, giải phóng gần toàn bộ.  
> **Đường dẫn project:** `/home/npt102/gcp/Devops2/yas`  
> **Đường dẫn deploy scripts:** `/home/npt102/gcp/Devops2/yas/k8s/deploy`  
> **Đường dẫn runner:** `/home/npt102/gcp/Devops2/actions-runner`

---

## Mục lục

- [Trường hợp 1: Tắt cluster để giải phóng RAM](#trường-hợp-1-tắt-cluster-để-giải-phóng-ram)
- [Trường hợp 2: Khôi phục sau `minikube stop` (phổ biến nhất)](#trường-hợp-2-khôi-phục-sau-minikube-stop-phổ-biến-nhất)
  - [Bước 1–5: Khởi động cluster + fix DNS + inotify](#bước-1-khởi-động-minikube)
  - [Bước 6: Xử lý Kafka broker không tự phục hồi](#bước-6-xử-lý-kafka-broker-không-tự-phục-hồi)
  - [Bước 7: Scale lại namespace đã tắt trước đó](#bước-7-scale-lại-namespace-đã-tắt-trước-đó-nếu-có)
  - [Bước 8–9: Verification checklist](#bước-8-verification-checklist)
- [Trường hợp 3: Khôi phục sau reboot/restart máy](#trường-hợp-3-khôi-phục-sau-rebootrestart-máy)
- [Trường hợp 4: Cluster hỏng nặng — Xóa và cài lại từ đầu](#trường-hợp-4-cluster-hỏng-nặng--xóa-và-cài-lại-từ-đầu)
- [Trường hợp 5: Chỉ khôi phục 1 namespace cụ thể](#trường-hợp-5-chỉ-khôi-phục-1-namespace-cụ-thể)
- [Trường hợp 6: Bật lại GitHub Actions Runner](#trường-hợp-6-bật-lại-github-actions-runner)
- [Script tự động khôi phục (Quick Recovery)](#script-tự-động-khôi-phục-quick-recovery)
- [Bảng số lượng pods mong đợi theo namespace](#bảng-số-lượng-pods-mong-đợi-theo-namespace)
- [Bảng lỗi thường gặp](#bảng-lỗi-thường-gặp)
- [Thông tin cấu hình cluster](#thông-tin-cấu-hình-cluster)

---

## Trường hợp 1: Tắt cluster để giải phóng RAM

> **Khi nào dùng:** Nghỉ ngơi, máy lag, không dùng đồ án tạm thời.  
> **Ảnh hưởng:** Tất cả pods dừng, giải phóng ~19GB RAM. Dữ liệu PersistentVolume vẫn giữ.

### Bước 1: (Tùy chọn) Ghi nhớ trạng thái hiện tại

Trước khi tắt, ghi lại xem namespace nào đang bật, namespace nào đã scale to 0, 
để khi khôi phục biết cần bật lại cái gì:

```bash
# Xem tổng quan nhanh
for ns in dev developer staging yas argocd istio-system; do
  count=$(kubectl get pods -n $ns --no-headers 2>/dev/null | grep -c Running || echo 0)
  echo "$ns: $count running pods"
done
```

Kết quả ví dụ (trạng thái trước khi tắt lần gần nhất):
```
dev: 20 running pods          ← Đang active (20/21, payment-paypal bị lỗi)
developer: 0 running pods     ← Không có deployment
staging: 0 running pods       ← Chưa deploy
yas: 0 running pods           ← Đã scale to 0 để tiết kiệm RAM
argocd: 0 running pods        ← Đã scale to 0
istio-system: 0 running pods  ← Đã scale to 0
```

### Bước 2: Tắt runner (nếu đang chạy)

```bash
# Kiểm tra runner
ps aux | grep Runner.Listener | grep -v grep

# Nếu đang chạy → tắt
pkill -f "Runner.Listener" 2>/dev/null
```

### Bước 3: Tắt minikube

```bash
minikube stop
```

### Bước 4: Xác nhận đã tắt

```bash
# Không có container minikube nào đang chạy
docker ps --filter "name=minikube" --format "{{.Names}}: {{.Status}}"
# → Không output gì, HOẶC status = "Exited"

# RAM đã giải phóng
free -h
# Mem used nên giảm ~15-19GB so với khi cluster chạy
```

**CẢNH BÁO quan trọng:**
- **KHÔNG chạy** `minikube delete` — lệnh đó **xóa toàn bộ cluster + data** vĩnh viễn
- Dữ liệu PostgreSQL, Kafka, Elasticsearch vẫn nằm trong Docker volumes → an toàn
- Runner GitHub Actions sẽ hiện offline trên GitHub → bình thường, workflow sẽ queue chờ

**Khi muốn bật lại:** Xem [Trường hợp 2](#trường-hợp-2-khôi-phục-sau-minikube-stop-phổ-biến-nhất).

---

## Trường hợp 2: Khôi phục sau `minikube stop` (phổ biến nhất)

> **Khi nào dùng:** Đã tắt bằng `minikube stop`, muốn bật lại để tiếp tục làm việc.  
> **Thời gian:** ~5-10 phút (cluster ready sau 2 phút, pods ready thêm 3-8 phút).  
> **Yêu cầu:** Docker daemon đang chạy (`systemctl is-active docker` → `active`).

### Bước 1: Khởi động minikube

```bash
minikube start
```

Lệnh này tự động:
- Start Docker container `minikube` (control plane) 
- Start Docker container `minikube-m02` (worker)
- Restore kubelet, API server, etcd, scheduler, controller-manager
- Tất cả PersistentVolume data vẫn nguyên vẹn

**Nếu worker không lên** (chỉ thấy 1 node khi `kubectl get nodes`):
```bash
# Start thủ công container worker
docker start minikube-m02

# Chờ 10 giây rồi kiểm tra lại
sleep 10 && kubectl get nodes
```

Kiểm tra:
```bash
minikube status
```

**Kết quả mong đợi:**
```
minikube
type: Control Plane
host: Running
kubelet: Running
apiserver: Running
kubeconfig: Configured

minikube-m02
host: Running
kubelet: Running
```

**Nếu `apiserver: Stopped`:** Chờ thêm 30 giây, chạy lại `minikube status`. Nếu vẫn Stopped → `minikube start` lần nữa.

### Bước 2: Sửa /etc/hosts bên trong container (BẮT BUỘC)

**Đây là bước QUAN TRỌNG NHẤT.** Sau mỗi lần stop/start, file `/etc/hosts` bên trong 
Docker container bị reset → mất entry `control-plane.minikube.internal` → worker node 
không tìm được API server → `NotReady`.

```bash
# Thêm entry vào cả 2 node (idempotent — chạy lại không sao)
docker exec minikube bash -c \
  'grep -q "control-plane.minikube.internal" /etc/hosts || echo "192.168.49.2 control-plane.minikube.internal" >> /etc/hosts'

docker exec minikube-m02 bash -c \
  'grep -q "control-plane.minikube.internal" /etc/hosts || echo "192.168.49.2 control-plane.minikube.internal" >> /etc/hosts'
```

Kiểm tra:
```bash
docker exec minikube cat /etc/hosts | grep control-plane
docker exec minikube-m02 cat /etc/hosts | grep control-plane
# Cả 2 phải thấy: 192.168.49.2 control-plane.minikube.internal
```

### Bước 3: Tăng giới hạn inotify (BẮT BUỘC)

Cluster có nhiều pods → cần nhiều file watches. Giới hạn mặc định quá thấp → Promtail 
và kubelet sẽ crash với lỗi "too many open files".

```bash
# Control plane
docker exec minikube sysctl -w fs.inotify.max_user_watches=524288 fs.inotify.max_user_instances=512

# Worker
docker exec minikube-m02 sysctl -w fs.inotify.max_user_watches=524288 fs.inotify.max_user_instances=512
```

> **Lưu ý:** Cấu hình `sysctl` này **không persist** qua stop/start. Phải chạy lại mỗi lần bật cluster.

### Bước 4: Restart kubelet trên worker và chờ nodes Ready

Sau khi sửa /etc/hosts, worker cần restart kubelet để nhận DNS mới:

```bash
docker exec minikube-m02 systemctl restart kubelet

# Chờ 15 giây rồi kiểm tra
sleep 15
kubectl get nodes
```

**Kết quả mong đợi:**
```
NAME           STATUS   ROLES           AGE    VERSION
minikube       Ready    control-plane   ...    v1.35.1
minikube-m02   Ready    <none>          ...    v1.35.1
```

**Nếu worker vẫn NotReady** sau 30 giây:
```bash
# Kiểm tra lại /etc/hosts
docker exec minikube-m02 cat /etc/hosts | grep control-plane
# Nếu thiếu → chạy lại bước 2

# Restart kubelet lần nữa
docker exec minikube-m02 systemctl restart kubelet

# Chờ thêm 15 giây
sleep 15 && kubectl get nodes
```

### Bước 5: Sửa CoreDNS và kube-proxy (nếu cần)

Kiểm tra kube-system pods:
```bash
kubectl get pods -n kube-system
```

**Nếu CoreDNS bị 0/1 hoặc CrashLoopBackOff:**
```bash
kubectl delete pod -n kube-system -l k8s-app=kube-dns
sleep 10
kubectl get pods -n kube-system -l k8s-app=kube-dns
# Phải 1/1 Running
```

**Nếu service-to-service call bị timeout (iptables chưa sync):**
```bash
kubectl delete pod -n kube-system -l k8s-app=kube-proxy --field-selector spec.nodeName=minikube
sleep 5
kubectl get pods -n kube-system -l k8s-app=kube-proxy -o wide
# Phải 2 pods Running (1 mỗi node)
```

### Bước 6: Xử lý Kafka broker không tự phục hồi

> **Đây là vấn đề hay gặp nhất sau stop/start.** Kafka broker (KRaft mode) đôi khi 
> không tự recover do Strimzi operator chưa reconcile kịp hoặc PVC permissions bị sai.

**Chờ 2-3 phút rồi kiểm tra:**
```bash
kubectl get pods -n kafka
```

**Kịch bản A: Tất cả pods Running → OK, bỏ qua bước này.**
```
strimzi-cluster-operator-xxx              1/1   Running   0   2m
kafka-cluster-dual-role-0                 1/1   Running   0   2m
kafka-cluster-entity-operator-xxx         2/2   Running   0   1m
akhq-xxx                                  1/1   Running   0   2m
```

**Kịch bản B: `kafka-cluster-dual-role-0` bị `CrashLoopBackOff` hoặc `Error`**

Kiểm tra lý do:
```bash
kubectl logs kafka-cluster-dual-role-0 -n kafka --tail=30
```

**Nếu thấy lỗi permissions** (`Permission denied`, `cannot write to /var/lib/kafka`):
```bash
# Chạy script fix permissions
bash /home/npt102/gcp/Devops2/yas/k8s/deploy/fix-kafka-permissions.sh

# Xóa pod để recreate
kubectl delete pod kafka-cluster-dual-role-0 -n kafka

# Chờ pod mới Running (~1-2 phút)
kubectl get pods -n kafka -w
```

**Nếu thấy lỗi metadata** (`inconsistent cluster metadata`, `not enough voters`):
```bash
# Xóa pod — StatefulSet tự tạo lại
kubectl delete pod kafka-cluster-dual-role-0 -n kafka

# Nếu vẫn lỗi sau khi recreate → restart operator để reconcile lại
kubectl rollout restart deployment/strimzi-cluster-operator -n kafka
sleep 30
kubectl get pods -n kafka -w
```

**Kịch bản C: `kafka-cluster-dual-role-0` không tồn tại (chỉ có operator)**

Strimzi operator chưa reconcile hoặc bị lỗi:
```bash
# Kiểm tra operator logs
kubectl logs deploy/strimzi-cluster-operator -n kafka --tail=30

# Restart operator
kubectl rollout restart deployment/strimzi-cluster-operator -n kafka
sleep 60

# Kiểm tra broker đã được tạo lại chưa
kubectl get pods -n kafka
# Nếu vẫn thiếu broker → xem TH5a (khôi phục Kafka chi tiết)
```

**Kịch bản D: Debezium Connect pod `Error`**

Đây là lỗi đã biết (image Kafka 3.x không tương thích Kafka 4.1.0). **Bỏ qua** — không 
ảnh hưởng đồ án:
```bash
# (Tùy chọn) Scale to 0 để không thấy pod Error
kubectl scale kafkaconnect/debezium-connect-cluster --replicas=0 -n kafka 2>/dev/null
```

### Bước 7: Scale lại namespace đã tắt trước đó (nếu có)

> **Bước này chỉ cần nếu trước khi tắt cluster, bạn đã scale to 0 một số namespace** 
> để tiết kiệm RAM (yas, argocd, istio-system, v.v.). 
> Nếu tất cả namespace đều đang active trước khi tắt → bỏ qua bước này.

**Trạng thái trước khi tắt (lần gần nhất):**
- `dev`: 20/21 pods active (payment-paypal bị lỗi image — bình thường)
- `yas`, `argocd`, `istio-system`: đã scale to 0

**Scale lại `dev` (nếu cần):** Dev namespace tự phục hồi vì pods không bị scale to 0. 
Chỉ cần chờ 3-5 phút.

**Scale lại `yas` (nếu muốn):**
```bash
# Scale tất cả deployments trong yas lên 1 replica
kubectl get deploy -n yas --no-headers -o custom-columns=":metadata.name" | \
  xargs -I{} kubectl scale deploy/{} --replicas=1 -n yas

# Chờ pods Ready (~3-5 phút)
kubectl get pods -n yas -w
```

**Scale lại `istio-system` (nếu muốn dùng service mesh):**
```bash
kubectl get deploy -n istio-system --no-headers -o custom-columns=":metadata.name" | \
  xargs -I{} kubectl scale deploy/{} --replicas=1 -n istio-system

# Chờ istiod + gateway Running
kubectl get pods -n istio-system -w
```

**Scale lại `argocd` (nếu muốn dùng ArgoCD):**
```bash
kubectl get deploy -n argocd --no-headers -o custom-columns=":metadata.name" | \
  xargs -I{} kubectl scale deploy/{} --replicas=1 -n argocd

# Cần scale statefulset riêng (Redis):
kubectl get statefulset -n argocd --no-headers -o custom-columns=":metadata.name" | \
  xargs -I{} kubectl scale statefulset/{} --replicas=1 -n argocd

kubectl get pods -n argocd -w
```

> **Mẹo tiết kiệm RAM:** Nếu chỉ cần demo CI/CD, KHÔNG cần bật `yas`, `argocd`, `istio-system`. 
> Chỉ cần `dev` namespace là đủ. Tiết kiệm ~8GB RAM.

### Bước 8: Verification checklist

Chờ **5 phút** sau khi cluster start, rồi kiểm tra từng phần:

```bash
echo "========== NODES =========="
kubectl get nodes
echo ""

echo "========== KUBE-SYSTEM =========="
kubectl get pods -n kube-system --no-headers | awk '{printf "%-50s %s\n", $1, $3}'
echo ""

echo "========== INFRASTRUCTURE =========="
for ns in postgres kafka elasticsearch keycloak redis; do
  echo "--- $ns ---"
  kubectl get pods -n $ns --no-headers 2>/dev/null | awk '{printf "  %-50s %s\n", $1, $3}'
done
echo ""

echo "========== OBSERVABILITY =========="
kubectl get pods -n observability --no-headers | awk '{printf "  %-50s %s\n", $1, $3}'
echo ""

echo "========== APPLICATION NAMESPACES =========="
for ns in dev developer staging yas; do
  count=$(kubectl get pods -n $ns --no-headers 2>/dev/null | grep -c Running || echo 0)
  total=$(kubectl get pods -n $ns --no-headers 2>/dev/null | wc -l || echo 0)
  echo "$ns: $count/$total Running"
done
echo ""

echo "========== PROBLEM PODS (not Running/Completed) =========="
kubectl get pods -A --no-headers | grep -Ev "Running|Completed" | head -20
```

**Mong đợi sau recovery thành công:**
- Nodes: 2/2 Ready
- kube-system: ~10 pods Running
- postgres: 3 pods (postgresql-0, operator, pgadmin)
- kafka: 3-4 pods (operator, dual-role-0, entity-operator, akhq)
- elasticsearch: 1-2 pods (elasticsearch-standalone-0, có thể thêm operator)
- keycloak: 1-2 pods (keycloak-0, có thể thêm operator)
- redis: 1-3 pods
- observability: ~15-20 pods (loki, prometheus, grafana, otel, promtail, tempo)
- dev: 20/21 Running (payment-paypal luôn crash — bình thường)

### Bước 9: (Tùy chọn) Force restart nếu pods kẹt

Nếu sau 5 phút vẫn có pods `Error` / `CrashLoopBackOff` trong namespace `dev`:
```bash
# Restart tất cả deployments
kubectl rollout restart deployment -n dev

# Chờ 3 phút rồi kiểm tra
sleep 180
kubectl get pods -n dev | grep -Ev "Running|Completed"
```

Nếu pods kẹt ở `Pending` (không đủ resource):
```bash
# Xem pod nào bị pending
kubectl get pods -n dev --field-selector status.phase=Pending

# Xem lý do
kubectl describe pod <pod-name> -n dev | tail -10
# Thường là: "Insufficient memory" hoặc "Insufficient cpu"

# Giải pháp: Scale to 0 namespace không cần
kubectl get deploy -n yas --no-headers -o custom-columns=":metadata.name" | \
  xargs -I{} kubectl scale deploy/{} --replicas=0 -n yas
kubectl get deploy -n argocd --no-headers -o custom-columns=":metadata.name" | \
  xargs -I{} kubectl scale deploy/{} --replicas=0 -n argocd
```

---

## Trường hợp 3: Khôi phục sau reboot/restart máy

> **Khi nào dùng:** Máy tính bị tắt nguồn, restart OS, đơ phải force shutdown.  
> **Khác với TH2:** Docker daemon có thể chưa chạy, minikube container có thể bị corrupt.  
> **Thời gian:** ~5-15 phút.

### Bước 1: Đảm bảo Docker đang chạy

```bash
# Kiểm tra Docker
systemctl is-active docker
```

**Nếu output `inactive` hoặc `failed`:**
```bash
sudo systemctl start docker
sudo systemctl enable docker   # Đảm bảo tự start khi boot

# Chờ Docker sẵn sàng
sleep 5
docker info > /dev/null 2>&1 && echo "Docker OK" || echo "Docker FAILED"
```

### Bước 2: Kiểm tra trạng thái container minikube

```bash
docker ps -a --filter "name=minikube" --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
```

**Kịch bản A — Container "Exited" (phổ biến nhất sau reboot):**
```
NAMES          STATUS                     PORTS
minikube       Exited (130) 2 hours ago
minikube-m02   Exited (130) 2 hours ago
```
→ Chạy `minikube start` và tiếp tục như [TH2 từ Bước 1](#bước-1-khởi-động-minikube).

**Kịch bản B — Container "Running" nhưng kubelet Stopped** (máy bị OOM trước đó):
```bash
minikube status
# Nếu host=Running nhưng kubelet=Stopped:
docker exec minikube systemctl start kubelet
docker exec minikube-m02 systemctl restart kubelet
# Rồi tiếp tục TH2 từ Bước 2
```

**Kịch bản C — Container không tồn tại (bị xóa hoặc Docker bị reset):**
```bash
docker ps -a --filter "name=minikube"
# → Không có output → container đã bị xóa
```
→ Xem [Trường hợp 4: Cài lại từ đầu](#trường-hợp-4-cluster-hỏng-nặng--xóa-và-cài-lại-từ-đầu)

**Kịch bản D — `minikube start` báo lỗi certificate expired:**
```
Unable to connect to the server: x509: certificate has expired
```
```bash
# Renew certificates
minikube update-context
minikube start

# Nếu vẫn lỗi:
minikube delete --all --purge   # ⚠️ MẤT DATA
# Rồi cài lại từ TH4
```

### Bước 3-9: Giống Trường hợp 2

Sau khi minikube start thành công, làm theo **Bước 2 → Bước 9** của 
[Trường hợp 2](#trường-hợp-2-khôi-phục-sau-minikube-stop-phổ-biến-nhất).

**Tóm tắt nhanh (copy-paste):**
```bash
# Fix /etc/hosts
docker exec minikube bash -c 'grep -q "control-plane.minikube.internal" /etc/hosts || echo "192.168.49.2 control-plane.minikube.internal" >> /etc/hosts'
docker exec minikube-m02 bash -c 'grep -q "control-plane.minikube.internal" /etc/hosts || echo "192.168.49.2 control-plane.minikube.internal" >> /etc/hosts'

# Fix inotify
docker exec minikube sysctl -w fs.inotify.max_user_watches=524288 fs.inotify.max_user_instances=512
docker exec minikube-m02 sysctl -w fs.inotify.max_user_watches=524288 fs.inotify.max_user_instances=512

# Restart worker kubelet
docker exec minikube-m02 systemctl restart kubelet

# Chờ + kiểm tra
sleep 15 && kubectl get nodes
kubectl get pods -A --no-headers | grep -Ev "Running|Completed" | head -10
```

---

## Trường hợp 4: Cluster hỏng nặng — Xóa và cài lại từ đầu

> **Khi nào dùng:** 
> - `minikube start` liên tục lỗi không khắc phục được
> - Cluster bị corrupt (etcd hỏng, certificates expired, container bị xóa)
> - Muốn bắt đầu sạch hoàn toàn
> 
> **⚠️ CẢNH BÁO:** Mất toàn bộ data: PostgreSQL, Kafka messages, Elasticsearch indexes, 
> Keycloak users/realms. Phải cài lại infrastructure + import lại realm + deploy lại tất cả.
>
> **Thời gian:** ~45-60 phút (phần lớn là chờ pods khởi động).

### Giai đoạn 1: Xóa sạch cluster cũ

```bash
# Xóa cluster minikube (MẤT TOÀN BỘ DATA)
minikube delete --all --purge

# Dọn dẹp Docker volumes còn sót
docker volume prune -f

# Xác nhận sạch
docker ps -a --filter "name=minikube"
# → Không có gì
minikube status
# → Profile "minikube" not found
```

### Giai đoạn 2: Tạo cluster mới

```bash
# Tạo cluster 2 nodes
# Khuyến nghị: 6 CPU + 12GB RAM cho cluster stable
# Tối thiểu: 4 CPU + 8GB RAM (một số pod có thể bị Pending)
minikube start --cpus=6 --memory=12288 --driver=docker

# Thêm worker node
minikube node add

# Kiểm tra 2 nodes Ready
kubectl get nodes
# NAME           STATUS   ROLES           AGE   VERSION
# minikube       Ready    control-plane   1m    v1.35.1
# minikube-m02   Ready    <none>          30s   v1.35.1
```

> **Nếu `minikube node add` lỗi:** Chờ 1 phút rồi thử lại. Control plane cần hoàn tất 
> khởi tạo trước khi add worker.

### Giai đoạn 3: Tăng inotify (ngay sau khi tạo cluster)

```bash
docker exec minikube sysctl -w fs.inotify.max_user_watches=524288 fs.inotify.max_user_instances=512
docker exec minikube-m02 sysctl -w fs.inotify.max_user_watches=524288 fs.inotify.max_user_instances=512
```

### Giai đoạn 4: Cài Ingress Controller

```bash
minikube addons enable ingress

# Chờ ingress controller Ready (~1 phút)
kubectl get pods -n ingress-nginx -w
# Khi thấy controller 1/1 Running → Ctrl+C
```

### Giai đoạn 5: Cài infrastructure

```bash
cd /home/npt102/gcp/Devops2/yas/k8s/deploy

# Cài Helm dependencies + operators + database + kafka + ES + observability
chmod +x *.sh
./setup-cluster.sh
```

> ⏱ **Mất ~10-15 phút.** Script tự thêm Helm repos và cài lần lượt.

**Theo dõi tiến trình:**
```bash
# Terminal khác — xem pods tạo dần
watch -n 10 'kubectl get pods -A --no-headers | awk "{print \$1}" | sort | uniq -c | sort -rn'
```

**⚠️ Các vấn đề chắc chắn sẽ gặp khi chạy setup-cluster.sh:**

Script `setup-cluster.sh` sẽ **fail** ở một vài bước do chart version mới. Cần fix thủ công:

**Vấn đề 1 — Loki: `schema_config` error:**
```bash
# Script fail khi cài Loki → cài thủ công:
helm upgrade --install loki grafana/loki \
  --namespace observability \
  -f ./observability/loki.values.yaml \
  --set loki.useTestSchema=true
```

**Vấn đề 2 — Prometheus: `assertNoLeakedSecrets`:**
```bash
# Cài thủ công:
helm upgrade --install prometheus prometheus-community/kube-prometheus-stack \
  --namespace observability \
  -f ./observability/prometheus.values.yaml \
  --set grafana.assertNoLeakedSecrets=false
```

**Vấn đề 3 — OTel Collector crash (đã sửa sẵn trong repo):**
Nếu vẫn crash:
```bash
kubectl delete opentelemetrycollectors opentelemetry -n observability 2>/dev/null
helm upgrade --install opentelemetry-collector ./observability/opentelemetry -n observability
```

**Kiểm tra sau setup-cluster.sh:**
```bash
echo "=== postgres ===" && kubectl get pods -n postgres
echo "=== kafka ===" && kubectl get pods -n kafka
echo "=== elasticsearch ===" && kubectl get pods -n elasticsearch
echo "=== observability ===" && kubectl get pods -n observability --no-headers | wc -l
echo "=== cert-manager ===" && kubectl get pods -n cert-manager
```

**Mong đợi:**
- postgres: `postgresql-0` 1/1 Running, `postgres-operator` 1/1 Running, `pgadmin` 1/1 Running
- kafka: `strimzi-cluster-operator` Running, `kafka-cluster-dual-role-0` Running (có thể mất thêm 2 phút)
- elasticsearch: `elastic-operator` Running (ECK operator)
- observability: ~15-20 pods
- cert-manager: 3 pods Running

### Giai đoạn 6: Deploy Elasticsearch standalone

> ECK operator cài từ setup-cluster.sh không tương thích ES 9.x + K8s 1.35. 
> Dùng standalone StatefulSet thay thế.

```bash
kubectl apply -f elasticsearch/es-standalone.yaml -n elasticsearch

# Chờ pod Running (~1 phút)
kubectl get pods -n elasticsearch -w
# elasticsearch-standalone-0   1/1   Running   0   1m
```

**Kiểm tra ES hoạt động:**
```bash
kubectl exec -n elasticsearch elasticsearch-standalone-0 -- \
  curl -s http://localhost:9200/_cluster/health | python3 -m json.tool
# Phải thấy "status": "green" hoặc "yellow"
```

### Giai đoạn 7: Cài Keycloak + Import Realm

```bash
cd /home/npt102/gcp/Devops2/yas/k8s/deploy

# 7a. Cài Keycloak
./setup-keycloak.sh
# ⏱ ~3 phút

# Chờ Keycloak Ready
kubectl get pods -n keycloak -w
# keycloak-0   1/1   Running   0   2m
```

**7b. Import realm `yas`:**

Sau khi Keycloak chạy, phải import realm `yas` (chứa clients, roles, scopes cho các microservices):

**Cách 1: Qua giao diện web (khuyến nghị cho lần đầu):**
```bash
# Port-forward
kubectl port-forward svc/keycloak -n keycloak 8080:80 &
PF_PID=$!

# Mở browser: http://localhost:8080
# Login: admin / admin
# Bước 1: Click dropdown "master" góc trái → "Create realm"
# Bước 2: Click "Browse..." → chọn file identity/realm-export.json
# Bước 3: Click "Create"
# Bước 4: Verify: Menu trái → Clients → phải thấy các client: backoffice, storefront, swagger-ui...

# Tắt port-forward
kill $PF_PID
```

**Cách 2: Qua CLI (nhanh hơn):**
```bash
# Copy file vào pod
kubectl cp /home/npt102/gcp/Devops2/yas/identity/realm-export.json \
  keycloak/keycloak-0:/tmp/realm-export.json

# Login admin
kubectl exec -n keycloak keycloak-0 -- /opt/keycloak/bin/kcadm.sh config credentials \
  --server http://localhost:8080 --realm master --user admin --password admin

# Import realm (skip nếu resource đã tồn tại)
kubectl exec -n keycloak keycloak-0 -- /opt/keycloak/bin/kcadm.sh create partialImport \
  -r yas -s ifResourceExists=SKIP -f /tmp/realm-export.json

# Verify
kubectl exec -n keycloak keycloak-0 -- /opt/keycloak/bin/kcadm.sh get clients -r yas \
  --fields clientId | head -20
```

### Giai đoạn 8: Cài Redis

```bash
cd /home/npt102/gcp/Devops2/yas/k8s/deploy
./setup-redis.sh

kubectl get pods -n redis
# redis-master-0   1/1   Running
```

### Giai đoạn 9: Deploy YAS configuration + applications

```bash
cd /home/npt102/gcp/Devops2/yas/k8s/deploy

# 9a. Deploy ConfigMaps + Secrets (cần thiết trước khi deploy services)
./deploy-yas-configuration.sh

# Kiểm tra
kubectl get cm -n yas --no-headers | wc -l    # Phải > 10
kubectl get secret -n yas --no-headers | wc -l  # Phải > 5
```

```bash
# 9b. Deploy tất cả microservices
./deploy-yas-applications.sh
```

> ⏱ **Mất ~20-30 phút** (deploy lần lượt, mỗi service cách 60 giây).
> 
> **Theo dõi tiến trình (terminal khác):**
> ```bash
> watch -n 10 'echo "Running:" && kubectl get pods -n yas --no-headers | grep -c Running && echo "Not running:" && kubectl get pods -n yas --no-headers | grep -Ev Running | head -10'
> ```

**Kiểm tra sau khi deploy xong:**
```bash
kubectl get pods -n yas --no-headers | awk '{print $3}' | sort | uniq -c | sort -rn
# Mong đợi: ~20 Running, 1 CrashLoopBackOff (payment-paypal — lỗi image, bình thường)
```

### Giai đoạn 10: Cấu hình /etc/hosts trên máy host

```bash
# Lấy IP Minikube
MINIKUBE_IP=$(minikube ip)
echo "Minikube IP: $MINIKUBE_IP"

# Xóa entries cũ (nếu có) rồi thêm mới
sudo sed -i '/yas\.local\.com/d' /etc/hosts
sudo bash -c "cat >> /etc/hosts << EOF
$MINIKUBE_IP yas.local.com api.yas.local.com backoffice.yas.local.com storefront.yas.local.com
$MINIKUBE_IP identity.yas.local.com pgadmin.yas.local.com grafana.yas.local.com
$MINIKUBE_IP kibana.yas.local.com akhq.yas.local.com
$MINIKUBE_IP dev.yas.local.com api.dev.yas.local.com backoffice.dev.yas.local.com
$MINIKUBE_IP staging.yas.local.com api.staging.yas.local.com
$MINIKUBE_IP developer.yas.local.com api.developer.yas.local.com
EOF"

# Verify
grep yas /etc/hosts
```

### Giai đoạn 11: (Tùy chọn) Cài Istio Service Mesh

> Chỉ cần nếu muốn demo phần nâng cao (mTLS, authorization policy, retry).

```bash
cd /home/npt102/gcp/Devops2/yas

# 11a. Cài Istio
export PATH=$PWD/istio-1.29.1/bin:$PATH
istioctl install --set profile=demo -y

# Kiểm tra
kubectl get pods -n istio-system
# istiod, istio-ingressgateway, istio-egressgateway — tất cả Running

# 11b. Cài Kiali (service mesh visualization)
kubectl apply -f https://raw.githubusercontent.com/istio/istio/release-1.22/samples/addons/kiali.yaml
kubectl apply -f https://raw.githubusercontent.com/istio/istio/release-1.22/samples/addons/prometheus.yaml

# 11c. Enable sidecar injection cho namespace yas
kubectl label namespace yas istio-injection=enabled --overwrite
kubectl rollout restart deployment -n yas
# Chờ pods restart xong (~3-5 phút)

# 11d. Apply Istio policies
kubectl apply -f istio/peer-authentication.yaml    # mTLS STRICT
kubectl apply -f istio/destination-rule.yaml        # ISTIO_MUTUAL TLS
kubectl apply -f istio/authorization-policy.yaml    # Service-to-service access control
kubectl apply -f istio/virtual-service-retry.yaml   # Retry 5xx (3 attempts)

# 11e. Verify mTLS
kubectl get peerauthentication -n yas
# NAME      MODE     AGE
# default   STRICT   ...
```

### Giai đoạn 12: Deploy vào namespace `dev` (CI/CD)

Sau khi tất cả infrastructure ready, có 2 cách deploy vào `dev`:

**Cách 1: Push commit vào `main` (tự động):**
```bash
# Sửa file bất kỳ, commit và push
cd /home/npt102/gcp/Devops2/yas
echo "# rebuild" >> README.md
git add . && git commit -m "trigger dev deploy" && git push origin main
# Workflow npt-dev-deploy.yml sẽ tự chạy
# ⚠️ Cần runner đang online (xem TH6)
```

**Cách 2: Chạy thủ công script deploy:**
```bash
cd /home/npt102/gcp/Devops2/yas/k8s/deploy
./deploy-yas-configuration.sh   # Config cho namespace dev
# Rồi dùng helm install cho từng service...
# (Hoặc đợi CI/CD tự deploy — khuyến nghị)
```

### Giai đoạn 13: Kiểm tra tổng thể

```bash
echo "===== NODES =====" && kubectl get nodes
echo ""
echo "===== INFRASTRUCTURE ====="
for ns in postgres kafka elasticsearch keycloak redis cert-manager ingress-nginx; do
  running=$(kubectl get pods -n $ns --no-headers 2>/dev/null | grep -c Running || echo 0)
  total=$(kubectl get pods -n $ns --no-headers 2>/dev/null | wc -l || echo 0)
  printf "  %-20s %s/%s Running\n" "$ns" "$running" "$total"
done
echo ""
echo "===== OBSERVABILITY ====="
running=$(kubectl get pods -n observability --no-headers | grep -c Running)
total=$(kubectl get pods -n observability --no-headers | wc -l)
echo "  observability: $running/$total Running"
echo ""
echo "===== APPLICATION ====="
for ns in yas dev developer staging; do
  running=$(kubectl get pods -n $ns --no-headers 2>/dev/null | grep -c Running || echo 0)
  total=$(kubectl get pods -n $ns --no-headers 2>/dev/null | wc -l || echo 0)
  printf "  %-20s %s/%s Running\n" "$ns" "$running" "$total"
done
echo ""
echo "===== PROBLEM PODS ====="
kubectl get pods -A --no-headers | grep -Ev "Running|Completed" | head -10
```

**Truy cập kiểm tra:**
- Storefront: http://storefront.yas.local.com
- Backoffice: http://backoffice.yas.local.com
- Keycloak: http://identity.yas.local.com (admin/admin)
- pgAdmin: http://pgadmin.yas.local.com
- Grafana: http://grafana.yas.local.com (admin/admin)
- Swagger: http://api.yas.local.com/swagger-ui
- Dev env: http://dev.yas.local.com

---

## Trường hợp 5: Chỉ khôi phục 1 namespace cụ thể

> **Khi nào dùng:** 1 service/namespace bị lỗi, không muốn restart cả cluster.  
> **Quan trọng:** Nhiều namespace có dependency. Xem bảng dependency trước khi fix:
>
> | Service | Phụ thuộc |
> |---------|-----------|
> | Keycloak | PostgreSQL |
> | Tất cả microservices (yas/dev) | PostgreSQL, Kafka, Elasticsearch, Keycloak, Redis |
> | Observability (OTel, Promtail) | Loki, Tempo |
> | BFF (storefront-bff, backoffice-bff) | Redis, Keycloak |
>
> **Nếu PostgreSQL hoặc Kafka bị lỗi, fix chúng TRƯỚC rồi mới fix service khác.**

### 5a. Kafka — Broker không phục hồi (thường gặp nhất)

**Kiểm tra trạng thái:**
```bash
kubectl get pods -n kafka
kubectl get kafkanodepools -n kafka
kubectl get kafka -n kafka
```

**Kịch bản 1: `kafka-cluster-dual-role-0` bị `CrashLoopBackOff`**

```bash
# Xem lỗi cụ thể
kubectl logs kafka-cluster-dual-role-0 -n kafka --tail=50
```

**Nếu lỗi permissions** (`Permission denied`, `cannot create directory`):
```bash
# Script sửa ownership data directory
bash /home/npt102/gcp/Devops2/yas/k8s/deploy/fix-kafka-permissions.sh

# Xóa pod để tạo lại
kubectl delete pod kafka-cluster-dual-role-0 -n kafka
kubectl get pods -n kafka -w
# Chờ đến khi 1/1 Running
```

**Nếu lỗi metadata/KRaft** (`inconsistent cluster ID`, `not enough voters`, `log segment`):
```bash
# Xóa pod → StatefulSet tự tạo lại
kubectl delete pod kafka-cluster-dual-role-0 -n kafka

# Nếu sau 2 phút vẫn crash → restart operator
kubectl rollout restart deployment/strimzi-cluster-operator -n kafka
sleep 60 && kubectl get pods -n kafka
```

**Kịch bản 2: Pod `kafka-cluster-dual-role-0` không tồn tại**

```bash
# Kiểm tra KafkaNodePool
kubectl get kafkanodepools -n kafka
# Nếu không thấy "dual-role" → operator chưa reconcile

# Restart operator
kubectl rollout restart deployment/strimzi-cluster-operator -n kafka

# Chờ operator Running, rồi chờ broker xuất hiện (~2 phút)
kubectl get pods -n kafka -w
```

**Nếu operator Running nhưng broker vẫn không xuất hiện sau 3 phút:**
```bash
# Kiểm tra operator logs
kubectl logs deploy/strimzi-cluster-operator -n kafka --tail=50 | grep -i "error\|warn"

# Thử xóa và redeploy Kafka cluster
cd /home/npt102/gcp/Devops2/yas/k8s/deploy
helm uninstall kafka-cluster -n kafka 2>/dev/null
sleep 30
helm upgrade --install kafka-cluster ./kafka/kafka-cluster \
  --namespace kafka \
  --set kafka.replicas=1 \
  --set postgresql.username=yasadminuser \
  --set postgresql.password=admin
kubectl get pods -n kafka -w
```

**Kịch bản 3: Debezium Connect crash → Bỏ qua**
```bash
kubectl scale kafkaconnect/debezium-connect-cluster --replicas=0 -n kafka 2>/dev/null
```

**Kịch bản 4: Entity operator crash**
```bash
kubectl delete pod -l strimzi.io/name=kafka-cluster-entity-operator -n kafka
# Operator sẽ tạo lại tự động
```

**Verify Kafka hoạt động:**
```bash
# Tạo test topic
kubectl exec kafka-cluster-dual-role-0 -n kafka -- \
  /opt/kafka/bin/kafka-topics.sh --bootstrap-server localhost:9092 --list
# Phải thấy list topics (có thể trống nếu cluster mới)
```

### 5b. PostgreSQL bị lỗi

```bash
kubectl get pods -n postgres
```

**Pod `postgresql-0` bị CrashLoopBackOff:**
```bash
# Xem logs
kubectl logs postgresql-0 -n postgres --tail=30

# Thường là lỗi PVC hoặc config → xóa pod để recreate
kubectl delete pod postgresql-0 -n postgres
# StatefulSet tự tạo lại (~1 phút)
kubectl get pods -n postgres -w
```

**Pod `postgresql-0` bị Pending:**
```bash
# Kiểm tra lý do
kubectl describe pod postgresql-0 -n postgres | tail -20
# Thường: "Insufficient memory" → scale to 0 namespace yas hoặc argocd để giải phóng RAM
```

**Operator bị lỗi:**
```bash
kubectl rollout restart deployment/postgres-operator -n postgres
sleep 30
kubectl get pods -n postgres
```

**Verify PostgreSQL hoạt động:**
```bash
kubectl exec postgresql-0 -n postgres -- psql -U yasadminuser -d postgres -c "SELECT version();"
# Phải thấy PostgreSQL version output
```

### 5c. Keycloak bị lỗi

> **Kiểm tra PostgreSQL trước!** Keycloak phụ thuộc PostgreSQL. Nếu Postgres down, Keycloak sẽ crash.

```bash
# Kiểm tra dependency trước
kubectl get pods -n postgres | grep postgresql-0
# Phải 1/1 Running

# Rồi mới fix Keycloak
kubectl get pods -n keycloak
```

**Keycloak-0 crash:**
```bash
# Xem logs
kubectl logs keycloak-0 -n keycloak --tail=30

# Xóa pod để recreate
kubectl delete pod keycloak-0 -n keycloak
kubectl get pods -n keycloak -w
```

**Verify:**
```bash
kubectl exec keycloak-0 -n keycloak -- curl -s http://localhost:8080/health | head -5
# Phải thấy "status": "UP"
```

### 5d. Elasticsearch bị lỗi

```bash
kubectl get pods -n elasticsearch
```

**elasticsearch-standalone-0 crash:**
```bash
# Xóa pod → StatefulSet tạo lại
kubectl delete pod elasticsearch-standalone-0 -n elasticsearch
kubectl get pods -n elasticsearch -w
```

**Nếu PVC bị corrupt (dữ liệu hỏng):**
```bash
# ⚠️ Mất toàn bộ ES indexes — search service cần reindex sau
kubectl delete statefulset elasticsearch-standalone -n elasticsearch
kubectl delete pvc elasticsearch-data-elasticsearch-standalone-0 -n elasticsearch
kubectl apply -f /home/npt102/gcp/Devops2/yas/k8s/deploy/elasticsearch/es-standalone.yaml -n elasticsearch
kubectl get pods -n elasticsearch -w
```

**Verify:**
```bash
kubectl exec elasticsearch-standalone-0 -n elasticsearch -- \
  curl -s http://localhost:9200/_cluster/health
# Phải thấy "status": "green" hoặc "yellow"
```

### 5e. Dev namespace (YAS microservices)

```bash
kubectl get pods -n dev
```

**Restart 1 service cụ thể:**
```bash
# Ví dụ restart tax service:
kubectl rollout restart deployment/tax -n dev
kubectl get pods -n dev -l app=tax -w
```

**Restart tất cả services:**
```bash
kubectl rollout restart deployment -n dev
# Chờ 3-5 phút
```

**Nếu nhiều pods Pending (thiếu resource):**
```bash
# Xem pods pending
kubectl get pods -n dev --field-selector status.phase=Pending

# Giải phóng RAM bằng cách scale to 0 namespace không cần:
kubectl get deploy -n yas --no-headers -o custom-columns=":metadata.name" | \
  xargs -I{} kubectl scale deploy/{} --replicas=0 -n yas
kubectl get deploy -n argocd --no-headers -o custom-columns=":metadata.name" | \
  xargs -I{} kubectl scale deploy/{} --replicas=0 -n argocd
```

**Payment-paypal luôn CrashLoopBackOff:**
Đây là lỗi đã biết (`no main manifest attribute in /app.jar`). Image từ repo gốc bị hỏng.
Không cần fix:
```bash
# Scale to 0 để không thấy lỗi
kubectl scale deployment/payment-paypal --replicas=0 -n dev 2>/dev/null
```

### 5f. Observability (Loki, Prometheus, Grafana, OTel)

```bash
kubectl get pods -n observability
```

**OTel Collector crash (config issue):**
```bash
# PHẢI xóa CR cũ trước (tránh Helm merge giữ lại config sai)
kubectl delete opentelemetrycollectors opentelemetry -n observability 2>/dev/null
helm uninstall opentelemetry-collector -n observability 2>/dev/null
sleep 5
helm upgrade --install opentelemetry-collector \
  /home/npt102/gcp/Devops2/yas/k8s/deploy/observability/opentelemetry \
  -n observability
kubectl get pods -n observability | grep otel
```

**Promtail crash (too many open files):**
```bash
# Tăng inotify limits
docker exec minikube sysctl -w fs.inotify.max_user_watches=524288 fs.inotify.max_user_instances=512
docker exec minikube-m02 sysctl -w fs.inotify.max_user_watches=524288 fs.inotify.max_user_instances=512

# Restart
kubectl rollout restart daemonset/promtail -n observability
```

**Prometheus/Grafana crash:**
```bash
kubectl rollout restart deployment/prometheus-grafana -n observability
kubectl rollout restart statefulset/prometheus-prometheus-kube-prometheus-prometheus -n observability
```

**Loki pods crash:**
```bash
# Restart Loki components
kubectl rollout restart statefulset -n observability -l app.kubernetes.io/name=loki
kubectl rollout restart deployment -n observability -l app.kubernetes.io/name=loki
```

### 5g. Ingress NGINX — Không truy cập được website

```bash
kubectl get pods -n ingress-nginx
```

**Controller crash hoặc missing:**
```bash
# Disable rồi enable lại
minikube addons disable ingress
sleep 10
minikube addons enable ingress
kubectl get pods -n ingress-nginx -w
```

**Kiểm tra ingress rules:**
```bash
# Xem tất cả ingress rules
kubectl get ingress -A

# Kiểm tra cụ thể dev namespace
kubectl get ingress -n dev -o wide
```

---

## Trường hợp 6: Bật lại GitHub Actions Runner

> **Khi nào dùng:** Sau khi cluster đã chạy, muốn CI/CD hoạt động lại.  
> **Runner location:** `/home/npt102/gcp/Devops2/actions-runner/`  
> **Runner name:** `fedora`  
> **Workflow cần runner:** npt-dev-deploy, npt-staging-deploy, npt-developer_build, npt-cleanup  
> **Workflow KHÔNG cần runner:** npt-ci (chạy trên `ubuntu-latest` GitHub-hosted)

### Bước 1: Kiểm tra runner có đang chạy không

```bash
ps aux | grep Runner.Listener | grep -v grep
```

- Nếu **có output** → runner đã chạy. Kiểm tra trên GitHub:
  Settings → Actions → Runners → runner "fedora" phải hiện **Idle** (xanh lá).
- Nếu **không có output** → tiếp bước 2.

### Bước 2: Khởi động runner

```bash
cd /home/npt102/gcp/Devops2/actions-runner

# Chạy background (khuyến nghị — tắt terminal không ảnh hưởng)
nohup ./run.sh > runner.log 2>&1 &

# Xem log
tail -f runner.log
# Khi thấy "Listening for Jobs" → Ctrl+C, runner đã sẵn sàng
```

Hoặc chạy foreground (để debug):
```bash
./run.sh
# → Thấy "Connected to GitHub" + "Listening for Jobs"
# Ctrl+C để tắt
```

### Bước 3: Kiểm tra trên GitHub

Vào https://github.com/NPT-102/yas-2/settings/actions/runners
- Trạng thái **Idle** (xanh lá) → OK
- Trạng thái **Offline** (xám) → runner chưa kết nối, kiểm tra lại bước 2

### Xử lý lỗi runner

**Session conflict** (runner process cũ chưa tắt hẳn):
```bash
pkill -f "Runner.Listener" 2>/dev/null
sleep 3
cd /home/npt102/gcp/Devops2/actions-runner
nohup ./run.sh > runner.log 2>&1 &
```

**Runner outdated** (GitHub yêu cầu update):
```bash
cd /home/npt102/gcp/Devops2/actions-runner
# Runner tự update khi kết nối → chỉ cần restart:
pkill -f "Runner.Listener" 2>/dev/null
sleep 3
nohup ./run.sh > runner.log 2>&1 &
```

**Runner không tìm thấy kubectl** (self-hosted runner cần có kubectl trong PATH):
```bash
# Kiểm tra
which kubectl
# Nếu không có → thêm vào PATH:
export PATH=$PATH:/usr/local/bin
# Hoặc kiểm tra minikube kubectl:
minikube kubectl -- get nodes
```

---

## Script tự động khôi phục (Quick Recovery)

> Dùng cho **Trường hợp 2** (sau `minikube stop`). Lưu script 1 lần, dùng mãi.

### Tạo script (chỉ cần làm 1 lần)

```bash
cat > ~/recover-cluster.sh << 'EOF'
#!/bin/bash
set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${YELLOW}=== [1/8] Starting minikube ===${NC}"
minikube start
docker start minikube-m02 2>/dev/null || true
sleep 5

echo -e "${YELLOW}=== [2/8] Fixing /etc/hosts ===${NC}"
docker exec minikube bash -c \
  'grep -q "control-plane.minikube.internal" /etc/hosts || echo "192.168.49.2 control-plane.minikube.internal" >> /etc/hosts'
docker exec minikube-m02 bash -c \
  'grep -q "control-plane.minikube.internal" /etc/hosts || echo "192.168.49.2 control-plane.minikube.internal" >> /etc/hosts'
echo "  /etc/hosts fixed on both nodes"

echo -e "${YELLOW}=== [3/8] Setting inotify limits ===${NC}"
docker exec minikube sysctl -w fs.inotify.max_user_watches=524288 fs.inotify.max_user_instances=512 > /dev/null
docker exec minikube-m02 sysctl -w fs.inotify.max_user_watches=524288 fs.inotify.max_user_instances=512 > /dev/null
echo "  inotify limits set"

echo -e "${YELLOW}=== [4/8] Restarting worker kubelet ===${NC}"
docker exec minikube-m02 systemctl restart kubelet
echo "  kubelet restarted"

echo -e "${YELLOW}=== [5/8] Waiting for nodes Ready (15s) ===${NC}"
sleep 15
kubectl get nodes

echo -e "${YELLOW}=== [6/8] Fixing CoreDNS + kube-proxy ===${NC}"
kubectl delete pod -n kube-system -l k8s-app=kube-dns --ignore-not-found 2>/dev/null || true
kubectl delete pod -n kube-system -l k8s-app=kube-proxy --field-selector spec.nodeName=minikube --ignore-not-found 2>/dev/null || true
sleep 10

echo -e "${YELLOW}=== [7/8] Waiting for infrastructure pods (120s) ===${NC}"
echo "  Checking every 15 seconds..."
for i in $(seq 1 8); do
  sleep 15
  KAFKA_OK=$(kubectl get pods -n kafka --no-headers 2>/dev/null | grep -c "Running" || echo 0)
  PG_OK=$(kubectl get pods -n postgres --no-headers 2>/dev/null | grep -c "Running" || echo 0)
  KC_OK=$(kubectl get pods -n keycloak --no-headers 2>/dev/null | grep -c "Running" || echo 0)
  echo "  [${i}/8] postgres=$PG_OK kafka=$KAFKA_OK keycloak=$KC_OK"
  if [[ $KAFKA_OK -ge 3 && $PG_OK -ge 2 && $KC_OK -ge 1 ]]; then
    echo -e "  ${GREEN}Infrastructure ready!${NC}"
    break
  fi
done

echo -e "${YELLOW}=== [8/8] Final status ===${NC}"
echo ""
echo "--- Nodes ---"
kubectl get nodes
echo ""
echo "--- Infrastructure ---"
for ns in postgres kafka elasticsearch keycloak redis; do
  running=$(kubectl get pods -n $ns --no-headers 2>/dev/null | grep -c Running || echo 0)
  total=$(kubectl get pods -n $ns --no-headers 2>/dev/null | wc -l || echo 0)
  printf "  %-20s %s/%s Running\n" "$ns" "$running" "$total"
done
echo ""
echo "--- Application ---"
for ns in dev developer staging yas; do
  running=$(kubectl get pods -n $ns --no-headers 2>/dev/null | grep -c Running || echo 0)
  total=$(kubectl get pods -n $ns --no-headers 2>/dev/null | wc -l || echo 0)
  printf "  %-20s %s/%s Running\n" "$ns" "$running" "$total"
done
echo ""
echo "--- Problem pods ---"
PROBLEMS=$(kubectl get pods -A --no-headers 2>/dev/null | grep -Ev "Running|Completed" | head -10)
if [ -z "$PROBLEMS" ]; then
  echo -e "  ${GREEN}No problem pods!${NC}"
else
  echo "$PROBLEMS"
fi

echo ""
echo -e "${GREEN}=== Recovery complete ===${NC}"
echo "If Kafka broker is missing/crashing, see KHOI-PHUC-CLUSTER.md → TH2 Bước 6"
echo "To start runner: cd ~/gcp/Devops2/actions-runner && nohup ./run.sh > runner.log 2>&1 &"
EOF

chmod +x ~/recover-cluster.sh
echo "Script saved to ~/recover-cluster.sh"
```

### Sử dụng

```bash
# Mỗi lần muốn khôi phục sau minikube stop:
~/recover-cluster.sh

# Nếu cần bật runner nữa:
cd /home/npt102/gcp/Devops2/actions-runner && nohup ./run.sh > runner.log 2>&1 &
```

### Script tắt cluster (tùy chọn)

```bash
cat > ~/stop-cluster.sh << 'EOF'
#!/bin/bash
echo "=== Stopping runner ==="
pkill -f "Runner.Listener" 2>/dev/null && echo "  Runner stopped" || echo "  Runner not running"

echo "=== Stopping minikube ==="
minikube stop

echo "=== RAM freed ==="
free -h | grep Mem
echo "Done. Run ~/recover-cluster.sh to start again."
EOF

chmod +x ~/stop-cluster.sh
```

---

## Bảng số lượng pods mong đợi theo namespace

> Dùng bảng này để verify recovery. Số pods có thể thay đổi ±1-2 tùy cấu hình.

| Namespace | Pods mong đợi | Chi tiết |
|-----------|--------------|----------|
| `kube-system` | ~10 | etcd, apiserver, controller-manager, scheduler, coredns, kube-proxy×2, kindnet×2, storage-provisioner |
| `ingress-nginx` | 1-2 | ingress-nginx-controller (+ admission job Completed) |
| `cert-manager` | 3 | cert-manager, cainjector, webhook |
| `postgres` | 3 | postgresql-0, postgres-operator, pgadmin |
| `kafka` | 3-4 | strimzi-operator, kafka-cluster-dual-role-0, entity-operator, akhq. Debezium scaled to 0 |
| `elasticsearch` | 1-2 | elasticsearch-standalone-0 (+ elastic-operator nếu chưa xóa) |
| `keycloak` | 1-2 | keycloak-0 (+ keycloak-operator nếu có) |
| `redis` | 1-3 | redis-master-0 (+ sentinel/replica tùy cấu hình) |
| `observability` | ~15-20 | loki (backend, read, write, gateway, minio, canary×2, cache×2), prometheus, grafana, alertmanager, kube-state-metrics, node-exporter×2, otel-operator, otel-collector, promtail×2, tempo |
| `dev` | **20-21** | 21 microservices. payment-paypal thường crash (image lỗi) → 20 Running là bình thường |
| `yas` | 0 hoặc 21 | Scale to 0 nếu không dùng, hoặc 21 nếu bật |
| `developer` | 0 | Chỉ có khi chạy developer_build workflow |
| `staging` | 0 | Chỉ có khi push tag v* |
| `istio-system` | 0 hoặc 3-5 | istiod, ingress-gateway, egress-gateway (+ kiali, prometheus nếu cài) |
| `argocd` | 0 hoặc 6-7 | server, repo-server, app-controller, applicationset-controller, redis, dex, notifications |

---

## Bảng lỗi thường gặp

| # | Lỗi / Triệu chứng | Nguyên nhân | Cách sửa nhanh |
|---|-----|-------------|----------|
| 1 | Worker `NotReady` / `control-plane.minikube.internal: no such host` | /etc/hosts bị reset sau stop/start | [TH2 Bước 2](#bước-2-sửa-etchosts-bên-trong-container-bắt-buộc): thêm entry 192.168.49.2 vào /etc/hosts cả 2 node |
| 2 | Promtail `CrashLoopBackOff: too many open files` | inotify limit thấp (mặc định 128) | [TH2 Bước 3](#bước-3-tăng-giới-hạn-inotify-bắt-buộc): `docker exec minikube sysctl -w fs.inotify.max_user_watches=524288 fs.inotify.max_user_instances=512` cho cả 2 node |
| 3 | Kafka broker `CrashLoopBackOff: Permission denied` | Volume hostPath ownership sai sau restart | [TH5a](#5a-kafka--broker-không-phục-hồi-thường-gặp-nhất): `bash k8s/deploy/fix-kafka-permissions.sh` → xóa pod |
| 4 | Kafka broker pod không tồn tại | Strimzi operator chưa reconcile | [TH5a](#5a-kafka--broker-không-phục-hồi-thường-gặp-nhất): restart operator → chờ 2 phút |
| 5 | Debezium Connect `Error` | Image Kafka 3.x không tương thích Kafka 4.1.0 | Bỏ qua: `kubectl scale kafkaconnect/debezium-connect-cluster --replicas=0 -n kafka` |
| 6 | Payment-paypal `CrashLoopBackOff` | `no main manifest attribute in /app.jar` — image hỏng | Scale to 0: `kubectl scale deploy/payment-paypal --replicas=0 -n dev` |
| 7 | CoreDNS `0/1 Ready` | Khởi động trước API server ready | Delete pod: `kubectl delete pod -n kube-system -l k8s-app=kube-dns` |
| 8 | Service-to-service timeout | kube-proxy chưa sync iptables | [TH2 Bước 5](#bước-5-sửa-coredns-và-kube-proxy-nếu-cần): restart kube-proxy pod |
| 9 | OTel Collector crash: `receivers unknown type: "loki"` | Config merge giữ lại config cũ | [TH5f](#5f-observability-loki-prometheus-grafana-otel): xóa CR → reinstall helm |
| 10 | OTel Collector: `the logging exporter has been deprecated` | Exporter đổi tên | Đã sửa trong repo: `logging` → `debug`. Nếu vẫn lỗi → xóa CR + reinstall |
| 11 | Loki: `schema_config` error khi helm install | Chart mới bắt buộc schema | Thêm flag: `--set loki.useTestSchema=true` |
| 12 | Prometheus: `assertNoLeakedSecrets` | Grafana chart mới kiểm tra password trong values | Thêm flag: `--set grafana.assertNoLeakedSecrets=false` |
| 13 | ArgoCD applicationset-controller crash | CRDs chưa apply hoặc quá cũ | `kubectl apply -k "https://github.com/argoproj/argo-cd/manifests/crds?ref=stable" --server-side` |
| 14 | `kubectl apply` CRD lỗi `Too long: must have at most 262144 bytes` | Annotation quá lớn (ArgoCD CRDs) | Dùng: `kubectl apply ... --server-side` |
| 15 | Máy bị đơ/freeze | Cluster + Loki + Prometheus dùng ~20GB RAM | Tắt nhanh: `minikube stop`. Phòng: scale to 0 namespace không dùng |
| 16 | Runner báo "session conflict" | Process cũ chưa tắt | `pkill -f "Runner.Listener"` → chờ 3s → `./run.sh` |
| 17 | `minikube start` timeout | Docker daemon chưa chạy | `sudo systemctl start docker` |
| 18 | Certificate expired (`x509`) | Cluster tắt quá lâu (>1 năm) hoặc clock skew | `minikube update-context && minikube start`. Nếu fail → TH4 |
| 19 | Pods kẹt `Pending` | Thiếu CPU/Memory | Scale to 0 namespace không dùng (yas, argocd, istio-system) |
| 20 | Payment `CrashLoopBackOff: Liquibase` | Checksum mismatch | Đã fix bằng image tag `fixed` trong charts |

---

## Thông tin cấu hình cluster

### Cluster

| Thông số | Giá trị |
|----------|---------|
| Minikube version | v1.38.1 |
| Kubernetes version | v1.35.1 |
| Docker driver | Docker |
| Nodes | 2 (minikube + minikube-m02) |
| Control plane IP | 192.168.49.2 |
| Worker node IP | 192.168.49.3 |
| Pod CIDR (control) | 10.244.0.0/24 |
| Pod CIDR (worker) | 10.244.1.0/24 |

### Infrastructure services

| Service | Endpoint trong cluster | Namespace |
|---------|----------------------|-----------|
| PostgreSQL | postgresql.postgres:5432 | postgres |
| Kafka Bootstrap | kafka-cluster-kafka-brokers.kafka:9092 | kafka |
| Elasticsearch | elasticsearch-es-http.elasticsearch:9200 | elasticsearch |
| Keycloak (internal) | keycloak.keycloak:80 | keycloak |
| Redis | redis-master.redis:6379 | redis |
| Loki Gateway | loki-gateway.observability:80 | observability |
| Tempo | tempo.observability:4318 | observability |

### Ingress domains

| Domain | Trỏ đến | Dùng cho |
|--------|---------|----------|
| `yas.local.com` | storefront-bff (namespace yas) | Namespace gốc |
| `api.yas.local.com` | các backend services (namespace yas) | API gốc |
| `dev.yas.local.com` | storefront-bff (namespace dev) | Dev environment |
| `backoffice.dev.yas.local.com` | backoffice-bff (namespace dev) | Dev backoffice |
| `api.dev.yas.local.com` | các backend services (namespace dev) | Dev API |
| `staging.yas.local.com` | storefront-bff (namespace staging) | Staging environment |
| `api.staging.yas.local.com` | các backend services (namespace staging) | Staging API |
| `developer.yas.local.com` | storefront-bff (namespace developer) | Developer build |
| `identity.yas.local.com` | Keycloak | Login/SSO |
| `pgadmin.yas.local.com` | pgAdmin | DB management |
| `grafana.yas.local.com` | Grafana | Dashboards |
| `kibana.yas.local.com` | Kibana | Log search |
| `akhq.yas.local.com` | AKHQ | Kafka management |

### Đường dẫn quan trọng

| Gì | Đường dẫn |
|----|-----------|
| Project root | `/home/npt102/gcp/Devops2/yas` |
| Deploy scripts | `/home/npt102/gcp/Devops2/yas/k8s/deploy` |
| Helm charts | `/home/npt102/gcp/Devops2/yas/k8s/charts` |
| CI/CD workflows | `/home/npt102/gcp/Devops2/yas/.github/workflows` |
| Istio configs | `/home/npt102/gcp/Devops2/yas/istio` |
| Keycloak realm | `/home/npt102/gcp/Devops2/yas/identity/realm-export.json` |
| ES standalone | `/home/npt102/gcp/Devops2/yas/k8s/deploy/elasticsearch/es-standalone.yaml` |
| Kafka fix script | `/home/npt102/gcp/Devops2/yas/k8s/deploy/fix-kafka-permissions.sh` |
| GitHub Runner | `/home/npt102/gcp/Devops2/actions-runner` |
| Recovery script | `~/recover-cluster.sh` |
| Stop script | `~/stop-cluster.sh` |
| GitHub Repo | https://github.com/NPT-102/yas-2 |

### Namespaces

| Namespace | Chứa gì | Dependency | Ghi chú |
|-----------|---------|------------|---------|
| `kube-system` | K8s core (etcd, apiserver, coredns, proxy) | — | Tự động, không can thiệp |
| `ingress-nginx` | NGINX Ingress Controller | — | Minikube addon |
| `cert-manager` | TLS Certificate Manager | — | |
| `postgres` | PostgreSQL (Zalando) + pgAdmin | — | **Cần lên TRƯỚC keycloak và services** |
| `kafka` | Strimzi + Kafka KRaft + AKHQ | — | KRaft mode, không cần ZooKeeper |
| `elasticsearch` | ES 9.2.3 standalone + Kibana | — | Standalone StatefulSet, không dùng ECK |
| `keycloak` | Keycloak 26.0.1 (Identity) | postgres | Phải có postgres Running trước |
| `redis` | Redis (session cache) | — | BFF cần Redis cho session |
| `observability` | Loki, Tempo, Prometheus, Grafana, OTel, Promtail | — | ~15-20 pods, tốn nhiều RAM |
| `istio-system` | Istiod, Ingress/Egress gateway, Kiali | — | Tùy chọn, scale to 0 nếu không demo |
| `yas` | 21 microservices (gốc) | postgres, kafka, es, keycloak, redis | Thường scale to 0 để tiết kiệm RAM |
| `dev` | 21 microservices (CI/CD dev) | postgres, kafka, es, keycloak, redis | **Dùng chính cho demo đồ án** |
| `developer` | 21 microservices (manual deploy) | postgres, kafka, es, keycloak, redis | Tạo bởi developer_build workflow |
| `staging` | 21 microservices (tag release) | postgres, kafka, es, keycloak, redis | Tạo bởi staging-deploy workflow |
| `argocd` | ArgoCD (GitOps) | — | Tùy chọn, scale to 0 nếu không dùng |

### Credentials

| Service | Username | Password | Ghi chú |
|---------|----------|----------|---------|
| PostgreSQL | yasadminuser | admin | Từ cluster-config.yaml |
| Keycloak | admin | admin | Bootstrap admin |
| Grafana | admin | admin | Sub-chart prometheus |
| Docker Hub | (xem GitHub Secrets) | (Access Token) | `DOCKER_USER` / `DOCKER_PASS` |
