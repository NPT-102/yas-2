# Hướng dẫn khôi phục Cluster sau khi Restart máy

> **Lưu ý:** File này tổng hợp tất cả bước cần thực hiện khi máy bị restart/đơ/reboot.
> Cluster sử dụng: Minikube v1.38.1, K8s v1.35.1, Docker driver, 2 nodes (control-plane + worker).

---

## Mục lục

1. [Khởi động Minikube](#1-khởi-động-minikube)
2. [Sửa /etc/hosts trên cả 2 node](#2-sửa-etchosts-trên-cả-2-node)
3. [Sửa inotify limits](#3-sửa-inotify-limits)
4. [Khởi động kubelet](#4-khởi-động-kubelet)
5. [Kiểm tra nodes Ready](#5-kiểm-tra-nodes-ready)
6. [Sửa CoreDNS nếu bị lỗi](#6-sửa-coredns-nếu-bị-lỗi)
7. [Restart kube-proxy trên control plane](#7-restart-kube-proxy-trên-control-plane)
8. [Bật lại storage-provisioner nếu cần](#8-bật-lại-storage-provisioner-nếu-cần)
9. [Kiểm tra infrastructure pods](#9-kiểm-tra-infrastructure-pods)
10. [Restart YAS pods nếu cần](#10-restart-yas-pods-nếu-cần)
11. [Xác nhận toàn bộ hệ thống](#11-xác-nhận-toàn-bộ-hệ-thống)

---

## 1. Khởi động Minikube

```bash
# Khởi động control plane
minikube start

# Khởi động worker node (container Docker)
docker start minikube-m02
```

Kiểm tra trạng thái:
```bash
minikube status
# Nếu control plane host=Running nhưng kubelet=Stopped → xem bước 4
```

---

## 2. Sửa /etc/hosts trên cả 2 node

**Đây là bước QUAN TRỌNG NHẤT.** Sau mỗi lần restart, file `/etc/hosts` bên trong container Docker bị reset, mất entry `control-plane.minikube.internal`. Nếu không sửa, kubelet và kube-proxy sẽ không kết nối được API server → cluster hỏng.

```bash
# Sửa trên CONTROL PLANE
docker exec minikube bash -c \
  'echo "192.168.49.2 control-plane.minikube.internal" >> /etc/hosts'

# Sửa trên WORKER NODE
docker exec minikube-m02 bash -c \
  'echo "192.168.49.2 control-plane.minikube.internal" >> /etc/hosts'
```

Kiểm tra:
```bash
docker exec minikube cat /etc/hosts | grep control-plane
docker exec minikube-m02 cat /etc/hosts | grep control-plane
# Phải thấy: 192.168.49.2 control-plane.minikube.internal
```

---

## 3. Sửa inotify limits

Cluster có nhiều pods nên cần tăng giới hạn inotify, nếu không kubelet sẽ báo lỗi "too many open files":

```bash
# Trên control plane
docker exec minikube sysctl -w fs.inotify.max_user_watches=524288
docker exec minikube sysctl -w fs.inotify.max_user_instances=512

# Trên worker node
docker exec minikube-m02 sysctl -w fs.inotify.max_user_watches=524288
docker exec minikube-m02 sysctl -w fs.inotify.max_user_instances=512
```

---

## 4. Khởi động kubelet

Sau reboot, kubelet có thể ở trạng thái `inactive (dead)`:

```bash
# Khởi động kubelet trên control plane
docker exec minikube systemctl start kubelet

# Khởi động kubelet trên worker
docker exec minikube-m02 systemctl restart kubelet
```

---

## 5. Kiểm tra nodes Ready

```bash
kubectl get nodes
```

**Kết quả mong đợi:**
```
NAME           STATUS   ROLES           AGE   VERSION
minikube       Ready    control-plane   ...   v1.35.1
minikube-m02   Ready    <none>          ...   v1.35.1
```

Nếu worker vẫn `NotReady`:
```bash
# Kiểm tra /etc/hosts trên worker đã đúng chưa (bước 2)
docker exec minikube-m02 cat /etc/hosts | grep control-plane

# Restart lại kubelet trên worker
docker exec minikube-m02 systemctl restart kubelet
```

---

## 6. Sửa CoreDNS nếu bị lỗi

CoreDNS có thể bị 0/1 Ready nếu nó khởi động trước API server:

```bash
kubectl get pods -n kube-system -l k8s-app=kube-dns
```

Nếu thấy `0/1 Running` hoặc `CrashLoopBackOff`:
```bash
# Xóa pod để tạo mới
kubectl delete pod -n kube-system -l k8s-app=kube-dns

# Chờ ~10s, kiểm tra lại
kubectl get pods -n kube-system -l k8s-app=kube-dns
# Phải thấy 1/1 Running
```

---

## 7. Restart kube-proxy trên control plane

**Bước này RẤT QUAN TRỌNG.** Nếu không làm, tất cả ClusterIP services sẽ không hoạt động từ trong pods (iptables rules không được sync).

```bash
# Xóa kube-proxy pod trên control plane để tạo mới
kubectl delete pod -n kube-system -l k8s-app=kube-proxy \
  --field-selector spec.nodeName=minikube

# Chờ ~5s, kiểm tra
kubectl get pods -n kube-system -l k8s-app=kube-proxy -o wide
# Phải thấy cả 2 pods Running (1 trên minikube, 1 trên minikube-m02)
```

Kiểm tra kube-proxy trên control-plane không có lỗi:
```bash
kubectl logs -n kube-system -l k8s-app=kube-proxy \
  --field-selector spec.nodeName=minikube --tail=5
# KHÔNG được thấy "no such host" hay "Failed to watch"
```

---

## 8. Bật lại storage-provisioner nếu cần

```bash
kubectl get pod storage-provisioner -n kube-system
```

Nếu không tìm thấy:
```bash
minikube addons enable storage-provisioner
```

---

## 9. Kiểm tra infrastructure pods

```bash
# Kafka
kubectl get pods -n kafka
# Cần: kafka-cluster-dual-role-0 1/1 Running

# PostgreSQL
kubectl get pods -n postgres
# Cần: postgresql-* Running

# Keycloak
kubectl get pods -n keycloak
# Cần: keycloak-0 1/1 Running (có thể mất 2-3 phút)

# Elasticsearch
kubectl get pods -n elasticsearch
# Cần: elasticsearch-standalone-0 1/1 Running

# Redis
kubectl get pods -n redis

# Cert Manager
kubectl get pods -n cert-manager

# Monitoring (nếu đã cài)
kubectl get pods -n monitoring
kubectl get pods -n tracing
kubectl get pods -n logging
```

Nếu có infrastructure pod bị `CrashLoopBackOff` hoặc `Error`:
```bash
# Restart theo namespace
kubectl delete pods --all -n <namespace>
# Ví dụ: kubectl delete pods --all -n kafka
```

**Lưu ý riêng cho Kafka:** Nếu Kafka bị lỗi permissions, chạy:
```bash
bash k8s/deploy/fix-kafka-permissions.sh
```

---

## 10. Restart YAS pods nếu cần

Sau khi tất cả infrastructure đã Running, restart các YAS pods:

```bash
# Restart tất cả deployments trong namespace yas
kubectl rollout restart deployment -n yas

# Chờ ~60s rồi kiểm tra
kubectl get pods -n yas
```

**Thứ tự phục hồi thường là:**
1. Infrastructure pods (Postgres, Kafka, Keycloak) khởi động trước
2. Sau đó các YAS services mới kết nối được
3. Một số services có thể CrashLoopBackOff 2-3 lần rồi tự phục hồi

---

## 11. Xác nhận toàn bộ hệ thống

```bash
echo "=== Nodes ===" && kubectl get nodes
echo "=== Ingress ===" && kubectl get pods -n ingress-nginx
echo "=== Kafka ===" && kubectl get pods -n kafka | grep -E "Running|NAME"
echo "=== Keycloak ===" && kubectl get pods -n keycloak
echo "=== ES ===" && kubectl get pods -n elasticsearch
echo "=== YAS ===" && kubectl get pods -n yas
```

**Kết quả mong đợi:**
- 2 nodes Ready
- Ingress controller 1/1 Running
- Kafka broker 1/1 Running
- Keycloak 1/1 Running
- Elasticsearch standalone 1/1 Running
- Tất cả 21 YAS pods 1/1 Running (payment-paypal scaled to 0)

---

## Script tự động khôi phục (Quick Recovery)

Chạy lệnh sau để thực hiện tất cả bước trên tự động:

```bash
#!/bin/bash
set -e
echo "=== [1/8] Starting minikube nodes ==="
minikube start
docker start minikube-m02 2>/dev/null || true

echo "=== [2/8] Fixing /etc/hosts ==="
docker exec minikube bash -c 'grep -q control-plane.minikube.internal /etc/hosts || echo "192.168.49.2 control-plane.minikube.internal" >> /etc/hosts'
docker exec minikube-m02 bash -c 'grep -q control-plane.minikube.internal /etc/hosts || echo "192.168.49.2 control-plane.minikube.internal" >> /etc/hosts'

echo "=== [3/8] Setting inotify limits ==="
docker exec minikube sysctl -w fs.inotify.max_user_watches=524288 fs.inotify.max_user_instances=512
docker exec minikube-m02 sysctl -w fs.inotify.max_user_watches=524288 fs.inotify.max_user_instances=512

echo "=== [4/8] Starting kubelet ==="
docker exec minikube systemctl start kubelet
docker exec minikube-m02 systemctl restart kubelet

echo "=== [5/8] Waiting for nodes ==="
sleep 10
kubectl get nodes

echo "=== [6/8] Fixing CoreDNS ==="
kubectl delete pod -n kube-system -l k8s-app=kube-dns --ignore-not-found
sleep 10

echo "=== [7/8] Restarting kube-proxy on control plane ==="
kubectl delete pod -n kube-system -l k8s-app=kube-proxy --field-selector spec.nodeName=minikube
sleep 5

echo "=== [8/8] Checking cluster ==="
kubectl get nodes
kubectl get pods -n kube-system | grep -E "Running|NAME"
echo ""
echo "=== Recovery complete! Check YAS pods: ==="
echo "kubectl get pods -n yas"
echo "If services are CrashLoopBackOff, wait 1-2 minutes or run:"
echo "kubectl rollout restart deployment -n yas"
```

---

## Các lỗi đã biết và cách xử lý

| Lỗi | Nguyên nhân | Cách sửa |
|-----|------------|----------|
| `control-plane.minikube.internal: no such host` | /etc/hosts bị reset sau reboot | Bước 2: thêm entry vào /etc/hosts |
| ClusterIP services không kết nối từ pods | kube-proxy không sync iptables | Bước 7: restart kube-proxy |
| CoreDNS 0/1 Ready | Khởi động trước API server | Bước 6: delete pod |
| ES `cannot upgrade from 8.8.1 to 9.2.3` | ECK không hỗ trợ upgrade path | Đã xử lý bằng standalone ES |
| Payment Liquibase `is_enabled` column | Cột tên sai trong SQL migration | Đã sửa, dùng image `:fixed` |
| Payment-paypal CrashLoopBackOff | Module đã tích hợp vào payment | Đã scale to 0 |
| Kafka permissions error | Volume hostPath ownership | Chạy `fix-kafka-permissions.sh` |
| Debezium CrashLoopBackOff | Kafka 3.x connector vs 4.x broker | Known issue, bỏ qua |
| Máy bị đơ/freeze | Cluster dùng quá nhiều RAM (~12GB) | Đóng app không cần thiết, tắt monitoring khi không dùng |

---

## Thông tin cấu hình cluster

| Thông số | Giá trị |
|----------|---------|
| Control plane IP | 192.168.49.2 |
| Worker node IP | 192.168.49.3 |
| Pod CIDR (control) | 10.244.0.0/24 |
| Pod CIDR (worker) | 10.244.1.0/24 |
| Ingress ClusterIP | 10.107.249.153 |
| ES Service | elasticsearch-es-http.elasticsearch:9200 |
| Kafka Bootstrap | kafka-cluster-kafka-brokers.kafka:9092 |
| Keycloak | identity.yas.local.com (qua ingress) |
