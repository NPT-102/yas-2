# Hướng dẫn Chạy lại Từ Đầu Đến Cuối — K3s + YAS

> **Dùng khi:** Máy mới, sau khi gỡ cài đặt, hoặc muốn cài lại từ đầu.  
> **Môi trường:** fedora (control-plane, 172.16.0.240) + quoctan (worker, WSL2, 172.16.1.169)  
> **Thời gian ước tính:** ~45–60 phút

---

## Mục lục

1. [Cài công cụ cần thiết](#1-cài-công-cụ-cần-thiết)
2. [Cài K3s trên control plane (fedora)](#2-cài-k3s-trên-control-plane-fedora)
3. [Cấu hình kubeconfig](#3-cấu-hình-kubeconfig)
4. [Tăng giới hạn inotify](#4-tăng-giới-hạn-inotify)
5. [Cài ingress-nginx](#5-cài-ingress-nginx)
6. [Cấu hình /etc/hosts — làm SỚM](#6-cấu-hình-etchosts--làm-sớm)
7. [Thêm worker node (quoctan) — tùy chọn](#7-thêm-worker-node-quoctan--tùy-chọn)
8. [Build Helm dependencies](#8-build-helm-dependencies)
9. [Deploy Infrastructure (setup-cluster.sh)](#9-deploy-infrastructure-setup-clustersh)
10. [Fix Kafka — Strimzi CRD race condition](#10-fix-kafka--strimzi-crd-race-condition)
11. [Cài Keycloak](#11-cài-keycloak)
12. [Cài Redis](#12-cài-redis)
13. [Cập nhật CoreDNS](#13-cập-nhật-coredns)
14. [Deploy YAS Configuration](#14-deploy-yas-configuration)
15. [Deploy YAS Services (Minimal)](#15-deploy-yas-services-minimal)
16. [Cài Istio + Apply policies](#16-cài-istio--apply-policies)
17. [Cài ArgoCD](#17-cài-argocd)
18. [Kiểm tra tổng thể](#18-kiểm-tra-tổng-thể)
19. [Troubleshooting](#19-troubleshooting)

---

## 1. Cài công cụ cần thiết

```bash
# Kiểm tra xem đã có chưa
helm version && yq --version && kubectl version --client && git --version
```

**Kết quả đúng:**
```
version.BuildInfo{Version:"v3.x.x", ...}
yq (https://github.com/mikefarah/yq/) version v4.x.x
Client Version: v1.3x.x
```

**Cài nếu thiếu:**
```bash
# helm
curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

# yq
sudo wget -qO /usr/local/bin/yq https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64
sudo chmod +x /usr/local/bin/yq

# gh CLI (nếu cần trigger GitHub Actions thủ công)
sudo dnf install -y gh && gh auth login
```

---

## 2. Cài K3s trên control plane (fedora)

> **Bỏ qua nếu K3s đã cài** → kiểm tra: `sudo systemctl status k3s`  
> **KHÔNG dùng v1.35.x** — có bug cloud-controller-manager crash loop ngay khi bootstrap RBAC.

```bash
curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION=v1.32.5+k3s1 sh -s - \
  --disable=traefik \
  --write-kubeconfig-mode=644

sudo systemctl enable k3s
```

**Kết quả đúng:**
```bash
sudo systemctl status k3s
# ● k3s.service - Lightweight Kubernetes
#    Active: active (running) since ...

kubectl get nodes
# NAME     STATUS   ROLES                  AGE   VERSION
# fedora   Ready    control-plane,master   1m    v1.32.5+k3s1
```

**Tạo /etc/rancher/k3s/config.yaml (đầy đủ tham số, dễ bảo trì):**

```bash
sudo tee /etc/rancher/k3s/config.yaml <<'EOF'
# K3s server configuration

disable:
  - traefik

write-kubeconfig-mode: "644"

# CNI backend: host-gw (không encapsulation, route trực tiếp, nhanh hơn vxlan)
# Yêu cầu: control-plane và worker phải cùng L2 hoặc có route tới nhau
flannel-backend: host-gw
EOF
```

> Config này có hiệu lực ở lần **restart tiếp theo** của K3s. Nếu vừa cài mới từ đầu thì restart ngay:
> ```bash
> sudo systemctl restart k3s
> ```

---

## 3. Cấu hình kubeconfig

```bash
mkdir -p ~/.kube
sudo cp /etc/rancher/k3s/k3s.yaml ~/.kube/config
sudo chown $USER:$USER ~/.kube/config
chmod 600 ~/.kube/config
```

**Kiểm tra:**
```bash
kubectl cluster-info
# Kubernetes control plane is running at https://127.0.0.1:6443
# CoreDNS is running at https://127.0.0.1:6443/api/v1/namespaces/kube-system/services/kube-dns:dns/proxy
```

---

## 4. Tăng giới hạn inotify

Bắt buộc — nếu thiếu, K3s và nhiều pod sẽ lỗi `too many open files` hoặc `inotify limit reached`:

```bash
sudo sysctl -w fs.inotify.max_user_watches=524288
sudo sysctl -w fs.inotify.max_user_instances=512

# Persist qua reboot
sudo tee /etc/sysctl.d/99-k3s.conf <<'EOF'
fs.inotify.max_user_watches=524288
fs.inotify.max_user_instances=512
EOF
sudo sysctl --system
```

**Kiểm tra:**
```bash
sysctl fs.inotify.max_user_watches
# fs.inotify.max_user_watches = 524288
```

---

## 5. Cài ingress-nginx

K3s đã tắt Traefik (bước 2), cần cài ingress-nginx thay thế:

```bash
kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-v1.11.0/deploy/static/provider/cloud/deploy.yaml

kubectl wait --namespace ingress-nginx \
  --for=condition=Ready pod \
  --selector=app.kubernetes.io/component=controller \
  --timeout=180s
```

**Kết quả đúng:**
```bash
kubectl get svc -n ingress-nginx
# NAME                       TYPE           CLUSTER-IP      EXTERNAL-IP    PORT(S)
# ingress-nginx-controller   LoadBalancer   10.43.x.x       172.16.0.240   80:3xxxx/TCP,443:3xxxx/TCP
```

> K3s tích hợp sẵn **servicelb** (cloud controller), tự động gán EXTERNAL-IP bằng IP của node (172.16.0.240). Không cần MetalLB.

---

## 6. Cấu hình /etc/hosts — làm SỚM

> ⚠️ **Phải làm trước bước 15 (deploy-yas-minimal.sh)**. Script đó curl `identity.yas.local.com` để chờ Keycloak ready — nếu `/etc/hosts` chưa có thì script treo mãi không thoát.

```bash
sudo tee -a /etc/hosts <<'EOF'
# YAS local cluster
172.16.0.240 storefront.yas.local.com
172.16.0.240 backoffice.yas.local.com
172.16.0.240 api.yas.local.com
172.16.0.240 identity.yas.local.com
172.16.0.240 pgadmin.yas.local.com
172.16.0.240 akhq.yas.local.com
172.16.0.240 kibana.yas.local.com
172.16.0.240 dev.yas.local.com
172.16.0.240 backoffice.dev.yas.local.com
172.16.0.240 api.dev.yas.local.com
172.16.0.240 staging.yas.local.com
172.16.0.240 backoffice.staging.yas.local.com
172.16.0.240 api.staging.yas.local.com
EOF
```

**Kiểm tra:**
```bash
ping -c1 identity.yas.local.com
# PING identity.yas.local.com (172.16.0.240): 56 bytes...
```

---

## 7. Thêm worker node (quoctan) — tùy chọn

> Bỏ qua nếu chỉ chạy single-node hoặc quoctan không available.

### 7.1 Mở firewall trên fedora (control plane)

> **Lưu ý:** Đang dùng `host-gw` backend (không phải vxlan), nên **không cần mở port 8472/udp** và **không có interface flannel.1**.

```bash
# Chạy trên FEDORA
sudo firewall-cmd --permanent --add-port=6443/tcp    # Kubernetes API
sudo firewall-cmd --permanent --add-port=10250/tcp   # Kubelet API
sudo firewall-cmd --permanent --zone=trusted --add-interface=cni0
sudo firewall-cmd --permanent --zone=trusted --add-source=10.42.0.0/16  # Pod CIDR
sudo firewall-cmd --permanent --zone=trusted --add-source=10.43.0.0/16  # Service CIDR
sudo firewall-cmd --permanent --zone=trusted --add-source=172.16.1.0/24 # Subnet quoctan
sudo firewall-cmd --reload

# Verify
sudo firewall-cmd --list-all
```

### 7.2 Lấy join token từ fedora

```bash
sudo cat /var/lib/rancher/k3s/server/node-token
# K10xxxxxxxxxxxxxxxxxxxx::server:xxxxxxxxxxxxxxxxxxxxxxxx
```

### 7.3 Cài K3s agent trên quoctan (WSL2)

```bash
# Chạy trên QUOCTAN — thay TOKEN và IP
CONTROL_PLANE_IP="172.16.0.240"
TOKEN="<token từ bước trên>"

curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION=v1.32.5+k3s1 \
  K3S_URL="https://${CONTROL_PLANE_IP}:6443" \
  K3S_TOKEN="${TOKEN}" \
  sh -

sudo systemctl enable k3s-agent
```

### 7.4 Fix inotify trên quoctan

```bash
# Chạy trên QUOCTAN
sudo sysctl -w fs.inotify.max_user_watches=524288
sudo sysctl -w fs.inotify.max_user_instances=512
sudo tee /etc/sysctl.d/99-k3s.conf <<'EOF'
fs.inotify.max_user_watches=524288
fs.inotify.max_user_instances=512
EOF
```

### 7.5 Verify từ fedora

```bash
kubectl get nodes
# NAME      STATUS   ROLES                  AGE   VERSION
# fedora    Ready    control-plane,master   ...   v1.32.5+k3s1
# quoctan   Ready    <none>                 ...   v1.32.5+k3s1
```

### 7.6 Pin CoreDNS lên fedora

Phòng tránh DNS fail cluster-wide khi quoctan mất kết nối:

```bash
kubectl patch deployment coredns -n kube-system --type=merge -p '{
  "spec": {"template": {"spec": {"nodeSelector": {"kubernetes.io/hostname": "fedora"}}}}
}'
kubectl rollout restart deployment coredns -n kube-system
kubectl wait pod -n kube-system -l k8s-app=kube-dns --for=condition=Ready --timeout=60s
```

---

## 8. Build Helm dependencies

Phải làm sau mỗi lần `git clone` hoặc `checkout` — file `.tgz` trong `.gitignore` không được commit:

```bash
cd /home/npt102/gcp/Devops2/yas

for chart in k8s/charts/*/; do
  helm dependency build "$chart" --skip-refresh 2>/dev/null && echo "OK $chart" || echo "SKIP $chart"
done
```

**Kết quả đúng:** Không có dòng `Error:`, chỉ có `OK` hoặc `SKIP` (chart không có dependencies).

---

## 9. Deploy Infrastructure (setup-cluster.sh)

> Chạy từ thư mục `k8s/deploy/` vì script dùng đường dẫn tương đối.

```bash
cd /home/npt102/gcp/Devops2/yas/k8s/deploy

# Xem cấu hình trước khi chạy
cat cluster-config.yaml

bash setup-cluster.sh
```

**Script cài theo thứ tự:**

| Thứ tự | Component | Namespace |
|---|---|---|
| 1 | Istio 1.24.3 (via istioctl) | `istio-system` |
| 2 | postgres-operator | `postgres` |
| 3 | PostgreSQL | `postgres` |
| 4 | pgAdmin | `postgres` |
| 5 | strimzi-kafka-operator | `kafka` |
| 6 | kafka-cluster (Kafka + Debezium) | `kafka` |
| 7 | AKHQ | `kafka` |
| 8 | ECK operator | `elasticsearch` |
| 9 | elasticsearch-cluster | `elasticsearch` |
| 10 | Zookeeper | `zookeeper` |

> **Lưu ý:** Script tự động gọi `fix-kafka-permissions.sh` sau khi tạo PVC Kafka. Script dùng `set -x` nên in ra rất nhiều output — bình thường.

**Chờ và kiểm tra:**
```bash
# Theo dõi pods đang khởi động
watch kubectl get pods -A | grep -Ev "Running|Completed"

# Kiểm tra từng namespace
kubectl get pods -n postgres       # postgres-operator, postgres-*, pgadmin
kubectl get pods -n kafka          # strimzi-*, kafka-cluster-*, akhq
kubectl get pods -n elasticsearch  # elastic-operator, elasticsearch-es-node-0
kubectl get pods -n zookeeper      # zookeeper-0
kubectl get pods -n istio-system   # istiod, istio-ingressgateway
```

**Kết quả đúng — tất cả pods:**
```
NAME                                  READY   STATUS    RESTARTS
elastic-operator-0                    1/1     Running   0
elasticsearch-es-node-0               1/1     Running   0
postgres-operator-xxx                 1/1     Running   0
postgres-xxx-0                        1/1     Running   0
kafka-cluster-dual-role-0             1/1     Running   0
strimzi-cluster-operator-xxx          1/1     Running   0
istiod-xxx                            1/1     Running   0
```

---

## 10. Fix Kafka — Strimzi CRD race condition

`setup-cluster.sh` có thể lỗi ở bước cài `kafka-cluster` vì CRDs của Strimzi chưa kịp register sau khi cài operator. Kiểm tra và fix:

```bash
# Kiểm tra xem kafka-cluster đã deploy chưa
helm status kafka-cluster -n kafka 2>&1

# Nếu lỗi "no matches for kind Kafka":
kubectl wait --for=condition=Ready pod -n kafka \
  -l name=strimzi-cluster-operator --timeout=120s

# Re-deploy kafka-cluster
cd /home/npt102/gcp/Devops2/yas/k8s/deploy
helm upgrade --install kafka-cluster ./kafka/kafka-cluster \
  --namespace kafka \
  --set kafka.replicas=1 \
  --set zookeeper.replicas=1 \
  --set postgresql.username=yasadminuser \
  --set postgresql.password=admin
```

**Kiểm tra Kafka hoạt động:**
```bash
kubectl get kafka -n kafka
# NAME              DESIRED KAFKA REPLICAS   DESIRED ZK REPLICAS   READY
# kafka-cluster     1                        1                     True

kubectl get pod kafka-cluster-dual-role-0 -n kafka
# NAME                        READY   STATUS    RESTARTS
# kafka-cluster-dual-role-0   1/1     Running   0
```

---

## 11. Cài Keycloak

```bash
cd /home/npt102/gcp/Devops2/yas/k8s/deploy
bash setup-keycloak.sh
```

Script này cài:
- Keycloak operator CRDs (từ GitHub keycloak-k8s-resources 26.0.2)
- Keycloak instance (qua Helm chart)
- **Realm "Yas" được import tự động** qua CRD `KeycloakRealmImport` có sẵn trong chart

**Chờ Keycloak ready (~3-5 phút):**
```bash
kubectl wait pod -n keycloak \
  -l app.kubernetes.io/managed-by=keycloak-operator \
  --for=condition=Ready --timeout=300s
```

**Kiểm tra:**
```bash
kubectl get keycloak -n keycloak
# NAME       READY   STATUS    AGE
# keycloak   True    ...       ...

kubectl get keycloakrealmimport -n keycloak
# NAME           DONE    STARTED AT             ERRORS
# yas-realm-kc   true    ...

# Test realm API
curl -s http://identity.yas.local.com/realms/Yas/.well-known/openid-configuration \
  | python3 -m json.tool | grep issuer
# "issuer": "http://identity.yas.local.com/realms/Yas"
```

---

## 12. Cài Redis

```bash
cd /home/npt102/gcp/Devops2/yas/k8s/deploy
bash setup-redis.sh
```

Script cài Redis via OCI chart từ Docker Hub với password `redis` (theo `cluster-config.yaml`).

**Kiểm tra:**
```bash
kubectl get pods -n redis
# NAME               READY   STATUS    RESTARTS
# redis-master-0     1/1     Running   0
# redis-replicas-0   1/1     Running   0

# Test kết nối
kubectl exec -n redis redis-master-0 -- redis-cli -a redis ping
# PONG
```

---

## 13. Cập nhật CoreDNS

Các Spring Boot services cần kết nối Keycloak qua hostname `identity.yas.local.com`. Trỏ hostname này thẳng đến ClusterIP để bypass ingress (tránh loop):

```bash
KEYCLOAK_IP=$(kubectl get svc keycloak-service -n keycloak -o jsonpath='{.spec.clusterIP}')
echo "Keycloak ClusterIP: $KEYCLOAK_IP"

kubectl patch configmap coredns -n kube-system --type=merge -p "{
  \"data\": {
    \"NodeHosts\": \"${KEYCLOAK_IP} identity.yas.local.com\n\"
  }
}"

kubectl rollout restart deployment coredns -n kube-system
kubectl wait pod -n kube-system -l k8s-app=kube-dns --for=condition=Ready --timeout=60s
```

**Kiểm tra DNS resolution từ trong cluster:**
```bash
kubectl run dns-test --image=busybox:1.28 --restart=Never --rm -it -- \
  sh -c "nslookup identity.yas.local.com"
# Server: 10.43.0.10
# Name: identity.yas.local.com
# Address: 10.43.x.x   ← ClusterIP của keycloak-service (KHÔNG phải 172.16.0.240)
```

---

## 14. Deploy YAS Configuration

Deploy ConfigMaps và Secrets cho tất cả services (env vars, DB URL, Kafka, Redis...):

```bash
cd /home/npt102/gcp/Devops2/yas/k8s/deploy
bash deploy-yas-configuration.sh
```

**Kiểm tra:**
```bash
kubectl get configmap -n yas | head -20
# NAME                    DATA   AGE
# yas-config              1      ...
# ...

kubectl get secret -n yas | grep -v "kubernetes.io/service-account"
```

---

## 15. Deploy YAS Services (Minimal)

Deploy 13 services thiết yếu, bỏ: location, payment, payment-paypal, promotion, rating, recommendation, webhook, sampledata.

> ⚠️ **Yêu cầu:** `/etc/hosts` đã có `identity.yas.local.com` (bước 6) và Keycloak realm đã ready (bước 11). Script sẽ poll Keycloak trước khi tiếp tục.

```bash
cd /home/npt102/gcp/Devops2/yas/k8s/deploy
bash deploy-yas-minimal.sh
```

Script deploy theo thứ tự: backoffice-bff → backoffice-ui → storefront-bff → storefront-ui → swagger-ui → 8 backend services (product, cart, order, customer, inventory, tax, media, search).

**Theo dõi (~10-15 phút):**
```bash
watch kubectl get pods -n yas
```

**Kết quả đúng (TRƯỚC khi cài Istio):**
```
NAME                            READY   STATUS    RESTARTS
backoffice-bff-xxx              1/1     Running   0
backoffice-ui-xxx               1/1     Running   0
cart-xxx                        1/1     Running   0
customer-xxx                    1/1     Running   0
...
```

**Kết quả đúng (SAU khi cài Istio sidecar injection):**
```
NAME                            READY   STATUS    RESTARTS
backoffice-bff-xxx              2/2     Running   0   ← 2/2 = app + istio-proxy
```

---

## 16. Cài Istio + Apply policies

`setup-cluster.sh` đã cài Istio istiod. Bước này label namespace và apply policies.

### 16.1 Verify Istio istiod đang chạy

```bash
kubectl get pods -n istio-system
# NAME                    READY   STATUS    RESTARTS
# istiod-xxx              1/1     Running   0
```

### 16.2 Label namespace + inject sidecar

```bash
kubectl label namespace yas istio-injection=enabled --overwrite
kubectl label namespace ingress-nginx istio-injection=enabled --overwrite

# Restart để inject sidecar vào pods hiện có
kubectl rollout restart deployment -n yas
kubectl rollout restart deployment ingress-nginx-controller -n ingress-nginx

# Chờ tất cả pods ready
kubectl wait pods -n yas --all --for=condition=Ready --timeout=300s
```

### 16.3 Apply Istio policies

```bash
cd /home/npt102/gcp/Devops2/yas

# mTLS STRICT (bắt buộc mọi traffic đều phải có mTLS)
kubectl apply -f istio/peer-authentication.yaml

# DestinationRules (circuit breaker + load balancing cho từng service)
kubectl apply -f istio/destination-rule.yaml

# AuthorizationPolicies (deny-all + whitelist)
kubectl apply -f istio/authorization-policy.yaml

# VirtualService với retry policy
kubectl apply -f istio/virtual-service-retry.yaml
```

**Kiểm tra:**
```bash
kubectl get peerauthentication -n yas
# NAME      MODE     AGE
# default   STRICT   ...

kubectl get destinationrule -n yas | wc -l
# 22  (header + 21 services)

kubectl get authorizationpolicy -n yas
# NAME           ACTION   AGE
# deny-all       DENY     ...
# allow-xxx      ALLOW    ...  (nhiều dòng)
```

### 16.4 Verify không có 502

Sau khi inject sidecar vào ingress-nginx:
```bash
curl -s -o /dev/null -w "%{http_code}\n" http://storefront.yas.local.com
# 200 hoặc 302 (redirect đến Keycloak login)

curl -s -o /dev/null -w "%{http_code}\n" http://api.yas.local.com/swagger-ui
# 200
```

> Nếu `502`: sidecar ingress-nginx chưa inject → `kubectl rollout restart deployment ingress-nginx-controller -n ingress-nginx`

---

## 17. Cài ArgoCD

```bash
kubectl create namespace argocd

# --server-side bắt buộc vì CRD của ArgoCD > 256KB (client-side apply sẽ lỗi annotation limit)
kubectl apply -n argocd \
  -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml \
  --server-side

kubectl wait --for=condition=Ready pods --all -n argocd --timeout=300s
```

**Kết quả đúng:**
```bash
kubectl get pods -n argocd
# NAME                                   READY   STATUS    RESTARTS
# argocd-application-controller-0        1/1     Running   0
# argocd-applicationset-controller-xxx   1/1     Running   0
# argocd-dex-server-xxx                  1/1     Running   0
# argocd-notifications-controller-xxx    1/1     Running   0
# argocd-redis-xxx                       1/1     Running   0
# argocd-repo-server-xxx                 1/1     Running   0
# argocd-server-xxx                      1/1     Running   0
```

**Lấy password admin:**
```bash
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath="{.data.password}" | base64 -d && echo
```

### 17.1 Apply ApplicationSets

```bash
cd /home/npt102/gcp/Devops2/yas

kubectl apply -f argocd/applications/yas-project.yaml --server-side
kubectl apply -f argocd/applications/dev-appset.yaml --server-side
kubectl apply -f argocd/applications/staging-appset.yaml --server-side
```

**Kiểm tra:**
```bash
kubectl get appproject -n argocd
# NAME    AGE
# yas     ...

kubectl get applications -n argocd | wc -l
# 41  (header + 20 dev + 20 staging + yas-configuration)
```

### 17.2 Truy cập ArgoCD UI

```bash
kubectl port-forward svc/argocd-server -n argocd 9090:443 &
# Mở: https://localhost:9090
# Username: admin | Password: <từ bước trên>
```

---

## 18. Kiểm tra tổng thể

Chạy từng lệnh theo thứ tự — tất cả phải pass:

```bash
# 1. Nodes
kubectl get nodes
# fedora   Ready   control-plane,master   ...   v1.32.5+k3s1

# 2. Infra pods
kubectl get pods -n postgres -n kafka -n elasticsearch -n zookeeper -n keycloak -n redis \
  | grep -v "Running\|Completed"
# → Không có output = tất cả OK

# 3. YAS pods (2/2 với Istio)
kubectl get pods -n yas
# Tất cả READY=2/2, STATUS=Running

# 4. Ingress
kubectl get ingress -n yas
# Tất cả có ADDRESS=172.16.0.240

# 5. Endpoints có dữ liệu (không có <none>)
kubectl get endpoints -n yas | grep -v "^NAME\|<none>"

# 6. Istio analysis
istioctl analyze -n yas
# ✔ No validation issues found when analyzing namespace: yas.

# 7. HTTP test
curl -si http://storefront.yas.local.com | head -5
# HTTP/1.1 200 OK  (hoặc 302 Found → redirect login)

curl -si http://backoffice.yas.local.com | head -5
# HTTP/1.1 200 OK  (hoặc 302 Found)

curl -si http://api.yas.local.com/swagger-ui | head -5
# HTTP/1.1 200 OK

# 8. Keycloak API
curl -s http://identity.yas.local.com/realms/Yas/.well-known/openid-configuration \
  | python3 -m json.tool | grep '"issuer"'
# "issuer": "http://identity.yas.local.com/realms/Yas"

# 9. ArgoCD apps synced
kubectl get applications -n argocd -o wide | grep -v Synced
# → Chỉ có header, không có app nào OutOfSync
```

---

## 19. Troubleshooting

### 19.1 deploy-yas-minimal.sh treo chờ Keycloak

**Triệu chứng:** Script in `Waiting for Keycloak realm 'Yas' to be ready...` rồi không tiến tiếp.

**Nguyên nhân:** `/etc/hosts` chưa có `identity.yas.local.com` → curl không resolve được domain.

**Fix:**
```bash
# Thoát script bằng Ctrl+C
# Thêm hosts entry (bước 6), sau đó chạy lại script
```

---

### 19.2 Kafka lỗi "no matches for kind Kafka"

**Triệu chứng:**
```
Error: no matches for kind "Kafka" in version "kafka.strimzi.io/v1beta2"
```

**Nguyên nhân:** Race condition — `kafka-cluster` deploy trước khi Strimzi operator đăng ký CRDs.

**Fix:**
```bash
kubectl wait --for=condition=Ready pod -n kafka \
  -l name=strimzi-cluster-operator --timeout=120s

cd /home/npt102/gcp/Devops2/yas/k8s/deploy
helm upgrade --install kafka-cluster ./kafka/kafka-cluster \
  --namespace kafka \
  --set kafka.replicas=1 \
  --set zookeeper.replicas=1 \
  --set postgresql.username=yasadminuser \
  --set postgresql.password=admin
```

---

### 19.3 Pod Pending — PV nodeAffinity conflict

**Triệu chứng:** Pod stuck `Pending`, describe thấy `didn't match node selector`.

**Nguyên nhân:** PersistentVolume được tạo với `nodeAffinity` gắn vào node cũ (ví dụ `minikube`) nhưng giờ node tên `fedora`.

**Fix:**
```bash
# Xem PV nào bị conflict
kubectl get pv | grep -v "Bound"
kubectl describe pv <pv-name> | grep -A5 "nodeAffinity"

# Xóa PV + PVC để tạo lại (mất data)
kubectl delete pvc <pvc-name> -n <namespace>
kubectl delete pv <pv-name>
# Pod sẽ tự tạo PVC mới với PV đúng node
```

---

### 19.4 502 Bad Gateway

**Triệu chứng:** `curl http://storefront.yas.local.com` trả về `502`.

**Nguyên nhân:** ingress-nginx chưa có Istio sidecar → mTLS STRICT reject kết nối.

**Fix:**
```bash
kubectl label namespace ingress-nginx istio-injection=enabled --overwrite
kubectl rollout restart deployment ingress-nginx-controller -n ingress-nginx
kubectl wait pod -n ingress-nginx --all --for=condition=Ready --timeout=120s
```

---

### 19.5 DNS timeout trong pod

**Triệu chứng:** Spring Boot log `Unable to connect to identity.yas.local.com`, hoặc curl từ trong pod bị timeout.

**Nguyên nhân:** CoreDNS pod chết (thường khi worker node disconnect).

**Fix:**
```bash
kubectl delete pod -n kube-system -l k8s-app=kube-dns
kubectl wait pod -n kube-system -l k8s-app=kube-dns --for=condition=Ready --timeout=60s
```

---

### 19.6 ImagePullBackOff

**Triệu chứng:** Pod stuck `ImagePullBackOff`.

**Debug:**
```bash
kubectl describe pod <pod-name> -n yas | grep -A10 "Events:"
```

**Nguyên nhân thường gặp:**
- Docker Hub rate limit (anonymous pull) → cần imagePullSecret
- Image tag không tồn tại trên Docker Hub → kiểm tra `npt219/yas-k3s-<service>:latest`

---

### 19.7 ArgoCD OutOfSync mãi

**Triệu chứng:** App luôn `OutOfSync` dù đã sync nhiều lần.

**Debug:**
```bash
argocd app diff <app-name>
```

**Nguyên nhân thường gặp:** Helm chart thiếu file `.tgz` dependency (do `.gitignore`).

**Fix:**
```bash
cd /home/npt102/gcp/Devops2/yas
helm dependency build k8s/charts/<service-name>
git add k8s/charts/<service-name>/charts/
git commit -m "fix: add helm chart dependencies"
git push
```

---

## Quick Reference — Thứ tự chạy

```
Bước 1   helm + yq + kubectl
Bước 2   Cài K3s v1.32.5+k3s1 (--disable=traefik)
Bước 3   /etc/rancher/k3s/config.yaml (flannel-backend: host-gw)
Bước 4   kubeconfig ~/.kube/config
Bước 5   inotify limits
Bước 6   ingress-nginx
Bước 7   /etc/hosts  ← PHẢI LÀM TRƯỚC deploy-yas-minimal.sh
Bước 8   (Optional) Worker node quoctan + firewall
Bước 9   helm dependency build k8s/charts/*/
Bước 10  cd k8s/deploy && bash setup-cluster.sh
Bước 11  Fix Kafka nếu CRD race condition
Bước 12  bash setup-keycloak.sh
Bước 13  bash setup-redis.sh
Bước 14  CoreDNS patch (identity → Keycloak ClusterIP)
Bước 15  bash deploy-yas-configuration.sh
Bước 16  bash deploy-yas-minimal.sh
Bước 17  Istio: label ns + apply policies
Bước 18  ArgoCD + ApplicationSets
```
