# YAS Service Mesh — Test Scenarios

Tài liệu này mô tả các kịch bản kiểm thử Service Mesh (Istio) đã được thực hiện trên cụm YAS, bao gồm mTLS, AuthorizationPolicy, DestinationRule và Retry.

---

## Kiến trúc tổng quan

```
Internet
   │
   ▼
ingress-nginx (namespace: ingress-nginx, có Istio sidecar)
   │  mTLS ISTIO_MUTUAL (DestinationRule exportTo ingress-nginx)
   ▼
backoffice-bff / storefront-bff  (namespace: yas)
   │  mTLS ISTIO_MUTUAL
   ▼
product / cart / order / customer / inventory / tax / media / search
   │
   ▼ (Kafka, PostgreSQL — ngoài mesh)
```

Tất cả pod trong namespace `yas` và `ingress-nginx` đều được inject Istio sidecar (`istio-proxy`).

---

## Kịch bản 1: Xác nhận mTLS STRICT hoạt động

### Mục tiêu

Đảm bảo toàn bộ traffic trong namespace `yas` đều dùng mTLS, không có plain-text connection.

### Cấu hình liên quan

- `infra/istio/peer-authentication.yaml`: `PeerAuthentication` mode `STRICT`
- `infra/istio/destination-rule.yaml`: `DestinationRule` mode `ISTIO_MUTUAL` cho từng service

### Cách kiểm tra

**1. Kiểm tra PeerAuthentication đã được apply:**
```bash
kubectl get peerauthentication -n yas
# Expected: default-mtls   STRICT
```

**2. Xem Kiali — Security indicators:**
- Truy cập `http://kiali.yas.local.com`
- Vào **Graph → Namespace: yas**
- Các edge giữa service phải có biểu tượng khóa (lock icon) màu xanh

**3. Thử gọi trực tiếp không dùng mTLS (từ pod không có sidecar):**
```bash
# Tạo pod test không có sidecar
kubectl run test-no-sidecar --image=curlimages/curl \
  --namespace=default \
  --labels='sidecar.istio.io/inject=false' \
  --rm -it -- sh

# Thử gọi service trong namespace yas
curl http://product.yas.svc.cluster.local/api/product/storefront/products/paging
# Expected: connection refused hoặc RBAC denied (vì không có mTLS cert)
```

**4. Gọi từ pod có sidecar (BFF):**
```bash
kubectl exec -n yas deploy/backoffice-bff -c backoffice-bff -- \
  curl -s http://product.yas.svc.cluster.local/api/product/storefront/products/paging | head -c 200
# Expected: 200 OK với JSON response
```

### Kết quả mong đợi

| Test | Expected |
|---|---|
| Pod không sidecar → yas service | Connection refused / RBAC denied |
| Pod có sidecar (in-mesh) → yas service | 200 OK |
| Kiali lock icons | Hiển thị trên tất cả edge trong namespace yas |

---

## Kịch bản 2: AuthorizationPolicy — Deny-all + Allow rules

### Mục tiêu

Xác nhận rằng `deny-all` policy chặn mọi traffic không được whitelist, và chỉ các service được phép mới giao tiếp được với nhau.

### Cấu hình liên quan

- `infra/istio/authorization-policy.yaml`

### Các policy đã cấu hình

| Policy | Source | Destination |
|---|---|---|
| `deny-all` | (default deny) | Toàn bộ namespace `yas` |
| `allow-ingress-to-yas` | `ingress-nginx` SA | Toàn bộ namespace `yas` |
| `allow-bff-to-backends` | `backoffice-bff`, `storefront-bff` SA | Toàn bộ namespace `yas` |
| `allow-order-dependencies` | `order` SA | `cart` service |
| `allow-order-to-tax` | `order` SA | `tax` service |
| `allow-order-to-inventory` | `order` SA | `inventory` service |
| `allow-order-to-customer` | `order` SA | `customer` service |
| `allow-search-to-product` | `search` SA | `product` service |

### Cách kiểm tra

**Test 1: ingress-nginx → yas service (phải PASS)**
```bash
# Gọi thông qua ingress
curl -v http://api.yas.local.com/api/product/storefront/products/paging
# Expected: 200 OK
```

**Test 2: Service không được phép → service khác (phải FAIL)**
```bash
# Thử gọi từ product → cart (không có policy cho phép)
kubectl exec -n yas deploy/product -c product -- \
  curl -s -o /dev/null -w "%{http_code}" http://cart.yas.svc.cluster.local/api/cart
# Expected: 403 RBAC: access denied
```

**Test 3: order → cart (phải PASS)**
```bash
kubectl exec -n yas deploy/order -c order -- \
  curl -s -o /dev/null -w "%{http_code}" http://cart.yas.svc.cluster.local/api/cart/items/count
# Expected: 200 (hoặc 401 nếu cần auth token — không phải 403)
```

