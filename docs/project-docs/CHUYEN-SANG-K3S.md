# Hướng dẫn chuyển từ Minikube sang K3s

> **Máy:** Fedora Linux 43 · 32 CPU · 32GB RAM · NVMe 952GB  
> **Đường dẫn project:** `/home/npt102/gcp/Devops2/yas`  
> **Thời gian ước tính:** ~30-40 phút

---

## Mục lục

1. [Tại sao chuyển sang K3s?](#1-tại-sao-chuyển-sang-k3s)
2. [Dọn dẹp Minikube (giải phóng ~8-10GB)](#2-dọn-dẹp-minikube)
3. [Cài đặt K3s](#3-cài-đặt-k3s)
4. [Cấu hình kubeconfig](#4-cấu-hình-kubeconfig)
5. [Cài Ingress NGINX (thay Traefik)](#5-cài-ingress-nginx)
6. [Tăng giới hạn inotify](#6-tăng-giới-hạn-inotify)
7. [Chạy setup-cluster.sh (Infrastructure)](#7-chạy-setup-clustersh)
8. [Thêm Worker Node (scale-out cluster)](#8-thêm-worker-node-scale-out-cluster) ⚠️ Làm TRƯỚC khi deploy services để máy chủ không lag
9. [Deploy Elasticsearch standalone](#9-deploy-elasticsearch-standalone)
10. [Cài Keycloak](#10-cài-keycloak)
11. [Cài Redis](#11-cài-redis)
12. [Cấu hình /etc/hosts](#12-cấu-hình-etchosts) ⚠️ Làm TRƯỚC bước 13
13. [Deploy YAS Configuration + Applications](#13-deploy-yas-configuration--applications)
14. [Cập nhật KUBE_CONFIG secret cho GitHub Actions](#14-cập-nhật-kube_config-secret)
15. [Bật lại GitHub Actions Runner](#15-bật-lại-github-actions-runner)
16. [Cài ArgoCD (GitOps)](#16-cài-argocd-gitops)
17. [Cài Istio Service Mesh (mTLS + Kiali)](#17-cài-istio-service-mesh-mtls--kiali)
18. [Kiểm tra tổng thể](#18-kiểm-tra-tổng-thể)
19. [Khôi phục sau reboot (cực đơn giản)](#19-khôi-phục-sau-reboot)
20. [Bảng khác biệt Minikube vs K3s](#20-bảng-khác-biệt-minikube-vs-k3s)

---

## 1. Tại sao chuyển sang K3s?

| | Minikube | K3s |
|---|---|---|
| Cách chạy | Docker container lồng nhau | Systemd service (native process) |
| RAM overhead | ~2-3GB (Docker-in-Docker) | ~512MB |
| Auto-start sau reboot | Không (phải chạy `minikube start`) | Có (`systemctl enable k3s`) |
| Port 80/443 | Cần `minikube tunnel` (phải giữ terminal) | Không cần — truy cập thẳng qua `127.0.0.1` |
| /etc/hosts | Phải fix sau mỗi lần restart | Ổn định, chỉ cần set 1 lần |
| Storage class mặc định | `standard` (hostPath thủ công) | `local-path` (provisioner tự quản lý) |
| Worker node | Thêm qua Docker container | Thêm agent thật (VM / máy khác) |
| Sau reboot | Phải fix `/etc/hosts`, DNS, kube-proxy... | Chỉ cần chờ systemd start xong |

---

## 2. Dọn dẹp Minikube

> ⚠️ **Dữ liệu trong cluster sẽ bị mất hoàn toàn.** Chỉ chạy khi đã sẵn sàng.

```bash
# Nếu minikube đang chạy thì stop trước
minikube stop 2>/dev/null || true

# Xóa cluster và toàn bộ volumes
minikube delete --all --purge

# Xóa Docker image kicbase (~2GB)
docker rmi gcr.io/k8s-minikube/kicbase:v0.0.50 2>/dev/null || true

# Xóa các Docker volumes mồ côi (nếu còn)
docker volume prune -f

# Kiểm tra - không còn container nào tên "minikube"
docker ps -a --filter "name=minikube"
# → Không có output = sạch
```

**RAM sau khi dọn dẹp:** Giải phóng ~6-8GB RAM (Docker containers không còn chạy) + ~2GB disk.

---

## 3. Cài đặt K3s

### 3.1 Cài K3s (single-node, disable Traefik)

```bash
# Cài K3s v1.32.5 (stable LTS), tắt Traefik (vì sẽ dùng ingress-nginx)
curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION=v1.32.5+k3s1 sh -s - \
  --disable=traefik \
  --write-kubeconfig-mode=644
```

> **Giải thích các flag:**
> - `INSTALL_K3S_VERSION=v1.32.5+k3s1`: Cố định version stable LTS. **Không dùng v1.35.x** — có bug: `cloud-controller-manager` exit ngay khi gặp 403 Forbidden lúc bootstrap RBAC (race condition), khiến K3s crash loop vĩnh viễn.
> - `--disable=traefik`: Không cài Traefik ingress mặc định, sẽ dùng ingress-nginx thay thế
> - `--write-kubeconfig-mode=644`: Cho phép user thường đọc kubeconfig mà không cần sudo

**Chờ ~1-2 phút.** Kiểm tra:

```bash
sudo systemctl status k3s
# → Active: active (running)

kubectl get nodes
```

**✅ Kết quả đúng:**
```
NAME     STATUS   ROLES                  AGE   VERSION
fedora   Ready    control-plane,master   1m    v1.x.x+k3s1
```

### 3.2 Cho phép K3s tự khởi động sau reboot

```bash
sudo systemctl enable k3s
# → Đã được enable tự động khi cài, lệnh này chỉ để xác nhận
```

---

## 4. Cấu hình kubeconfig

K3s lưu kubeconfig tại `/etc/rancher/k3s/k3s.yaml`. Copy về `~/.kube/config`:

```bash
mkdir -p ~/.kube
sudo cp /etc/rancher/k3s/k3s.yaml ~/.kube/config
sudo chown $USER:$USER ~/.kube/config
chmod 600 ~/.kube/config

# Kiểm tra
kubectl config current-context
kubectl config view --minify --raw | grep server
kubectl cluster-info
# → Kubernetes control plane is running at https://172.16.0.240:6443
```

> **Lưu ý:** Khác với Minikube (`192.168.49.2`), K3s thường dùng `127.0.0.1:6443` khi chạy local. Trên máy này kubeconfig hiện đang trỏ tới `https://172.16.0.240:6443`, nên nếu bạn dựng lại cluster mới thì hãy ghi lại đúng IP của control-plane và thay lại endpoint trong `~/.kube/config` khi cần.

---

## 5. Cài Ingress NGINX

K3s mặc định dùng Traefik, đã disable ở bước 3. Cài ingress-nginx:

```bash
kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-v1.11.0/deploy/static/provider/cloud/deploy.yaml

# Chờ controller Ready
kubectl wait --namespace ingress-nginx \
  --for=condition=Ready pod \
  --selector=app.kubernetes.io/component=controller \
  --timeout=120s
```

**✅ Kết quả đúng:**
```bash
kubectl get svc -n ingress-nginx ingress-nginx-controller
# NAME                       TYPE           CLUSTER-IP     EXTERNAL-IP   PORT(S)
# ingress-nginx-controller   LoadBalancer   10.43.x.x      127.0.0.1     80:xxxxx/TCP,443:xxxxx/TCP
```

> K3s sử dụng **klipper-lb** (built-in ServiceLB), tự động assign IP của node (`172.16.0.240` trong trường hợp máy này) cho LoadBalancer service → truy cập thẳng port 80/443 mà **không cần `minikube tunnel`**.
>
> Kiểm tra EXTERNAL-IP thực tế bằng: `kubectl get svc -n ingress-nginx ingress-nginx-controller`

---

## 6. Tăng giới hạn inotify

Cần thiết để Kafka, Promtail và một số pod khác không crash "too many open files":

```bash
# Áp dụng ngay
sudo sysctl -w fs.inotify.max_user_watches=524288
sudo sysctl -w fs.inotify.max_user_instances=512

# Persist qua reboot (quan trọng — K3s tự restart, giới hạn phải persist)
echo "fs.inotify.max_user_watches=524288" | sudo tee -a /etc/sysctl.d/99-k3s.conf
echo "fs.inotify.max_user_instances=512"  | sudo tee -a /etc/sysctl.d/99-k3s.conf
sudo sysctl --system
```

> **Khác với Minikube:** Trước đây phải chạy `docker exec minikube sysctl ...` sau mỗi lần start. Với K3s, chỉ cần set 1 lần trong `/etc/sysctl.d/` và sẽ persist vĩnh viễn.

---

## 7. Chạy setup-cluster.sh

Script cài PostgreSQL, Kafka, pgAdmin, AKHQ. **Không cần sửa** — các lệnh `sudo sysctl` ở đầu script vẫn hoạt động bình thường.

```bash
cd /home/npt102/gcp/Devops2/yas/k8s/deploy
./setup-cluster.sh
```

> ⏱ **~10-15 phút.** Script chờ từng component.

**Sau khi xong, kiểm tra:**

```bash
kubectl get pods -n postgres
kubectl get pods -n kafka
```

### Kafka Permission Fix trên K3s

K3s dùng `local-path` provisioner — tạo thư mục tại `/var/lib/rancher/k3s/storage/` với quyền `root:root`. Kafka vẫn cần fix permissions:

```bash
bash /home/npt102/gcp/Devops2/yas/k8s/deploy/fix-kafka-permissions.sh
```

---

## 8. Thêm Worker Node (scale-out cluster)

Khi máy chủ chính lag vì phải chạy quá nhiều pod, thêm máy khác vào cluster để Kubernetes tự phân phối workload.

> **Yêu cầu:** 2 máy worker cần kết nối được đến máy control plane qua mạng LAN (cùng network). Bất kỳ distro Linux nào đều được.
> **⚠️ Quan trọng:** Làm bước này TRƯỚC khi deploy services (Elasticsearch, Keycloak, Redis, YAS apps). Những pod mới sau đó sẽ tự động phân phối sang worker → máy chủ sẽ nhẹ hơn 50%.

### 8.1 Lấy thông tin kết nối từ control plane (máy chính)

```bash
# Lấy token (dùng để worker xác thực)
sudo cat /var/lib/rancher/k3s/server/node-token
# → Copy output này (dạng: K10abc...::server:xxx)

# Lấy IP của máy control plane (IP LAN, không phải 127.0.0.1)
ip addr show | grep "inet " | grep -v "127.0.0.1"
# Hoặc:
hostname -I | awk '{print $1}'
# → Ví dụ: 192.168.1.100
```

> **Lưu ý:** Dùng IP LAN (192.168.x.x hoặc 10.x.x.x), không dùng 127.0.0.1 — worker máy khác không connect được qua localhost.

### 8.2 Mở firewall trên control plane (máy chính)

Worker cần connect vào port 6443 (API server) và 10250 (kubelet) của control plane:

```bash
# Chạy trên máy CONTROL PLANE
sudo firewall-cmd --permanent --add-port=6443/tcp    # Kubernetes API
sudo firewall-cmd --permanent --add-port=10250/tcp   # Kubelet metrics
sudo firewall-cmd --permanent --add-port=8472/udp    # Flannel VXLAN (overlay network)
sudo firewall-cmd --reload

echo "Firewall updated"
```

### 8.3 Cài K3s agent trên từng máy worker

Chạy trên **mỗi máy worker** (thay `<CONTROL_PLANE_IP>` và `<TOKEN>`):

```bash
# Ví dụ: control plane IP = 192.168.1.100
# Token = K10abc123...::server:xyz

CONTROL_PLANE_IP="192.168.1.100"
TOKEN="<token lấy từ bước 8.1>"

curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION=v1.32.5+k3s1 \
  K3S_URL="https://${CONTROL_PLANE_IP}:6443" \
  K3S_TOKEN="${TOKEN}" \
  sh -
```

**Kiểm tra agent đã start:**
```bash
# Trên máy worker
sudo systemctl status k3s-agent
# → Active: active (running)

# Cho phép tự start sau reboot
sudo systemctl enable k3s-agent
```

### 8.4 Fix firewall trên máy worker (Fedora)

```bash
# Chạy trên mỗi máy WORKER
sudo firewall-cmd --permanent --zone=trusted --add-interface=cni0
sudo firewall-cmd --permanent --zone=trusted --add-interface=flannel.1
sudo firewall-cmd --permanent --zone=trusted --add-source=10.42.0.0/16
sudo firewall-cmd --permanent --zone=trusted --add-source=10.43.0.0/16
sudo firewall-cmd --reload
```

### 8.5 Tăng giới hạn inotify trên máy worker

```bash
# Chạy trên mỗi máy WORKER
sudo sysctl -w fs.inotify.max_user_watches=524288
sudo sysctl -w fs.inotify.max_user_instances=512
echo "fs.inotify.max_user_watches=524288" | sudo tee -a /etc/sysctl.d/99-k3s.conf
echo "fs.inotify.max_user_instances=512"  | sudo tee -a /etc/sysctl.d/99-k3s.conf
sudo sysctl --system
```

### 8.6 Kiểm tra trên control plane

```bash
# Kiểm tra các node đã join
kubectl get nodes
```

**✅ Kết quả đúng (sau khi 2 worker join):**
```
NAME        STATUS   ROLES                  AGE   VERSION
fedora      Ready    control-plane,master   2d    v1.32.5+k3s1
worker-01   Ready    <none>                 5m    v1.32.5+k3s1
worker-02   Ready    <none>                 3m    v1.32.5+k3s1
```

Kubernetes sẽ **tự động** phân phối các pod mới sang worker nodes — không cần cấu hình thêm gì.

### 8.7 (Tuỳ chọn) Đặt tên đẹp cho worker nodes

```bash
# Đặt label để dễ nhận biết
kubectl label node <tên-worker-1> node-role.kubernetes.io/worker=worker
kubectl label node <tên-worker-2> node-role.kubernetes.io/worker=worker

# Xem phân phối pod trên các nodes
kubectl get pods -n yas -o wide
```

### 8.8 (Tuỳ chọn) Evict pods từ control plane sang worker

Nếu muốn giảm tải cho máy chính ngay lập tức:

```bash
# Không cho schedule thêm pod mới lên control plane
kubectl taint node fedora node-role.kubernetes.io/master=:NoSchedule

# Drain (evict) hết pod sang worker (TRỪ DaemonSets và static pods)
kubectl drain fedora --ignore-daemonsets --delete-emptydir-data --force

# Bỏ cordon để control plane có thể nhận pod lại (nếu cần)
kubectl uncordon fedora
```

> ⚠️ **Lưu ý drain:** Các pod stateful (PostgreSQL, Kafka, Elasticsearch) dùng `local-path` PVC gắn với máy chính sẽ không thể evict — chúng sẽ bị terminate và tạo lại trên worker nhưng **mất data** nếu PV không có trên worker. Chỉ drain nếu đã di chuyển storage hoặc chấp nhận data reset.

### 8.9 Khôi phục worker sau reboot

K3s agent tự start theo systemd — không cần làm gì thêm:

```bash
# Trên worker — chỉ kiểm tra:
sudo systemctl status k3s-agent
```

---

## 9. Deploy Elasticsearch standalone

File `es-standalone.yaml` đã được cập nhật dùng `storageClassName: local-path` (K3s). Apply trực tiếp:

```bash
cd /home/npt102/gcp/Devops2/yas
kubectl create namespace elasticsearch 2>/dev/null || true
kubectl apply -f k8s/deploy/elasticsearch/es-standalone.yaml
```

**Kiểm tra:**

```bash
kubectl get pods -n elasticsearch
# elasticsearch-standalone-0   1/1   Running   0   ...

kubectl exec -n elasticsearch elasticsearch-standalone-0 -- \
  curl -s http://localhost:9200/_cluster/health
# → "status":"green"
```

---

## 10. Cài Keycloak

```bash
cd /home/npt102/gcp/Devops2/yas/k8s/deploy
./setup-keycloak.sh
```

**Chờ Keycloak sẵn sàng (~3-5 phút):**

```bash
kubectl get pods -n keycloak -w
# keycloak-0   1/1   Running   0   ...
```

**Kiểm tra realm YAS đã được import:**

Realm được import tự động qua `KeycloakRealmImport` CR trong Helm chart (`setup-keycloak.sh` đã làm điều này). Chỉ cần kiểm tra:

```bash
kubectl get keycloakrealmimport -n keycloak
# → yas-realm-kc   ...

# Xem trạng thái (Done: True, HasErrors: False = thành công)
kubectl get keycloakrealmimport yas-realm-kc -n keycloak -o jsonpath='{.status.conditions}' | python3 -m json.tool
```

**✅ Kết quả đúng:**
```json
[
    {"status": "True",  "type": "Done"},
    {"status": "False", "type": "HasErrors"}
]
```

> Không cần `kubectl apply` thêm gì — realm đã được nhúng vào Helm chart.


---

## 11. Cài Redis

```bash
cd /home/npt102/gcp/Devops2/yas/k8s/deploy
./setup-redis.sh
```
Kiểm tra các pod:
kubectl get pods -n redis
---

## 12. Cấu hình /etc/hosts

**Khác biệt chính với Minikube:**

| Minikube | K3s |
|---|---|
| `192.168.49.2` (IP của Docker container) | IP của node máy chủ (lấy từ `kubectl get svc -n ingress-nginx ingress-nginx-controller`) |

Lấy EXTERNAL-IP thực tế:
```bash
INGRESS_IP=$(kubectl get svc -n ingress-nginx ingress-nginx-controller -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
echo "Dùng IP: $INGRESS_IP"
```

Trên máy này IP là `172.16.0.240`. Thêm vào `/etc/hosts`:

```bash
# Xóa các dòng cũ (nếu còn)
sudo sed -i '/yas.local.com/d' /etc/hosts

# Thêm entries cho K3s (thay 172.16.0.240 bằng EXTERNAL-IP của ingress-nginx)
sudo tee -a /etc/hosts <<'EOF'
# YAS K3s
172.16.0.240 yas.local.com
172.16.0.240 storefront.yas.local.com
172.16.0.240 backoffice.yas.local.com
172.16.0.240 api.yas.local.com
172.16.0.240 identity.yas.local.com
172.16.0.240 pgadmin.yas.local.com
172.16.0.240 akhq.yas.local.com
172.16.0.240 grafana.yas.local.com
172.16.0.240 kibana.yas.local.com
# Dev / Staging namespaces
172.16.0.240 dev.yas.local.com
172.16.0.240 backoffice.dev.yas.local.com
172.16.0.240 api.dev.yas.local.com
172.16.0.240 staging.yas.local.com
172.16.0.240 backoffice.staging.yas.local.com
172.16.0.240 api.staging.yas.local.com
172.16.0.240 developer.yas.local.com
172.16.0.240 api.developer.yas.local.com
EOF
```

**Kiểm tra:**

```bash
curl -s -o /dev/null -w "%{http_code}" --connect-timeout 5 http://identity.yas.local.com
# → 302 ✅ (không timeout, không cần tunnel!)
```

---

## 13. Deploy YAS Configuration + Applications

```bash
cd /home/npt102/gcp/Devops2/yas/k8s/deploy

# Deploy ConfigMaps + Secrets
./deploy-yas-configuration.sh

# Deploy 13 core services (hoặc dùng full stack nếu cần)
./deploy-yas-applications.sh
# Hoặc đầy đủ:
# Deploy YAS core stack + mesh policies
```

---

## 14. Cập nhật KUBE_CONFIG secret

GitHub Actions runner (self-hosted) cần kubeconfig để deploy lên K3s. Secret `KUBE_CONFIG` trong repo cần được cập nhật.

```bash
# Lấy kubeconfig K3s (đã có ở ~/.kube/config)
cat ~/.kube/config | base64 -w 0
# → Copy output này
```

Vào GitHub repo → **Settings → Secrets and variables → Actions → KUBE_CONFIG** → Update value bằng output ở trên.

> **Lưu ý:** K3s kubeconfig có `server: https://127.0.0.1:6443`. Runner tự-host trên cùng máy nên connect được. Nếu dùng runner từ xa, thay `127.0.0.1` bằng IP máy chủ.

---

## 15. Bật lại GitHub Actions Runner

```bash
# Kill process cũ (nếu còn)
pkill -f "Runner.Listener" 2>/dev/null || true

# Start runner
cd /home/npt102/gcp/Devops2/actions-runner
nohup ./run.sh > runner.log 2>&1 &

# Kiểm tra
ps aux | grep Runner.Listener | grep -v grep
```

---

## 16. Cài ArgoCD (GitOps)

ArgoCD theo dõi Git repo và tự động sync Helm charts vào cluster. Dùng cho môi trường `dev` và `staging`.

### 16.1 Cài ArgoCD

```bash
kubectl create namespace argocd

kubectl apply -n argocd \
  -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml \
  --server-side

# Chờ tất cả pod sẵn sàng (~2 phút)
kubectl wait --for=condition=Ready pods --all -n argocd --timeout=300s

kubectl get pods -n argocd
# argocd-application-controller-0         Running
# argocd-applicationset-controller-xxx    Running
# argocd-dex-server-xxx                   Running
# argocd-notifications-controller-xxx     Running
# argocd-redis-xxx                         Running
# argocd-repo-server-xxx                  Running
# argocd-server-xxx                       Running
```

### 16.2 Lấy mật khẩu admin

```bash
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath="{.data.password}" | base64 -d && echo
```

### 16.3 Truy cập ArgoCD UI

```bash
# Port-forward (chạy nền)
kubectl port-forward svc/argocd-server -n argocd 9090:443 &

# Mở trình duyệt: https://localhost:9090
# Username: admin  |  Password: <output ở trên>
```

### 16.4 Apply cấu hình Applications

```bash
cd /home/npt102/gcp/Devops2/yas

# Tạo project
kubectl apply -f argocd/applications/yas-project.yaml

# ApplicationSet cho dev
kubectl apply -f argocd/applications/dev-appset.yaml

# ApplicationSet cho staging
kubectl apply -f argocd/applications/staging-appset.yaml

# Kiểm tra
kubectl get applications -n argocd
```

### 16.5 Troubleshooting ArgoCD

**Lỗi CRD quá 256KB khi apply:**
```bash
# Dùng --server-side để tránh lỗi annotation quá lớn
kubectl apply -n argocd -f <manifest> --server-side
```

**App status Unknown hoặc OutOfSync:**
```bash
# Xem log repo-server
kubectl logs -n argocd deployment/argocd-repo-server

# Force refresh
kubectl -n argocd app get <tên-app> --refresh
```

---

## 17. Cài Istio Service Mesh (mTLS + Kiali)

Istio inject sidecar vào mỗi pod → toàn bộ traffic trong namespace `yas` đi qua mTLS. `ingress-nginx` cũng được inject để tham gia mesh.

### 17.1 Cài Istio với istioctl

```bash
cd /home/npt102/gcp/Devops2/yas

# Cài Istio profile demo với resource limits tối ưu
./istio-1.24.3/bin/istioctl install -f istio/istio-overlay.yaml -y

# Kiểm tra
kubectl get pods -n istio-system
# istiod-xxx                  Running
# istio-ingressgateway-xxx    Running
# istio-egressgateway-xxx     Running
```

### 17.2 Bật Istio sidecar injection

```bash
# Bật injection cho namespace yas
kubectl label namespace yas istio-injection=enabled

# Bật injection cho ingress-nginx (để ingress tham gia mesh → STRICT mTLS hoạt động)
kubectl label namespace ingress-nginx istio-injection=enabled

# Restart tất cả pod để nhận sidecar
kubectl rollout restart deployment -n yas
kubectl rollout restart deployment ingress-nginx-controller -n ingress-nginx

# Kiểm tra — mỗi pod phải có 2/2 containers (app + istio-proxy)
kubectl get pods -n yas
```

### 17.3 Apply mTLS STRICT

```bash
# PeerAuthentication: bắt buộc mTLS cho toàn namespace yas
kubectl apply -f istio/peer-authentication.yaml

# DestinationRule: mỗi service dùng ISTIO_MUTUAL, export cả sang ingress-nginx
kubectl apply -f istio/destination-rule.yaml

# AuthorizationPolicy: deny-all mặc định, chỉ allow ingress-nginx vào yas
kubectl apply -f istio/authorization-policy.yaml
```

> **Lưu ý:** `ingress-nginx` phải có sidecar (bước 16.2) và `DestinationRule` phải export sang namespace `ingress-nginx`, nếu không ingress sẽ nhận 502.

### 17.4 Cài addons: Kiali + Prometheus + Grafana

```bash
# Prometheus (bắt buộc cho Kiali metrics)
kubectl apply -f https://raw.githubusercontent.com/istio/istio/release-1.24/samples/addons/prometheus.yaml

# Grafana
kubectl apply -f https://raw.githubusercontent.com/istio/istio/release-1.24/samples/addons/grafana.yaml

# Kiali dashboard
kubectl apply -f https://raw.githubusercontent.com/istio/istio/release-1.24/samples/addons/kiali.yaml

# Chờ sẵn sàng
kubectl wait --for=condition=Ready pods --all -n istio-system --timeout=300s
```

### 17.5 Truy cập Kiali

```bash
# Port-forward Kiali
kubectl port-forward svc/kiali -n istio-system 20001:20001 &

# Mở trình duyệt: http://localhost:20001
# Vào menu Graph → chọn namespace "yas" để xem service mesh topology
```

### 17.6 Kiểm tra mTLS

```bash
# Verify PeerAuthentication
kubectl get peerauthentication -n yas

# Kiểm tra service-to-service traffic có mTLS
./istio-1.24.3/bin/istioctl experimental authz check \
  $(kubectl get pod -n yas -l app.kubernetes.io/name=product -o jsonpath='{.items[0].metadata.name}') \
  -n yas

# Curl test — storefront vẫn trả 200
curl -o /dev/null -w "%{http_code}" http://storefront.yas.local.com
# → 200 ✅
```

### 17.7 Troubleshooting Istio/Kiali

**502 Bad Gateway sau khi bật STRICT mTLS:**

Nguyên nhân: `ingress-nginx` không có sidecar hoặc `DestinationRule` chưa export sang namespace `ingress-nginx`.

```bash
# Kiểm tra ingress-nginx-controller có 2/2 containers không
kubectl get pod -n ingress-nginx -l app.kubernetes.io/name=ingress-nginx

# Kiểm tra DestinationRule có exportTo ingress-nginx không
kubectl get destinationrule -n yas -o yaml | grep exportTo

# Nếu thiếu: restart ingress-nginx
kubectl rollout restart deployment ingress-nginx-controller -n ingress-nginx
```

**Kiali báo "Namespace metrics is not available":**

```bash
# Cài lại Prometheus nếu chưa có
kubectl apply -f https://raw.githubusercontent.com/istio/istio/release-1.24/samples/addons/prometheus.yaml
kubectl rollout restart deployment/kiali -n istio-system
```

**Kiali KIA0601 — Port name không đúng format:**

Port metrics của backend service tên `metric`, phải đổi thành `http-metric`:

```bash
for svc in backoffice-bff cart customer inventory location media order product promotion rating recommendation sampledata search storefront-bff tax webhook; do
  kubectl patch svc "$svc" -n yas --type='json' \
    -p='[{"op":"replace","path":"/spec/ports/1/name","value":"http-metric"}]'
done
```

**DestinationRule wildcard host bị Kiali lỗi đỏ:**

Kiali v2.x không validate được `*.yas.svc.cluster.local`. Xóa wildcard và apply từng DestinationRule riêng (đã có trong `istio/destination-rule.yaml`):

```bash
kubectl delete destinationrule default-mtls-destination -n yas 2>/dev/null || true
kubectl apply -f istio/destination-rule.yaml
```

---

## 18. Kiểm tra tổng thể

```bash
# Tất cả pods phải Running
kubectl get pods -A | grep -v "Running\|Completed"
# → Không có output = tất cả OK

# Test các URL chính

```

**✅ Kết quả đúng:**
```
storefront.yas.local.com → 200
backoffice.yas.local.com → 302
identity.yas.local.com   → 302
pgadmin.yas.local.com    → 302
akhq.yas.local.com       → 307
```

---

## 19. Khôi phục sau reboot

**Cực đơn giản** — K3s tự start theo systemd:

```bash
# Sau reboot, chỉ cần kiểm tra:
systemctl status k3s
kubectl get nodes
kubectl get pods -A | grep -v "Running\|Completed"
```

Không còn cần:
- ~~`minikube start`~~
- ~~Fix `/etc/hosts`~~
- ~~Fix DNS `control-plane.minikube.internal`~~
- ~~Restart kube-proxy~~
- ~~`nohup minikube tunnel`~~
- ~~Set inotify trên Docker containers~~

Chỉ cần bật lại runner nếu tắt:

```bash
cd /home/npt102/gcp/Devops2/actions-runner && nohup ./run.sh > runner.log 2>&1 &
```

---

## 20. Bảng khác biệt Minikube vs K3s

### Thay đổi trong project

| Hạng mục | Minikube | K3s | Cần sửa? |
|---|---|---|---|
| `storageClassName` trong `es-standalone.yaml` | `standard` | `local-path` | ✅ Đã sửa trong repo |
| `/etc/hosts` IP | `192.168.49.2` | IP của node (`172.16.0.240` trên máy này) | ✅ Bước 12 |
| inotify (Docker nodes) | `docker exec minikube sysctl ...` | Không cần (K3s native) | ✅ Persist trong `/etc/sysctl.d/` |
| Port 80/443 access | `minikube tunnel` | Tự động (klipper-lb) | ✅ Không cần làm gì |
| `setup-cluster.sh` | Hoạt động bình thường | Hoạt động bình thường | Không |
| `fix-kafka-permissions.sh` | Cần | Vẫn cần | Không |
| Workflows GitHub Actions | Dùng KUBE_CONFIG | Dùng KUBE_CONFIG (cập nhật) | ✅ Bước 13 |

### Lưu ý về storage

K3s lưu PersistentVolume data tại:
```
/var/lib/rancher/k3s/storage/
```

Khi cần xóa data của 1 service để reset:
```bash
# Xóa PVC (dữ liệu sẽ mất)
kubectl delete pvc <tên-pvc> -n <namespace>
# K3s local-path-provisioner tự dọn thư mục
```

### Tắt K3s để tiết kiệm RAM

```bash
# Tắt (pods dừng, giải phóng RAM)
sudo systemctl stop k3s

# Bật lại
sudo systemctl start k3s
kubectl get nodes  # Chờ Ready
```

> Khác Minikube: Không cần bất kỳ fix nào sau khi `start` — mọi thứ tự phục hồi.

---

## Xử lý lỗi thường gặp trên K3s

### K3s start chậm hoặc node NotReady sau reboot

```bash
sudo systemctl restart k3s
kubectl wait --for=condition=Ready node --all --timeout=120s
```

### Ingress-nginx không nhận EXTERNAL-IP

K3s klipper-lb cần quyền bind port 80/443. Kiểm tra:
```bash
kubectl get svc -n ingress-nginx ingress-nginx-controller
# Nếu EXTERNAL-IP = <pending> quá lâu:
sudo systemctl restart k3s
```

### SELinux (Fedora) block K3s mount

```bash
# Kiểm tra SELinux có block không
sudo ausearch -m AVC -ts recent | grep k3s

# Nếu có: thêm flag --selinux khi cài K3s
# Hoặc tạm thời:
sudo setenforce 0
```

### Pod không phân giải được yas.local.com (UnknownHostException)

**Triệu chứng:** Pod log `java.net.UnknownHostException: identity.yas.local.com` — pod không dùng được `/etc/hosts` của host.

**Fix:** Thêm hostname vào CoreDNS ConfigMap, bên trong block `hosts /etc/coredns/NodeHosts {}` đang có sẵn:

```bash
kubectl edit configmap coredns -n kube-system
```

Tìm block `hosts /etc/coredns/NodeHosts {` và thêm các dòng sau **trước dòng `fallthrough`**:

```
172.16.0.240 identity.yas.local.com
172.16.0.240 api.yas.local.com
172.16.0.240 storefront.yas.local.com
172.16.0.240 backoffice.yas.local.com
172.16.0.240 yas.local.com
```

> **Lưu ý:** KHÔNG tạo block `hosts {}` mới — CoreDNS chỉ cho phép 1 block `hosts` per server. Phải thêm vào block đã có.

```bash
# Áp dụng ngay
kubectl rollout restart deployment/coredns -n kube-system

# Restart các pod bị ảnh hưởng
kubectl rollout restart deployment/backoffice-bff deployment/storefront-bff -n yas
```

### Tắt Istio tạm thời (khi máy lag hoặc pods bị 1/2)

**Triệu chứng:** Pods hiển thị `1/2 Running` hoặc `1/2 Error` — sidecar Istio inject vào nhưng istiod chưa cài hoặc crash → toàn bộ pods restart liên tục, máy cực lag.

```bash
# Bước 1: Xóa label injection
kubectl label namespace yas istio-injection-
kubectl label namespace ingress-nginx istio-injection- 2>/dev/null || true

# Bước 2: Restart tất cả pods để loại bỏ sidecar
kubectl rollout restart deployment -n yas
kubectl rollout restart deployment ingress-nginx-controller -n ingress-nginx

# Bước 3: Chờ pods về 1/1
kubectl get pods -n yas --watch
# → Tất cả READY 1/1 = OK
```

**Khi muốn bật lại Istio:** Xem lại [Bước 16](#16-cài-istio-service-mesh-mtls--kiali).

---

### Firewall block traffic (Fedora — PHẢI LÀM NGAY SAU CÀI K3s)

Fedora firewalld không tự nhận interface CNI của K3s → block inter-pod traffic → ingress-nginx 502 khi proxy đến pod.

**Triệu chứng:** `curl http://identity.yas.local.com` → 502, logs ingress-nginx có `connect() failed (113: Host is unreachable)`.

**Fix vĩnh viễn:**
```bash
sudo firewall-cmd --permanent --zone=trusted --add-interface=cni0
sudo firewall-cmd --permanent --zone=trusted --add-interface=flannel.1
sudo firewall-cmd --permanent --zone=trusted --add-source=10.42.0.0/16   # Pod CIDR
sudo firewall-cmd --permanent --zone=trusted --add-source=10.43.0.0/16   # Service CIDR
sudo firewall-cmd --reload

# Kiểm tra
curl -o /dev/null -w "%{http_code}" http://identity.yas.local.com/realms/Yas/.well-known/openid-configuration
# → 200 ✅
```

> **Lưu ý:** Các rule này persist qua reboot. Chỉ cần chạy một lần.
