# Troubleshooting: Chuyển từ Minikube sang K3s

Ghi lại các vấn đề gặp phải trong quá trình migration và cách khắc phục.

---

## Vấn đề 1: Kafka CRD race condition trong setup-cluster.sh

### Triệu chứng

```
Error: unable to build kubernetes objects from release manifest:
  no matches for kind "Kafka" in version "kafka.strimzi.io/v1beta2"
  ensure CRDs are installed first
  no matches for kind "KafkaConnect" in version "kafka.strimzi.io/v1beta2"
  no matches for kind "KafkaConnector" in version "kafka.strimzi.io/v1beta2"
  no matches for kind "KafkaNodePool" in version "kafka.strimzi.io/v1beta2"
```

### Nguyên nhân

`setup-cluster.sh` cài Strimzi operator rồi **ngay lập tức** chạy `helm install kafka-cluster` mà không chờ CRDs được đăng ký. Strimzi operator cần 30-60 giây để đăng ký CRDs vào API server.

### Cách khắc phục

Chờ Strimzi operator pod Running, sau đó chạy lại kafka-cluster:

```bash
# Chờ operator sẵn sàng
kubectl wait --for=condition=Ready pod -n kafka -l name=strimzi-cluster-operator --timeout=120s

# Re-deploy kafka-cluster
cd /home/npt102/gcp/Devops2/yas/k8s/deploy
helm upgrade --install kafka-cluster ./kafka/kafka-cluster --namespace kafka \
  --set kafka.replicas=1 \
  --set zookeeper.replicas=1 \
  --set postgresql.username=yasadminuser \
  --set postgresql.password=admin
```

---

## Vấn đề 2: Strimzi 1.0.0 đổi API version từ v1beta2 → v1

### Triệu chứng

Sau khi Strimzi operator đã cài và CRDs đã có, vẫn lỗi tương tự:

```
no matches for kind "Kafka" in version "kafka.strimzi.io/v1beta2"
```

Kiểm tra thấy CRDs chỉ serve `kafka.strimzi.io/v1`, không còn `v1beta2`:

```bash
kubectl api-resources | grep kafka
# KafkaBridge   kafka.strimzi.io/v1   ← v1 không phải v1beta2
# Kafka         kafka.strimzi.io/v1
```

### Nguyên nhân

**Strimzi 1.0.0** (phiên bản mới nhất khi cài qua `helm install strimzi/strimzi-kafka-operator`) đã **chính thức loại bỏ** `v1beta2` và chỉ còn `v1`. Chart templates trong project vẫn dùng `v1beta2`.

### Cách khắc phục

Sửa API version trong tất cả template files của `kafka/kafka-cluster`:

```bash
sed -i 's|kafka.strimzi.io/v1beta2|kafka.strimzi.io/v1|g' \
  k8s/deploy/kafka/kafka-cluster/templates/kafka-cluster.yaml \
  k8s/deploy/kafka/kafka-cluster/templates/debezium-connect-cluster.yaml \
  k8s/deploy/kafka/kafka-cluster/templates/debezium-connector-postgresql-product-db.yaml
```

**Files đã sửa:**
- `k8s/deploy/kafka/kafka-cluster/templates/kafka-cluster.yaml` (2 dòng)
- `k8s/deploy/kafka/kafka-cluster/templates/debezium-connect-cluster.yaml`
- `k8s/deploy/kafka/kafka-cluster/templates/debezium-connector-postgresql-product-db.yaml`

---

## Vấn đề 3: KafkaConnect thiếu required fields trong Strimzi 1.0.0

### Triệu chứng

Sau khi fix API version, vẫn còn lỗi:

```
KafkaConnect.kafka.strimzi.io "debezium-connect-cluster" is invalid:
  [spec.groupId: Required value,
   spec.configStorageTopic: Required value,
   spec.statusStorageTopic: Required value,
   spec.offsetStorageTopic: Required value]
```

### Nguyên nhân

Strimzi 1.0.0 yêu cầu `groupId`, `offsetStorageTopic`, `configStorageTopic`, `statusStorageTopic` là **top-level fields** trong `spec`, thay vì chỉ nằm trong `spec.config` như phiên bản cũ.

### Cách khắc phục

Thêm các fields vào `spec` trong `debezium-connect-cluster.yaml`:

