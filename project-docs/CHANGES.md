# Danh sách thay đổi so với repo gốc (nashtech-garage/yas)

> Repo gốc: https://github.com/nashtech-garage/yas  
> Fork: https://github.com/NPT-102/yas-2  
> Mục đích: Đồ án 2 — Xây dựng hệ thống CI/CD cho microservices trên Kubernetes

---

## Mục lục

- [1. Nâng cấp Java & Dependencies](#1-nâng-cấp-java--dependencies)
- [2. Workflow CI/CD mới (5 file)](#2-workflow-cicd-mới-5-file)
- [3. Sửa workflow gốc (22 file)](#3-sửa-workflow-gốc-22-file)
- [4. Composite Action](#4-composite-action)
- [5. Kafka — Chuyển từ ZooKeeper sang KRaft](#5-kafka--chuyển-từ-zookeeper-sang-kraft)
- [6. PostgreSQL — Sửa lỗi Helm template](#6-postgresql--sửa-lỗi-helm-template)
- [7. Elasticsearch — Deploy standalone (bypass ECK)](#7-elasticsearch--deploy-standalone-bypass-eck)
- [8. OpenTelemetry Collector — Migrate v1beta1](#8-opentelemetry-collector--migrate-v1beta1)
- [9. Helm Charts — Sửa image tag](#9-helm-charts--sửa-image-tag)
- [10. Istio Service Mesh (4 file mới)](#10-istio-service-mesh-4-file-mới)
- [11. Các file khác](#11-các-file-khác)
- [Tổng kết](#tổng-kết)

---

## 1. Nâng cấp Java & Dependencies

### File: `pom.xml` (root)

| Mục | Repo gốc | Sau thay đổi | Lý do |
|-----|----------|-------------|-------|
| Java version | 21 | **25** | Minikube v1.38.1 cài sẵn JDK 25; Spring Boot 4.0.2 hỗ trợ Java 25 |
| Spring Boot | 3.x | **4.0.2** | Repo gốc đã nâng lên 4.0.2, cần Java 25 tương ứng |
| Elasticsearch client | 8.x | **9.2.3** | Tương thích với ES 9.x server |
| Keycloak adapter | 25.x | **26.0.1** | Bản mới nhất tại thời điểm deploy |

**Tại sao phải nâng Java?** Spring Boot 4.0.2 trong repo gốc đã nâng `maven.compiler.release` 
lên 25. Nếu GitHub Actions CI dùng JDK 21, Maven sẽ báo lỗi:
```
Fatal error compiling: error: release version 25 not supported
```

---

## 2. Workflow CI/CD mới (5 file)

### 2.1. `.github/workflows/npt-ci.yml` — CI Build & Push (Yêu cầu 3)

**Mục đích:** Mỗi branch push code → detect service thay đổi → build image → push Docker Hub.

**Hoạt động:**
1. `detect-changes`: So sánh `git diff HEAD~1 HEAD`, tìm thư mục service nào thay đổi
2. `build-java`: Maven build → Docker build → push `<DOCKER_USER>/<service>:<commit_id>`
3. `build-frontend`: Docker multi-stage build cho backoffice/storefront

**Khác biệt với CI gốc:** CI gốc (`*-ci.yaml`) push image lên GHCR (`ghcr.io/nashtech-garage/...`) 
và chạy SonarCloud, OWASP, JaCoCo. Workflow mới push lên Docker Hub cá nhân với tag = commit SHA.

| Trigger | Tất cả branch push |
|---------|-------------------|
| Runner | `ubuntu-latest` |
| JDK | 25 (Temurin) |
| Image tag | `<commit_sha_7_chars>`, thêm `latest` nếu branch main |

---

### 2.2. `.github/workflows/npt-dev-deploy.yml` — Auto Deploy Dev (Yêu cầu 6a)

**Mục đích:** Push vào `main` → tự động deploy tất cả services vào namespace `dev`.

**Hoạt động:**
1. Decode `KUBE_CONFIG` secret → ghi vào `~/.kube/config`
2. Deploy `yas-configuration` (ConfigMaps + Secrets)
3. Deploy BFF: backoffice-bff dùng host `backoffice.dev.yas.local.com`, storefront-bff dùng `dev.yas.local.com`
4. Deploy UI: backoffice-ui, storefront-ui
5. Deploy 16 backend services với ingress host `api.dev.yas.local.com`

**Lưu ý đặc biệt — Ingress conflict:** Backoffice-bff và storefront-bff không thể dùng 
chung host+path vì cả hai đều cần path `/`. Giải pháp: tách backoffice-bff ra subdomain riêng.

| Trigger | Push to `main` |
|---------|----------------|
| Runner | `self-hosted` (cần kubectl đến cluster nội bộ) |
| Namespace | `dev` |
| Domain | `dev.yas.local.com`, `backoffice.dev.yas.local.com` |

---

### 2.3. `.github/workflows/npt-developer_build.yml` — Developer CD (Yêu cầu 4)

**Mục đích:** Developer chạy thủ công, chọn service + branch → deploy vào namespace `developer`.

**Hoạt động:**
1. Nhận input: `service_name` (dropdown), `branch_name` (text)
2. Lấy commit SHA cuối cùng của branch → dùng làm image tag
3. Deploy tất cả services (dùng image `latest`), riêng service được chọn dùng image từ Docker Hub 
   với tag = commit SHA từ branch đã chọn
4. Service được chọn expose thêm NodePort

**Yêu cầu:** CI phải chạy xong trên branch đó trước (để image tồn tại trên Docker Hub).

| Trigger | `workflow_dispatch` (manual) |
|---------|------------------------------|
| Runner | `self-hosted` |
| Namespace | `developer` |
| Domain | `developer.yas.local.com` |

---

### 2.4. `.github/workflows/npt-cleanup.yml` — Cleanup (Yêu cầu 5)

**Mục đích:** Xóa toàn bộ namespace `developer` (deployment từ Yêu cầu 4).

**An toàn:** Yêu cầu nhập `yes` để xác nhận trước khi xóa.

| Trigger | `workflow_dispatch` (manual) |
|---------|------------------------------|
| Runner | `self-hosted` |
| Action | `kubectl delete namespace developer` |

---

### 2.5. `.github/workflows/npt-staging-deploy.yml` — Staging Deploy (Yêu cầu 6b)

**Mục đích:** Tạo tag `v*` trên main → build TẤT CẢ services → push image với tag version → deploy vào `staging`.

**Hoạt động:**
1. Build + push tất cả 18 Java services + 2 frontend services với tag = version (ví dụ `v1.0.0`)
2. Deploy vào namespace `staging` với image tag = version

**Khác với dev-deploy:** Staging build image mới (không dùng image `latest`), đảm bảo 
staging environment luôn dùng đúng version được release.

| Trigger | Push tag `v*` (ví dụ `v1.0.0`) |
|---------|-------------------------------|
| Runner | `self-hosted` |
| JDK | 25 (cần build Maven) |
| Namespace | `staging` |
| Domain | `staging.yas.local.com` |

---

## 3. Sửa workflow gốc (22 file)

### 3.1. Xóa `pom.xml` và self-reference khỏi trigger paths (21 file `*-ci.yaml`)

**File ảnh hưởng:** `cart-ci.yaml`, `customer-ci.yaml`, `inventory-ci.yaml`, `location-ci.yaml`, 
`media-ci.yaml`, `order-ci.yaml`, `payment-ci.yaml`, `payment-paypal-ci.yaml`, `product-ci.yaml`, 
`promotion-ci.yaml`, `rating-ci.yaml`, `recommendation-ci.yaml`, `sampledata-ci.yaml`, 
`search-ci.yaml`, `storefront-ci.yaml`, `storefront-bff-ci.yaml`, `tax-ci.yaml`, `webhook-ci.yaml`, 
`backoffice-ci.yaml`, `backoffice-bff-ci.yaml`, `charts-ci.yaml`

**Thay đổi:**
```yaml
# TRƯỚC (repo gốc):
paths:
  - "cart/**"
  - "pom.xml"                        # ← Bất kỳ thay đổi pom.xml nào cũng trigger
  - ".github/workflows/cart-ci.yaml" # ← Thay đổi workflow cũng trigger

# SAU:
paths:
  - "cart/**"
  - ".github/workflows/actions/action.yaml"  # Chỉ trigger khi composite action thay đổi
```

**Lý do:** Khi push commit sửa file `.github/workflows/npt-ci.yml` hoặc `pom.xml` root, 
TẤT CẢ 21 CI workflow gốc đều trigger → build 21 lần → GitHub quota hết nhanh, runner quá tải.

### 3.2. Thêm `permissions` block vào `payment-ci.yaml` và `payment-paypal-ci.yaml`

```yaml
permissions:
  contents: read
  checks: write
  pull-requests: write
```

**Lý do:** GitHub token mặc định ở fork không có quyền `checks: write`. Thiếu permission 
→ job `Test Results` (dorny/test-reporter) fail với lỗi 403.

### 3.3. Thêm `skip_existing: true` vào `charts-ci.yaml`

```yaml
- name: Run chart-releaser
  uses: helm/chart-releaser-action@v1.5.0
  with:
    charts_dir: k8s/charts
    skip_existing: true          # ← THÊM MỚI
```

**Lý do:** Chart-releaser tạo GitHub Release cho mỗi chart version. Nếu release đã tồn 
tại (ví dụ `payment-0.2.0`), action fail với lỗi `422 Validation Failed: tag_name already exists`.
Flag `skip_existing` bỏ qua chart đã release thay vì fail.

---

## 4. Composite Action

### File: `.github/workflows/actions/action.yaml`

**Nội dung:**
```yaml
runs:
  using: 'composite'
  steps:
    - uses: actions/setup-java@v4
      with:
        java-version: '25'
        distribution: 'temurin'
        cache: 'maven'
    - uses: actions/cache@v4
      with:
        path: ~/.sonar/cache
        key: ${{ runner.os }}-sonar
```

**Thay đổi:** JDK 21 → 25 (tương ứng với `pom.xml` root).

**Tại sao quan trọng:** Tất cả 21 CI workflow gốc dùng `uses: ./.github/workflows/actions` 
để setup JDK. Nếu action dùng JDK 21 mà `pom.xml` yêu cầu 25 → all CI fail.

---

## 5. Kafka — Chuyển từ ZooKeeper sang KRaft

### File: `k8s/deploy/kafka/kafka-cluster/templates/kafka-cluster.yaml`

**Thay đổi hoàn toàn cấu trúc:**

| Mục | Repo gốc | Sau thay đổi |
|-----|----------|-------------|
| Mode | ZooKeeper | **KRaft** (Kafka Raft) |
| Kafka version | 3.9.0 | **4.1.0** |
| `spec.zookeeper` | Có (3 replicas) | **Xóa hoàn toàn** |
| `spec.kafka.replicas` | Có (3) | **Xóa** (dùng KafkaNodePool) |
| KafkaNodePool | Không có | **Thêm mới** (`dual-role`: controller + broker) |
| Annotations | Không có | `strimzi.io/kraft: enabled`, `strimzi.io/node-pools: enabled` |

**Chuỗi lý do:**
1. Strimzi 0.51.0 (version mới nhất) **bỏ hoàn toàn** hỗ trợ ZooKeeper
2. Không thể hạ Strimzi về 0.44.0/0.45.0 vì K8s 1.35 có field `emulationMajor` mới → fabric8 client cũ crash
3. Strimzi 0.51.0 chỉ hỗ trợ Kafka 4.0.0 và 4.1.0 → phải nâng từ 3.9.0

**Hệ quả:** Namespace `zookeeper` không còn cần thiết. Debezium Connect image cũ (build cho 
Kafka 3.x) không tương thích → scaled to 0.

---

## 6. PostgreSQL — Sửa lỗi Helm template

### File: `k8s/deploy/postgres/postgresql/templates/postgresql.yaml`

**Thay đổi:**
```yaml
# TRƯỚC (repo gốc — có khoảng trắng thừa):
    recommendation: { { .Values.username } }
    webhook: { { .Values.username } }

# SAU (syntax Helm đúng):
    recommendation: {{ .Values.username }}
    webhook: {{ .Values.username }}
```

**Lý do:** Khoảng trắng giữa `{ {` và `} }` khiến Helm coi là string literal, không 
interpolate giá trị → Zalando PostgreSQL operator nhận cấu hình sai → không tạo được cluster.

---

## 7. Elasticsearch — Deploy standalone (bypass ECK)

### File mới: `k8s/deploy/elasticsearch/es-standalone.yaml`

**Mục đích:** Deploy Elasticsearch 9.2.3 dạng StatefulSet đơn giản, không qua ECK operator.

**Cấu hình:**
- Image: `docker.elastic.co/elasticsearch/elasticsearch:9.2.3`
- Mode: `discovery.type: single-node`
- Security: `xpack.security.enabled: false` (dev environment)
- Resources: 1Gi RAM, 500m-1000m CPU
- Service name: `elasticsearch-es-http` (giữ tên cũ để các service khác không cần đổi config)

**Lý do:** ECK (Elastic Cloud on Kubernetes) operator 3.3.2 chưa tương thích hoàn toàn với 
ES 9.x + K8s 1.35. Deploy standalone đơn giản hơn cho môi trường dev/test.

---

## 8. OpenTelemetry Collector — Migrate v1beta1

### File 1: `k8s/deploy/observability/opentelemetry/templates/opentelemetry-collector.yaml`

**Thay đổi:**
```yaml
# TRƯỚC:
apiVersion: opentelemetry.io/v1alpha1
# ports: [3500 cho loki receiver]

# SAU:
apiVersion: opentelemetry.io/v1beta1
# Bỏ ports (không cần loki receiver)
```

### File 2: `k8s/deploy/observability/opentelemetry/values.yaml`

| Mục | Repo gốc | Sau thay đổi | Lý do |
|-----|----------|-------------|-------|
| `receivers.loki` | Có | **Xóa** | OTel Collector mới không bundle loki receiver |
| `exporters.loki` | Có | **Đổi thành** `otlphttp/loki` | Gửi log qua OTLP protocol đến Loki gateway |
| `exporters.logging` | Có | **Đổi thành** `debug` | `logging` exporter bị rename |
| `processors.batch` | null | `batch: {}` | Tránh null object warning |
| API version | v1alpha1 | **v1beta1** | v1alpha1 deprecated |

---

## 9. Helm Charts — Sửa image tag

### File: `k8s/charts/payment/values.yaml`

```yaml
# TRƯỚC:
image:
  tag: latest

# SAU:
image:
  tag: fixed
```

**Lý do:** Image `ghcr.io/nashtech-garage/yas-payment:latest` gây lỗi Liquibase checksum 
mismatch khi database đã có schema từ version trước. Tag `fixed` là image đã test ổn định.

### File: `k8s/charts/payment-paypal/values.yaml`

Giữ nguyên `tag: latest`. Image `ghcr.io/nashtech-garage/yas-payment-paypal:latest` bị lỗi 
`no main manifest attribute in /app.jar` → service này được scale to 0 (không có image hoạt động).

---

## 10. Istio Service Mesh (4 file mới)

### 10.1. `istio/peer-authentication.yaml`
- **Scope:** Namespace `yas`
- **Config:** mTLS mode `STRICT` — tất cả traffic trong namespace phải mã hóa TLS

### 10.2. `istio/destination-rule.yaml`
- **Host:** `*.yas.svc.cluster.local`
- **Config:** TLS mode `ISTIO_MUTUAL` — sử dụng certificate do Istio quản lý

### 10.3. `istio/authorization-policy.yaml`
- **Default:** Deny all traffic trong namespace `yas`
- **Allow rules:**
  - BFF (backoffice-bff, storefront-bff) → tất cả backend services
  - Order → Cart, Payment, Tax, Inventory, Customer (service-to-service calls)
  - Các service khác bị chặn nếu không có rule cho phép

### 10.4. `istio/virtual-service-retry.yaml`
- **Retry policy** cho 5 service quan trọng:
  - Tax: 3 lần, timeout 2s
  - Order: 3 lần, timeout 3s
  - Cart: 3 lần, timeout 2s
  - Payment: 3 lần, timeout 3s
  - Product: 3 lần, timeout 2s
- **Trigger:** Retry khi gặp lỗi 5xx

---

## 11. Các file khác

### `.gitignore`
Thêm 3 entry:
```
istio-1.29.1/    # Binary Istio (giải nén từ download, không commit)
minikube-linux-amd64  # Binary minikube
tempo-data/      # Dữ liệu Tempo (observability)
```

### `HUONG-DAN-DO-AN.md`
File hướng dẫn bằng tiếng Việt, mô tả chi tiết:
- Cách setup infrastructure từ đầu
- 9 vấn đề gặp phải khi triển khai và cách khắc phục
- Hướng dẫn sử dụng từng workflow CI/CD
- Cấu hình Istio service mesh

---

## Tổng kết

| Loại thay đổi | Số file | Chi tiết |
|--------------|---------|----------|
| Workflow CI/CD mới | 5 | npt-ci, npt-dev-deploy, npt-developer_build, npt-cleanup, npt-staging-deploy |
| Sửa workflow gốc | 22 | 21 *-ci.yaml (xóa pom.xml path) + charts-ci (skip_existing) |
| Composite Action | 1 | JDK 21→25 |
| K8s deploy | 4 | Kafka KRaft, PostgreSQL template, ES standalone, OTel v1beta1 |
| Helm charts | 2 | payment (tag: fixed), payment-paypal (tag: latest) |
| Istio config | 4 | mTLS, authorization, destination-rule, retry |
| Project config | 2 | pom.xml (Java 25), .gitignore |
| Documentation | 2 | HUONG-DAN-DO-AN.md, CHANGES.md (file này) |
| **Tổng** | **~42 file** | |