**Test 4: Xem logs Envoy để xác nhận RBAC:**
```bash
kubectl logs -n yas deploy/cart -c istio-proxy | grep -i "rbac\|denied\|allowed" | tail -20
```

### Kết quả mong đợi

| Caller | Target | Expected |
|---|---|---|
| ingress-nginx | product | 200 OK |
| product | cart | 403 RBAC denied |
| order | cart | 200 OK / 401 |
| search | product | 200 OK |
| storefront-bff | product | 200 OK |

---

## Kịch bản 3: DestinationRule — ISTIO_MUTUAL exportTo ingress-nginx

### Mục tiêu

Xác nhận DestinationRule được export đúng cách tới namespace `ingress-nginx`, cho phép sidecar của ingress-nginx thiết lập mTLS khi forward request vào namespace `yas`.

### Cấu hình liên quan

- `infra/istio/destination-rule.yaml`: `exportTo: [".", "ingress-nginx"]`

### Cách kiểm tra

**1. Xem DestinationRule đã apply:**
```bash
kubectl get destinationrule -n yas
# Expected: danh sách mtls-backoffice-bff, mtls-cart, mtls-product, ...
```

**2. Kiểm tra Envoy config của ingress-nginx có nhận DR không:**
```bash
kubectl exec -n ingress-nginx deploy/ingress-nginx-controller -c controller -- \
  curl -s localhost:15000/config_dump | \
  python3 -c "import sys,json; d=json.load(sys.stdin); [print(c['name']) for c in d.get('configs',[]) if 'dynamic_cluster' in c.get('@type','')]" 2>/dev/null || \
  istioctl proxy-config cluster -n ingress-nginx deploy/ingress-nginx-controller | grep yas
# Expected: cluster entries cho các service trong yas với TLS mode ISTIO_MUTUAL
```

**3. Traffic generator — xác nhận 0 fail:**
```bash
YAS_DOMAIN=yas.local.com YAS_INTERVAL_MS=1500 node infra/scripts/generate-traffic.js
# Expected: 17 OK, 1 redirect (Keycloak), 0 auth-blocked, 0 fail
```

### Kết quả mong đợi

- `istioctl proxy-config cluster` cho ingress-nginx hiển thị services của `yas` với TLS mode `ISTIO_MUTUAL`
- Traffic generator không có `fail` count

---

## Kịch bản 4: VirtualService Retry — Tự động retry khi 5xx

### Mục tiêu

Xác nhận Istio tự động retry request khi service trả về lỗi 5xx, giảm thiểu lỗi thoáng qua (transient error).

### Cấu hình liên quan

- `infra/istio/virtual-service-retry.yaml`

| Service | Attempts | Per-try Timeout | Retry On |
|---|---|---|---|
| `tax` | 3 | 2s | `5xx` |
| `order` | 3 | 3s | `5xx` |
| `cart` | 3 | 2s | `5xx` |
| `product` | 3 | 2s | `5xx` |

### Cách kiểm tra

**Test 1: Xem VirtualService đã apply:**
```bash
kubectl get virtualservice -n yas
# Expected: tax-retry, order-retry, cart-retry, product-retry
kubectl describe virtualservice tax-retry -n yas
# Expected: retries.attempts=3, perTryTimeout=2s, retryOn=5xx
```

**Test 2: Mô phỏng 5xx bằng cách scale down tạm thời (fault injection):**
```bash
# Inject fault cho tax service — 50% requests trả 500
cat <<EOF | kubectl apply -f -
apiVersion: networking.istio.io/v1alpha3
kind: VirtualService
metadata:
  name: tax-fault-test
  namespace: yas
spec:
  hosts:
  - tax
  http:
  - fault:
      abort:
        percentage:
          value: 50
        httpStatus: 500
    route:
    - destination:
        host: tax
    retries:
      attempts: 3
      perTryTimeout: 2s
      retryOn: 5xx
EOF

# Gọi endpoint qua BFF và quan sát — với retry, caller nhận 200 thay vì 500
curl http://api.yas.local.com/api/tax/...
# Expected: 200 OK (Istio đã retry thành công)
```

**Test 3: Xem metrics retry trong Prometheus:**
```bash
curl -s "http://prometheus.yas.local.com/api/v1/query?query=envoy_cluster_upstream_rq_retry_total%7Bcluster_name%3D~%22.*tax.*%22%7D" \
  | python3 -m json.tool
# Expected: retry counter tăng khi có fault injection
```

**Dọn dẹp sau khi test:**
```bash
kubectl delete virtualservice tax-fault-test -n yas
# Restore VirtualService gốc
kubectl apply -f infra/istio/virtual-service-retry.yaml
```

