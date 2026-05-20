# YAS Service Mesh — Test Scenarios

Kiểm thử Service Mesh (Istio) trên cụm YAS: mTLS, AuthorizationPolicy, DestinationRule, Retry.
Demo flow 10 phút: Pre-check → KC1 mTLS → KC2 AuthZ → KC3 DestinationRule → KC4 Fault Injection → KC5 Kiali.

---

## Kiến trúc

```
Internet → ingress-nginx (sidecar) ──mTLS ISTIO_MUTUAL──▶ yas namespace
                                                           ├─ backoffice-bff / storefront-bff
                                                           └─ product / cart / order / customer / inventory / tax / media / search
                                                                │
                                                                ▼ (out-of-mesh: Kafka, PostgreSQL, Redis, Elasticsearch)
```

---

## Pre-check (30 giây)

Liệt kê tất cả pod trong namespace `yas` và trạng thái của chúng. Mỗi pod phải có đúng `2/2` container ready — container thứ nhất là app, container thứ hai là `istio-proxy` (Envoy sidecar). Nếu bất kỳ pod nào chỉ có `1/2`, sidecar chưa inject và mTLS sẽ không hoạt động đúng.

```bash
kubectl get pods -n yas
```

Xác nhận tất cả Istio resource đã được apply. Expected:
- `peerauthentication/default-mtls` — STRICT (toàn bộ traffic trong yas phải dùng mTLS)
- 14 `destinationrule` — mỗi service một DR, cấu hình ISTIO_MUTUAL TLS
- `authorizationpolicy/deny-all` + 7 allow rules
- 4 `virtualservice` — cart, order, product, tax — mỗi VS cấu hình retry 3 lần cho lỗi 5xx

```bash
kubectl get peerauthentication,destinationrule,authorizationpolicy,virtualservice -n yas
```

---

## KC1: mTLS STRICT (~2 phút)

**Mục tiêu:** Chứng minh `PeerAuthentication STRICT` chặn plain-text HTTP, chỉ cho phép traffic có mTLS certificate (tức là phải có sidecar).
**Files liên quan:** `infra/istio/peer-authentication.yaml`, `infra/istio/destination-rule.yaml`

**Test 1 — FAIL expected:** Tạo pod trong namespace `default` — namespace này không bật Istio injection nên pod không có sidecar. Khi pod này gọi vào `product.yas.svc.cluster.local`, Envoy sidecar của product nhận connection nhưng bắt buộc phải có mTLS handshake (STRICT mode). Pod không sidecar không thể cung cấp certificate → connection bị reset ngay lập tức → `curl` trả về HTTP code `000` (tức là không nhận được response nào).

```bash
kubectl run test-no-sidecar --image=curlimages/curl:8.5.0 -n default --restart=Never -- sleep 60
kubectl wait --for=condition=Ready pod/test-no-sidecar -n default --timeout=30s
kubectl exec -n default test-no-sidecar -- \
  curl -s -o /dev/null -w "%{http_code}\n" --max-time 5 \
  "http://product.yas.svc.cluster.local/product/storefront/products?pageNo=0&pageSize=2"
kubectl delete pod test-no-sidecar -n default
```

Expected: `000` (connection reset — không có mTLS cert)

**Test 2 — PASS expected:** `storefront-bff` có sidecar, sidecar tự động inject mTLS certificate khi gọi sang `product`. Dùng `wget` thay vì `curl` vì Spring Boot image không cài curl; `wget -qS` in headers ra stderr nên dùng `2>&1 | grep HTTP/` để lấy status line.

```bash
kubectl exec -n yas deploy/storefront-bff -c storefront-bff -- \
  wget -qS -O/dev/null --timeout=5 \
  "http://product.yas.svc.cluster.local/product/storefront/products?pageNo=0&pageSize=2" 2>&1 | grep "HTTP/"
```

Expected: `HTTP/1.1 200 OK`

| Test | Expected |
|---|---|
| Pod không sidecar → product | `000` connection reset |
| storefront-bff → product | `HTTP/1.1 200 OK` |

---

## KC2: AuthorizationPolicy — Deny-all + Allow rules (~2 phút)

**Mục tiêu:** Chứng minh layer thứ hai của bảo mật: dù có sidecar và mTLS, pod vẫn bị block nếu ServiceAccount của nó không có trong allow list.
**File:** `infra/istio/authorization-policy.yaml`

`deny-all` là baseline — mặc định chặn toàn bộ traffic vào namespace `yas`. Các allow rules sau đó mở ra chính xác từng nguồn:

| Policy | Source | Destination |
|---|---|---|
| `deny-all` | — | Toàn bộ namespace `yas` |
| `allow-ingress-to-yas` | ingress-nginx SA | Toàn bộ namespace `yas` |
| `allow-bff-to-backends` | backoffice-bff, storefront-bff SA | Toàn bộ namespace `yas` |
| `allow-order-dependencies` | order SA | cart, tax, inventory, customer |
| `allow-search-to-product` | search SA | product |

