# Worklog — STRICT mTLS và ingress-nginx

## Mục tiêu

Xử lý xung đột giữa `PeerAuthentication STRICT` của Istio và `ingress-nginx`, sao cho:

- Không cần đổi namespace `yas` sang `PERMISSIVE`
- Các URL public vẫn truy cập được từ browser
- Traffic trong mesh vẫn giữ `mTLS STRICT`

## Nguyên nhân gốc đã xác định

Ban đầu `ingress-nginx` nằm ngoài mesh, không có sidecar, nên khi proxy vào service trong namespace `yas` nó gửi plain HTTP.

Khi `PeerAuthentication` của `yas` để `STRICT`, sidecar của workload trong `yas` từ chối luồng plain HTTP này. Kết quả là:

- `ingress-nginx` log `recv() failed (104: Connection reset by peer)`
- Browser nhận `502 Bad Gateway`

## Các hướng đã thử

### 1. Đổi toàn namespace sang PERMISSIVE

Hướng này giải quyết được truy cập web nhưng không đạt mục tiêu giữ `STRICT` cho bài đồ án.

### 2. Dùng `portLevelMtls`

Đã thử cấu hình `portLevelMtls` để cho phép riêng port 80 nhận plaintext. Tuy nhiên Istio yêu cầu `selector`, nên không áp dụng được theo kiểu namespace-wide policy đơn giản.

## Giải pháp đã áp dụng

### 1. Đưa ingress-nginx vào mesh

- Label namespace `ingress-nginx` với `istio-injection=enabled`
- Restart `ingress-nginx-controller` để pod mới được inject sidecar

Sau bước này pod `ingress-nginx-controller` chạy với `2/2` containers, trong đó có `istio-proxy`.

### 2. Xuất DestinationRule cho namespace ingress-nginx

Cập nhật `istio/destination-rule.yaml` để thêm:

```yaml
exportTo:
  - "."
  - "ingress-nginx"
```

Mục đích là để sidecar trong namespace `ingress-nginx` cũng nhìn thấy được `DestinationRule` của `yas` và tự dùng `ISTIO_MUTUAL`.

### 3. Giữ PeerAuthentication ở STRICT

Cập nhật `istio/peer-authentication.yaml` về:

```yaml
mtls:
  mode: STRICT
```

### 4. Cập nhật AuthorizationPolicy cho ingress-nginx principal

Do `ingress-nginx` đã nằm trong mesh, nó không còn là request "ngoài mesh" nữa. Vì vậy policy allow được đổi từ `notPrincipals` sang principal rõ ràng:

```yaml
cluster.local/ns/ingress-nginx/sa/ingress-nginx
```

### 5. Bước quan trọng nhất: ép ingress-nginx proxy theo service identity

Chỉ inject sidecar là chưa đủ. Ban đầu `ingress-nginx` vẫn route theo Pod IP, khi đó Envoy chỉ thấy `PassthroughCluster` và không match được `DestinationRule` `*.yas.svc.cluster.local`.

Fix đã được xác nhận là:

- Bật `service-upstream: "true"`
- Set `upstream-vhost: <service>.<namespace>.svc.cluster.local`

Khi đó log của sidecar chuyển từ `PassthroughCluster` sang dạng:

```text
outbound|80||storefront-bff.yas.svc.cluster.local
```

Đây là dấu hiệu cho thấy traffic đã được route theo service identity của Istio và có thể dùng `mTLS` đúng cách.

## Các file đã sửa trong repo

- `istio/peer-authentication.yaml`
- `istio/destination-rule.yaml`
- `istio/authorization-policy.yaml`
- `k8s/charts/backend/templates/ingress.yaml`
- `k8s/charts/ui/templates/ingress.yaml`
- `k8s/charts/swagger-ui/templates/ingress.yaml`
- `k8s/charts/swagger-ui/templates/api-ingress.yaml`

## Thay đổi template Helm

Đã thêm logic tự động cho các ingress dùng `nginx`:

- Thêm annotation `nginx.ingress.kubernetes.io/service-upstream: "true"`
- Thêm annotation `nginx.ingress.kubernetes.io/upstream-vhost: <service>.<namespace>.svc.cluster.local`

Với `swagger-ui` API ingress, đã tách ingress nhiều backend thành nhiều ingress 1 backend/path để mỗi ingress có `upstream-vhost` đúng với service phía sau.

## Kết quả test tại cluster

Sau khi patch và test trực tiếp trên cluster:

- `storefront.yas.local.com` trả `200`
- `backoffice.yas.local.com` trả `302`
- `api.yas.local.com/` trả `404` tại root path
- `api.yas.local.com/product/api/products` vẫn `503` ở cluster hiện tại vì resource live của swagger API chưa được redeploy theo template mới

## Kết luận

Có thể giữ `mTLS STRICT` mà vẫn dùng được `ingress-nginx`, nhưng cần đồng thời đáp ứng 3 điều kiện:

1. `ingress-nginx` nằm trong mesh
2. `DestinationRule` được export cho namespace `ingress-nginx`
3. `ingress-nginx` proxy theo service identity bằng `service-upstream` và `upstream-vhost`

Nếu thiếu bước 3, `STRICT` vẫn sẽ fail dù đã inject sidecar cho `ingress-nginx`.

## Việc tiếp theo nên làm

