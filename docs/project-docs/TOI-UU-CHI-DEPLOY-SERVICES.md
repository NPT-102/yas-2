# Backlog Sửa Hệ Thống YAS

## Mục Tiêu

- Chạy ổn định trên cluster mới trong WSL/K3s.
- Chỉ deploy 13 service cốt lõi cho demo.
- Có service mesh đầy đủ theo yêu cầu đồ án.
- Có observability đầy đủ với Prometheus và Grafana, kèm Loki/Tempo/OTel nếu hạ tầng cho phép.
- Có script kiểm thử tự động để xác nhận cấu hình sau mỗi lần dựng lại.

## Scope Service Hiện Tại

| Service | Lý do giữ |
|---------|-----------|
| `product` | Sản phẩm, trung tâm của shop |
| `cart` | Giỏ hàng, demo flow mua hàng |
| `order` | Đơn hàng, demo flow đặt hàng và retry policy |
| `customer` | Thông tin khách hàng |
| `inventory` | Kho hàng, order phụ thuộc |
| `tax` | Thuế, demo VirtualService retry |
| `media` | Upload hình ảnh sản phẩm |
| `search` | Tìm kiếm, demo AuthorizationPolicy |
| `storefront-bff` | BFF cho giao diện người dùng |
| `storefront-ui` | Giao diện cửa hàng |
| `backoffice-bff` | BFF cho quản trị |
| `backoffice-ui` | Giao diện quản trị |
| `swagger-ui` | API documentation |

Tổng: 13 services.

## Backlog Ưu Tiên

| Priority | Hạng mục | Việc cần làm | Kết quả mong đợi |
|----------|----------|--------------|------------------|
| P0 | Dựng lại cluster | Xóa cluster hiện tại trong WSL và cài lại K3s sạch hoặc Minikube 2-node | `kubectl get nodes` xanh, kubeconfig ổn định, ghi lại đầy đủ bước kết nối trong docs |
| P0 | Chốt hạ tầng cốt lõi | Cài PostgreSQL, Kafka, Elasticsearch, Keycloak và các dependency nền tảng | Các namespace hạ tầng chạy ổn định trước khi deploy app |
| P0 | Deploy 13 service cốt lõi | Chỉ giữ 13 service ở scope trên | Demo flow mua hàng, quản trị và Swagger hoạt động |
| P0 | Service mesh | Bật Istio sidecar cho namespace app, mTLS STRICT, AuthorizationPolicy, DestinationRule, VirtualService retry, Kiali | Topology hiển thị đúng, access control hoạt động, retry evidence rõ ràng |
| P0 | Observability | Cài Prometheus, Grafana, Loki, Tempo, OpenTelemetry Collector | Xem được metrics, dashboard và trace/log liên quan |
| P1 | CI theo commit ID | Build/push image theo commit SHA cho từng branch hoặc service branch | Image có traceability, không còn phụ thuộc `latest` cho nhánh dev |
| P1 | CD developer_build | Job nhận branch input và deploy đúng service branch đó | Dev thử nhanh một service mà không ảnh hưởng toàn bộ hệ thống |
| P1 | Job cleanup | Có job xóa triển khai developer | Có thể rollback về baseline sạch |
| P1 | Ảnh hóa môi trường dev/staging | Nếu dùng ArgoCD, map rõ dev/staging và tag release | Dev/staging tách biệt, dễ demo |
| P2 | Script kiểm thử JS | Viết `verify-yas-stack.js` và `smoke-yas-http.js` để kiểm tra pods, routes, mesh policy, Prometheus/Grafana/Kiali health | Chạy 1 lệnh là biết hệ thống còn ổn hay không |
| P2 | Chuẩn hóa docs | Ghi rõ cách kết nối kubeconfig, IP cluster, hosts file và trình tự cài đặt | Người khác có thể dựng lại từ đầu không cần đoán |
| P2 | Dọn nhãn cũ | Loại bỏ tên gọi và tài liệu theo hướng core services hoặc full stack | Repo nhất quán, không còn thông điệp mâu thuẫn |

## Ghi Chú Khi Triển Khai

- Không ưu tiên các service phụ ngoài 13 service cốt lõi cho demo chính.
- Chỉ giữ các service phụ khi nó phục vụ trực tiếp cho kiểm thử hoặc chứng minh vấn đề cụ thể.
- Nếu một service gây crash hoặc tiêu tốn tài nguyên mà không nằm trong scope demo, không đưa vào luồng mặc định.

## Tiêu Chí Hoàn Thành

- 13 service cốt lõi chạy ổn định trong namespace ứng dụng.
- K3s/Minikube mới được ghi lại đầy đủ bước kết nối và tái tạo.
- Istio, Prometheus và Grafana hoạt động được trên cluster thật.
- Có script kiểm thử tự động và kết quả pass/fail rõ ràng.
- Không còn tài liệu chính nào định nghĩa flow theo hướng thu gọn.