```yaml
# Thêm sau dòng "image:"
spec:
  replicas: 1
  bootstrapServers: kafka-cluster-kafka-bootstrap:9092
  image: {{ .Values.debeziumConnect.image }}
  # Thêm 4 dòng này:
  groupId: connect-cluster
  offsetStorageTopic: kafka_connect_offsets
  configStorageTopic: kafka_connect_configs
  statusStorageTopic: kafka_connect_status
  config:
    # Các config cũ vẫn giữ nguyên
```

File đã sửa: `k8s/deploy/kafka/kafka-cluster/templates/debezium-connect-cluster.yaml`

---

## Vấn đề 4: deploy-yas-minimal.sh bị treo chờ Keycloak (DNS chưa set)

### Triệu chứng

Script `deploy-yas-minimal.sh` in ra:

```
Waiting for Keycloak realm 'Yas' to be ready...
```

Rồi bị treo vô tận, không tiến tiếp.

### Nguyên nhân

Script curl `http://identity.yas.local.com/realms/Yas/.well-known/openid-configuration` để kiểm tra Keycloak ready. Nhưng `/etc/hosts` chưa có entry `identity.yas.local.com` → DNS không phân giải được → curl timeout lặp lại mãi.

### Cách khắc phục

Phải **update `/etc/hosts` trước khi chạy `deploy-yas-minimal.sh`**:

```bash
sudo tee -a /etc/hosts <<'EOF'
172.16.0.240 storefront.yas.local.com
172.16.0.240 backoffice.yas.local.com
172.16.0.240 api.yas.local.com
172.16.0.240 identity.yas.local.com
172.16.0.240 pgadmin.yas.local.com
172.16.0.240 akhq.yas.local.com
172.16.0.240 dev.yas.local.com
172.16.0.240 backoffice.dev.yas.local.com
172.16.0.240 api.dev.yas.local.com
172.16.0.240 staging.yas.local.com
172.16.0.240 backoffice.staging.yas.local.com
172.16.0.240 api.staging.yas.local.com
172.16.0.240 kibana.yas.local.com
EOF
```

> **Lưu ý cho hướng dẫn CHUYEN-SANG-K3S.md:** Bước 12 (cấu hình `/etc/hosts`) nên được thực hiện **trước** Bước 11 (deploy-yas-minimal.sh).

---

## Vấn đề 5: Elasticsearch — ECK 9.x hoạt động tốt trên K3s (khác Minikube)

### Bối cảnh

Trên Minikube đã gặp vấn đề với ECK 3.3.2 + ES 9.2.3 (DNS race condition, upgrade path rejection) nên đã tạo `es-standalone.yaml`. Tuy nhiên trên K3s, **ECK hoạt động bình thường** với ES 9.2.3.

### Kết quả thực tế trên K3s

```
NAME                         READY   STATUS    RESTARTS
elastic-operator-0           1/1     Running   0
elasticsearch-es-node-0      1/1     Running   0
kibana-kb-86758bdd48-97slk   1/1     Running   0
```

Service `elasticsearch-es-http` (port 9200) có sẵn, đúng tên mà YAS services cần kết nối.

### Kết luận

Không cần dùng `es-standalone.yaml` trên K3s. `setup-cluster.sh` cài ECK + elasticsearch-cluster chart là đủ.

---

## Thứ tự đúng để tránh các vấn đề trên

```
1. Cài K3s + ingress-nginx + inotify
2. Cập nhật /etc/hosts  ← Làm SỚM, trước bước deploy
3. Chạy setup-cluster.sh
4. Chờ Strimzi CRDs sẵn sàng, re-deploy kafka-cluster
5. Chạy setup-keycloak.sh
6. Chạy setup-redis.sh
7. Chạy deploy-yas-configuration.sh
8. Chạy deploy-yas-minimal.sh  ← /etc/hosts đã có, sẽ không bị treo
```

---

## Bảng tổng kết

| # | Vấn đề | Nguyên nhân | Fix |
|---|---|---|---|
| 1 | Kafka CRD not found (lần 1) | Race condition: chart deploy trước khi CRDs ready | Chờ operator pod Running, re-deploy |
| 2 | Kafka API v1beta2 not found | Strimzi 1.0.0 đổi sang v1 | `sed` đổi apiVersion trong chart templates |
| 3 | KafkaConnect missing required fields | Strimzi 1.0.0 yêu cầu thêm top-level spec fields | Thêm `groupId`, `*StorageTopic` vào spec |
| 4 | deploy-yas-minimal.sh treo | `/etc/hosts` chưa có domain | Update hosts trước khi deploy |
| 5 | ECK + ES 9.x | Không phải vấn đề trên K3s | Không cần xử lý |
