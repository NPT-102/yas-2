# Hướng dẫn triển khai Đồ án 2: Xây dựng hệ thống CD

## Mục lục
- [A. Chuẩn bị môi trường](#a-chuẩn-bị-môi-trường)
- [B. Cấu hình GitHub Secrets](#b-cấu-hình-github-secrets)
- [C. Phần CI (Yêu cầu 3)](#c-phần-ci-yêu-cầu-3)
- [D. Phần CD - Developer Build (Yêu cầu 4)](#d-phần-cd---developer-build-yêu-cầu-4)
- [E. Xóa deployment (Yêu cầu 5)](#e-xóa-deployment-yêu-cầu-5)
- [F. Deploy Dev & Staging (Yêu cầu 6)](#f-deploy-dev--staging-yêu-cầu-6)
- [G. Service Mesh - Istio (Nâng cao)](#g-service-mesh---istio-nâng-cao)
- [H. Cấu trúc file đã tạo](#h-cấu-trúc-file-đã-tạo)

---

## A. Chuẩn bị môi trường

### 1. K8S Cluster (Yêu cầu 2)

Dùng Minikube hoặc cluster 1 master + 1 worker. Ví dụ với Minikube:

```bash
# Cài minikube
curl -LO https://storage.googleapis.com/minikube/releases/latest/minikube-linux-amd64
sudo install minikube-linux-amd64 /usr/local/bin/minikube

# Khởi tạo cluster
minikube start --cpus=4 --memory=8192 --driver=docker

# Kiểm tra
kubectl get nodes
```

Hoặc nếu dùng GCE / VMs, cài kubeadm:

```bash
# Trên master
kubeadm init --pod-network-cidr=10.244.0.0/16

# Trên worker
kubeadm join <master-ip>:6443 --token <token> --discovery-token-ca-cert-hash <hash>
```

### 2. Cài NGINX Ingress Controller

```bash
# Minikube
minikube addons enable ingress

# Hoặc Helm
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
helm install ingress-nginx ingress-nginx/ingress-nginx \
  --namespace ingress-nginx --create-namespace \
  --set controller.service.type=NodePort
```

### 3. Cài infrastructure cho YAS

#### 3.0 Cài đặt công cụ cần thiết

```bash
# Cài Helm (nếu chưa có)
curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
helm version

# Cài yq (scripts dùng yq để đọc YAML config)
sudo snap install yq
# Hoặc: sudo wget -qO /usr/local/bin/yq https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64 && sudo chmod +x /usr/local/bin/yq
yq --version
```

#### 3.1 Chỉnh cấu hình cluster

```bash
cd k8s/deploy
vim cluster-config.yaml
```

Nội dung file `cluster-config.yaml` — giữ nguyên hoặc đổi password nếu muốn:

```yaml
domain: yas.local.com          # Domain cho ingress, thêm vào /etc/hosts sau
postgresql:
  replicas: 1
  username: yasadminuser
  password: admin              # Đổi nếu muốn bảo mật hơn
kafka:
  replicas: 1
zookeeper:
  replicas: 1
elasticsearch:
  replicas: 1
  username: yas
  password: LarUmB3A49NTg9YmgW4=
keycloak:
  bootstrapAdmin:
    username: admin
    password: admin
  backofficeRedirectUrl: http://backoffice.yas.local.com
  storefrontRedirectUrl: http://storefront.yas.local.com
grafana:
  username: admin
  password: admin
redis:
  password: redis
```

#### 3.2 Cài infrastructure chính (PostgreSQL, Kafka, Elasticsearch, Observability)

```bash
cd k8s/deploy
chmod +x setup-cluster.sh setup-keycloak.sh setup-redis.sh deploy-yas-configuration.sh deploy-yas-applications.sh

# Chạy script — sẽ tự thêm Helm repos và cài tất cả
./setup-cluster.sh
```

Script này tạo các namespace và cài:
- `postgres` → PostgreSQL (Zalando operator) + pgAdmin
- `kafka` → Kafka (Strimzi operator) + Debezium CDC + AKHQ
- `elasticsearch` → Elasticsearch (ECK operator) + Kibana  
- `observability` → Loki, Tempo, Prometheus, Grafana, OpenTelemetry
- `cert-manager` → Certificate manager
- `zookeeper` → ZooKeeper

> ⏱ **Mất khoảng 10-15 phút.** Chờ tất cả pods Ready trước khi tiếp:

```bash
# Theo dõi pods (Ctrl+C để thoát)
kubectl get pods --all-namespaces -w

# Hoặc kiểm tra từng namespace
kubectl get pods -n postgres
kubectl get pods -n kafka
kubectl get pods -n elasticsearch
kubectl get pods -n observability
```

> **Nếu gặp lỗi:** Pod stuck ở `Pending` → thiếu resource. Giảm replicas trong `cluster-config.yaml` hoặc tăng resource cho cluster.

#### ⚠️ Các vấn đề gặp phải khi triển khai và cách khắc phục

---

##### Vấn đề 1: PostgreSQL cluster không tạo được — Template Syntax Error

**Triệu chứng:**
Sau khi chạy `./setup-cluster.sh`, pod `postgresql-0` không xuất hiện trong namespace `postgres`.
Chỉ có pod `postgres-operator-xxx` ở trạng thái `Running`, nhưng không có pod database nào.

```bash
$ kubectl get pods -n postgres
NAME                                 READY   STATUS    RESTARTS   AGE
postgres-operator-77d6f8d5bb-xxxxx   1/1     Running   0          5m
# ← Thiếu postgresql-0!
```

Kiểm tra logs operator:
```bash
$ kubectl logs -n postgres deploy/postgres-operator | tail -20
# Thấy lỗi liên quan đến "failed to sync" hoặc "invalid owner"
```

Kiểm tra Helm template render:
```bash
$ helm template postgres ./postgres/postgresql --set username=yasadminuser --set password=admin
# Thấy output YAML có dòng lạ: "recommendation: { { .Values.username } }"
# Thay vì giá trị thực "recommendation: yasadminuser"
```

**Nguyên nhân gốc:**
Trong file `k8s/deploy/postgres/postgresql/templates/postgresql.yaml`, hai dòng cấu hình
database `recommendation` và `webhook` có **khoảng trắng bên trong cặp ngoặc nhọn Helm**:

```yaml
# ❌ SAI — Helm không nhận diện đây là template expression:
    recommendation: { { .Values.username } }
    webhook: { { .Values.username } }

# ✅ ĐÚNG — Helm template syntax chuẩn:
    recommendation: {{ .Values.username }}
    webhook: {{ .Values.username }}
```

Khi có khoảng trắng `{ { ... } }`, Helm coi đây là string literal chứ không phải template 
directive, nên PostgreSQL CRD nhận giá trị sai → Zalando operator không thể tạo cluster.

**Các bước đã thử:**
1. ❌ Xóa và cài lại postgres-operator → Vẫn lỗi vì template vẫn sai
2. ❌ `kubectl describe postgresql -n postgres` → Không thấy resource nào được tạo
3. ✅ Chạy `helm template` để render dry-run → Phát hiện 2 dòng không được interpolate

**Cách khắc phục:**

Sửa file `k8s/deploy/postgres/postgresql/templates/postgresql.yaml`:
```bash
# Tìm và sửa 2 dòng bị lỗi (xóa khoảng trắng thừa)
sed -i 's/{ { .Values.username } }/{{ .Values.username }}/g' \
  k8s/deploy/postgres/postgresql/templates/postgresql.yaml
```

Deploy lại PostgreSQL:
```bash
cd k8s/deploy
helm upgrade --install postgres ./postgres/postgresql \
  --namespace postgres \
  --set replicas=1 --set username=yasadminuser --set password=admin

# Chờ và kiểm tra
kubectl get pods -n postgres -w
# Kết quả mong đợi:
# postgresql-0   1/1   Running   0   2m
```

> **Lưu ý:** File trong repo này **đã được sửa sẵn**. Nếu bạn clone từ repo gốc 
> nashtech-garage/yas, cần sửa thủ công.

---

##### Vấn đề 2: Strimzi Kafka Operator — Không tương thích ZooKeeper + Version conflict

**Triệu chứng:**
Pod Kafka broker không khởi động được. Tùy version Strimzi, lỗi khác nhau:

```bash
$ kubectl get pods -n kafka
NAME                                          READY   STATUS             RESTARTS   AGE
strimzi-cluster-operator-xxx                  1/1     Running            0          5m
kafka-cluster-zookeeper-0                     0/1     Pending            0          3m   # Hoặc không xuất hiện
kafka-cluster-kafka-0                         0/1     CrashLoopBackOff   0          2m   # Hoặc không xuất hiện
```

Kiểm tra logs Strimzi operator:
```bash
$ kubectl logs -n kafka deploy/strimzi-cluster-operator | grep -i "error\|unsupported\|zookeeper"
# Strimzi 0.51.0: "ZooKeeper-based Apache Kafka clusters are not supported anymore"
# Strimzi 0.44.0: fabric8 client error "emulationMajor" (K8s 1.35 incompatible)
```

**Nguyên nhân gốc — Chuỗi 3 vấn đề liên tiếp:**

**Vấn đề 2a: Strimzi 0.51.0 không hỗ trợ ZooKeeper**

Repo gốc dùng Kafka cấu hình ZooKeeper mode (file `kafka-cluster.yaml` có section 
`spec.zookeeper`). Strimzi từ version 0.46.0 trở lên đã **loại bỏ hoàn toàn hỗ trợ 
ZooKeeper**, chỉ hỗ trợ KRaft mode (Kafka Raft — Kafka tự quản lý metadata, không cần 
ZooKeeper nữa).

```
Timeline Strimzi:
- 0.39.0: KRaft mode experimental
- 0.44.0: KRaft mode stable  
- 0.46.0: ZooKeeper mode DEPRECATED → BỎ hoàn toàn
- 0.51.0: Chỉ có KRaft mode + yêu cầu Kafka 4.x
```

**Vấn đề 2b: Không thể hạ version Strimzi về 0.44.0/0.45.0 trên K8s 1.35**

Thử hạ Strimzi về 0.44.0 (version cuối cùng hỗ trợ ZooKeeper + KRaft):
```bash
$ helm upgrade --install strimzi strimzi/strimzi-kafka-operator --version 0.44.0 -n kafka
# → ERROR: operator pod CrashLoopBackOff
```

Logs cho thấy:
```
java.lang.NoSuchFieldError: emulationMajor
  at io.fabric8.kubernetes.client...
```

Nguyên nhân: Strimzi 0.44.0 dùng thư viện `fabric8` phiên bản cũ, chưa hỗ trợ trường 
`emulationMajor` mới được thêm vào Kubernetes API từ v1.35. Đây là lỗi **tương thích ngược** 
giữa K8s client library và K8s server version.

Thử Strimzi 0.45.0:
```bash
$ helm upgrade --install strimzi strimzi/strimzi-kafka-operator --version 0.45.0 -n kafka
# → Cùng lỗi fabric8 emulationMajor
```

**Vấn đề 2c: Strimzi 0.51.0 + Kafka version sai**

Quay lại Strimzi 0.51.0, sửa `kafka-cluster.yaml` sang KRaft mode nhưng vẫn dùng 
`version: 3.9.0` (từ repo gốc):

```bash
$ kubectl logs -n kafka deploy/strimzi-cluster-operator | grep "version"
# "Unsupported Kafka version 3.9.0. Supported versions are: [4.0.0, 4.1.0]"
```

Strimzi 0.51.0 chỉ hỗ trợ Kafka **4.0.0** và **4.1.0**.

**Giải pháp cuối cùng: Strimzi 0.51.0 + KRaft mode + Kafka 4.1.0**

Cần chuyển đổi hoàn toàn file `kafka-cluster.yaml` từ ZooKeeper mode sang KRaft mode.
Thay đổi gồm:

| Thay đổi | Cũ (ZooKeeper mode) | Mới (KRaft mode) |
|----------|---------------------|-------------------|
| Kafka version | `3.9.0` | `4.1.0` |
| ZooKeeper section | `spec.zookeeper: {...}` | **Xóa hoàn toàn** |
| Kafka replicas | `spec.kafka.replicas: 3` | **Xóa** (dùng KafkaNodePool) |
| Kafka storage | Nằm trong `spec.kafka.storage` | **Xóa** (dùng KafkaNodePool) |
| KRaft annotations | Không có | `strimzi.io/kraft: enabled` + `strimzi.io/node-pools: enabled` |
| KafkaNodePool | Không có | Thêm resource KafkaNodePool loại `dual-role` (controller + broker) |

File `kafka-cluster.yaml` sau khi sửa (tóm tắt cấu trúc):

```yaml
# Resource 1: KafkaNodePool (MỚI — thay thế phần replicas + storage)
apiVersion: kafka.strimzi.io/v1beta2
kind: KafkaNodePool
metadata:
  name: kafka-cluster-dual-role
  labels:
    strimzi.io/cluster: kafka-cluster
spec:
  replicas: {{ .Values.kafka.replicas }}
  roles:
    - controller      # Thay thế ZooKeeper
    - broker           # Xử lý message
  storage:
    type: persistent-claim
    size: 10Gi
---
# Resource 2: Kafka (SỬA — thêm annotations, bỏ zookeeper)
apiVersion: kafka.strimzi.io/v1beta2
kind: Kafka
metadata:
  name: kafka-cluster
  annotations:
    strimzi.io/kraft: enabled           # ← BẮT BUỘC
    strimzi.io/node-pools: enabled      # ← BẮT BUỘC
spec:
  kafka:
    version: "4.1.0"                    # ← ĐỔI TỪ 3.9.0
    listeners: [...]
    config:
      offsets.topic.replication.factor: 1
      # ...
  # KHÔNG CÒN spec.zookeeper
```

**Cách khắc phục (đã được sửa sẵn trong repo):**

```bash
cd k8s/deploy

# Xóa Kafka cũ nếu đang chạy
helm uninstall kafka-cluster -n kafka 2>/dev/null

# Chờ pods cũ terminate
kubectl get pods -n kafka -w

# Deploy bản mới (KRaft mode)
helm upgrade --install kafka-cluster ./kafka/kafka-cluster \
  --namespace kafka \
  --set kafka.replicas=1 \
  --set postgresql.username=yasadminuser \
  --set postgresql.password=admin

# Kiểm tra — pod tên mới là "dual-role" thay vì "kafka"
kubectl get pods -n kafka -w
# Kết quả mong đợi:
# kafka-cluster-dual-role-0              1/1   Running   0   3m
# kafka-cluster-entity-operator-xxx      3/3   Running   0   2m
```

> **Ghi chú:** Không cần namespace `zookeeper` nữa. Có thể xóa:
> ```bash
> helm uninstall zookeeper -n zookeeper 2>/dev/null
> kubectl delete namespace zookeeper 2>/dev/null
> ```

---

##### Vấn đề 3: Promtail CrashLoopBackOff — "too many open files"

**Triệu chứng:**
Pod Promtail (DaemonSet trong namespace `observability`) liên tục restart:

```bash
$ kubectl get pods -n observability | grep promtail
promtail-xxxxx   0/1   CrashLoopBackOff   5   8m
promtail-yyyyy   0/1   CrashLoopBackOff   5   8m
```

Kiểm tra logs:
```bash
$ kubectl logs -n observability daemonset/promtail --previous
level=error msg="error creating inotify watcher: too many open files"
# Hoặc
level=error msg="failed to start file target manager: too many open files"
```

**Nguyên nhân gốc:**
Promtail sử dụng `inotify` (Linux kernel API) để theo dõi file log mới. Mỗi file cần 1 
inotify watch instance. Minikube (chạy trong container Docker) có giới hạn mặc định rất thấp:

```bash
$ minikube ssh -- cat /proc/sys/fs/inotify/max_user_instances
128    # ← quá ít! Promtail cần hàng trăm watches
$ minikube ssh -- cat /proc/sys/fs/inotify/max_user_watches
8192   # ← cũng thấp
```

Kubernetes cluster có nhiều pods → nhiều file log → Promtail cần nhiều inotify handles 
hơn mức cho phép → crash.

**Các bước đã thử:**
1. ❌ `kubectl delete pod promtail-xxx -n observability` → Pod mới tạo ra vẫn crash vì 
   giới hạn kernel vẫn thấp
2. ❌ Giảm `scrape_configs` trong Promtail config → Vẫn cần nhiều watches cho các namespace khác
3. ✅ Tăng giới hạn inotify trực tiếp trên kernel của Minikube nodes

**Cách khắc phục:**

```bash
# Tăng giới hạn trên node chính
minikube ssh -- "sudo sysctl -w fs.inotify.max_user_instances=1024 && sudo sysctl -w fs.inotify.max_user_watches=65536"

# Nếu có multi-node, tăng trên tất cả các node
minikube ssh -n minikube-m02 -- "sudo sysctl -w fs.inotify.max_user_instances=1024 && sudo sysctl -w fs.inotify.max_user_watches=65536"
# Lặp lại cho minikube-m03, m04... nếu có

# Restart Promtail DaemonSet
kubectl rollout restart daemonset/promtail -n observability

# Kiểm tra
kubectl get pods -n observability | grep promtail
# Kết quả mong đợi:
# promtail-xxxxx   1/1   Running   0   30s
# promtail-yyyyy   1/1   Running   0   30s
```

> **Lưu ý quan trọng:** Cấu hình `sysctl` bằng lệnh trên **không persist** sau khi restart
> Minikube. Nếu restart minikube (`minikube stop && minikube start`), cần chạy lại lệnh 
> `sysctl` ở trên.

---

##### Vấn đề 4: ArgoCD ApplicationSet Controller CrashLoopBackOff

**Triệu chứng:**
Sau khi cài ArgoCD, pod `applicationset-controller` liên tục crash:

```bash
$ kubectl get pods -n argocd
NAME                                               READY   STATUS             RESTARTS   AGE
argocd-applicationset-controller-xxx               0/1     CrashLoopBackOff   4          5m
argocd-server-xxx                                  1/1     Running            0          5m
argocd-repo-server-xxx                             1/1     Running            0          5m
# Các pod khác OK, chỉ applicationset-controller crash
```

Kiểm tra logs:
```bash
$ kubectl logs -n argocd deploy/argocd-applicationset-controller
# "failed to get informer from cache: failed to get API group resources: ... 
#  ApplicationSet ... the server could not find the requested resource"
```

**Nguyên nhân gốc:**
ArgoCD ApplicationSet Controller cần CRD (Custom Resource Definition) `ApplicationSet` 
đã được đăng ký trong cluster. Nếu cài ArgoCD bằng Helm chart mà CRDs chưa được apply 
đúng cách (do version mismatch hoặc chart không include CRDs), controller sẽ crash vì 
không tìm thấy API resource.

**Các bước đã thử:**
1. ❌ `kubectl delete pod argocd-applicationset-controller-xxx -n argocd` → Pod mới vẫn crash
2. ❌ `helm upgrade --install argocd argo/argo-cd -n argocd` → CRDs không được update 
   (Helm không update CRDs trong upgrade)
3. ❌ `kubectl apply -f "https://...argocd.../crds?ref=stable"` → Thất bại với lỗi:
   ```
   The CustomResourceDefinition "applications.argoproj.io" is invalid: 
   metadata.annotations: Too long: must have at most 262144 bytes
   ```
   Lý do: ArgoCD CRDs rất lớn (>256KB annotations), vượt quá giới hạn mặc định của 
   `kubectl apply` (lưu last-applied-configuration annotation)
4. ✅ Dùng `--server-side` flag để bypass giới hạn annotation

**Cách khắc phục:**

```bash
# Apply CRDs với server-side apply (bypass annotation size limit)
kubectl apply -k "https://github.com/argoproj/argo-cd/manifests/crds?ref=stable" --server-side

# Chờ CRDs registered
kubectl get crd | grep argoproj
# applicationsets.argoproj.io        2024-...
# applications.argoproj.io           2024-...
# appprojects.argoproj.io            2024-...

# Restart controller
kubectl rollout restart deployment/argocd-applicationset-controller -n argocd

# Kiểm tra
kubectl get pods -n argocd
# Kết quả mong đợi:
# argocd-applicationset-controller-xxx   1/1   Running   0   30s
```

> **Giải thích `--server-side`:** Khi dùng `kubectl apply` bình thường (client-side), 
> kubectl lưu toàn bộ manifest vào annotation `kubectl.kubernetes.io/last-applied-configuration`.
> ArgoCD CRDs quá lớn → vượt giới hạn 262144 bytes. Flag `--server-side` chuyển logic apply 
> sang API server, **không cần lưu annotation này** → không bị giới hạn kích thước.

---

##### Vấn đề 5: Debezium Connect CrashLoopBackOff (KHÔNG ảnh hưởng đồ án)

**Triệu chứng:**
Pod `debezium-connect-cluster-connect-0` liên tục crash trong namespace `kafka`:

```bash
$ kubectl get pods -n kafka | grep debezium
debezium-connect-cluster-connect-0   0/1   Error   5   10m

$ kubectl logs -n kafka debezium-connect-cluster-connect-0
# java.io.FileNotFoundException: /opt/kafka/config/log4j.properties (No such file or directory)
# Hoặc:
# ClassNotFoundException: org.apache.kafka.connect.runtime.WorkerConfig
```

**Nguyên nhân gốc:**
Image `ghcr.io/nashtech-garage/debezium-connect-postgresql:latest` được build cho 
**Kafka 3.x** (ZooKeeper mode). Khi chạy trên Kafka **4.x** (KRaft mode), có nhiều 
thay đổi breaking:
- Đường dẫn config file thay đổi (`log4j.properties` → `log4j2.properties` trong Kafka 4.x)
- Một số class bị đổi tên hoặc xóa trong Kafka 4.x
- API Connect protocol có thay đổi nhỏ

**Các bước đã thử:**
1. ❌ `kubectl delete pod debezium-connect-cluster-connect-0 -n kafka` → Restart vẫn crash
2. ❌ Tìm image Debezium mới hơn → Chưa có bản chính thức cho Kafka 4.x
3. ➡️ **Bỏ qua** — Debezium làm CDC (Change Data Capture), dùng để sync data từ PostgreSQL 
   sang Kafka topics. **Không cần thiết cho đồ án CD.**

**Cách xử lý:**

Debezium là thành phần phụ trợ, **không ảnh hưởng đến:**
- Pipeline CI/CD (build, deploy)
- Các microservices hoạt động bình thường
- Service mesh Istio

Có thể bỏ qua hoặc scale về 0 để không thấy pod Error:
```bash
# (Tùy chọn) Scale Debezium Connect về 0
kubectl scale kafkaconnect/debezium-connect-cluster --replicas=0 -n kafka
```

Nếu muốn fix triệt để (KHÔNG bắt buộc):
- Build lại Debezium Connect image với base image Kafka 4.x
- Hoặc chờ Debezium project release bản hỗ trợ Kafka 4.x

---

##### Vấn đề 6: Loki chart mới yêu cầu schema_config

**Triệu chứng:**
`setup-cluster.sh` không cài được Loki. Kiểm tra Helm releases thấy thiếu Loki:

```bash
$ helm list -n observability | grep loki
# ← Không có kết quả!
```

Cài thủ công cũng thất bại:
```bash
$ helm upgrade --install loki grafana/loki --namespace observability -f ./observability/loki.values.yaml
Error: execution error at (loki/templates/validate.yaml:40:4): 
  You must provide a schema_config for Loki, one is not provided as this will be 
  individual for every Loki cluster. See https://grafana.com/docs/loki/latest/operations/storage/schema/ 
  for schema information. For quick testing (with no persistence) add `--set loki.useTestSchema=true`
```

**Nguyên nhân gốc:**
Repo gốc dùng Loki chart phiên bản cũ. Chart Loki mới (6.x) **bắt buộc** cấu hình 
`schema_config` — đây là cấu hình schema versioning cho cách Loki lưu trữ index và 
chunks. File `loki.values.yaml` trong repo gốc không có trường này.

Chart validate sẽ fail ngay ở template render, không tạo ra resource nào cả.

**Các bước đã thử:**
1. ❌ Chạy với values file gốc → Lỗi validate `schema_config` 
2. ❌ Thêm `schema_config` thủ công → Phức tạp, cần biết chính xác `from` date, `store`, 
   `object_store`, `schema` version, `index.prefix`, `index.period`
3. ✅ Dùng flag `--set loki.useTestSchema=true` — chart tự generate schema phù hợp cho 
   dev/test (filesystem storage, không cần external object store)

**Cách khắc phục:**

```bash
cd k8s/deploy
helm upgrade --install loki grafana/loki \
  --namespace observability \
  -f ./observability/loki.values.yaml \
  --set loki.useTestSchema=true

# Kiểm tra — Loki deploy nhiều pods (microservice mode)
kubectl get pods -n observability | grep loki
# Kết quả mong đợi (sau 2-3 phút):
# loki-backend-0                     2/2   Running   0   2m
# loki-canary-xxxxx                  1/1   Running   0   2m
# loki-canary-yyyyy                  1/1   Running   0   2m
# loki-chunks-cache-0                2/2   Running   0   2m
# loki-gateway-xxxxx                 1/1   Running   0   2m
# loki-minio-0                       1/1   Running   0   2m
# loki-read-xxxxx                    1/1   Running   0   2m
# loki-results-cache-0               2/2   Running   0   2m
# loki-write-0                       1/1   Running   0   2m
```

> **Giải thích `useTestSchema`:** Flag này bảo chart tự tạo `schema_config` mặc định 
> dùng filesystem storage (MinIO). Phù hợp cho dev/test. Trong production cần cấu hình 
> S3 hoặc GCS và viết `schema_config` riêng.

---

##### Vấn đề 7: Prometheus + Grafana — leaked secrets validation

**Triệu chứng:**
`setup-cluster.sh` không cài được Prometheus + Grafana. Cài thủ công thất bại:

```bash
$ helm upgrade --install prometheus prometheus-community/kube-prometheus-stack \
    --namespace observability -f ./observability/prometheus.values.yaml

Error: execution error at (kube-prometheus-stack/charts/grafana/templates/deployment.yaml:36:28): 
  Sensitive key 'database.password' should not be defined explicitly in values. 
  Use variable expansion instead. You can disable this client-side validation 
  by changing the value of assertNoLeakedSecrets.
```

**Nguyên nhân gốc:**
Chart `kube-prometheus-stack` mới tích hợp sub-chart Grafana phiên bản mới hơn. Grafana 
chart mới có **security validation** kiểm tra xem có key nào chứa từ "password" hoặc 
"secret" được định nghĩa trực tiếp trong values hay không.

File `prometheus.values.yaml` trong repo gốc chứa:
```yaml
grafana:
  grafana.ini:
    database:
      password: admin    # ← Chart mới coi đây là "leaked secret"
```

Đây là tính năng bảo mật mới của chart, ngăn người dùng vô tình commit password vào Git.
Trong production nên dùng Kubernetes Secret + variable expansion, nhưng trong môi trường 
dev/test thì có thể tắt validation này.

**Các bước đã thử:**
1. ❌ Chạy với values file gốc → Lỗi `assertNoLeakedSecrets`
2. ❌ Xóa password khỏi values file → Grafana không kết nối được PostgreSQL
3. ✅ Tắt validation bằng flag `--set grafana.assertNoLeakedSecrets=false`

**Cách khắc phục:**

```bash
cd k8s/deploy
helm upgrade --install prometheus prometheus-community/kube-prometheus-stack \
  --namespace observability \
  -f ./observability/prometheus.values.yaml \
  --set grafana.assertNoLeakedSecrets=false

# Kiểm tra
kubectl get pods -n observability | grep prometheus
# Kết quả mong đợi (sau 2-3 phút):
# alertmanager-prometheus-kube-prometheus-alertmanager-0   2/2   Running   0   2m
# prometheus-grafana-xxxxx                                3/3   Running   0   2m
# prometheus-kube-prometheus-operator-xxxxx               1/1   Running   0   2m
# prometheus-kube-state-metrics-xxxxx                     1/1   Running   0   2m
# prometheus-prometheus-kube-prometheus-prometheus-0       2/2   Running   0   2m
# prometheus-prometheus-node-exporter-xxxxx               1/1   Running   0   2m (mỗi node 1 pod)
```

> **Lưu ý:** Grafana instance ở đây là sub-chart của `kube-prometheus-stack`, khác với 
> `grafana-operator` (dùng để quản lý dashboards/datasources qua CRD). Cả hai cùng chạy 
> song song.

---

##### Vấn đề 8: OpenTelemetry Collector — receiver/exporter "loki" không tồn tại

**Triệu chứng:**
Pod OpenTelemetry Collector liên tục crash:

```bash
$ kubectl get pods -n observability | grep opentelemetry-collector
opentelemetry-collector-xxxxx   0/1   CrashLoopBackOff   8   10m
```

Kiểm tra logs:
```bash
$ kubectl logs -n observability deploy/opentelemetry-collector
Error: failed to get config: cannot unmarshal the configuration: decoding failed due to the following error(s):

'receivers' unknown type: "loki" for id: "loki" (valid values: [otlp otelarrow filelog 
  httpcheck journald k8s_events k8sobjects prometheus receiver_creator zipkin 
  fluentforward hostmetrics jaeger k8s_cluster kubeletstats])
'exporters' the logging exporter has been deprecated, use the debug exporter instead
```

**Nguyên nhân gốc:**
File `observability/opentelemetry/values.yaml` trong repo gốc cấu hình:
1. **`loki` receiver** — dùng để nhận log theo Loki push format
2. **`loki` exporter** — dùng để gửi log đến Loki endpoint
3. **`logging` exporter** — dùng để print log ra stdout

Tuy nhiên, image OTel Collector mặc định (`contrib` distribution) từ operator phiên bản 
mới **không bundle** `loki` receiver và `loki` exporter nữa. Đồng thời `logging` exporter 
bị rename thành `debug`.

Ngoài ra, file template dùng API `v1alpha1` đã deprecated, cần migrate sang `v1beta1`.

**Các bước đã thử:**
1. ❌ `helm uninstall` + `helm install` lại → Vẫn crash vì config sai
2. ❌ Chỉ sửa values.yaml mà không xóa CR → Helm merge config cũ + mới (strategic merge), 
   kết quả config vẫn chứa `loki` receiver/exporter cũ
3. ✅ Xóa hoàn toàn OTel Collector CR → uninstall Helm → sửa config → reinstall

**Cách khắc phục:**

Sửa 2 file:

**File 1:** `k8s/deploy/observability/opentelemetry/templates/opentelemetry-collector.yaml`
```yaml
# ĐỔI: v1alpha1 → v1beta1, xóa port loki 3500
apiVersion: opentelemetry.io/v1beta1        # ← ĐỔI TỪ v1alpha1
kind: OpenTelemetryCollector
metadata:
  name: opentelemetry
spec:
  mode: deployment
  # XÓA phần ports (không cần port 3500 cho loki receiver nữa)
  config:
    {{ toYaml .Values.opentelemetryCollectorConfig | nindent 4 }}
```

**File 2:** `k8s/deploy/observability/opentelemetry/values.yaml`
```yaml
opentelemetryCollectorConfig:
  receivers:
    otlp:                           # Chỉ giữ otlp (bỏ loki receiver)
      protocols:
        grpc:
          endpoint: 0.0.0.0:4317
        http:
          endpoint: 0.0.0.0:4318
  processors:
    batch: {}                       # Phải có {} (không để trống)
  exporters:
    debug:                          # ĐỔI TỪ logging → debug
      verbosity: detailed
    otlphttp/tempo:                 # Gửi traces đến Tempo
      endpoint: http://tempo:4318
    otlphttp/loki:                  # Gửi logs đến Loki qua OTLP (không dùng loki exporter)
      endpoint: http://loki-gateway:80/otlp
  service:
    pipelines:
      logs:
        receivers: [otlp]           # ĐỔI TỪ [loki] → [otlp]
        processors: [batch]         # ĐỔI TỪ [attributes] → [batch]
        exporters: [otlphttp/loki]  # ĐỔI TỪ [loki] → [otlphttp/loki]
      traces:
        receivers: [otlp]
        processors: [batch]
        exporters: [otlphttp/tempo] # ĐỔI TỪ [otlphttp] → [otlphttp/tempo]
```

Thay đổi chính:
| Cũ | Mới | Lý do |
|----|-----|-------|
| `receivers.loki` | Xóa | Không có trong standard OTel image |
| `exporters.loki` | `exporters.otlphttp/loki` | Dùng OTLP protocol gửi đến Loki gateway |
| `exporters.logging` | `exporters.debug` | `logging` bị rename thành `debug` |
| `processors.batch:` (null) | `processors.batch: {}` | Tránh warning null object |
| `v1alpha1` | `v1beta1` | `v1alpha1` deprecated |

Deploy:
```bash
cd k8s/deploy

# QUAN TRỌNG: Phải xóa CR cũ trước (tránh merge config)
kubectl delete opentelemetrycollectors opentelemetry -n observability 2>/dev/null
helm uninstall opentelemetry-collector -n observability 2>/dev/null

# Cài lại
helm upgrade --install opentelemetry-collector ./observability/opentelemetry \
  --namespace observability

# Kiểm tra
kubectl get pods -n observability | grep opentelemetry-collector
# Kết quả mong đợi:
# opentelemetry-collector-xxxxx   1/1   Running   0   30s
```

> **Tại sao phải xóa CR trước?** Helm dùng strategic merge patch khi upgrade. Nếu CR cũ 
> đã có field `receivers.loki`, merge sẽ **giữ lại** field cũ + thêm field mới → config 
> vẫn chứa `loki` receiver → vẫn crash. Phải xóa CR hoàn toàn rồi tạo mới.

---

##### Vấn đề 9: Cluster quá tải — API server ngừng hoạt động

**Triệu chứng:**
Sau khi cài thêm Loki + Prometheus + Grafana, lệnh `kubectl` không phản hồi:

```bash
$ kubectl get pods -A
Unable to connect to the server: net/http: TLS handshake timeout

$ minikube status
minikube
type: Control Plane
host: Running
kubelet: Stopped         # ← kubelet tắt!
apiserver: Stopped       # ← API server tắt!
```

**Nguyên nhân gốc:**
Minikube chạy trong Docker container có giới hạn tài nguyên. Khi cài thêm Loki 
(9 pods mới: backend, read, write, gateway, minio, canary×2, chunks-cache, results-cache)
và Prometheus (6 pods: alertmanager, grafana, operator, state-metrics, prometheus, 
node-exporter×2) → tổng ~15 pods mới → **bộ nhớ vượt quá giới hạn** → kubelet và 
API server bị kernel OOM killer tắt.

Kiểm tra tài nguyên:
```bash
$ minikube ssh -- free -h
              total        used        free      shared  buff/cache   available
Mem:           31Gi        21Gi       514Mi       4.0Gi        11Gi       9.2Gi
# ← 21GB used, gần hết!

$ docker inspect minikube --format '{{.HostConfig.Memory}}'  
4141875200
# ← Container minikube chỉ được cấp ~4GB RAM!
```

**Cách khắc phục:**

```bash
# Restart Minikube — tự phục hồi kubelet và API server
minikube start

# Chờ cluster ổn định (~1-2 phút)
# Pods tự restart lại nhờ ReplicaSet/StatefulSet/DaemonSet controllers

# Kiểm tra
kubectl get pods -A --no-headers | awk '{print $4}' | sort | uniq -c | sort -rn
# Kết quả mong đợi:
#   56 Running
#    3 Completed
```

> **Phòng tránh:** Nếu cluster hay bị OOM, tăng resource khi tạo Minikube:
> ```bash
> minikube start --cpus=6 --memory=12288 --driver=docker
> ```
> Hoặc giảm replicas trong `cluster-config.yaml` (đặt tất cả về 1).

---

##### Tổng kết trạng thái sau khi fix tất cả

Sau khi áp dụng tất cả 9 fix trên, trạng thái cluster:

```bash
$ kubectl get pods -A --no-headers | grep -Ev "Running|Completed"
# ← Không có dòng nào! Tất cả pods đều healthy.

$ kubectl get pods -A --no-headers | awk '{print $4}' | sort | uniq -c | sort -rn
     56 Running
      3 Completed
# ← 56 pods Running, 3 Completed (ingress admission jobs — bình thường)
```

Danh sách pods chạy OK theo namespace:

| Namespace | Pods | Mô tả |
|-----------|------|-------|
| `postgres` | postgresql-0, postgres-operator, pgadmin | Database cluster |
| `kafka` | kafka-cluster-dual-role-0, entity-operator, strimzi-operator, akhq | Message broker (KRaft) |
| `elasticsearch` | elastic-operator, elasticsearch-es-node-0, kibana | Search engine |
| `observability` | grafana-operator, otel-operator, otel-collector, promtail×2, tempo | Tracing + Log collection |
| `observability` | loki-backend, loki-read, loki-write, loki-gateway, loki-minio, loki-canary×2, loki-*-cache×2 | Log aggregation (Loki) |
| `observability` | prometheus-grafana, prometheus-operator, prometheus-0, alertmanager-0, kube-state-metrics, node-exporter×2 | Metrics + Dashboards |
| `argocd` | server, repo-server, applicationset-controller, redis, dex, notifications-controller | GitOps CD |
| `istio-system` | istiod, ingress-gateway, egress-gateway, kiali | Service mesh |
| `ingress-nginx` | ingress-nginx-controller | Ingress controller |
| `cert-manager` | cert-manager, cainjector, webhook | TLS certificates |
| `kube-system` | coredns, etcd, apiserver, controller-manager, scheduler, kube-proxy×2, kindnet×2, storage-provisioner | K8s core |

#### 3.3 Cài Keycloak (Identity server)

```bash
cd k8s/deploy
./setup-keycloak.sh
```

Script này:
1. Tạo namespace `keycloak`
2. Cài Keycloak CRDs (Custom Resource Definitions) phiên bản 26.0.2
3. Deploy Keycloak kết nối đến PostgreSQL đã cài ở bước 3.2

```bash
# Chờ Keycloak pod Ready
kubectl get pods -n keycloak -w
# Khi thấy STATUS = Running, READY = 1/1 → OK
```

#### 3.4 Cài Redis (Session cache cho BFF)

```bash
cd k8s/deploy
./setup-redis.sh
```

```bash
# Kiểm tra
kubectl get pods -n redis
```

#### 3.5 Deploy cấu hình chung (ConfigMaps + Secrets)

```bash
cd k8s/deploy
./deploy-yas-configuration.sh
```

Script này tạo namespace `yas` và deploy chart `yas-configuration` chứa:
- ConfigMaps: cấu hình Spring Boot, gateway routes, logging, service-specific configs
- Secrets: credentials PostgreSQL, Elasticsearch, Keycloak, Redis

```bash
# Kiểm tra
kubectl get configmaps -n yas
kubectl get secrets -n yas
```

#### 3.6 Deploy tất cả microservices

```bash
cd k8s/deploy
./deploy-yas-applications.sh
```

Script này deploy lần lượt (mỗi service cách nhau 60s để chờ startup):
1. `backoffice-bff` + `backoffice-ui`
2. `storefront-bff` + `storefront-ui`
3. `swagger-ui`
4. 16 backend services: cart, customer, inventory, location, media, order, payment, payment-paypal, product, promotion, rating, search, tax, recommendation, webhook, sampledata

> ⏱ **Mất khoảng 20-30 phút.**

```bash
# Theo dõi tiến trình
kubectl get pods -n yas -w

# Khi xong, kiểm tra tổng quan
kubectl get pods -n yas
kubectl get svc -n yas
kubectl get ingress -n yas
```

#### 3.7 Cấu hình /etc/hosts và truy cập

Lấy IP của node:
```bash
# Minikube
minikube ip

# Hoặc cluster thật
kubectl get nodes -o wide
# Lấy cột INTERNAL-IP của worker node
```

Thêm vào `/etc/hosts` (thay `<NODE_IP>` bằng IP thật):
```bash
sudo bash -c 'echo "<NODE_IP> yas.local.com api.yas.local.com backoffice.yas.local.com storefront.yas.local.com identity.yas.local.com pgadmin.yas.local.com grafana.yas.local.com kibana.yas.local.com akhq.yas.local.com" >> /etc/hosts'
```

Truy cập kiểm tra:
- Storefront: http://storefront.yas.local.com
- Backoffice: http://backoffice.yas.local.com
- Keycloak: http://identity.yas.local.com (admin/admin)
- pgAdmin: http://pgadmin.yas.local.com
- Grafana: http://grafana.yas.local.com (admin/admin)
- Swagger: http://api.yas.local.com/swagger-ui

#### Tóm tắt thứ tự chạy

```bash
cd k8s/deploy

# 1. Infrastructure
./setup-cluster.sh              # ~15 phút, chờ pods Ready
kubectl get pods --all-namespaces  # Kiểm tra

# 2. Identity
./setup-keycloak.sh             # ~3 phút
kubectl get pods -n keycloak    # Kiểm tra

# 3. Session cache
./setup-redis.sh                # ~1 phút
kubectl get pods -n redis       # Kiểm tra

# 4. Config (ConfigMaps + Secrets)
./deploy-yas-configuration.sh   # ~1 phút
kubectl get cm,secret -n yas    # Kiểm tra

# 5. Microservices
./deploy-yas-applications.sh    # ~25 phút
kubectl get pods -n yas         # Kiểm tra
```

### 4. Docker Hub account

Tạo tài khoản tại https://hub.docker.com nếu chưa có.

---

## B. Cấu hình GitHub Secrets

Các workflow CI/CD cần 3 secrets để hoạt động:

| Secret Name | Mục đích | Dùng trong workflow |
|-------------|----------|---------------------|
| `DOCKER_USER` | Tên đăng nhập Docker Hub — dùng để login và đặt tên image | CI, Developer Build, Dev Deploy, Staging Deploy |
| `DOCKER_PASS` | Password/Token Docker Hub — dùng để push image | CI, Developer Build, Dev Deploy, Staging Deploy |
| `KUBE_CONFIG` | Kubeconfig base64 — dùng để kubectl deploy lên cluster | Developer Build, Cleanup, Dev Deploy, Staging Deploy |

### Bước 1: Tạo Docker Hub Access Token

1. Đăng nhập https://hub.docker.com
2. Click avatar góc phải → **Account settings**
3. Menu trái → **Personal access tokens** (hoặc **Security**)
4. Click **Generate new token**
5. Đặt tên: `yas-github-actions`
6. Chọn quyền: **Read & Write** (cần push image)
7. Click **Generate** → **Copy token ngay** (chỉ hiện 1 lần!)

> **Lưu ý:** Nên dùng Access Token thay vì password gốc. Token có thể revoke riêng nếu bị lộ.

### Bước 2: Lấy KUBE_CONFIG

Trên máy đang chạy cluster (máy có quyền kubectl):

```bash
# Encode kubeconfig thành base64 (1 dòng, không xuống hàng)
cat ~/.kube/config | base64 -w 0
```

Copy toàn bộ output (chuỗi base64 rất dài).

> **Quan trọng — Kubeconfig dùng IP nội bộ:**
> 
> Kiểm tra IP của cluster trong kubeconfig:
> ```bash
> grep "server:" ~/.kube/config
> # Nếu thấy: server: https://192.168.49.2:8443  ← IP nội bộ!
> # Hoặc:      server: https://127.0.0.1:xxxxx    ← localhost!
> ```
> 
> Nếu cluster dùng IP nội bộ (192.168.x.x, 10.x.x.x, 127.0.0.1), GitHub Actions runner
> (chạy trên cloud) **không thể kết nối** được. Có 2 giải pháp:
> 
> - **Giải pháp A:** Dùng self-hosted runner (xem bước 4 bên dưới) — **khuyến nghị**
> - **Giải pháp B:** Expose cluster qua public IP (phức tạp, không khuyến nghị cho đồ án)

### Bước 3: Thêm Secrets vào GitHub repo

1. Mở browser → vào **https://github.com/NPT-102/yas-2**
2. Click tab **Settings** (biểu tượng bánh răng, cuối hàng tabs)
3. Menu trái → mở rộng **Secrets and variables** → click **Actions**
4. Click nút **New repository secret** (màu xanh lá)

Thêm lần lượt 3 secrets:

**Secret 1: DOCKER_USER**
- Name: `DOCKER_USER`
- Secret: `<tên đăng nhập Docker Hub>` (ví dụ: `npt102`)
- Click **Add secret**

**Secret 2: DOCKER_PASS**
- Name: `DOCKER_PASS`
- Secret: `<Access Token đã copy ở bước 1>` (ví dụ: `dckr_pat_xxxxx...`)
- Click **Add secret**

**Secret 3: KUBE_CONFIG**
- Name: `KUBE_CONFIG`
- Secret: `<chuỗi base64 đã copy ở bước 2>`
- Click **Add secret**

Sau khi thêm xong, trang Secrets sẽ hiển thị 3 secrets với trạng thái "Updated X seconds ago".

### Bước 4: Cài Self-hosted Runner (bắt buộc nếu cluster dùng IP nội bộ)

Vì Minikube chạy trên máy local với IP `192.168.49.2`, GitHub Actions runner trên cloud 
không thể kết nối. Cần cài self-hosted runner trên chính máy chạy cluster.

**4.1. Tạo runner trên GitHub:**

1. Vào **https://github.com/NPT-102/yas-2/settings/actions/runners**
2. Click **New self-hosted runner**
3. Chọn:
   - Operating system: **Linux**
   - Architecture: **x64**
4. GitHub sẽ hiện lệnh cài đặt, **làm theo lần lượt**:

**4.2. Cài runner trên máy local:**

```bash
# Tạo thư mục cho runner
mkdir -p ~/actions-runner && cd ~/actions-runner

# Download runner (copy URL chính xác từ trang GitHub)
curl -o actions-runner-linux-x64-2.322.0.tar.gz -L \
  https://github.com/actions/runner/releases/download/v2.322.0/actions-runner-linux-x64-2.322.0.tar.gz

# Giải nén
tar xzf ./actions-runner-linux-x64-2.322.0.tar.gz

# Cấu hình (copy token từ trang GitHub — mỗi token chỉ dùng 1 lần)
./config.sh --url https://github.com/NPT-102/yas-2 --token <TOKEN_TỪ_GITHUB>
# Khi hỏi:
#   Runner group: nhấn Enter (default)
#   Runner name: nhấn Enter (default = tên máy)
#   Labels: nhấn Enter (default = self-hosted, Linux, X64)
#   Work folder: nhấn Enter (default = _work)
```

> **Lưu ý:** Version runner và token thay đổi theo thời gian. Luôn copy chính xác
> từ trang GitHub Settings → Runners → New self-hosted runner.

**4.3. Chạy runner:**

```bash
# Chạy foreground (test)
cd ~/actions-runner
./run.sh

# Hoặc chạy background (service) — khuyến nghị
sudo ./svc.sh install
sudo ./svc.sh start
sudo ./svc.sh status
```

Khi runner kết nối thành công, trang GitHub Runners sẽ hiện trạng thái **Idle** (sẵn sàng).

**4.4. Sửa workflow dùng self-hosted runner:**

Các workflow có deploy lên cluster (developer_build, cleanup, dev-deploy, staging-deploy) 
cần đổi `runs-on` từ `ubuntu-latest` sang `self-hosted`:

```bash
# Sửa tất cả workflow cần kubectl
cd /home/npt102/gcp/Devops2/yas

# developer_build — job deploy
sed -i 's/runs-on: ubuntu-latest/runs-on: self-hosted/' .github/workflows/npt-developer_build.yml

# cleanup
sed -i 's/runs-on: ubuntu-latest/runs-on: self-hosted/' .github/workflows/npt-cleanup.yml

# dev-deploy — job deploy
sed -i 's/runs-on: ubuntu-latest/runs-on: self-hosted/' .github/workflows/npt-dev-deploy.yml

# staging-deploy — job deploy
sed -i 's/runs-on: ubuntu-latest/runs-on: self-hosted/' .github/workflows/npt-staging-deploy.yml
```

> **Lưu ý:** Workflow CI (`npt-ci.yml`) **không cần** self-hosted runner vì chỉ build 
> và push image lên Docker Hub, không cần kubectl.
> 
> Tuy nhiên nếu muốn đơn giản, có thể đổi tất cả sang `self-hosted` luôn.

**4.5. Commit và push thay đổi:**

```bash
git add .github/workflows/
git commit -m "chore: use self-hosted runner for deploy workflows"
git push origin main
```

### Kiểm tra Secrets đã cấu hình đúng

```bash
# Test Docker login (chạy trên máy local)
echo "<DOCKER_PASS>" | docker login -u <DOCKER_USER> --password-stdin
# Kết quả mong đợi: Login Succeeded

# Test kubeconfig
kubectl get nodes
# Kết quả mong đợi: minikube + minikube-m02 Ready

# Test runner (nếu đã cài)
# Vào GitHub → Settings → Actions → Runners
# Runner hiện trạng thái: Idle (màu xanh lá)
```

### Tóm tắt

```
GitHub Secrets cần tạo:
┌──────────────┬─────────────────────────────────────┐
│ DOCKER_USER  │ Docker Hub username                  │
│ DOCKER_PASS  │ Docker Hub Access Token              │
│ KUBE_CONFIG  │ cat ~/.kube/config | base64 -w 0     │
└──────────────┴─────────────────────────────────────┘

Self-hosted Runner:
┌─────────────────────────────────────────────────────┐
│ Cài trên máy chạy cluster (máy có kubectl)          │
│ Đổi runs-on: self-hosted trong workflow deploy      │
│ Chạy background: sudo ./svc.sh install && start     │
└─────────────────────────────────────────────────────┘
```

---

## C. Phần CI (Yêu cầu 3)

**File:** `.github/workflows/npt-ci.yml`

**Cách hoạt động:**
1. Bất kỳ branch nào push code
2. Detect service nào có file thay đổi
3. Build Maven (Java) hoặc Docker multi-stage (Frontend)
4. Push image lên Docker Hub với tag = `commit_id` (7 ký tự đầu của SHA)
5. Nếu push lên `main`, cũng tag thêm `latest`

**Test thử:**

```bash
# Tạo branch mới
git checkout -b dev_tax_service

# Sửa code trong tax/
echo "// test" >> tax/src/main/java/com/yas/tax/TaxApplication.java

# Commit và push
git add .
git commit -m "test CI pipeline"
git push origin dev_tax_service
```

Kiểm tra: Vào GitHub → Actions → "CI Build and Push" → xem log.

Image sẽ được push: `<DOCKER_USER>/tax:<commit_id>`

---

## D. Phần CD - Developer Build (Yêu cầu 4)

**File:** `.github/workflows/npt-developer_build.yml`

**Cách sử dụng:**

1. Vào GitHub → Actions → **developer_build** → Run workflow
2. Chọn `service_name`: ví dụ `tax`
3. Nhập `branch_name`: ví dụ `dev_tax_service`
4. Click **Run workflow**

**Kết quả:**
- Tất cả service deploy với image `latest` (default)
- Service `tax` deploy với image tag = commit SHA cuối cùng của branch `dev_tax_service`
- Service được chọn expose qua NodePort
- Xem **Summary** của workflow run để lấy IP:Port truy cập

**Cấu hình /etc/hosts trên máy developer:**

```bash
# Thêm dòng này (thay <WORKER_IP> bằng IP thật)
<WORKER_IP> developer.yas.local.com api.developer.yas.local.com
```

---

## E. Xóa deployment (Yêu cầu 5)

**File:** `.github/workflows/npt-cleanup.yml`

**Cách sử dụng:**

1. Vào GitHub → Actions → **cleanup_developer_build** → Run workflow
2. Nhập `yes` vào ô confirm
3. Click **Run workflow**

Toàn bộ namespace `developer` sẽ bị xóa.

---

## F. Deploy Dev & Staging (Yêu cầu 6)

### 6a. Dev environment (auto deploy)

**File:** `.github/workflows/npt-dev-deploy.yml`

- **Tự động** chạy khi push vào `main`
- Deploy tất cả services vào namespace `dev`
- Domain: `dev.yas.local.com`, `api.dev.yas.local.com`

Thêm vào `/etc/hosts`:
```
<WORKER_IP> dev.yas.local.com api.dev.yas.local.com
```

### 6b. Staging environment (tag release)

**File:** `.github/workflows/npt-staging-deploy.yml`

**Cách tạo release:**

```bash
# Trên branch main, tạo tag
git checkout main
git pull
git tag v1.0.0
git push origin v1.0.0
```

- Pipeline sẽ **build tất cả services** với tag `v1.0.0`
- Push images: `<DOCKER_USER>/<service>:v1.0.0`
- Deploy vào namespace `staging`
- Domain: `staging.yas.local.com`, `api.staging.yas.local.com`

Thêm vào `/etc/hosts`:
```
<WORKER_IP> staging.yas.local.com api.staging.yas.local.com
```

---

## G. Service Mesh - Istio (Nâng cao)

### 1. Cài Istio trên cluster

```bash
# Download istioctl
curl -L https://istio.io/downloadIstio | ISTIO_VERSION=1.29.1 sh -
cd istio-1.29.1
export PATH=$PWD/bin:$PATH

# Cài Istio lên cluster
istioctl install --set profile=demo -y

# Cài Kiali (visualization)
kubectl apply -f https://raw.githubusercontent.com/istio/istio/release-1.22/samples/addons/kiali.yaml
kubectl apply -f https://raw.githubusercontent.com/istio/istio/release-1.22/samples/addons/prometheus.yaml
```

### 2. Enable sidecar injection cho namespace yas

```bash
kubectl label namespace yas istio-injection=enabled --overwrite

# Restart pods để inject sidecar
kubectl rollout restart deployment -n yas
```

### 3. Apply Istio policies

```bash
# mTLS toàn bộ namespace
kubectl apply -f istio/peer-authentication.yaml

# DestinationRule mTLS
kubectl apply -f istio/destination-rule.yaml

# Authorization policies (service-to-service access)
kubectl apply -f istio/authorization-policy.yaml

# Retry policies
kubectl apply -f istio/virtual-service-retry.yaml
```

### 4. Kiểm tra mTLS

```bash
# Xem trạng thái mTLS
istioctl x describe pod <pod-name> -n yas

# Hoặc dùng PeerAuthentication check
kubectl get peerauthentication -n yas
```

### 5. Test Authorization Policy

```bash
# Vào pod order, curl đến tax (PHẢI được phép)
kubectl exec -n yas deploy/order -- curl -v http://tax:80/tax/actuator/health

# Vào pod search, curl đến tax (PHẢI bị chặn vì không có policy cho phép)
kubectl exec -n yas deploy/search -- curl -v http://tax:80/tax/actuator/health
# -> Expected: RBAC: access denied
```

### 6. Test Retry Policy

```bash
# Xem config retry
istioctl x describe svc tax -n yas

# Xem logs envoy sidecar để thấy retry
kubectl logs deploy/order -n yas -c istio-proxy | grep retry
```

### 7. Xem Kiali Topology

```bash
# Port forward Kiali dashboard
kubectl port-forward svc/kiali -n istio-system 20001:20001

# Mở browser: http://localhost:20001
# Vào Graph → chọn namespace yas → xem topology
```

**Chụp screenshot Kiali topology cho báo cáo.**

---

## H. Cấu trúc file đã tạo

```
yas/
├── .github/workflows/
│   ├── npt-ci.yml                    # YC3: CI - build image với commit tag
│   ├── npt-developer_build.yml       # YC4: CD - developer deploy branch
│   ├── npt-cleanup.yml               # YC5: Xóa developer deployment
│   ├── npt-dev-deploy.yml            # YC6a: Auto deploy dev khi push main
│   └── npt-staging-deploy.yml        # YC6b: Deploy staging khi tag v*
├── istio/
│   ├── peer-authentication.yaml      # NC: mTLS STRICT
│   ├── destination-rule.yaml         # NC: DestinationRule mTLS
│   ├── authorization-policy.yaml     # NC: Service-to-service access control
│   └── virtual-service-retry.yaml    # NC: Retry 5xx (3 attempts)
├── k8s/                              # (Từ repo gốc - giữ nguyên)
│   ├── charts/                       # Helm charts cho tất cả services
│   └── deploy/                       # Scripts setup cluster + deploy
└── .gitignore                        # Đã thêm ignore binaries
```

---

## Checklist trước khi nộp bài

- [ ] K8S cluster chạy OK (`kubectl get nodes` thấy Ready)
- [ ] GitHub Secrets đã cấu hình (`DOCKER_USER`, `DOCKER_PASS`, `KUBE_CONFIG`)
- [ ] CI: Push branch bất kỳ → image được build và push lên Docker Hub
- [ ] developer_build: Chạy workflow → services deploy thành công → truy cập được qua NodePort
- [ ] cleanup: Chạy workflow → namespace developer bị xóa
- [ ] Dev: Push main → auto deploy vào namespace dev
- [ ] Staging: Tạo tag v* → build + deploy vào namespace staging
- [ ] Istio: mTLS enabled, Authorization policy hoạt động, Retry policy hoạt động
- [ ] Kiali: Screenshot topology
- [ ] Báo cáo: Chụp hình từng bước cấu hình
