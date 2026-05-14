# 📦 Yas E-Commerce - DevOps Fundamentals Project 2

Chào mừng đến với **Project 2** môn học **Cơ sở hạ tầng DevOps (DevOps Fundamentals)**. Dự án này tập trung vào việc triển khai, vận hành và chuẩn hóa kiến trúc phân tán (Microservices) cho hệ thống thương mại điện tử **Yas** trên hạ tầng Kubernetes sử dụng triết lý GitOps tiên tiến.

---

## 📂 1. Cấu trúc Repository (Repository Architecture)

Hệ thống được tổ chức dưới dạng Monorepo đã được tối ưu hóa và tái cấu trúc chuyên nghiệp, phân tách rõ ràng giữa **Logic Nghiệp vụ (Services)** và **Cơ sở Hạ tầng (Infrastructure)**:

```text
yas-2/
├── .github/                    # Quy trình Tự động hóa CI/CD Workflows
│   └── workflows/              # Các kịch bản CI, Developer CD & Release Staging
│
├── infra/                      # 🌟 TOÀN BỘ TÀI NGUYÊN HẠ TẦNG (DevOps Central)
│   ├── argocd/                 # Cấu hình GitOps & ApplicationSets
│   ├── istio/                  # Mesh traffic routing (mTLS, VirtualServices, Policies)
│   ├── nginx/                  # Cấu hình máy chủ Nginx Proxy cho Local Dev
│   ├── k8s/                    # Môi trường Kubernetes (K3s)
│   │   ├── charts/             # Helm Charts cho từng Microservice và Cấu hình Chung
│   │   └── deploy/             # Scripts thiết lập Cụm (Cluster Setup) & Core Infra
│   └── scripts/                # Bộ tiện ích vận hành hệ thống (Shell Scripts)
│
├── [22 Microservices]          # Các modules ứng dụng thương mại điện tử
│   ├── cart/                   # Giỏ hàng
│   ├── product/                # Danh mục sản phẩm
│   ├── order/                  # Xử lý đơn hàng
│   ├── payment/                # Tích hợp thanh toán
│   └── ...                     # Các dịch vụ phụ trợ (tax, rating, location, v.v.)
│
├── docs/                       # Toàn bộ tài liệu báo cáo dự án (Markdown & LaTeX)
│   ├── project-docs/           # Hướng dẫn kỹ thuật chi tiết & Báo cáo tiến độ
│   └── report-latex/           # Mã nguồn LaTeX báo cáo tổng kết đồ án
│
├── docker-compose.yml          # Hỗ trợ chạy thử nghiệm nhanh dưới máy cục bộ (Local Dev)
└── pom.xml                     # Maven Root cấu hình quản lý thư viện dùng chung
```

---

## 🛠️ 2. Công nghệ & Công cụ Sử dụng (Tech Stack)

| Lĩnh vực | Công nghệ / Công cụ | Mô tả chi tiết |
| :--- | :--- | :--- |
| **Core Platform** | Java 25 & Spring Boot 4.0.2 | Công nghệ lõi xây dựng backend cho toàn bộ hệ thống |
| **Containerization** | Docker & Docker Compose | Đóng gói dịch vụ và thiết lập môi trường giả lập |
| **Orchestration** | K3s / Kubernetes (v1.38+) | Môi trường quản trị, vận hành Container ổn định, nhẹ nhàng |
| **Service Mesh** | Istio (v1.24+) | Quản lý vi lưu lượng, mã hóa mTLS, bảo mật & phân luồng traffic |
| **GitOps** | ArgoCD (ApplicationSet) | Tự động hóa hoàn toàn việc đồng bộ trạng thái ứng dụng từ Git |
| **Package Manager** | Helm (v3.x) | Đóng gói các tài nguyên Kubernetes dưới dạng Template Charts |
| **CI/CD Pipelines** | GitHub Actions & Self-hosted Runner | Tự động build mã nguồn, đóng gói image & trigger deployment |
| **Observability** | Grafana LGTM (Loki, Grafana, Tempo, Mimir) | Giám sát Log tập trung, Dashboard & Trace giao dịch phân tán |
| **Data Backbone** | Kafka, PostgreSQL, Redis, Elasticsearch | Hạ tầng lưu trữ, bộ đệm, tìm kiếm & truyền thông điệp phi đồng bộ |

---

## 🚀 3. Hướng dẫn Vận hành Nhanh (Quick Start Guide)

### A. Môi trường Cục bộ (Docker Compose Local Dev)

1. Đảm bảo bạn đã cấu hình tệp tin `/etc/hosts` (hoặc `C:\Windows\System32\drivers\etc\hosts` trên Windows):
   ```text
   127.0.0.1 identity api.yas.local pgadmin.yas.local storefront backoffice elasticsearch kafka
   ```
2. Khởi động toàn bộ hệ thống Yas trên nền tảng Docker:
   ```bash
   # Sử dụng script tiện ích đã quy hoạch
   bash infra/scripts/start-yas.sh
   ```
3. Sau khi tất cả container ở trạng thái `Running`, thiết lập Debezium Kafka Connectors:
   ```bash
   bash infra/scripts/start-source-connectors.sh
   ```