1. Redeploy chart `swagger-ui` để tạo lại các ingress API từ template mới
2. Re-test `api.yas.local.com` trên từng path backend
3. Nếu cần báo cáo đồ án, chụp log Envoy có `outbound|80||storefront-bff.yas.svc.cluster.local` để chứng minh ingress-nginx đã nói chuyện qua mesh đúng cách

---

## Các vấn đề gặp phải khi cài Kiali Dashboard

### Vấn đề 1: Kiali không có metrics — "Namespace metrics is not available"

**Hiện tượng:**
- Trang Overview hiển thị "Namespace metrics is not available" cho tất cả namespace
- Istio config hiện `N/A`
- Góc trên phải báo lỗi đỏ: `Could not fetch health: Error while fetching app health: Post "http://prometheus.istio-system:9090/api/v1/query": dial tcp: lookup prometheus.istio-system on 10.96.0.10:53: no such host`

**Nguyên nhân:**
Kiali cần Prometheus để lấy metrics nhưng chưa cài Prometheus trong namespace `istio-system`.

**Cách giải quyết:**
```bash
kubectl apply -f https://raw.githubusercontent.com/istio/istio/release-1.24/samples/addons/prometheus.yaml
```

### Vấn đề 2: Grafana Unreachable

**Hiện tượng:**
- Istio Components Status hiện `grafana: Unreachable`
- Message Center báo: `grafana URL is not set in Kiali configuration`

**Nguyên nhân:**
Chưa cài Grafana và chưa cấu hình URL trong Kiali config.

**Cách giải quyết:**

1. Cài Grafana:
```bash
kubectl apply -f https://raw.githubusercontent.com/istio/istio/release-1.24/samples/addons/grafana.yaml
```

2. Thêm Grafana URL vào configmap Kiali:
```yaml
external_services:
  grafana:
    enabled: true
    in_cluster_url: http://grafana.istio-system:3000
    url: http://localhost:3000
```

3. Restart Kiali:
```bash
kubectl rollout restart deployment/kiali -n istio-system
```

### Vấn đề 3: AuthorizationPolicy warning — "No matching workload found for the selector"

**Hiện tượng:**
- 7 AuthorizationPolicy hiện icon ⚠️ vàng trong Kiali Istio Config
- Message: `No matching workload found for the selector in this namespace`

**Nguyên nhân:**
Các AuthorizationPolicy dùng selector `app: cart`, `app: customer`... nhưng pod thực tế dùng label `app.kubernetes.io/name: cart` (do Helm chart tạo ra).

**Cách giải quyết:**
Sửa tất cả selector trong `istio/authorization-policy.yaml` từ:
```yaml
selector:
  matchLabels:
    app: cart
```
thành:
```yaml
selector:
  matchLabels:
    app.kubernetes.io/name: cart
```

Áp dụng cho 7 policy: `allow-order-dependencies`, `allow-order-to-customer`, `allow-order-to-inventory`, `allow-order-to-payment`, `allow-order-to-tax`, `allow-payment-to-paypal`, `allow-search-to-product`.

### Vấn đề 4: KIA0601 — Port name không đúng format Istio

**Hiện tượng:**
- Tất cả 18 backend service hiện icon 🔴 trong Kiali Services
- Lỗi: `KIA0601 Port name must follow <protocol>[-suffix] form`

**Nguyên nhân:**
Service port 8090 (metrics) có `name: metric` nhưng Istio yêu cầu tên port phải bắt đầu bằng protocol (ví dụ `http`, `grpc`, `tcp`...).

**Cách giải quyết:**

1. Sửa Helm template `k8s/charts/backend/templates/service.yaml` — đổi `name: metric` thành `name: http-metric`
2. Patch tất cả service đang live:
```bash
for svc in backoffice-bff cart customer inventory location media order payment payment-paypal product promotion rating recommendation sampledata search storefront-bff tax webhook; do
  kubectl patch svc "$svc" -n yas --type='json' \
    -p='[{"op":"replace","path":"/spec/ports/1/name","value":"http-metric"}]'
done
```

### Vấn đề 5: DestinationRule wildcard host bị Kiali báo lỗi đỏ

**Hiện tượng:**
- DestinationRule `default-mtls-destination` luôn hiện icon 🔴 trong Istio Config
- Khi click vào xem chi tiết, Kiali hiện cảnh báo trên dòng `host`, `trafficPolicy`, `exportTo`
- Dù đã thêm ignore KIA0201/KIA0202 vào config Kiali nhưng vẫn lỗi

**Nguyên nhân:**
Kiali v2.0 không validate được DestinationRule dùng wildcard host `*.yas.svc.cluster.local` — nó không match được host cụ thể nào trong service registry.

**Cách giải quyết:**
Xoá DestinationRule wildcard và tạo riêng cho từng service:

```bash
# Xoá cái cũ
kubectl delete destinationrule default-mtls-destination -n yas

# Apply file mới với 21 DestinationRule (1 per service)
kubectl apply -f istio/destination-rule.yaml
```

Mỗi DestinationRule có dạng:
```yaml
apiVersion: networking.istio.io/v1beta1
kind: DestinationRule
metadata:
  name: mtls-<tên-service>
  namespace: yas
spec:
  host: <tên-service>.yas.svc.cluster.local
  exportTo: [".", "ingress-nginx"]
  trafficPolicy:
    tls:
      mode: ISTIO_MUTUAL
```

Sau khi tách, tất cả DestinationRule hiện ✅ xanh trong Kiali.