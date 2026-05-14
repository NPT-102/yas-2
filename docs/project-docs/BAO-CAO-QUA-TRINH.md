# BÁO CÁO QUÁ TRÌNH THỰC HIỆN ĐỒ ÁN 2

> **Đề tài:** Xây dựng hệ thống CI/CD cho kiến trúc Microservices trên Kubernetes  
> **Sinh viên:** NPT-102  
> **Repository:** https://github.com/NPT-102/yas-2  
> **Dự án gốc:** [YAS - Yet Another Shop](https://github.com/nashtech-garage/yas) (NashTech)  
> **Ngày hoàn thành:** 13/04/2026

---

## Mục lục

- [1. Tổng quan hệ thống](#1-tổng-quan-hệ-thống)
- [2. Hạ tầng Kubernetes](#2-hạ-tầng-kubernetes)
- [3. CI/CD Pipeline](#3-cicd-pipeline)
- [4. ArgoCD - GitOps CD](#4-argocd---gitops-cd)
- [5. Istio Service Mesh](#5-istio-service-mesh)
- [6. Monitoring & Observability](#6-monitoring--observability)
- [7. Các vấn đề đã giải quyết](#7-các-vấn-đề-đã-giải-quyết)
- [8. Cấu trúc thư mục](#8-cấu-trúc-thư-mục)
- [9. Danh sách file đã thay đổi/tạo mới](#9-danh-sách-file-đã-thay-đổitạo-mới)

---

## 1. Tổng quan hệ thống

### 1.1 Kiến trúc tổng thể

```
                          ┌─────────────────────────────┐
                          │        GitHub Repository      │
                          │   https://github.com/NPT-102  │
                          │          /yas-2.git            │
                          └──────────┬──────────┬─────────┘
                                     │          │
                    ┌────────────────┘          └────────────────┐
                    ▼                                            ▼
          ┌──────────────────┐                       ┌────────────────────┐
          │  GitHub Actions  │                       │     ArgoCD         │
          │  (CI Pipeline)   │                       │  (GitOps CD)       │
          │                  │                       │                    │
          │ • Build image    │                       │ • Watch Git repo   │
          │ • Push DockerHub │                       │ • Auto-sync Helm   │
          │ • Run tests      │                       │ • Self-heal        │
          └────────┬─────────┘                       └─────────┬──────────┘
                   │                                           │
                   ▼                                           ▼
         ┌──────────────┐                    ┌─────────────────────────────┐
         │  Docker Hub   │                    │   Minikube K8S Cluster     │
         │  (Registry)   │                    │   2 nodes (master+worker)  │
         └──────────────┘                    │                             │
                                             │  ┌───────┐ ┌───────┐       │
                                             │  │NS: yas│ │NS: dev│       │
                                             │  └───────┘ └───────┘       │
                                             │  ┌─────────┐ ┌──────────┐  │
                                             │  │NS:staging│ │NS:argocd│  │
                                             │  └─────────┘ └──────────┘  │
                                             └─────────────────────────────┘
```

### 1.2 Danh sách Microservices (21 services)

| # | Service | Loại | Port | Mô tả |
|---|---------|------|------|--------|
| 1 | storefront-bff | Spring Cloud Gateway | 80 | BFF cho storefront |
| 2 | backoffice-bff | Spring Cloud Gateway | 80 | BFF cho backoffice |
| 3 | storefront-ui | Next.js | 3000 | Giao diện storefront |
| 4 | backoffice-ui | Next.js | 3000 | Giao diện admin |
| 5 | cart | Spring Boot | 8080 | Giỏ hàng |
| 6 | customer | Spring Boot | 8080 | Khách hàng |
| 7 | inventory | Spring Boot | 8080 | Kho hàng |
| 8 | location | Spring Boot | 8080 | Địa chỉ |
| 9 | media | Spring Boot | 8080 | Quản lý media |
| 10 | order | Spring Boot | 8080 | Đơn hàng |
| 11 | payment | Spring Boot | 8080 | Thanh toán |
| 12 | product | Spring Boot | 8080 | Sản phẩm |
| 13 | promotion | Spring Boot | 8080 | Khuyến mãi |
| 14 | rating | Spring Boot | 8080 | Đánh giá |
| 15 | recommendation | Spring Boot | 8080 | Gợi ý |
| 16 | search | Spring Boot | 8080 | Tìm kiếm (Elasticsearch) |
| 17 | tax | Spring Boot | 8080 | Thuế |
| 18 | webhook | Spring Boot | 8080 | Webhook |
| 19 | sampledata | Spring Boot | 8080 | Dữ liệu mẫu |
| 20 | swagger-ui | - | 8080 | API Documentation |
| 21 | yas-reloader | Reloader | - | Hot-reload ConfigMap |

### 1.3 Infrastructure Services

| Service | Namespace | Mô tả |
|---------|-----------|--------|
| PostgreSQL | postgres | Database chính (1 instance, nhiều DB) |
| Kafka (KRaft) | kafka | Message broker (bỏ ZooKeeper) |
| Elasticsearch | yas | Search engine |
| Keycloak | yas | Identity provider (OAuth2/OIDC) |
| Redis | yas | Cache (session, gateway) |
| ingress-nginx | ingress-nginx | Ingress Controller |

---

## 2. Hạ tầng Kubernetes

### 2.1 Thông tin Cluster

| Thành phần | Chi tiết |
|------------|----------|
| Platform | Minikube v1.38.1 |
| Kubernetes | v1.35.1 |
| Container Runtime | Docker 29.2.1 |
| Nodes | 2 (1 control-plane + 1 worker) |
| Control Plane IP | 192.168.49.2 |
| Worker IP | 192.168.49.3 |
| OS | Debian GNU/Linux 12 (bookworm) |

### 2.2 Namespaces

| Namespace | Mục đích |
|-----------|----------|
| `yas` | Môi trường chính — chạy 21 services |
| `dev` | Môi trường dev — ArgoCD auto-sync từ main |
| `staging` | Môi trường staging — ArgoCD sync từ release tag |
| `developer` | Môi trường developer — deploy manual 1 service |
| `argocd` | ArgoCD controller + server |
| `istio-system` | Istio control plane + Kiali + Prometheus + Grafana |
| `ingress-nginx` | NGINX Ingress Controller (đã inject Istio sidecar) |
| `postgres` | PostgreSQL database |
| `kafka` | Kafka broker (KRaft mode) |

### 2.3 Helm Charts

Toàn bộ services được deploy bằng Helm charts tự viết:

```
k8s/charts/
├── backend/              # Shared template (Deployment, Service, Ingress, HPA, ServiceMonitor)
├── ui/                   # Shared template cho frontend
├── yas-configuration/    # ConfigMaps + Secrets trung tâm
├── cart/                 # values.yaml, values-dev.yaml, values-staging.yaml
├── customer/
├── order/
├── ... (20 service charts)
└── swagger-ui/
```

Mỗi service chart kế thừa từ `backend/` template qua Helm dependency:
```yaml
# cart/Chart.yaml
dependencies:
  - name: backend
    version: 0.1.0
    repository: file://../backend
```

---

## 3. CI/CD Pipeline

### 3.1 Tổng quan Workflows

| Workflow | File | Trigger | Mục đích |
|----------|------|---------|----------|
| CI Build & Push | `npt-ci.yml` | Push bất kỳ branch | Build Docker image, push Docker Hub |
| Developer Build | `npt-developer_build.yml` | Manual dispatch | Deploy 1 service từ 1 branch vào NS `developer` |
| Cleanup | `npt-cleanup.yml` | Manual dispatch | Xóa namespace `developer` |
| Dev Deploy | `npt-dev-deploy.yml` | Push main | Trigger ArgoCD sync NS `dev` |
| Staging Deploy | `npt-staging-deploy.yml` | Push tag `v*` | Build image + update values → ArgoCD sync NS `staging` |

### 3.2 CI Pipeline (npt-ci.yml)

```
Push code (bất kỳ branch)
    │
    ├── detect-changes (kiểm tra file nào thay đổi)
    │
    ├── build-java (matrix: cart, order, product, ...)
    │   ├── Maven build
    │   ├── Docker build
    │   └── Push Docker Hub: <DOCKER_USER>/<service>:<commit_id_7>
    │
    └── build-frontend (matrix: backoffice, storefront)
        ├── Docker build
        └── Push Docker Hub: <DOCKER_USER>/<service>:<commit_id_7>
```

**Đặc điểm:**
- Chỉ build services có file thay đổi (detect-changes)
- Tag image bằng commit ID 7 ký tự → truy vết được
- Trên main branch, thêm tag `latest`

### 3.3 Developer Build (npt-developer_build.yml)

```
Developer chọn: service_name + branch_name
    │
    ├── Checkout branch code cho service đó
    ├── Build image (tag = commit_short_hash)
    ├── Push Docker Hub
    └── Deploy FULL stack vào NS "developer"
        ├── Service đã chọn: dùng image vừa build
        └── Các service khác: dùng image "latest"
```

### 3.4 Dev Deploy với ArgoCD (npt-dev-deploy.yml)

```
Push code → main branch
    │
    └── GitHub Actions trigger
        ├── ArgoCD CLI login
        ├── List apps có label environment=dev
        └── Sync tất cả apps ngay lập tức
            └── ArgoCD deploy Helm charts → NS "dev"
```

### 3.5 Staging Deploy với ArgoCD (npt-staging-deploy.yml)

```
Developer tạo tag: git tag v1.0.0 → git push origin v1.0.0
    │
    ├── Build ALL Java services (tag = v1.0.0)
    ├── Build ALL Frontend services (tag = v1.0.0)
    ├── Push Docker Hub: <DOCKER_USER>/<service>:v1.0.0
    │
    ├── Update k8s/charts/*/values-staging.yaml → image.tag = v1.0.0
    ├── Git commit + push main (message: "[skip ci]")
    │
    └── ArgoCD phát hiện thay đổi values-staging.yaml
        └── Auto-sync → NS "staging" với image v1.0.0
```

---

## 4. ArgoCD - GitOps CD

### 4.1 Cài đặt

- ArgoCD được cài trên Minikube namespace `argocd`
- Dùng `--server-side` apply để tránh lỗi CRD > 256KB annotation limit
- UI truy cập qua port-forward: `https://localhost:9090`

### 4.2 Cấu hình

```
argocd/applications/
├── yas-project.yaml       # AppProject — scope cho namespace dev + staging
├── dev-appset.yaml        # ApplicationSet — 20 apps cho dev
└── staging-appset.yaml    # ApplicationSet — 20 apps cho staging
```

**AppProject `yas`:**
- Cho phép deploy vào namespace `dev` và `staging`
- Source: `https://github.com/NPT-102/yas-2.git`

**ApplicationSet `yas-dev`:**
- Generator: List (20 services)
- Source: Git repo, branch `main`, path `k8s/charts/<service>`
- Helm values: `values.yaml` + `values-dev.yaml`
- SyncPolicy: automated (prune + selfHeal)
- Destination: namespace `dev`

**ApplicationSet `yas-staging`:**
- Tương tự dev, nhưng dùng `values-staging.yaml`
- Destination: namespace `staging`

### 4.3 Environment Values Overlay

Mỗi chart có 3 file values:

| File | Mục đích | Image Tag |
|------|----------|-----------|
| `values.yaml` | Giá trị mặc định (NS yas) | `latest` |
| `values-dev.yaml` | Override cho dev | `latest` |
| `values-staging.yaml` | Override cho staging | `v1.0.0` (cập nhật bởi CI) |

### 4.4 Kết quả

- **40 ArgoCD Applications** đã tạo thành công (20 dev + 20 staging)
- ArgoCD Dashboard hiển thị tất cả apps với status
- Auto-sync + self-heal enabled

---

## 5. Istio Service Mesh

### 5.1 Cài đặt

- Istio release 1.24
- Cài qua `istioctl install --set profile=default`
- Namespace `yas` đã label: `istio-injection=enabled`
- Tất cả 21 pods chạy `2/2` (app container + istio-proxy sidecar)

### 5.2 mTLS STRICT

**File:** `istio/peer-authentication.yaml`

```yaml
apiVersion: security.istio.io/v1
kind: PeerAuthentication
metadata:
  name: default-mtls
  namespace: yas
spec:
  mtls:
    mode: STRICT
```

- Toàn bộ traffic trong namespace `yas` bắt buộc mTLS
- Không cho phép plaintext HTTP giữa các service
- Kiali hiển thị biểu tượng khóa trên mỗi kết nối

### 5.3 DestinationRule — ISTIO_MUTUAL

**File:** `istio/destination-rule.yaml`

Ban đầu dùng wildcard `*.yas.svc.cluster.local` → Kiali v2.0 báo lỗi không validate được.

**Giải pháp:** Tách thành 21 DestinationRule riêng biệt, mỗi service một rule:

```yaml
apiVersion: networking.istio.io/v1
kind: DestinationRule
metadata:
  name: mtls-cart
  namespace: yas
spec:
  host: cart.yas.svc.cluster.local
  exportTo:
    - "."
    - "ingress-nginx"
  trafficPolicy:
    tls:
      mode: ISTIO_MUTUAL
```

**exportTo:** `[".", "ingress-nginx"]` — cho phép cả service trong `yas` và `ingress-nginx` nhìn thấy rule này.

### 5.4 Authorization Policy

**File:** `istio/authorization-policy.yaml`

| Policy | Loại | Mô tả |
|--------|------|--------|
| `deny-all` | DENY | Mặc định từ chối tất cả traffic |
| `allow-ingress-to-yas` | ALLOW | Cho phép ingress-nginx truy cập yas |
| `allow-bff-to-backends` | ALLOW | BFF → tất cả backend services |
| `allow-order-dependencies` | ALLOW | order → cart, product, customer, inventory, payment, tax |
| `allow-order-to-customer` | ALLOW | order → customer |
| `allow-order-to-inventory` | ALLOW | order → inventory |
| `allow-order-to-payment` | ALLOW | order → payment |
| `allow-order-to-tax` | ALLOW | order → tax |
| `allow-payment-to-paypal` | ALLOW | payment → payment-paypal |
| `allow-search-to-product` | ALLOW | search → product |

**Label selector đã sửa:** Từ `app: cart` sang `app.kubernetes.io/name: cart` (khớp với Helm labels).

### 5.5 ingress-nginx trong Mesh

**Vấn đề:** ingress-nginx nằm ngoài mesh → gửi plaintext HTTP → bị STRICT mTLS reject → `502 Bad Gateway`.

**Giải pháp:**
1. Label namespace: `kubectl label ns ingress-nginx istio-injection=enabled`
2. Restart controller để inject sidecar
3. Thêm annotations trong Helm ingress template:
   ```yaml
   nginx.ingress.kubernetes.io/service-upstream: "true"
   nginx.ingress.kubernetes.io/upstream-vhost: "<service>.<namespace>.svc.cluster.local"
   ```

**Kết quả:** ingress-nginx controller chạy `2/2`, traffic đi qua sidecar → mTLS → service.

---

## 6. Monitoring & Observability

### 6.1 Kiali Dashboard

- **Version:** v2.0
- **Namespace:** istio-system
- **Truy cập:** `http://localhost:20001` (port-forward)
- **Chức năng:**
  - Traffic Graph — topology service mesh
  - Istio Config — validate DestinationRule, AuthorizationPolicy, PeerAuthentication
  - Workloads — chi tiết pod, sidecar
  - Services — endpoints, port naming

### 6.2 Prometheus

- Cài từ Istio addon
- Thu thập metrics từ tất cả services qua port `http-metric` (8090)
- ServiceMonitor scrape `/actuator/prometheus`

### 6.3 Grafana

- Cài từ Istio addon
- Tích hợp với Kiali (`in_cluster_url: http://grafana.istio-system:3000`)
- Dashboard: Istio Service, Istio Workload, Istio Mesh

---

## 7. Các vấn đề đã giải quyết

### 7.1 502 Bad Gateway — mTLS STRICT + ingress-nginx

| Mục | Chi tiết |
|-----|----------|
| **Triệu chứng** | `curl -H "Host: storefront.yas.local.com" http://192.168.49.2/` → 502 |
| **Nguyên nhân** | ingress-nginx ngoài mesh gửi plaintext, STRICT mTLS reject |
| **Log** | `recv() failed (104: Connection reset by peer)` |
| **Giải pháp** | Inject sidecar vào ingress-nginx + service-upstream + upstream-vhost |
| **Kết quả** | Storefront 200 OK, Backoffice 302 redirect |

### 7.2 Kiali — "Namespace metrics is not available"

| Mục | Chi tiết |
|-----|----------|
| **Nguyên nhân** | Chưa cài Prometheus |
| **Giải pháp** | `kubectl apply -f .../samples/addons/prometheus.yaml` |

### 7.3 Kiali — AuthorizationPolicy "No matching workload"

| Mục | Chi tiết |
|-----|----------|
| **Nguyên nhân** | Selector dùng `app: cart` nhưng pod label là `app.kubernetes.io/name: cart` |
| **Giải pháp** | Sửa tất cả 7 policies sang `app.kubernetes.io/name` |

### 7.4 Kiali — KIA0601 Port naming

| Mục | Chi tiết |
|-----|----------|
| **Nguyên nhân** | Port name `metric` không theo convention, phải bắt đầu bằng protocol |
| **Giải pháp** | Đổi `metric` → `http-metric` trong service.yaml template + patch 18 services |

### 7.5 Kiali — DestinationRule wildcard host lỗi đỏ

| Mục | Chi tiết |
|-----|----------|
| **Nguyên nhân** | Kiali v2.0 không validate được wildcard `*.yas.svc.cluster.local` |
| **Đã thử** | Ignore rules KIA0201/KIA0202 — không fix |
| **Giải pháp** | Tách wildcard thành 21 DestinationRule per-service |

### 7.6 ArgoCD — CRD annotation limit

| Mục | Chi tiết |
|-----|----------|
| **Nguyên nhân** | CRD > 256KB, client-side apply thêm `last-applied-configuration` annotation quá lớn |
| **Giải pháp** | Dùng `kubectl apply --server-side` |

---

## 8. Cấu trúc thư mục

```
yas/
├── .github/workflows/
│   ├── npt-ci.yml                    # CI: Build + Push Docker Hub
│   ├── npt-dev-deploy.yml            # CD: Dev deploy (ArgoCD)
│   ├── npt-staging-deploy.yml        # CD: Staging deploy (ArgoCD)
│   ├── npt-developer_build.yml       # CD: Developer manual deploy
│   └── npt-cleanup.yml               # Cleanup developer namespace
│
├── argocd/applications/
│   ├── yas-project.yaml              # ArgoCD Project scope
│   ├── dev-appset.yaml               # ApplicationSet dev (20 apps)
│   └── staging-appset.yaml           # ApplicationSet staging (20 apps)
│
├── istio/
│   ├── peer-authentication.yaml      # mTLS STRICT
│   ├── destination-rule.yaml         # 21 DestinationRules ISTIO_MUTUAL
│   └── authorization-policy.yaml     # RBAC: deny-all + allow rules
│
├── k8s/charts/
│   ├── backend/templates/            # Shared: Deployment, Service, Ingress, HPA
│   ├── ui/templates/                 # Shared: UI Deployment, Service, Ingress
│   ├── yas-configuration/            # Shared ConfigMaps + Secrets
│   ├── cart/                         # values.yaml + values-dev.yaml + values-staging.yaml
│   ├── order/
│   ├── product/
│   ├── ... (20 service charts)
│   └── swagger-ui/
│
├── project-docs/                     # Tài liệu đồ án
│   ├── BAO-CAO-QUA-TRINH.md         # ← File này
│   ├── HUONG-DAN-ARGOCD.md          # Hướng dẫn cài ArgoCD
│   ├── CAI-DAT-TU-DAU.md            # Hướng dẫn cài từ đầu
│   ├── CHANGES.md                    # Danh sách thay đổi so với repo gốc
│   ├── HUONG-DAN-DO-AN.md           # Hướng dẫn đồ án chi tiết
│   ├── KHOI-PHUC-CLUSTER.md         # Khôi phục cluster
│   ├── SESSION-STRICT-MTLS-INGRESS.md # Worklog xử lý mTLS
│   ├── TROUBLESHOOTING-INGRESS-ISTIO.md
│   ├── TROUBLESHOOTING-SERVICES.md
│   └── VIEC-CAN-LAM.md              # Checklist việc cần làm
│
├── cart/ order/ product/ ...         # Source code Java services
├── backoffice/ storefront/           # Source code frontend
└── docker-compose.yml                # Local development
```

---

## 9. Danh sách file đã thay đổi/tạo mới

### 9.1 Workflows (sửa)

| File | Thay đổi |
|------|----------|
| `.github/workflows/npt-dev-deploy.yml` | Đổi từ Helm trực tiếp → ArgoCD sync |
| `.github/workflows/npt-staging-deploy.yml` | Thêm bước update values-staging.yaml + ArgoCD sync |

### 9.2 Istio (sửa)

| File | Thay đổi |
|------|----------|
| `istio/peer-authentication.yaml` | mTLS STRICT |
| `istio/destination-rule.yaml` | Wildcard → 21 per-service DestinationRules |
| `istio/authorization-policy.yaml` | Fix label selectors `app` → `app.kubernetes.io/name` |

### 9.3 Helm Templates (sửa)

| File | Thay đổi |
|------|----------|
| `k8s/charts/backend/templates/ingress.yaml` | Thêm auto-inject service-upstream + upstream-vhost |
| `k8s/charts/backend/templates/service.yaml` | Port name `metric` → `http-metric` |
| `k8s/charts/ui/templates/ingress.yaml` | Thêm auto-inject service-upstream + upstream-vhost |
| `k8s/charts/swagger-ui/templates/ingress.yaml` | Thêm auto-inject |
| `k8s/charts/swagger-ui/templates/api-ingress.yaml` | Tách multi-backend → per-service ingress |

### 9.4 ArgoCD (mới)

| File | Mô tả |
|------|--------|
| `argocd/applications/yas-project.yaml` | AppProject cho dev + staging |
| `argocd/applications/dev-appset.yaml` | 20 apps auto-sync → NS dev |
| `argocd/applications/staging-appset.yaml` | 20 apps auto-sync → NS staging |

### 9.5 Values Overlay (mới — 40 files)

| Pattern | Số file | Mô tả |
|---------|---------|--------|
| `k8s/charts/*/values-dev.yaml` | 20 | Override image tag + ingress host cho dev |
| `k8s/charts/*/values-staging.yaml` | 20 | Override image tag + ingress host cho staging |

### 9.6 Documentation (mới + di chuyển)

| File | Mô tả |
|------|--------|
| `project-docs/BAO-CAO-QUA-TRINH.md` | Báo cáo tổng hợp (file này) |
| `project-docs/HUONG-DAN-ARGOCD.md` | Hướng dẫn ArgoCD chi tiết |
| `project-docs/SESSION-STRICT-MTLS-INGRESS.md` | Worklog debug mTLS + Kiali |
| Các file khác | Di chuyển từ root → `project-docs/` |

---

## Tổng kết

| Yêu cầu | Trạng thái | Giải pháp |
|----------|-----------|-----------|
| K8S Cluster (1 master + 1 worker) | ✅ | Minikube 2 nodes |
| CI: Build image → Push Docker Hub | ✅ | `npt-ci.yml` — detect changes + matrix build |
| CD Developer: Deploy 1 service từ branch | ✅ | `npt-developer_build.yml` — manual dispatch |
| Cleanup developer deployment | ✅ | `npt-cleanup.yml` — xóa namespace |
| Dev deploy: Push main → auto deploy | ✅ | `npt-dev-deploy.yml` + ArgoCD ApplicationSet |
| Staging deploy: Tag v* → build + deploy | ✅ | `npt-staging-deploy.yml` + ArgoCD ApplicationSet |
| ArgoCD handle dev + staging | ✅ | 40 Applications (20 dev + 20 staging) |
| Istio mTLS STRICT | ✅ | PeerAuthentication + 21 DestinationRules |
| Istio Authorization Policy | ✅ | deny-all + 9 allow rules |
| Monitoring (Kiali, Prometheus, Grafana) | ✅ | Istio addons + Kiali v2.0 |
