# YAS Startup Troubleshooting Report

## Môi trường

| Thành phần | Phiên bản / Chi tiết |
|---|---|
| Orchestration | K3s (Kubernetes) |
| Service Mesh | Istio 1.24.3 |
| Namespace ứng dụng | `yas` |
| Ingress | ingress-nginx (có Istio sidecar) |
| Auth | Keycloak realm `Yas` |
| Observability | Prometheus, Grafana, Kiali (istio-system) |

---

## Vấn đề 1: `api-inventory` trả về HTTP 400

### Triệu chứng

Traffic generator gọi endpoint `/api/inventory/backoffice/stocks` luôn nhận `400 Bad Request`.

### Nguyên nhân

Controller method `GET /backoffice/stocks` có parameter bắt buộc:

```java
@GetMapping("/backoffice/stocks")
public ResponseEntity<?> getStocks(@RequestParam Long warehouseId, ...) { ... }
```

`warehouseId` là `@RequestParam` không có `required = false` và không có `defaultValue`, nên Spring MVC trả 400 khi không truyền tham số này.

### Giải pháp

Thay endpoint trong traffic generator từ:
```
/inventory/backoffice/stocks
```
sang:
```
/inventory/backoffice/warehouses/paging?pageNo=0&pageSize=5
```

Endpoint `/backoffice/warehouses/paging` có các tham số `pageNo` và `pageSize` đều là `required = false` với giá trị mặc định, nên luôn trả `200 OK`.

**File đã sửa:** `infra/scripts/generate-traffic.js`

---

## Vấn đề 2: Grafana – Row "NGINX" hiển thị NaN

### Triệu chứng

Trên Grafana dashboard Istio Mesh, row dành cho `ingress-nginx` hiện `NaN` cho các metric L7 (request rate, success rate, latency).

### Nguyên nhân

`ingress-nginx` được inject Istio sidecar (namespace `ingress-nginx` có label `istio-injection=enabled`), nhưng sidecar của ingress-nginx **không expose Envoy metrics theo đúng format Istio workload**. Cụ thể:
- Metric `istio_requests_total{destination_service=~"ingress.*"}` không tồn tại hoặc bằng 0
- Biểu thức tính rate trong dashboard là `rate(...[5m]) / rate(...[5m])` → `0/0 = NaN`

### Đánh giá

Đây là **hành vi bình thường (expected)** với ingress-nginx trong Istio mesh:
- ingress-nginx đóng vai trò edge proxy, metrics L7 của nó không được scrape theo chuẩn Istio workload
- Các downstream services (`backoffice-bff`, `storefront-bff`, ...) đều hiển thị metrics bình thường
- Không ảnh hưởng đến hoạt động của hệ thống

### Hành động

Không cần fix. Có thể ẩn row `ingress-nginx` trên dashboard nếu muốn giao diện gọn hơn.

---

## Vấn đề 3: Prometheus UI hiển thị trống

### Triệu chứng

Truy cập `http://prometheus.yas.local.com` thấy trang trắng hoặc không load được data.

### Nguyên nhân

Không phải lỗi Prometheus. Có thể do:
1. **Cache browser**: Prometheus SPA cần JavaScript load đầy đủ
2. **Sai URL**: Cần truy cập đúng ingress host đã cấu hình
3. **Thời gian khởi động**: Prometheus addon của Istio cần 1-2 phút sau khi apply để sẵn sàng

### Xác nhận hệ thống hoạt động bình thường

```bash
# Kiểm tra Prometheus API
curl http://prometheus.yas.local.com/api/v1/targets | python3 -m json.tool | grep '"health"' | sort | uniq -c
```

Kết quả xác nhận: **29 active targets**, tất cả `"health": "up"`.

### Hành động

Thử hard refresh (Ctrl+Shift+R) hoặc dùng `curl` trực tiếp để xác nhận Prometheus hoạt động.

---

## Vấn đề 4: Istio sidecar chưa inject sau khi deploy

### Triệu chứng

Pod trong namespace `yas` chỉ có 1/1 container (không có sidecar `istio-proxy`), dẫn đến mTLS thất bại.

### Nguyên nhân

Namespace `yas` hoặc `ingress-nginx` chưa có label `istio-injection=enabled`, hoặc pod đã chạy trước khi label được thêm.

### Giải pháp

Script `deploy-yas-applications.sh` tự động xử lý:
```bash
kubectl label namespace yas istio-injection=enabled --overwrite
kubectl label namespace ingress-nginx istio-injection=enabled --overwrite
kubectl rollout restart deployment ingress-nginx-controller -n ingress-nginx
```

Nếu pods trong `yas` chưa có sidecar, restart deployment:
```bash
kubectl rollout restart deployment -n yas
```

Kiểm tra:
```bash
kubectl get pods -n yas
# Pods phải có dạng: 2/2 RUNNING (app container + istio-proxy)
```

---

## Vấn đề 5: Keycloak chưa sẵn sàng khi deploy BFF

### Triệu chứng

`backoffice-bff` hoặc `storefront-bff` crash loop vì không kết nối được đến Keycloak.

### Nguyên nhân

BFF được deploy trước khi Keycloak hoàn toàn khởi động và realm `Yas` được load.

### Giải pháp

Script `deploy-yas-applications.sh` có hàm `wait_for_keycloak()` chờ endpoint:
```
http://identity.yas.local.com/realms/Yas/.well-known/openid-configuration
```
trả về `issuer` trước khi deploy BFF.

Nếu vẫn lỗi, kiểm tra Keycloak pod:
```bash
kubectl get pods -n yas -l app.kubernetes.io/name=keycloak
kubectl logs -n yas <keycloak-pod>
```

---

## Vấn đề 6: Kafka volume permissions lỗi trên K3s hostPath

### Triệu chứng

Kafka pod ở trạng thái `CrashLoopBackOff` với lỗi permission denied trên PersistentVolume.

### Nguyên nhân

K3s dùng hostPath provisioner tạo volume với quyền `755 root:root`, trong khi Kafka cần ghi vào đó.

### Giải pháp

Script `setup-cluster.sh` gọi `fix-kafka-permissions.sh` sau khi tạo PVC:
```bash
bash ./fix-kafka-permissions.sh
```

Nếu cần chạy thủ công, xem script `infra/k8s/deploy/fix-kafka-permissions.sh`.

---

## Trạng thái cuối cùng sau khi fix

| Endpoint | Trạng thái |
|---|---|
| Traffic generator (17 endpoints) | 17 OK / round, 0 fail |
| Prometheus | 29 targets active |
| Grafana Istio Mesh Dashboard | Hoạt động (NaN ở nginx row là expected) |
| Kiali | mTLS lock icons hiển thị trên service graph |
| mTLS (STRICT) | Bật cho toàn bộ namespace `yas` |
| AuthorizationPolicy | deny-all + allow rules hoạt động |

---

## Lệnh kiểm tra nhanh

```bash
# Trạng thái pods
kubectl get pods -n yas

# Sidecar injection (phải có 2/2)
kubectl get pods -n yas -o custom-columns=NAME:.metadata.name,READY:.status.containerStatuses[*].ready

# mTLS status
kubectl get peerauthentication -n yas
kubectl get destinationrule -n yas

# AuthorizationPolicy
kubectl get authorizationpolicy -n yas

# Traffic generator
cd /home/npt102/DEVOPS-PRJ2/yas-2
YAS_DOMAIN=yas.local.com YAS_INTERVAL_MS=1500 node infra/scripts/generate-traffic.js
```
