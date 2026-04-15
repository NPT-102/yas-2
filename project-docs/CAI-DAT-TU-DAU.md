# Hướng dẫn cài đặt cluster từ đầu (Fresh Install)

> **Dùng khi:** Cluster hoàn toàn mới (vừa `minikube start`), hoặc sau khi `minikube delete`.  
> **Thời gian tổng:** ~45-60 phút (phần lớn là chờ pods khởi động).  
> **Yêu cầu máy:** Tối thiểu 4 CPU + 8GB RAM. Khuyến nghị 6 CPU + 12GB RAM.

---

## Mục lục

1. [Bước 1: Tạo cluster Minikube](#bước-1-tạo-cluster-minikube)
2. [Bước 2: Tăng giới hạn inotify](#bước-2-tăng-giới-hạn-inotify)
3. [Bước 3: Cài Ingress Controller](#bước-3-cài-ingress-controller)
4. [Bước 4: Cài công cụ cần thiết](#bước-4-cài-công-cụ-cần-thiết)
5. [Bước 5: Chạy setup-cluster.sh (Infrastructure)](#bước-5-chạy-setup-clustersh-infrastructure)
6. [Bước 6: Fix Loki (lỗi schema_config)](#bước-6-fix-loki-lỗi-schema_config)
7. [Bước 7: Fix Prometheus (lỗi assertNoLeakedSecrets)](#bước-7-fix-prometheus-lỗi-assertnoleakedsecrets)
8. [Bước 8: Chờ infrastructure pods Ready](#bước-8-chờ-infrastructure-pods-ready)
9. [Bước 9: Fix Kafka broker (nếu cần)](#bước-9-fix-kafka-broker-nếu-cần)
10. [Bước 10: Deploy Elasticsearch standalone](#bước-10-deploy-elasticsearch-standalone)
11. [Bước 11: Cài Keycloak](#bước-11-cài-keycloak)
12. [Bước 12: Import Keycloak Realm](#bước-12-import-keycloak-realm)
13. [Bước 13: Cài Redis](#bước-13-cài-redis)
14. [Bước 14: Deploy YAS Configuration](#bước-14-deploy-yas-configuration)
15. [Bước 15: Deploy YAS Applications](#bước-15-deploy-yas-applications)
16. [Bước 16: Cấu hình /etc/hosts](#bước-16-cấu-hình-etchosts)
17. [Bước 17: Kiểm tra tổng thể](#bước-17-kiểm-tra-tổng-thể)
18. [Bước 18: (Tùy chọn) Cài Istio Service Mesh](#bước-18-tùy-chọn-cài-istio-service-mesh)
19. [Bước 19: Bật GitHub Actions Runner](#bước-19-bật-github-actions-runner)
20. [Các vấn đề thường gặp và cách giải quyết](#các-vấn-đề-thường-gặp-và-cách-giải-quyết)

---

## Bước 1: Tạo cluster Minikube

> **Bỏ qua nếu đã có cluster đang chạy** (kiểm tra: `minikube status`).

```bash
# Tạo cluster 2 nodes
minikube start --cpus=6 --memory=12288 --driver=docker

# Thêm worker node
minikube node add
```


Hoặc 
```
# Gộp chung 1 lệnh
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

**❌ Nếu minikube-m02 không hiện:** Chờ 1 phút rồi chạy lại `kubectl get nodes`.
Nếu vẫn thiếu: `docker start minikube-m02 && sleep 10 && kubectl get nodes`.

---

## Bước 2: Tăng giới hạn inotify

Minikube mặc định giới hạn inotify rất thấp → Promtail và nhiều pods sẽ crash "too many open files".

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

## Bước 3: Cài Ingress Controller

```bash
minikube addons enable ingress
```

**✅ Kết quả đúng:**
```
💡  ingress is an addon maintained by Kubernetes. For any concerns contact minikube on GitHub.
🔎  Verifying ingress addon...
🌟  The 'ingress' addon is enabled
```

Chờ controller Ready (~1 phút):

```bash
kubectl get pods -n ingress-nginx -w
```

**✅ Kết quả đúng** (nhấn Ctrl+C khi thấy):
```
NAME                                        READY   STATUS      RESTARTS   AGE
ingress-nginx-admission-create-xxxxx        0/1     Completed   0          1m
ingress-nginx-admission-patch-xxxxx         0/1     Completed   0          1m
ingress-nginx-controller-xxxxx              1/1     Running     0          1m
```

---

## Bước 4: Cài công cụ cần thiết

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

## Bước 5: Chạy setup-cluster.sh (Infrastructure)

Script này cài tất cả infrastructure: PostgreSQL, Kafka, Elasticsearch operator.
(Lưu ý: Toàn bộ stack Observability gồm Loki, Prometheus, Grafana, Tempo, OpenTelemetry đã được lược bỏ khỏi đồ án để tiết kiệm RAM).

```bash
cd /home/npt102/gcp/Devops2/yas/k8s/deploy
./setup-cluster.sh
```

> ⏱ **Mất ~5-10 phút.** Script sẽ in rất nhiều output. Toàn bộ các tuỳ chỉnh giới hạn RAM cho Istio Sidecar cũng được chạy kèm bên trong script này tự động.

**Sau khi script chạy xong, kiểm tra namespaces đã được tạo:**

```bash
kubectl get ns
```

**✅ Kết quả đúng** (phải thấy TẤT CẢ các namespace sau):
```
NAME              STATUS   AGE
cert-manager      Active   5m <- Không xài Observability nên xóa rồi
default           Active   20m
elasticsearch     Active   8m
ingress-nginx     Active   15m
kafka             Active   10m
kube-node-lease   Active   20m
kube-public       Active   20m
kube-system       Active   20m
postgres          Active   12m
zookeeper         Active   3m
```

**❌ Nếu thiếu namespace nào** → script fail sớm hơn dự kiến. Kiểm tra lỗi và chạy lại:
```bash
./setup-cluster.sh 2>&1 | tail -50
```

---

## Bước 6: [LƯU Ý - KIẾN THỨC] Fix Loki (lỗi schema_config + permission denied)

> 💡 **Lưu ý quan trọng:** Bước 6 này hiện tại **KHÔNG CẦN CHẠY NỮA**. Cụm Observability đã bị loại bỏ hoàn toàn trong code mới. Tài liệu dưới đây chỉ được giữ lại để lưu trữ lại lịch sử config lỗi của phiên bản trước để phục vụ việc bảo vệ đồ án!

Chart Loki phiên bản mới bắt buộc `schema_config`, và trên Minikube hostPath provisioner
tạo PVC với quyền root nhưng Loki chạy với user 10001 → **permission denied**.

**Bước 6a: Uninstall Loki cũ (đang failed) và xóa PVC:**

```bash
helm uninstall loki -n observability
kubectl delete pvc -n observability -l app.kubernetes.io/name=loki --wait=false
kubectl delete pvc -n observability export-0-loki-minio-0 export-1-loki-minio-0 --wait=false 2>/dev/null
sleep 10
```

**Bước 6b: Reinstall với security context override:**

```bash
cd /home/npt102/gcp/Devops2/yas/k8s/deploy
helm upgrade --install loki grafana/loki \
  --namespace observability \
  -f ./observability/loki.values.yaml \
  --set loki.useTestSchema=true \
  --set loki.podSecurityContext.runAsNonRoot=false \
  --set loki.podSecurityContext.runAsUser=0 \
  --set loki.podSecurityContext.runAsGroup=0 \
  --set loki.podSecurityContext.fsGroup=0 \
  --set loki.containerSecurityContext.readOnlyRootFilesystem=false \
  --set loki.containerSecurityContext.allowPrivilegeEscalation=false \
  --set minio.podSecurityContext.enabled=false \
  --set minio.containerSecurityContext.enabled=false \
  --timeout 5m --wait=false
```

> ⚠️ Helm có thể báo "failed" do post-install hook timeout. **Đây là bình thường** — pods vẫn chạy OK.
> Nếu bị "failed", chờ 1-2 phút cho pods Ready rồi chạy lại lệnh trên (lần 2 sẽ là `upgrade` → status sẽ thành `deployed`).

**✅ Kết quả đúng:**
```
Release "loki" does not exist. Installing it now.
NAME: loki
LAST DEPLOYED: ...
NAMESPACE: observability
STATUS: deployed
```

Chờ Loki pods Ready (~2-3 phút):

```bash
kubectl get pods -n observability -l app.kubernetes.io/name=loki
```

**✅ Kết quả đúng** (tất cả pods phải Running hoặc Ready):
```
NAME                            READY   STATUS    RESTARTS   AGE
loki-backend-0                  2/2     Running   0          2m
loki-canary-xxxxx               1/1     Running   0          2m
loki-canary-yyyyy               1/1     Running   0          2m
loki-chunks-cache-0             2/2     Running   0          2m
loki-gateway-xxxxx              1/1     Running   0          2m
loki-minio-0                    1/1     Running   0          2m
loki-read-xxxxx                 1/1     Running   0          2m
loki-results-cache-0            2/2     Running   0          2m
loki-write-0                    1/1     Running   0          2m
```

> Nếu một số pod vẫn `ContainerCreating` → chờ thêm 2 phút. Nếu `CrashLoopBackOff` → xem log: `kubectl logs <pod-name> -n observability`

---

## Bước 7: [LƯU Ý - KIẾN THỨC] Fix Prometheus (lỗi assertNoLeakedSecrets)

> 💡 **Lưu ý quan trọng:** Bước 7 này hiện tại **KHÔNG CẦN CHẠY NỮA**. Prometheus đã bị gỡ bỏ để tiết kiệm RAM. Thông tin dưới đây chỉ để lưu lại cách fix sự cố trước đó!

Chart Grafana mới kiểm tra password trong values file → fail. Tắt validation:

```bash
cd /home/npt102/gcp/Devops2/yas/k8s/deploy
helm upgrade --install prometheus prometheus-community/kube-prometheus-stack \
  --namespace observability \
  -f ./observability/prometheus.values.yaml \
  --set grafana.assertNoLeakedSecrets=false
```

**✅ Kết quả đúng:**
```
Release "prometheus" does not exist. Installing it now.
NAME: prometheus
LAST DEPLOYED: ...
NAMESPACE: observability
STATUS: deployed
```

Chờ Prometheus + Grafana Ready (~2 phút):

```bash
kubectl get pods -n observability | grep -E "prometheus|grafana|alertmanager"
```

**✅ Kết quả đúng:**
```
alertmanager-prometheus-kube-prometheus-alertmanager-0   2/2     Running   0   2m
prometheus-grafana-xxxxx                                3/3     Running   0   2m
prometheus-kube-prometheus-operator-xxxxx               1/1     Running   0   2m
prometheus-kube-state-metrics-xxxxx                     1/1     Running   0   2m
prometheus-prometheus-kube-prometheus-prometheus-0       2/2     Running   0   2m
prometheus-prometheus-node-exporter-xxxxx               1/1     Running   0   2m (1 mỗi node)
```

---

## Bước 8: Chờ infrastructure pods Ready

Kiểm tra tổng thể infrastructure:

```bash
echo "=== postgres ===" && kubectl get pods -n postgres
echo ""
echo "=== kafka ===" && kubectl get pods -n kafka
echo ""
echo "=== elasticsearch ===" && kubectl get pods -n elasticsearch
```

**✅ Kết quả đúng cho postgres:**
```
NAME                                 READY   STATUS    RESTARTS   AGE
pgadmin-xxxxx                        1/1     Running   0          10m
postgres-operator-xxxxx              1/1     Running   0          12m
postgresql-0                         1/1     Running   0          10m
```

> **❌ Nếu `postgresql-0` không có:** Kiểm tra template: `helm template postgres ./postgres/postgresql --set username=yasadminuser --set password=admin | grep "{ {"`. Nếu thấy `{ {` có space → file template bị lỗi (đã sửa trong repo này, nhưng nếu clone từ gốc thì cần sửa thủ công).

**✅ Kết quả đúng cho kafka:**
```
NAME                                          READY   STATUS    RESTARTS   AGE
akhq-xxxxx                                    1/1     Running   0          8m
kafka-cluster-dual-role-0                     1/1     Running   0          8m
kafka-cluster-entity-operator-xxxxx           2/2     Running   0          5m
strimzi-cluster-operator-xxxxx                1/1     Running   0          10m
```

> **❌ Nếu `kafka-cluster-dual-role-0` bị CrashLoopBackOff:** Xem [Bước 9](#bước-9-fix-kafka-broker-nếu-cần).
>
> **❌ Nếu `kafka-cluster-dual-role-0` không tồn tại:** Chờ thêm 2 phút (operator cần thời gian reconcile). Nếu vẫn thiếu → restart operator: `kubectl rollout restart deployment/strimzi-cluster-operator -n kafka`

**✅ Kết quả đúng cho elasticsearch:**
```
NAME                                  READY   STATUS    RESTARTS   AGE
elastic-operator-0                    1/1     Running   0          8m
```

> ES operator chỉ là management layer. ES thực sự sẽ deploy ở Bước 10.



## Bước 9: Fix Kafka broker (nếu cần)

> **Bỏ qua nếu `kafka-cluster-dual-role-0` đã 1/1 Running ở bước 8.**

Kafka trên Minikube thường gặp lỗi permissions do hostPath provisioner:

```bash
kubectl logs kafka-cluster-dual-role-0 -n kafka --tail=20
```

**Nếu thấy lỗi `Permission denied` hoặc `cannot write`:**

```bash
# Chạy script fix permissions
bash /home/npt102/gcp/Devops2/yas/k8s/deploy/fix-kafka-permissions.sh

# Xóa pod để recreate
kubectl delete pod kafka-cluster-dual-role-0 -n kafka

# Chờ pod mới Running (~1-2 phút)
kubectl get pods -n kafka -w
```

**✅ Kết quả đúng sau fix:**
```
kafka-cluster-dual-role-0   1/1   Running   0   1m
```

**Nếu Debezium Connect pod bị Error:**
Đây là lỗi đã biết (image Kafka 3.x + server Kafka 4.1.0 không tương thích). **Bỏ qua:**
```bash
kubectl scale kafkaconnect/debezium-connect-cluster --replicas=0 -n kafka 2>/dev/null
```

---

## Bước 10: Deploy Elasticsearch standalone

ECK operator không tương thích ES 9.x + K8s 1.35. Dùng standalone StatefulSet:

```bash
cd /home/npt102/gcp/Devops2/yas/k8s/deploy
kubectl apply -f elasticsearch/es-standalone.yaml -n elasticsearch
```

**✅ Kết quả đúng:**
```
statefulset.apps/elasticsearch-standalone created
service/elasticsearch-es-http created
```

Chờ pod Ready (~1-2 phút):

```bash
kubectl get pods -n elasticsearch -w
```

**✅ Kết quả đúng:**
```
NAME                          READY   STATUS    RESTARTS   AGE
elastic-operator-0            1/1     Running   0          15m
elasticsearch-standalone-0    1/1     Running   0          1m
```

**Kiểm tra ES hoạt động:**

```bash
kubectl exec -n elasticsearch elasticsearch-standalone-0 -- \
  curl -s http://localhost:9200/_cluster/health
```

**✅ Kết quả đúng:**
```json
{"cluster_name":"docker-cluster","status":"green","number_of_nodes":1,...}
```

> `status` phải là `green` hoặc `yellow`. Nếu `red` → xem logs: `kubectl logs elasticsearch-standalone-0 -n elasticsearch`

---

## Bước 11: Cài Keycloak

> **Cần PostgreSQL Running trước!** Keycloak phụ thuộc PostgreSQL để lưu data.
> Kiểm tra: `kubectl get pods -n postgres | grep postgresql-0` — phải 1/1 Running.

```bash
cd /home/npt102/gcp/Devops2/yas/k8s/deploy
./setup-keycloak.sh
```

**✅ Kết quả đúng:**
```
namespace/keycloak created
customresourcedefinition.apiextensions.k8s.io/keycloaks.k8s.keycloak.org created
customresourcedefinition.apiextensions.k8s.io/keycloakrealmimports.k8s.keycloak.org created
...
Release "keycloak" does not exist. Installing it now.
NAME: keycloak
NAMESPACE: keycloak
STATUS: deployed
```

Chờ Keycloak Ready (~3 phút — pod lớn, khởi động chậm):

```bash
kubectl get pods -n keycloak -w
```

**✅ Kết quả đúng:**
```
NAME                                 READY   STATUS    RESTARTS   AGE
keycloak-0                           1/1     Running   0          3m
keycloak-operator-xxxxx              1/1     Running   0          3m
```

> **❌ Nếu keycloak-0 bị `CrashLoopBackOff`:**
> ```bash
> kubectl logs keycloak-0 -n keycloak --tail=30
> ```
> Thường do PostgreSQL chưa sẵn sàng. Fix: `kubectl delete pod keycloak-0 -n keycloak` và chờ.

---

## Bước 12: Kiểm tra Keycloak Realm

Helm chart Keycloak tự động import realm từ file `Yas-realm.json`. Pod `yas-realm-kc-xxxxx`
(status Completed) là job import. Kiểm tra:

```bash
# Xem log job import
kubectl logs -n keycloak -l app=keycloak-realm-import --tail=5
```

**✅ Kết quả đúng:**
```
... Realm 'Yas' imported
... Keycloak stopped in 0.055s
```

> ⚠️ **Tên realm là `Yas` (viết hoa Y)**, không phải `yas`.

**Kiểm tra realm hoạt động:**

```bash
# Service name là keycloak-service (KHÔNG phải keycloak)
kubectl port-forward svc/keycloak-service -n keycloak 8888:80 &
sleep 2
curl -s http://localhost:8888/realms/Yas/.well-known/openid-configuration | head -1
kill %1 2>/dev/null
```

**✅ Kết quả đúng:**
```
{"issuer":"http://identity.yas.local.com/realms/Yas","authorization_endpoint":...}
```

**Nếu muốn xem qua web browser:**

```bash
kubectl port-forward svc/keycloak-service -n keycloak 8888:80 &
```

Mở http://localhost:8888 → Login: `admin` / `admin` → Dropdown "master" → chọn **"Yas"**
→ **Clients** → phải thấy: `backoffice-bff`, `storefront-bff`, `swagger-ui`, v.v.

```bash
kill %1 2>/dev/null
```

### Nếu realm chưa được import tự động

> Trường hợp pod `yas-realm-kc-xxxxx` không tồn tại hoặc lỗi:

```bash
# (kubectl cp /home/npt102/gcp/Devops2/yas/identity/realm-export.json \
#   keycloak/keycloak-0:/tmp/realm-export.json)
# Copy file realm vào pod (Dùng cat input thay vì cp do container Keycloak không có lệnh tar)
cat /home/npt102/gcp/Devops2/yas/identity/realm-export.json | kubectl exec -i -n keycloak keycloak-0 -- sh -c "cat > /tmp/realm-export.json"

# Login admin (service port 80 bên trong cluster)
kubectl exec -n keycloak keycloak-0 -- /opt/keycloak/bin/kcadm.sh config credentials \
  --server http://localhost:8080 --realm master --user admin --password admin

# Tạo realm rồi import
kubectl exec -n keycloak keycloak-0 -- /opt/keycloak/bin/kcadm.sh create realms \
  -s realm=Yas -s enabled=true
kubectl exec -n keycloak keycloak-0 -- /opt/keycloak/bin/kcadm.sh create partialImport \
  -r Yas -s ifResourceExists=SKIP -f /tmp/realm-export.json
```

---

## Bước 13: Cài Redis

```bash
cd /home/npt102/gcp/Devops2/yas/k8s/deploy
./setup-redis.sh
```

**✅ Kết quả đúng:**
```
Release "redis" does not exist. Installing it now.
Pulled: registry-1.docker.io/bitnamicharts/redis:...
NAME: redis
NAMESPACE: redis
STATUS: deployed
```

Chờ Redis Ready (~1-2 phút):

```bash
kubectl get pods -n redis -w
```

**✅ Kết quả đúng:**
```
NAME               READY   STATUS    RESTARTS   AGE
redis-master-0     1/1     Running   0          1m
redis-replicas-0   1/1     Running   0          1m
```

> **❌ Nếu `redis-replicas-1` (hoặc replicas-2) bị CrashLoopBackOff:**
>
> Lỗi `Permission denied: appendonlydir` — do hostPath trên worker node (minikube-m02) 
> không cùng quyền. Fix: giảm replica count xuống 1 (đủ cho dev):
>
> ```bash
 kubectl scale statefulset redis-replicas -n redis --replicas=1
 kubectl delete pvc redis-data-redis-replicas-1 -n redis --wait=false 2>/dev/null
 kubectl delete pvc redis-data-redis-replicas-2 -n redis --wait=false 2>/dev/null
> ```
>
> **Kết quả sau fix:** 2 pods Running (master-0 + replicas-0).

---

## Bước 14: Deploy YAS Configuration

Deploy ConfigMaps và Secrets cần thiết cho tất cả microservices:

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

**✅ Kết quả đúng:**
- ConfigMaps: **>10** items
- Secrets: **>5** items

```bash
# Xem danh sách ConfigMaps
kubectl get cm -n yas
```

Phải thấy các ConfigMap như: `application`, `backoffice-bff`, `storefront-bff`, `cart`, 
`customer`, `media`, `order`, `payment`, `product`, `search`, v.v.

---

## Bước 15: Deploy YAS Applications

Deploy tất cả 21 microservices. Script deploy lần lượt, mỗi service cách 60 giây:

```bash
cd /home/npt102/gcp/Devops2/yas/k8s/deploy
./deploy-yas-applications.sh
```

> ⏱ **Mất ~25-30 phút.** Script deploy theo thứ tự:
> 1. backoffice-bff + backoffice-ui (chờ 60s)
> 2. storefront-bff + storefront-ui (chờ 60s)
> 3. swagger-ui (chờ 20s)
> 4. 16 backend services: cart, customer, inventory, location, media, order, payment,
>    payment-paypal, product, promotion, rating, search, tax, recommendation, webhook,
>    sampledata (mỗi service chờ 60s)

**Theo dõi tiến trình (terminal khác):**

```bash
watch -n 10 'echo "Running:" && kubectl get pods -n yas --no-headers | grep -c Running && echo "Total:" && kubectl get pods -n yas --no-headers | wc -l && echo "" && kubectl get pods -n yas --no-headers | grep -Ev Running'
```

**✅ Kết quả đúng khi script chạy xong:**

```bash
kubectl get pods -n yas
```

```
NAME                                READY   STATUS             RESTARTS   AGE
backoffice-bff-xxxxx                1/1     Running            0          25m
backoffice-ui-xxxxx                 1/1     Running            0          25m
cart-xxxxx                          1/1     Running            0          20m
customer-xxxxx                      1/1     Running            0          19m
inventory-xxxxx                     1/1     Running            0          18m
location-xxxxx                      1/1     Running            0          17m
media-xxxxx                         1/1     Running            0          16m
order-xxxxx                         1/1     Running            0          15m
payment-xxxxx                       1/1     Running            0          14m
payment-paypal-xxxxx                0/1     CrashLoopBackOff   5          13m   ← BÌNH THƯỜNG
product-xxxxx                       1/1     Running            0          12m
promotion-xxxxx                     1/1     Running            0          11m
rating-xxxxx                        1/1     Running            0          10m
recommendation-xxxxx                1/1     Running            0          5m
sampledata-xxxxx                    1/1     Running            0          3m
search-xxxxx                        1/1     Running            0          9m
storefront-bff-xxxxx                1/1     Running            0          24m
storefront-ui-xxxxx                 1/1     Running            0          24m
swagger-ui-xxxxx                    1/1     Running            0          22m
tax-xxxxx                           1/1     Running            0          7m
webhook-xxxxx                       1/1     Running            0          4m
```

**Tổng: 20/21 Running là ĐÚNG.** (22 pods tổng nếu tính yas-reloader)

> **payment-paypal `CrashLoopBackOff`** là lỗi đã biết — image gốc từ repo bị lỗi
> (`no main manifest attribute in /app.jar`). Không khắc phục được. Scale to 0 nếu muốn:
> ```bash
> kubectl scale deployment/payment-paypal --replicas=0 -n yas
> ```

> **❌ Nếu `payment` bị `ImagePullBackOff`:**
>
> Image `ghcr.io/nashtech-garage/yas-payment:fixed` không tồn tại trên GHCR.
> Ngoài ra image `latest` trên registry cũ bị lỗi Liquibase (column `is_enabled` vs `enabled`).
> **Fix: Build local image và load vào Minikube:**
>
> ```bash
> # 1. Cài parent POM + dependencies
> cd /home/npt102/gcp/Devops2/yas
> mvn install -N -DskipTests
> mvn install -pl common-library,payment-paypal -am -DskipTests -Dspring-boot.repackage.skip=true
>
> # 2. Build payment jar
> mvn package -pl payment -am -DskipTests
>
> # 3. Build Docker image
> cd payment
> docker build -t ghcr.io/nashtech-garage/yas-payment:local-fix .
>
> # 4. Load vào cả 2 nodes Minikube
> minikube image load ghcr.io/nashtech-garage/yas-payment:local-fix
> docker save ghcr.io/nashtech-garage/yas-payment:local-fix | \
>   docker exec -i minikube-m02 ctr -n=k8s.io images import -
>
> # 5. Drop + recreate payment database (Liquibase sẽ chạy lại từ đầu)
> kubectl exec -it postgresql-0 -n postgres -- psql -U yasadminuser -d postgres \
>   -c "DROP DATABASE IF EXISTS payment; CREATE DATABASE payment;"
>
> # 6. Cập nhật deployment dùng image local
> kubectl set image deployment/payment payment=ghcr.io/nashtech-garage/yas-payment:local-fix -n yas
> kubectl patch deployment payment -n yas \
>   -p '{"spec":{"template":{"spec":{"containers":[{"name":"payment","imagePullPolicy":"Never"}]}}}}'
>
> # 7. Chờ pod mới Running (~30s)
> kubectl get pods -n yas -l app.kubernetes.io/name=payment -w
> ```

> **❌ Nếu nhiều pods bị Pending:**
> Thiếu resource. Kiểm tra:
> ```bash
> kubectl describe pod <tên-pod-pending> -n yas | tail -10
> ```
> Fix: Giảm resource bằng cách chưa cài Istio/ArgoCD, hoặc tăng RAM khi tạo minikube.

---

## Bước 16: Cấu hình /etc/hosts

Thêm domain mappings vào máy host để browser truy cập được:

```bash
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
```

**Kiểm tra:**

```bash
grep yas /etc/hosts
```

**✅ Kết quả đúng:**
```
192.168.49.2 yas.local.com api.yas.local.com backoffice.yas.local.com storefront.yas.local.com
192.168.49.2 identity.yas.local.com pgadmin.yas.local.com
192.168.49.2 kibana.yas.local.com akhq.yas.local.com
192.168.49.2 dev.yas.local.com api.dev.yas.local.com backoffice.dev.yas.local.com
...
```

---

## Bước 17: Kiểm tra tổng thể

### 17a. Script kiểm tra toàn bộ cluster

```bash
echo "========== NODES =========="
kubectl get nodes
echo ""

echo "========== NAMESPACES =========="
kubectl get ns --no-headers | awk '{print $1}' | sort
echo ""

echo "========== INFRASTRUCTURE =========="
for ns in postgres kafka elasticsearch keycloak redis ingress-nginx; do
  running=$(kubectl get pods -n $ns --no-headers 2>/dev/null | grep -c Running || echo 0)
  total=$(kubectl get pods -n $ns --no-headers 2>/dev/null | wc -l || echo 0)
  printf "  %-20s %s/%s Running\n" "$ns" "$running" "$total"
done
echo ""

echo "========== YAS =========="
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
========== NODES ==========
minikube       Ready    control-plane   ...
minikube-m02   Ready    <none>          ...

========== INFRASTRUCTURE ==========
  postgres             3/3 Running
  kafka                3/4 Running        (Debezium có thể Error — bình thường)
  elasticsearch        2/2 Running
  keycloak             2/2 Running
  redis                1/4 Running        (hoặc 4/4 tùy chart)
  ingress-nginx        1/3 Running        (2 Completed admission jobs)

========== YAS ==========
  yas: 20/21 Running                      (payment-paypal crash — bình thường)
```

### 17b. Truy cập web kiểm tra

| URL | Mong đợi | Credentials |
|-----|----------|-------------|
| http://storefront.yas.local.com | Trang storefront hiện sản phẩm | — |
| http://backoffice.yas.local.com | Trang admin backoffice | — |
| http://identity.yas.local.com | Keycloak login page | admin / admin |
| http://pgadmin.yas.local.com | pgAdmin database manager | Xem config |
| http://akhq.yas.local.com | AKHQ Kafka manager | — |
| http://api.yas.local.com/swagger-ui | Swagger API docs | — |

> **❌ Nếu không truy cập được:** Kiểm tra:
> 1. `/etc/hosts` đã có đúng IP: `grep yas /etc/hosts`
> 2. Ingress controller Running: `kubectl get pods -n ingress-nginx`
> 3. Ingress rules tồn tại: `kubectl get ingress -n yas`
> 4. Service running: `kubectl get pods -n yas | grep <tên-service>`

---

## Bước 18: (Tùy chọn) Cài Istio Service Mesh

> Chỉ cần nếu muốn demo phần nâng cao: mTLS, authorization policy, retry.  
> **Cảnh báo:** Istio thêm sidecar proxy vào mỗi pod → tăng RAM usage.  
> **Yêu cầu:** Tất cả YAS services phải đang Running trước khi bật Istio.

### 18a. Cài Istio với resource limits

> ⚠️ Binary `istioctl` nằm trong thư mục `istio-1.24.3/bin/` (KHÔNG phải `istio-1.29.1`).  
> Nếu chạy `istioctl: command not found` → kiểm tra lại PATH.

```bash
cd /home/npt102/gcp/Devops2/yas

# Set PATH đến đúng thư mục chứa istioctl
export PATH=$PWD/istio-1.24.3/bin:$PATH

# Kiểm tra
istioctl version --remote=false
# client version: 1.24.3
```

**Cài Istio với resource limits** (quan trọng cho Minikube — không set limits sẽ ngốn rất nhiều RAM):

```bash
# Dùng overlay file có sẵn resource limits
istioctl install -f istio/istio-overlay.yaml -y
```

File `istio/istio-overlay.yaml` đã cấu hình sẵn:
- **istiod** (pilot): 128Mi request / 512Mi limit
- **Ingress gateway**: 64Mi request / 256Mi limit
- **Egress gateway**: 64Mi request / 256Mi limit
- **Sidecar proxy** (mỗi pod): 40Mi request / 128Mi limit

> ⚠️ Nếu KHÔNG dùng overlay, default sidecar proxy limit là **1Gi mỗi pod** → với 20+ services
> tổng reserve ~20GB chỉ cho sidecar. **PHẢI dùng overlay!**

**✅ Kết quả đúng:**
```
✔ Istio core installed
✔ Istiod installed
✔ Ingress gateways installed
✔ Egress gateways installed
✔ Installation complete
```

Chờ pods Ready (~1 phút):

```bash
kubectl get pods -n istio-system
```

**✅ Kết quả đúng:**
```
NAME                                    READY   STATUS    RESTARTS   AGE
istio-egressgateway-xxxxx               1/1     Running   0          1m
istio-ingressgateway-xxxxx              1/1     Running   0          1m
istiod-xxxxx                            1/1     Running   0          1m
```

**Kiểm tra resource limits đã được apply:**

```bash
kubectl get pods -n istio-system -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{range .spec.containers[*]}  {.name}: req={.resources.requests.memory} lim={.resources.limits.memory}{"\n"}{end}{end}'
```

**✅ Kết quả đúng:**
```
istio-egressgateway-xxxxx
  istio-proxy: req=64Mi lim=256Mi
istio-ingressgateway-xxxxx
  istio-proxy: req=64Mi lim=256Mi
istiod-xxxxx
  discovery: req=128Mi lim=512Mi
```

### 18b. Enable sidecar injection

```bash
# Label namespace để tự động inject sidecar vào mọi pod
kubectl label namespace yas istio-injection=enabled --overwrite

# Restart tất cả pods để inject sidecar (mỗi pod sẽ có thêm container istio-proxy)
kubectl rollout restart deployment -n yas
```

> ⏱ **Chờ 3-5 phút** cho tất cả pods restart. Trong thời gian này:
> - Pods sẽ lần lượt Terminating → ContainerCreating → Running
> - Một số service có thể CrashLoopBackOff tạm thời nếu Keycloak/PostgreSQL chưa kịp Ready
> - **Đây là bình thường** — pods sẽ tự recover sau 1-2 phút

**Kiểm tra sidecar đã được inject:**

```bash
kubectl get pods -n yas | head -5
```

```
NAME                       READY   STATUS
cart-xxxxx                 2/2     Running     ← 2/2 = có sidecar (app + istio-proxy)
customer-xxxxx             2/2     Running
media-xxxxx                2/2     Running
```

> **❌ Nếu pods vẫn 1/1** (không có sidecar): Kiểm tra label → `kubectl get ns yas --show-labels | grep istio-injection`

### 18c. Apply Istio policies

```bash
cd /home/npt102/gcp/Devops2/yas

# mTLS STRICT — bắt buộc mã hóa traffic giữa tất cả services
kubectl apply -f istio/peer-authentication.yaml

# DestinationRule — enforce ISTIO_MUTUAL TLS cho *.yas.svc.cluster.local
kubectl apply -f istio/destination-rule.yaml

# Authorization Policies — deny-all + selective ALLOW
# (BFF→backends, order→cart/payment/inventory/tax/customer, payment→paypal, search→product)
kubectl apply -f istio/authorization-policy.yaml

# VirtualService Retry — tự động retry 5xx cho tax, order, cart, payment, product
kubectl apply -f istio/virtual-service-retry.yaml
```

**✅ Kiểm tra policies đã apply:**

```bash
echo "=== PeerAuthentication ===" && kubectl get peerauthentication -n yas
echo "=== DestinationRule ===" && kubectl get destinationrule -n yas
echo "=== AuthorizationPolicy ===" && kubectl get authorizationpolicy -n yas
echo "=== VirtualService ===" && kubectl get virtualservice -n yas
```

**✅ Kết quả đúng:**
```
=== PeerAuthentication ===
NAME           MODE     AGE
default-mtls   STRICT   1m

=== DestinationRule ===
NAME                       HOST                          AGE
default-mtls-destination   *.yas.svc.cluster.local       1m

=== AuthorizationPolicy ===
NAME                       ACTION   AGE
allow-bff-to-backends      ALLOW    1m
allow-order-dependencies   ALLOW    1m
allow-order-to-customer    ALLOW    1m
allow-order-to-inventory   ALLOW    1m
allow-order-to-payment     ALLOW    1m
allow-order-to-tax         ALLOW    1m
allow-payment-to-paypal    ALLOW    1m
allow-search-to-product    ALLOW    1m
deny-all                            1m

=== VirtualService ===
NAME            GATEWAYS   HOSTS        AGE
cart-retry                 ["cart"]      1m
order-retry                ["order"]    1m
payment-retry              ["payment"]  1m
product-retry              ["product"]  1m
tax-retry                  ["tax"]      1m
```

### 18d. (Tùy chọn) Cài Kiali dashboard

> Kiali dùng để visualize service mesh topology. **Chỉ cài nếu có đủ RAM** (~200MB thêm).

```bash
kubectl apply -f istio-1.24.3/samples/addons/kiali.yaml
kubectl apply -f istio-1.24.3/samples/addons/prometheus.yaml
```

### 18e. Troubleshooting Istio

**❌ Pods bị CrashLoopBackOff sau khi bật Istio:**

Nguyên nhân phổ biến: Services gọi đến Keycloak (`identity.yas.local.com`) qua ingress (external domain)
nhưng Keycloak chưa kịp khởi động lại. Chờ Keycloak Ready rồi pods sẽ tự recover:

```bash
# Kiểm tra Keycloak
kubectl get pod keycloak-0 -n keycloak
# Nếu chưa Running → chờ hoặc: kubectl delete pod keycloak-0 -n keycloak
```

**❌ `istioctl: command not found`:**

```bash
# Binary nằm ở istio-1.24.3, KHÔNG phải istio-1.29.1
export PATH=/home/npt102/gcp/Devops2/yas/istio-1.24.3/bin:$PATH
istioctl version --remote=false
```

**❌ Sidecar proxy dùng quá nhiều RAM (1Gi/pod):**

Nếu cài Istio KHÔNG dùng overlay file, mỗi sidecar proxy sẽ có limit 1Gi. Fix:

```bash
# Reinstall với overlay
istioctl install -f istio/istio-overlay.yaml -y

# Restart pods để nhận limit mới
kubectl rollout restart deployment -n yas
```

**❌ Service-to-service bị blocked (403 RBAC access denied):**

Do `deny-all` AuthorizationPolicy + thiếu ALLOW rule. Kiểm tra:

```bash
# Xem log của pod bị block
kubectl logs <pod-name> -n yas -c istio-proxy --tail=20 | grep "RBAC"

# Nếu cần tạm tắt authorization để debug:
kubectl delete authorizationpolicy deny-all -n yas
# (Nhớ apply lại sau khi debug xong)
```

---

## Bước 19: Bật GitHub Actions Runner

> Cần runner khi muốn chạy workflows deploy: dev-deploy, staging-deploy, developer_build, cleanup.
> Workflow CI (`npt-ci.yml`) chạy trên GitHub-hosted runner → không cần.

```bash
cd /home/npt102/gcp/Devops2/actions-runner

# Kiểm tra runner đã chạy chưa
ps aux | grep Runner.Listener | grep -v grep

# Nếu chưa → khởi động
nohup ./run.sh > runner.log 2>&1 &

# Kiểm tra log
tail -5 runner.log
```

**✅ Kết quả đúng:**
```
√ Connected to GitHub
Current runner version: '2.333.1'
...
Listening for Jobs
```

**Kiểm tra trên GitHub:**
Vào https://github.com/NPT-102/yas-2/settings/actions/runners
→ Runner "fedora" hiện trạng thái **Idle** (xanh lá).

---

## Tổng kết thứ tự chạy (Quick Reference)

```
1.  minikube start + node add                    ← Cluster
2.  docker exec ... sysctl inotify               ← Fix limits
3.  minikube addons enable ingress               ← Ingress
4.  ./setup-cluster.sh                           ← Infrastructure (~15 phút, sẽ fail 2 chỗ)
5.  helm install loki ... --set useTestSchema    ← Fix Loki
6.  helm install prometheus ... --set assertNo   ← Fix Prometheus
7.  (chờ pods Ready)                             ← ~5 phút
8.  fix-kafka-permissions.sh (nếu cần)           ← Fix Kafka
9.  kubectl apply -f es-standalone.yaml          ← Elasticsearch
10. ./setup-keycloak.sh                          ← Keycloak (~3 phút)
11. Import realm-export.json                     ← Keycloak realm
12. ./setup-redis.sh                             ← Redis
13. ./deploy-yas-configuration.sh                ← ConfigMaps + Secrets
14. ./deploy-yas-applications.sh                 ← 21 services (~25 phút)
15. Sửa /etc/hosts                               ← Domain mapping
16. Kiểm tra                                     ← Verify
17. (Tùy chọn) istioctl install -f overlay  ← Istio + limits
18. (Tùy chọn) ./run.sh                          ← Runner
```

**Tổng thời gian: ~45-60 phút** (phần lớn là chờ pods khởi động).

---

## Các vấn đề thường gặp và cách giải quyết

### Vấn đề 1: Storefront / Backoffice trả về lỗi 500

**Triệu chứng:** Truy cập `http://storefront.yas.local.com` hoặc `http://backoffice.yas.local.com` trả về HTTP 500.

**Nguyên nhân:** Các BFF services (storefront-bff, backoffice-bff) gọi backend qua hostname docker-compose (ví dụ `localhost:8080`, `localhost:8087`). Trong K8s, các hostname này không tồn tại → BFF không kết nối được backend → trả 500.

**Cách fix:** Tạo ExternalName services hoặc kiểm tra ConfigMap trỏ đúng service name K8s:

```bash
# Kiểm tra ConfigMap của BFF
kubectl get cm storefront-bff -n yas -o yaml | grep -i url
kubectl get cm backoffice-bff -n yas -o yaml | grep -i url

# Nếu thấy URL trỏ localhost hoặc docker-compose hostnames → cần sửa
# URL đúng phải là: http://<service-name>:80 hoặc http://<service-name>
# Ví dụ: PRODUCT_URL=http://product, MEDIA_URL=http://media

# Sau khi sửa ConfigMap, restart BFF:
kubectl rollout restart deployment/storefront-bff -n yas
kubectl rollout restart deployment/backoffice-bff -n yas
```

---

### Vấn đề 2: PVC bị Pending mãi không tạo được

**Triệu chứng:** Pods bị Pending, describe thấy `waiting for a volume to be created`.

```bash
kubectl get pvc -A | grep Pending
```

**Nguyên nhân:** Addon `storage-provisioner` bị disabled hoặc chưa bật.

**Cách fix:**

```bash
minikube addons enable storage-provisioner
minikube addons enable default-storageclass

# Kiểm tra StorageClass tồn tại
kubectl get sc
# NAME                 PROVISIONER                RECLAIMPOLICY
# standard (default)   k8s.io/minikube-hostpath   Delete
```

---

### Vấn đề 3: RAM vượt ngưỡng — hệ thống chậm / swap nhiều

**Triệu chứng:** Máy chạy chậm, `free -h` thấy swap usage cao (>4GB), Docker stats thấy nodes dùng >90% memory.

```bash
free -h
docker stats --no-stream --format "table {{.Name}}\t{{.MemUsage}}" | grep minikube
```

**Nguyên nhân:** Quá nhiều pods chạy mà không set resource limits → pods dùng RAM không giới hạn.

**Cách fix tạm thời (Emergency):** Scale down các service KHÔNG cần thiết:

```bash
# Tắt observability stack (tiết kiệm ~4-6GB)
helm uninstall loki -n observability
helm uninstall prometheus -n observability
helm uninstall promtail -n observability

# Tắt Kafka + ES (tiết kiệm ~2-3GB)
kubectl scale statefulset kafka-cluster-dual-role --replicas=0 -n kafka
kubectl scale statefulset elasticsearch-standalone --replicas=0 -n elasticsearch

# Scale non-critical yas services
kubectl scale deployment/payment-paypal --replicas=0 -n yas
kubectl scale deployment/sampledata --replicas=0 -n yas
kubectl scale deployment/recommendation --replicas=0 -n yas
```

**Cách fix bền vững:** Set resource limits cho TẤT CẢ services:

```bash
# YAS Java backend services (mỗi service 512Mi limit)
for svc in cart customer inventory location media order payment product promotion rating search tax recommendation sampledata webhook; do
  helm upgrade $svc k8s/charts/backend -n yas \
    --set backend.resources.requests.memory=256Mi \
    --set backend.resources.limits.memory=512Mi \
    --reuse-values
done

# YAS UI services (NextJS, 512Mi limit)
helm upgrade storefront-ui k8s/charts/storefront-ui -n yas \
  -f k8s/charts/storefront-ui/values.yaml
helm upgrade backoffice-ui k8s/charts/backoffice-ui -n yas \
  -f k8s/charts/backoffice-ui/values.yaml

# Swagger UI (128Mi)
helm upgrade swagger-ui k8s/charts/swagger-ui -n yas \
  -f k8s/charts/swagger-ui/values.yaml
```

**Kiểm tra pods nào CHƯA có limits:**

```bash
kubectl get pods -A -o json | jq -r '
  .items[] | select(.status.phase=="Running") |
  .spec.containers[] | select(.resources.limits.memory == null) |
  "\(.name)"' | sort -u
```

---

### Vấn đề 4: Kafka entity-operator bị OOMKilled

**Triệu chứng:** Pod `kafka-cluster-entity-operator` restart liên tục, `kubectl describe` thấy `OOMKilled`.

```bash
kubectl describe pod -n kafka -l strimzi.io/name=kafka-cluster-entity-operator | grep -A3 "Last State"
```

**Nguyên nhân:** Default memory limit của entity-operator quá nhỏ (64-128Mi) cho Kafka 4.x.

**Cách fix:** Sửa `kafka-cluster.yaml` tăng limits cho entity-operator:

```yaml
# Trong file k8s/deploy/kafka/kafka-cluster/templates/kafka-cluster.yaml
# Thêm/sửa phần entityOperator:
spec:
  entityOperator:
    topicOperator:
      resources:
        requests:
          memory: 256Mi
        limits:
          memory: 512Mi
    userOperator:
      resources:
        requests:
          memory: 256Mi
        limits:
          memory: 512Mi
```

```bash
# Apply
cd /home/npt102/gcp/Devops2/yas/k8s/deploy
helm upgrade kafka-cluster ./kafka/kafka-cluster -n kafka
```

---

### Vấn đề 5: Pods không có memory limits sau helm upgrade

**Triệu chứng:** Sau khi scale services từ 0 lên 1 hoặc `helm upgrade --reuse-values`, pods không có limits.

**Nguyên nhân:** `helm upgrade --reuse-values` giữ lại values cũ (trống). Nếu lần đầu cài chưa set resources thì lần upgrade cũng không có.

**Cách fix:** KHÔNG dùng `--reuse-values` khi cần thay đổi resources. Dùng `-f values.yaml` trực tiếp:

```bash
# SAI: (giữ old empty resources)
helm upgrade my-service chart/ --reuse-values --set resources.limits.memory=512Mi

# ĐÚNG: (dùng values file hoàn chỉnh)
helm upgrade my-service chart/ -f chart/values.yaml
```

---

### Vấn đề 6: Swagger UI load được trang nhưng không hiện API docs (404)

**Triệu chứng:** Truy cập `http://api.yas.local.com/swagger-ui/` thấy trang Swagger UI, nhưng chọn bất kỳ service nào (vd: Product) đều báo `Failed to load API definition — Not Found http://api.yas.local.com/product/v3/api-docs`.

**Nguyên nhân:** Ingress của swagger-ui chỉ route path `/swagger-ui` → swagger-ui service. Các path khác như `/product`, `/media`, `/customer`... KHÔNG có rule ingress → trả 404.

**Cách fix:** Thêm ingress template `api-ingress.yaml` vào helm chart swagger-ui:

File `k8s/charts/swagger-ui/templates/api-ingress.yaml`:
```yaml
{{- if .Values.apiIngress.enabled -}}
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: {{ include "swagger-ui.fullname" . }}-api
  labels:
    {{- include "swagger-ui.labels" . | nindent 4 }}
spec:
  ingressClassName: {{ .Values.apiIngress.className }}
  rules:
    - host: {{ .Values.apiIngress.host | quote }}
      http:
        paths:
          {{- range .Values.apiIngress.paths }}
          - path: {{ .path }}
            pathType: Prefix
            backend:
              service:
                name: {{ .serviceName }}
                port:
                  number: {{ .servicePort }}
          {{- end }}
{{- end }}
```

Thêm vào `k8s/charts/swagger-ui/values.yaml`:
```yaml
apiIngress:
  enabled: true
  className: "nginx"
  host: api.yas.local.com
  annotations: {}
  paths:
    - path: /product
      serviceName: product
      servicePort: 80
    - path: /media
      serviceName: media
      servicePort: 80
    - path: /customer
      serviceName: customer
      servicePort: 80
    - path: /cart
      serviceName: cart
      servicePort: 80
    - path: /rating
      serviceName: rating
      servicePort: 80
    - path: /order
      serviceName: order
      servicePort: 80
    - path: /payment
      serviceName: payment
      servicePort: 80
    - path: /location
      serviceName: location
      servicePort: 80
    - path: /inventory
      serviceName: inventory
      servicePort: 80
    - path: /tax
      serviceName: tax
      servicePort: 80
    - path: /promotion
      serviceName: promotion
      servicePort: 80
    - path: /search
      serviceName: search
      servicePort: 80
```

```bash
# Deploy
helm upgrade swagger-ui k8s/charts/swagger-ui -n yas -f k8s/charts/swagger-ui/values.yaml
```

> **Lưu ý:** KHÔNG dùng `kubectl apply` trực tiếp để patch ingress — fix sẽ bị mất khi `helm upgrade` lần sau!

---

### Vấn đề 7: Loki write / backend bị CrashLoopBackOff (read-only file system / permission denied)

**Triệu chứng:** `loki-write-0` và `loki-backend-0` bị CrashLoopBackOff.

```bash
# loki-write log:
# "failed to flush chunks: store put chunk: mkdir fake: read-only file system"

# loki-backend log:
# "mkdir /var/loki/tsdb-shipper-cache/...: permission denied"
```

**Nguyên nhân:** Loki chart mặc định chạy với `readOnlyRootFilesystem=true` và user 10001. Trên Minikube hostPath, user 10001 không có quyền ghi.

**Cách fix:** Uninstall và reinstall với security context override:

```bash
# 1. Uninstall + xóa PVC cũ
helm uninstall loki -n observability
kubectl delete pvc -n observability -l app.kubernetes.io/name=loki --wait=false
kubectl delete pvc -n observability export-0-loki-minio-0 export-1-loki-minio-0 --wait=false 2>/dev/null
sleep 10

# 2. Reinstall với đầy đủ security context overrides
helm upgrade --install loki grafana/loki \
  --namespace observability \
  -f ./observability/loki.values.yaml \
  --set loki.useTestSchema=true \
  --set loki.podSecurityContext.runAsNonRoot=false \
  --set loki.podSecurityContext.runAsUser=0 \
  --set loki.podSecurityContext.runAsGroup=0 \
  --set loki.podSecurityContext.fsGroup=0 \
  --set loki.containerSecurityContext.readOnlyRootFilesystem=false \
  --set loki.containerSecurityContext.allowPrivilegeEscalation=false \
  --set minio.podSecurityContext.enabled=false \
  --set minio.containerSecurityContext.enabled=false \
  --timeout 5m --wait=false
```

> ⚠️ Nếu vẫn lỗi sau reinstall, có thể do PVC cũ chưa xóa hết. Kiểm tra:
> ```bash
> kubectl get pvc -n observability | grep loki
> ```
> Xóa tất cả PVC của Loki rồi reinstall lại.

---

### Vấn đề 8: Redis bị Permission Denied (appendonlydir)

**Triệu chứng:** `redis-replicas-x` bị CrashLoopBackOff, log thấy:

```
Can't open and create append only dir appendonlydir: Permission denied
```

**Nguyên nhân:** Minikube hostPath provisioner tạo PVC trên worker node (minikube-m02) với quyền root, nhưng Redis chạy với user 1001.

**Cách fix:**

```bash
# Xóa PVC cũ bị lỗi permissions
kubectl delete pvc -n redis -l app.kubernetes.io/name=redis --wait=false

# Giảm replicas xuống 1 (đủ cho dev, tránh scheduling lên node lỗi)
helm upgrade redis bitnami/redis -n redis \
  --set replica.replicaCount=1 \
  --reuse-values

# Chờ pods Ready
kubectl get pods -n redis -w
```

---

### Vấn đề 9: Debezium Connect bị CrashLoopBackOff

**Triệu chứng:** Pod `debezium-connect-cluster-connect-xxx` bị CrashLoopBackOff hoặc Error.

**Nguyên nhân:** Image Debezium Connect dùng Kafka client 3.x nhưng cluster chạy Kafka server 4.1.0 (Strimzi 0.45+). Kafka 4.x không backward-compatible hoàn toàn.

**Cách fix:** Đây là lỗi đã biết, **KHÔNG CÓ FIX** cho tới khi Debezium ra bản hỗ trợ Kafka 4.x. Tắt đi:

```bash
kubectl scale kafkaconnect/debezium-connect-cluster --replicas=0 -n kafka 2>/dev/null
```

> CDC (Change Data Capture) sẽ không hoạt động. Các chức năng không dùng CDC vẫn chạy bình thường.

---

### Vấn đề 10: payment-paypal bị CrashLoopBackOff

**Triệu chứng:** Pod `payment-paypal` crash ngay khi start, log thấy:

```
no main manifest attribute, in /app.jar
```

**Nguyên nhân:** Docker image gốc trên GHCR bị lỗi build — file JAR không có Main-Class manifest.

**Cách fix:** Tắt đi (không ảnh hưởng các chức năng khác):

```bash
kubectl scale deployment/payment-paypal --replicas=0 -n yas
```

Hoặc nếu cần chạy, build image local:

```bash
cd /home/npt102/gcp/Devops2/yas
mvn install -N -DskipTests
mvn package -pl payment-paypal -am -DskipTests

cd payment-paypal
docker build -t ghcr.io/nashtech-garage/yas-payment-paypal:local-fix .
minikube image load ghcr.io/nashtech-garage/yas-payment-paypal:local-fix

kubectl set image deployment/payment-paypal \
  payment-paypal=ghcr.io/nashtech-garage/yas-payment-paypal:local-fix -n yas
kubectl patch deployment payment-paypal -n yas \
  -p '{"spec":{"template":{"spec":{"containers":[{"name":"payment-paypal","imagePullPolicy":"Never"}]}}}}'
```

---

### Vấn đề 11: Promotion service bị lỗi (typo tên service)

**Triệu chứng:** Deploy hoặc helm upgrade promotion bị lỗi, hoặc service tên sai.

**Nguyên nhân:** Trong một số file cấu hình, tên service bị gõ sai `protion` thay vì `promotion`.

**Cách fix:** Tìm và sửa tất cả nơi bị typo:

```bash
# Tìm tất cả file có typo
grep -rn "protion" k8s/ --include="*.yaml" --include="*.yml"

# Sửa tất cả thành "promotion"
find k8s/ -name "*.yaml" -exec sed -i 's/protion/promotion/g' {} +
```

---

### Vấn đề 12: Elasticsearch Service bị mất sau cleanup

**Triệu chứng:** Các service phụ thuộc ES (search, product) lỗi kết nối. Kiểm tra thấy service `elasticsearch-es-http` không tồn tại.

```bash
kubectl get svc -n elasticsearch
# Chỉ thấy elastic-operator, KHÔNG có elasticsearch-es-http
```

**Nguyên nhân:** Khi cleanup để giảm RAM, nếu xóa ES StatefulSet thì Service cũng bị xóa theo.

**Cách fix:**

```bash
kubectl apply -f k8s/deploy/elasticsearch/es-standalone.yaml -n elasticsearch

# Kiểm tra
kubectl get svc elasticsearch-es-http -n elasticsearch
kubectl get pods -n elasticsearch | grep standalone
```

---

### Vấn đề 13: `istioctl: command not found`

**Triệu chứng:** Chạy `istioctl install` báo `command not found`.

**Nguyên nhân:** File CAI-DAT-TU-DAU.md cũ ghi `istio-1.29.1` nhưng thư mục thực tế trong repo là `istio-1.24.3`.

**Cách fix:**

```bash
# Sai (thư mục không tồn tại):
export PATH=$PWD/istio-1.29.1/bin:$PATH

# Đúng:
export PATH=$PWD/istio-1.24.3/bin:$PATH
istioctl version --remote=false
# client version: 1.24.3
```

---

### Vấn đề 14: Istio sidecar proxy dùng quá nhiều RAM (1Gi/pod)

**Triệu chứng:** Sau khi cài Istio, RAM tăng đột ngột. Kiểm tra thấy mỗi pod có istio-proxy limit 1Gi:

```bash
kubectl get pods -n yas -o jsonpath='{range .items[0:3]}{.metadata.name}{"\n"}{range .spec.containers[*]}  {.name}: lim={.resources.limits.memory}{"\n"}{end}{end}'
# istio-proxy: lim=1Gi   ← QUÁ CAO
```

**Nguyên nhân:** Cài Istio bằng `istioctl install --set profile=demo` (không có overlay) → sidecar dùng default limit 1Gi. Với 20+ pods, tổng tiêu thụ thêm ~20GB.

**Cách fix:**

```bash
# Reinstall Istio với overlay file có resource limits
export PATH=$PWD/istio-1.24.3/bin:$PATH
istioctl install -f istio/istio-overlay.yaml -y

# Restart pods để nhận sidecar limit mới (128Mi thay vì 1Gi)
kubectl rollout restart deployment -n yas

# Kiểm tra sidecar limit mới
kubectl get pods -n yas -o jsonpath='{range .items[0:1]}{range .spec.containers[*]}  {.name}: lim={.resources.limits.memory}{"\n"}{end}{end}'
# istio-proxy: lim=128Mi  ← ĐÃ GIẢM
```

---

### Vấn đề 15: Pods CrashLoopBackOff sau khi bật Istio (startup storm)

**Triệu chứng:** Sau khi `kubectl rollout restart deployment -n yas`, nhiều pods bị CrashLoopBackOff:
- BFF services: `Unable to resolve Configuration with the provided Issuer` (503 từ Keycloak)
- Backend services: `Connection timed out` đến PostgreSQL

**Nguyên nhân:** Khi restart đồng loạt 20+ services, tất cả cùng lúc kết nối đến Keycloak và PostgreSQL → overload. Keycloak chậm khởi động (JVM lớn), services retry liên tục → CrashLoopBackOff.

**Cách fix:** Chờ tự recovery (thường 3-5 phút). Nếu quá 10 phút:

```bash
# 1. Kiểm tra Keycloak đã Ready chưa
kubectl get pod keycloak-0 -n keycloak
# Nếu CrashLoopBackOff → restart:
kubectl delete pod keycloak-0 -n keycloak

# 2. Kiểm tra PostgreSQL
kubectl get pod postgresql-0 -n postgres
# Phải 1/1 Running

# 3. Sau khi Keycloak 1/1 Running, restart các BFF trước:
kubectl rollout restart deployment/storefront-bff deployment/backoffice-bff -n yas

# 4. Chờ 1 phút, rồi restart các backend còn crash:
kubectl get pods -n yas --no-headers | grep -Ev "Running|Completed" | awk '{print $1}'
# Restart từng service bị lỗi:
kubectl rollout restart deployment/<tên-service> -n yas
```

> **Mẹo:** Nếu máy chậm (RAM gần ngưỡng), restart từng batch nhỏ thay vì `restart deployment -n yas` đồng loạt:
> ```bash
> # Batch 1: BFF services (chờ 60s)
> kubectl rollout restart deployment/storefront-bff deployment/backoffice-bff -n yas
> sleep 60
> # Batch 2: Core services
> kubectl rollout restart deployment/product deployment/media deployment/customer -n yas
> sleep 60
> # Batch 3: Còn lại
> kubectl rollout restart deployment/cart deployment/order deployment/payment -n yas
> # ... tiếp tục
> ```

---

### Bảng tổng hợp nhanh

| # | Vấn đề | Nguyên nhân | Fix nhanh |
|---|--------|-------------|-----------|
| 1 | Storefront/Backoffice 500 | BFF trỏ sai hostname | Sửa ConfigMap URL → service name K8s |
| 2 | PVC Pending | storage-provisioner disabled | `minikube addons enable storage-provisioner` |
| 3 | RAM vượt ngưỡng | Pods không có limits | Set resource limits cho tất cả services |
| 4 | Entity-operator OOMKilled | Default limit quá nhỏ | Tăng lên 512Mi trong kafka-cluster.yaml |
| 5 | Limits mất sau upgrade | `--reuse-values` giữ giá trị cũ | Dùng `-f values.yaml` thay `--reuse-values` |
| 6 | Swagger 404 API docs | Ingress thiếu backend paths | Thêm api-ingress.yaml vào helm chart |
| 7 | Loki read-only / permission | Security context mặc định | Reinstall với `runAsUser=0`, `readOnlyRootFilesystem=false` |
| 8 | Redis permission denied | hostPath user mismatch | Xóa PVC + giảm replicas |
| 9 | Debezium crash | Kafka 3.x client vs 4.x server | Scale to 0 (chờ bản mới) |
| 10 | payment-paypal crash | Image JAR lỗi manifest | Scale to 0 hoặc build local |
| 11 | Promotion typo | Tên gõ sai `protion` | `sed -i 's/protion/promotion/g'` |
| 12 | ES service mất | Bị xóa khi cleanup | `kubectl apply -f es-standalone.yaml` |
| 13 | `istioctl` not found | Sai tên thư mục (1.29.1 vs 1.24.3) | `export PATH=$PWD/istio-1.24.3/bin:$PATH` |
| 14 | Sidecar proxy RAM 1Gi/pod | Cài Istio không có overlay | `istioctl install -f istio/istio-overlay.yaml` |
| 15 | CrashLoopBackOff sau Istio | Startup storm (overload PG/KC) | Chờ tự recovery hoặc restart từng batch |