**Test 1 — FAIL expected:** Tạo pod trong namespace `yas` với image `curlimages/curl`. Pod này được tạo với `default` ServiceAccount — SA này không có trong bất kỳ allow rule nào. Istio kiểm tra SA của caller qua mTLS SPIFFE certificate → `deny-all` bắt → 403 RBAC denied.

```bash
kubectl run curl-test-rbac --image=curlimages/curl:8.5.0 -n yas --restart=Never -- sleep 120
kubectl wait --for=condition=Ready pod/curl-test-rbac -n yas --timeout=30s
kubectl exec -n yas curl-test-rbac -- \
  curl -s -o /dev/null -w "%{http_code}\n" --max-time 5 \
  "http://product.yas.svc.cluster.local/product/storefront/products?pageNo=0&pageSize=2"
kubectl delete pod curl-test-rbac -n yas
```

Expected: `403`

**Test 2 — PASS expected:** Gọi qua ingress-nginx với domain `api.yas.local.com`. ingress-nginx có sidecar và ServiceAccount `ingress-nginx`, được whitelist bởi `allow-ingress-to-yas`. Curl gọi từ máy host (không trong mesh) → ingress-nginx xử lý → ingress-nginx's sidecar attach mTLS cert có SA `ingress-nginx` → product cho phép.

```bash
curl -s -o /dev/null -w "%{http_code}\n" \
  "http://api.yas.local.com/product/storefront/products?pageNo=0&pageSize=5"
```

Expected: `200`

**Test 3 — PASS expected:** `storefront-bff` dùng SA `storefront-bff` được whitelist bởi `allow-bff-to-backends`. Đây là luồng in-mesh bình thường của ứng dụng.

```bash
kubectl exec -n yas deploy/storefront-bff -c storefront-bff -- \
  wget -qS -O/dev/null --timeout=5 \
  "http://product.yas.svc.cluster.local/product/storefront/products?pageNo=0&pageSize=2" 2>&1 | grep "HTTP/"
```

Expected: `HTTP/1.1 200 OK`

---

## KC3: DestinationRule exportTo ingress-nginx (~1 phút)

**Mục tiêu:** Xác nhận `exportTo: [".", "ingress-nginx"]` hoạt động — ingress-nginx nhận được DR và biết phải dùng ISTIO_MUTUAL TLS khi gọi vào yas services.
**File:** `infra/istio/destination-rule.yaml`

`istioctl proxy-config cluster` dump toàn bộ Envoy cluster config của ingress-nginx controller. Cột cuối (cluster name) phải có dạng `mtls-<service>.yas` — đây là DR name, chứng tỏ ingress-nginx's Envoy đã nhận DR và sẽ dùng ISTIO_MUTUAL TLS. Nếu không có DR, cột cuối sẽ là `PassthroughCluster` hoặc rỗng, và mTLS sẽ fail. `istioctl` phải có trong `$PATH` — đã thêm vào `~/.bashrc`: `export PATH="/home/npt102/gcp/Devops2/yas/istio-1.24.3/bin:$PATH"`.

```bash
istioctl proxy-config cluster -n ingress-nginx deploy/ingress-nginx-controller | grep -E "\.yas\." | head -10
```

Expected: mỗi dòng kết thúc bằng `mtls-<service>.yas` — xác nhận DR đã export thành công tới ingress-nginx.

Chạy traffic generator gọi 17 endpoint liên tục để xác nhận toàn bộ hệ thống ổn định qua mesh. Script fetch JWT token từ Keycloak và test cả API cần auth lẫn public endpoint.

```bash
YAS_DOMAIN=yas.local.com node infra/scripts/generate-traffic.js
```

Expected: `16 OK, 1 redirect/auth-redirect, 0 auth-blocked, 0 fail` — 1 redirect là backoffice-ui redirect sang Keycloak login (bình thường).

---

## KC4: Fault Injection + VirtualService (~2 phút)

**Mục tiêu:** Chứng minh Istio có thể inject lỗi có kiểm soát vào traffic (chaos engineering). Đây là công cụ để test resilience của hệ thống khi có service failure. VirtualService `tax-retry` cũng có retry config cho REAL upstream failures (pod crash, rolling restart).
**File:** `infra/istio/virtual-service-retry.yaml`

> **Lưu ý kỹ thuật:** Fault injection (abort) và retry config trong cùng một VirtualService route — theo Istio design, fault-injected abort KHÔNG trigger retry vì abort là local Envoy response, không phải upstream error. Retry chỉ kích hoạt khi upstream thực sự trả về 5xx hoặc connection fail.

Bước 1 — Xem retry config hiện tại của tax trước khi inject fault:

```bash
kubectl get vs tax-retry -n yas -o yaml
```

Bước 2 — Lấy JWT token để gọi API backoffice (yêu cầu auth):