### Kết quả mong đợi

| Scenario | Without Retry | With Retry (3 attempts) |
|---|---|---|
| tax 50% fail | ~50% request trả 500 | ~12.5% trả 500 (0.5^3) |
| tax 100% fail | 100% trả 500 | 100% trả 500 (retry không giúp được) |
| tax < 100% fail (transient) | Fail thoáng qua | Transparent recovery |

---

## Kịch bản 5: Traffic Generator — Kiểm tra toàn bộ endpoint

### Mục tiêu

Chạy traffic generator liên tục để xác nhận toàn bộ 18 endpoint (17 OK + 1 auth-redirect) hoạt động ổn định qua service mesh.

### Cách chạy

```bash
cd /home/npt102/DEVOPS-PRJ2/yas-2
YAS_DOMAIN=yas.local.com YAS_INTERVAL_MS=1500 node infra/scripts/generate-traffic.js
```

### Giải thích output

```
[10:00:00 PM] Round 100 — 17 OK, 1 redirect/auth-redirect, 0 auth-blocked, 0 fail
```

| Trường | Ý nghĩa |
|---|---|
| `17 OK` | 17 endpoint public/API trả `2xx` |
| `1 redirect/auth-redirect` | 1 endpoint (thường `/storefront` UI) redirect sang Keycloak login — đây là **expected** |
| `0 auth-blocked` | Không có endpoint nào bị AuthorizationPolicy chặn (403) |
| `0 fail` | Không có endpoint nào trả `5xx` hoặc timeout |

### Kết quả đạt được

Sau **1142+ rounds** liên tục:
- `0 fail` — Không có service nào down
- `0 auth-blocked` — AuthorizationPolicy cấu hình đúng, không chặn traffic hợp lệ
- `17 OK` stable — Tất cả service đáp ứng request
- `1 redirect` — Keycloak auth redirect hoạt động đúng

---

## Kịch bản 6: Kiali — Service Graph và mTLS Visualization

### Mục tiêu

Xác nhận Kiali hiển thị đúng service graph với mTLS lock icons và không có validation error.

### Truy cập Kiali

```
http://kiali.yas.local.com
```

### Các điểm kiểm tra

**1. Service Graph:**
- Vào **Graph → Namespace: yas**
- Bật **Security** layer → Các edge phải hiển thị **mTLS lock icon**
- Không có edge màu đỏ (connection error)

**2. Istio Config Validation:**
- Vào **Istio Config → Namespace: yas**
- Tất cả resource phải có status `✓ Valid` (không có `✗ Invalid` hoặc `⚠ Warning`)
- Lưu ý: Wildcard host trong DestinationRule gây lỗi validation — đã fix bằng cách tạo riêng từng DR cho từng service

**3. Workload Health:**
- Vào **Workloads → Namespace: yas**
- Tất cả workload phải ở trạng thái `Healthy` (biểu tượng xanh)
- Pods phải có đúng số sidecar (`2/2`)

**4. Application metrics trong Kiali:**
- Vào từng service (vd: `product`) → **Inbound Metrics**
- Verify: Request Rate, Error Rate (phải = 0%), Response Time

### Kết quả mong đợi

| Mục | Expected |
|---|---|
| mTLS lock icons | Hiển thị trên tất cả edge trong namespace yas |
| Istio Config validation | Tất cả `Valid` |
| Workload health | Tất cả `Healthy` |
| Error rate | 0% (dựa trên traffic generator) |

---

## Tóm tắt kết quả kiểm thử

| Kịch bản | Kết quả |
|---|---|
| mTLS STRICT — plain-text bị chặn | PASS |
| AuthorizationPolicy deny-all | PASS |
| Allow rules cho BFF → backends | PASS |
| Allow rules cho order → cart/tax/inventory/customer | PASS |
| DestinationRule exportTo ingress-nginx | PASS |
| VirtualService Retry 5xx | PASS (cấu hình sẵn sàng) |
| Traffic generator 1000+ rounds 0 fail | PASS |
| Kiali mTLS visualization | PASS |

---

## Lệnh kiểm tra nhanh

```bash
# Tổng quan mesh config
kubectl get peerauthentication,destinationrule,authorizationpolicy,virtualservice -n yas

# Istio validation
istioctl analyze -n yas

# Proxy config của một service cụ thể
istioctl proxy-config listener -n yas deploy/product
istioctl proxy-config cluster -n yas deploy/product

# Check mTLS connections
istioctl authn tls-check -n yas product.yas.svc.cluster.local

# Envoy access log (xem request đến service)
kubectl logs -n yas deploy/cart -c istio-proxy --tail=50 | grep -v "kube-probe\|health"
```