4. Truy cập Cổng ứng dụng:
   - Storefront: `http://storefront/`
   - Backoffice: `http://backoffice/` (Đăng nhập: `admin/password`)

---

### B. Triển khai trên Cụm Kubernetes (K3s & GitOps)

#### Bước 1: Thiết lập Cluster ban đầu
1. Đảm bảo bạn đã truy cập vào cluster đích (cấu hình kubeconfig hợp lệ).
2. Di chuyển vào thư mục cài đặt hạ tầng:
   ```bash
   cd infra/k8s/deploy
   ```
3. Chạy script khởi tạo hạ tầng lõi (Postgres, Kafka, Redis, Keycloak...):
   ```bash
   bash setup-cluster.sh
   ```

#### Bước 2: Khởi tạo GitOps với ArgoCD
Toàn bộ ứng dụng và hạ tầng Yas được quản lý dưới dạng **ArgoCD ApplicationSets**. Để đưa ứng dụng lên cluster:

1. Cài đặt ArgoCD `Application` gốc (Root Application) trỏ vào cấu hình:
   ```bash
   kubectl apply -f ../argocd/applications/yas-project.yaml
   # Triển khai ApplicationSet cho môi trường mong muốn (Dev/Staging)
   kubectl apply -f ../argocd/applications/dev-appset.yaml
   ```
2. ArgoCD sẽ tự động quét thư mục `infra/k8s/charts/` và sinh ra 22 microservices tương ứng trên cụm Kubernetes của bạn.

---

## ⚙️ 4. Luồng Tự động hóa CI/CD (GitHub Actions Workflow)

Repository được trang bị **23 workflows** tối ưu hiệu suất, chạy song song trên **Self-hosted Runner** của nhóm:

1. **Liên tục Tích hợp (Continuous Integration - CI):**
   - Mỗi microservice sở hữu một file workflow độc lập `ci-<service-name>.yaml`.
   - Tự động kích hoạt khi có thay đổi code trong chính thư mục dịch vụ tương ứng.
   - Build Java bằng Maven và chạy kiểm thử tự động.
2. **Triển khai Môi trường Phát triển (Developer Build - CD):**
   - File: `cd-developer-build.yaml` (Kích hoạt thủ công thông qua `workflow_dispatch`).
   - Cho phép một lập trình viên build một bộ **18 core services** từ các nhánh (branch) bất kỳ vào một Namespace cô lập tùy chỉnh (ví dụ: `dev-tan`).
   - Hỗ trợ tải và biên dịch Chart song song giúp giảm thời gian deploy xuống dưới 5 phút.
3. **Triển khai Môi trường Staging (Release Staging - CD):**
   - File: `release-staging.yaml`.
   - Tự động kích hoạt khi một Release Tag có định dạng `v*.*.*` được đẩy lên (Push Tag).
   - Tự động cập nhật Image Tag mới vào các file `infra/k8s/charts/*/values-staging.yaml` và tự commit ngược lại nhánh `main`. ArgoCD sẽ phát hiện thay đổi và tự động thực hiện chiến lược Rolling Update cho toàn bộ cluster Staging.

---

## 🛠️ 5. Các Shell Scripts Hữu ích (Operational Scripts)

Tất cả scripts phục vụ vận hành đều được đặt trong thư mục `infra/scripts/`:

*   **`start-yas.sh`**: Khởi động hệ thống Yas cục bộ thông qua Docker Compose.
*   **`start-source-connectors.sh`**: Cấu hình luồng Change Data Capture (CDC) Debezium cho PostgreSQL sang Kafka.
*   **`argocd-toggle-minimal.sh`**: Cho phép chuyển nhanh ứng dụng trên ArgoCD sang cấu hình "Minimal" (tắt bớt pods, giảm replicas) để tiết kiệm RAM cho cụm K3s yếu, hoặc bật lại đầy đủ replicas.
    - *Bật Minimal:* `bash infra/scripts/argocd-toggle-minimal.sh enable`
    - *Tắt Minimal:* `bash infra/scripts/argocd-toggle-minimal.sh disable`

---

## 📚 6. Tài liệu Tham khảo

Để tìm hiểu sâu hơn về hệ thống, kiến trúc mesh hay các bước xử lý sự cố, vui lòng tham khảo tài liệu chi tiết trong thư mục `docs/project-docs/`:

*   📄 [Báo cáo quá trình làm đồ án](docs/project-docs/BAO-CAO-QUA-TRINH.md)
*   📄 [Hướng dẫn cấu hình & Tối ưu hạ tầng K3s](docs/project-docs/HUONG-DAN-TRIEN-KHAI-TOI-UU.md)
*   📄 [Tài liệu hướng dẫn GitOps với ArgoCD](docs/project-docs/HUONG-DAN-ARGOCD.md)
*   📄 [Cẩm nang Xử lý Sự cố CI/CD & Cluster (Troubleshooting)](docs/project-docs/TROUBLESHOOTING-CICD.md)

---
*Chúc các bạn có một kỳ thực hành DevOps thành công rực rỡ!* 🚀🌟