```bash
TOKEN=$(curl -s -X POST "http://identity.yas.local.com/realms/Yas/protocol/openid-connect/token" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d "grant_type=password&client_id=storefront-bff&client_secret=ZrU9I0q2uXBglBnmvyJdkl1lf0ncr8tn&username=admin&password=admin&scope=openid" \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['access_token'])")
```

Bước 3 — Gọi 10 lần khi KHÔNG có fault để xác nhận baseline (tất cả phải 200):

```bash
for i in $(seq 1 10); do
  curl -s -o /dev/null -w "%{http_code} " --max-time 8 \
    -H "Authorization: Bearer $TOKEN" \
    "http://api.yas.local.com/tax/backoffice/tax-classes"
done; echo
```

Expected baseline: `200 200 200 200 200 200 200 200 200 200`

Bước 4 — Inject 30% abort fault vào tax (giữ nguyên retry config), gọi lại 10 lần:

```bash
kubectl apply -f - <<'EOF'
apiVersion: networking.istio.io/v1beta1
kind: VirtualService
metadata:
  name: tax-retry
  namespace: yas
spec:
  hosts: [tax]
  http:
  - fault:
      abort:
        percentage: {value: 30}
        httpStatus: 500
    retries:
      attempts: 3
      perTryTimeout: 2s
      retryOn: 5xx
    route:
    - destination: {host: tax}
EOF
```

```bash
for i in $(seq 1 10); do
  curl -s -o /dev/null -w "%{http_code} " --max-time 8 \
    -H "Authorization: Bearer $TOKEN" \
    "http://api.yas.local.com/tax/backoffice/tax-classes"
done; echo
```

Expected với fault 30%: khoảng `~3/10 lần trả về 500` — xác nhận fault injection hoạt động đúng. Retry config vẫn có trong VS để handle REAL upstream failures (khi pod crash hoặc rolling restart, Envoy sẽ retry upstream 500 thật).

Bước 5 — Restore VirtualService gốc:

```bash
kubectl apply -f infra/istio/virtual-service-retry.yaml
```

| Cấu hình | Expected |
|---|---|
| Không fault (baseline) | 10/10 = 200 |
| Fault 30% abort | ~3/10 = 500, ~7/10 = 200 |
| Fault 80% abort | ~8/10 = 500 (chaos test) |

---

## KC5: Kiali Visualization (~1 phút)

**Mục tiêu:** Xác nhận dashboard Kiali hiển thị đúng trạng thái mesh: lock icon cho mTLS, không có validation error, traffic flow.
**URL:** `http://kiali.yas.local.com`

| Mục kiểm tra | Điều hướng | Expected |
|---|---|---|
| mTLS lock icons | Graph → Namespace: yas → bật Security layer | Lock icon trên tất cả edge |
| Không có validation error | Istio Config → Namespace: yas | Tất cả `✓ Valid` |
| Workload healthy | Workloads → Namespace: yas | Tất cả `Healthy`, pods `2/2` |
| Error rate = 0% | Services → product → Inbound Metrics | Error Rate: 0% |

---

## Tóm tắt kết quả (20/05/2026)

| Kịch bản | Lệnh kiểm tra | Kết quả |
|---|---|---|
| mTLS — pod không sidecar bị từ chối | curl từ default namespace | `000` connection reset — PASS ✓ |
| mTLS — BFF in-mesh được phép | wget từ storefront-bff | `200 OK` — PASS ✓ |
| AuthZ deny-all | curl từ pod không có SA whitelist | `403` RBAC denied — PASS ✓ |
| AuthZ allow rules | curl qua ingress, wget từ BFF | `200 OK` — PASS ✓ |
| DestinationRule exportTo ingress-nginx | istioctl proxy-config cluster | `mtls-*.yas` DR name — PASS ✓ |
| Traffic ổn định qua mesh | Traffic generator 17 endpoints | `16 OK, 0 fail` — PASS ✓ |
| Fault injection 30% abort | 10 calls với fault VS | `~3/10 = 500` confirmed — PASS ✓ |
| VirtualService retry config | kubectl get vs tax-retry -o yaml | retry 3 attempts, retryOn: 5xx — PASS ✓ |
| Kiali mTLS visualization | `http://kiali.yas.local.com` | Lock icons, 0 warnings — PASS ✓ |

---

## Lệnh hữu ích

Kiểm tra toàn bộ Istio config trong namespace `yas` — phát hiện misconfiguration, missing DR, conflicting VS:

```bash
istioctl analyze -n yas
```

Kiểm tra TLS mode thực tế đang dùng giữa client và server cho một service cụ thể — output gồm client mode (ISTIO_MUTUAL), server mode (STRICT), và DR name đang áp dụng:

```bash
istioctl authn tls-check -n yas product.yas.svc.cluster.local
```

Xem Envoy access log của cart sidecar, lọc bỏ liveness probe để chỉ còn traffic thật — hữu ích để debug khi một request không đến được service:

```bash
kubectl logs -n yas deploy/cart -c istio-proxy --tail=50 | grep -v "kube-probe\|health"
```
