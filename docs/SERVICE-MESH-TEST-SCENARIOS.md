# YAS Service Mesh — Test Scenarios

Kiểm thử Service Mesh (Istio) trên cụm YAS: mTLS, AuthorizationPolicy, DestinationRule, Retry.
Demo flow 10 phút: Pre-check → KC1 mTLS → KC2 AuthZ → KC3 DestinationRule → KC4 Retry → KC5 Kiali.

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

```bash
# Xác nhận tất cả pod yas đang chạy 2/2
kubectl get pods -n yas

# Xác nhận các Istio resource đã apply
kubectl get peerauthentication,destinationrule,authorizationpolicy,virtualservice -n yas
# Expected:
#   peerauthentication: default-mtls (STRICT)
#   destinationrule:    mtls-product, mtls-cart, ... (14 DRs)
#   authorizationpolicy: deny-all + 7 allow rules
#   virtualservice:     product-retry, cart-retry, order-retry, tax-retry
```

---

## KC1: mTLS STRICT (~2 phút)

**Mục tiêu:** Chứng minh plain-text bị từ chối, in-mesh traffic được chấp nhận.

**Files:** `infra/istio/peer-authentication.yaml`, `infra/istio/destination-rule.yaml`

```bash
# [FAIL expected] Pod không có sidecar → bị STRICT mode từ chối
kubectl run test-no-sidecar --image=curlimages/curl:8.5.0 -n default --restart=Never -- sleep 60
kubectl wait --for=condition=Ready pod/test-no-sidecar -n default --timeout=30s
kubectl exec -n default test-no-sidecar -- \
  curl -s -o /dev/null -w "%{http_code}\n" --max-time 5 \
  "http://product.yas.svc.cluster.local/product/storefront/products?pageNo=0&pageSize=2"
# Expected: 000 (connection reset — không có mTLS cert)
kubectl delete pod test-no-sidecar -n default

# [PASS expected] BFF có sidecar → 200 OK
kubectl exec -n yas deploy/storefront-bff -c storefront-bff -- \
  wget -qS -O/dev/null --timeout=5 \
  "http://product.yas.svc.cluster.local/product/storefront/products?pageNo=0&pageSize=2" 2>&1 | grep "HTTP/"
# Expected: HTTP/1.1 200 OK
```

| Test | Expected |
|---|---|
| Pod không sidecar → product | `000` connection reset |
| storefront-bff → product | `200 OK` |

---

## KC2: AuthorizationPolicy — Deny-all + Allow rules (~2 phút)

**Mục tiêu:** Chứng minh deny-all chặn pod không được whitelist, còn BFF và order được phép.

**File:** `infra/istio/authorization-policy.yaml`

| Policy | Source | Destination |
|---|---|---|
| `deny-all` | — | Toàn bộ namespace `yas` |
| `allow-ingress-to-yas` | ingress-nginx SA | Toàn bộ namespace `yas` |
| `allow-bff-to-backends` | backoffice-bff, storefront-bff SA | Toàn bộ namespace `yas` |
| `allow-order-dependencies` | order SA | cart, tax, inventory, customer |
| `allow-search-to-product` | search SA | product |

```bash
# [FAIL expected] Pod yas không có SA trong whitelist → 403
kubectl run curl-test-rbac --image=curlimages/curl:8.5.0 -n yas --restart=Never -- sleep 120
kubectl wait --for=condition=Ready pod/curl-test-rbac -n yas --timeout=30s
kubectl exec -n yas curl-test-rbac -- \
  curl -s -o /dev/null -w "%{http_code}\n" --max-time 5 \
  "http://product.yas.svc.cluster.local/product/storefront/products?pageNo=0&pageSize=2"
# Expected: 403 RBAC denied
kubectl delete pod curl-test-rbac -n yas

# [PASS expected] Gọi qua ingress (SA ingress-nginx được whitelist) → 200
curl -s -o /dev/null -w "%{http_code}\n" \
  "http://api.yas.local.com/product/storefront/products?pageNo=0&pageSize=5"
# Expected: 200

# [PASS expected] storefront-bff → product (SA trong whitelist) → 200
kubectl exec -n yas deploy/storefront-bff -c storefront-bff -- \
  wget -qS -O/dev/null --timeout=5 \
  "http://product.yas.svc.cluster.local/product/storefront/products?pageNo=0&pageSize=2" 2>&1 | grep "HTTP/"
# Expected: HTTP/1.1 200 OK
```

---

## KC3: DestinationRule exportTo ingress-nginx (~1 phút)

**Mục tiêu:** Xác nhận DR được export đúng tới ingress-nginx và traffic ổn định qua mesh.

**File:** `infra/istio/destination-rule.yaml` — `exportTo: [".", "ingress-nginx"]`

```bash
# Xác nhận ingress-nginx nhận DR và biết TLS mode ISTIO_MUTUAL cho yas services
istioctl proxy-config cluster -n ingress-nginx deploy/ingress-nginx-controller | grep "yas\|product\|cart"
# Expected: các entry yas.svc với TLS mode ISTIO_MUTUAL

# Traffic generator — toàn bộ 17 endpoint ổn định
YAS_DOMAIN=yas.local.com node infra/scripts/generate-traffic.js
# Expected: 16 OK, 1 redirect (backoffice→Keycloak), 0 auth-blocked, 0 fail
```

---

## KC4: VirtualService Retry — 5xx (~2 phút)

**Mục tiêu:** Fault injection 30% abort → retry tự bù đắp, client nhận 200.

**File:** `infra/istio/virtual-service-retry.yaml` — 3 attempts, 2s per-try, retryOn: 5xx

```bash
# Lấy JWT token
TOKEN=$(curl -s -X POST "http://identity.yas.local.com/realms/Yas/protocol/openid-connect/token" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d "grant_type=password&client_id=storefront-bff&client_secret=ZrU9I0q2uXBglBnmvyJdkl1lf0ncr8tn&username=admin&password=admin&scope=openid" \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['access_token'])")

# Inject 30% fault vào tax (cùng giữ retry 3 lần)
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

# Gọi 10 lần — 30% fault + 3 retries → tất cả phải là 200
for i in $(seq 1 10); do
  curl -s -o /dev/null -w "%{http_code} " --max-time 8 \
    -H "Authorization: Bearer $TOKEN" \
    "http://api.yas.local.com/tax/backoffice/tax-classes"
done; echo
# Expected: 200 200 200 200 200 200 200 200 200 200

# Restore VirtualService gốc
kubectl apply -f infra/istio/virtual-service-retry.yaml
```

| Fault rate | Attempts | Xác suất fail còn lại | Expected |
|---|---|---|---|
| 30% | 3 | 0.3³ = 2.7% | Gần như toàn 200 |
| 80% | 3 | 0.8³ = 51.2% | Mix 200/500 |

---

## KC5: Kiali Visualization (~1 phút)

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
| DestinationRule exportTo ingress-nginx | Traffic generator | `16 OK, 0 fail` stable — PASS ✓ |
| Retry 30% fault + 3 attempts | 10 calls với 30% abort | Tất cả `200` — PASS ✓ |
| Retry 80% fault (over-threshold) | 10 calls với 80% abort | Mix 200/500 — PASS ✓ |
| Kiali mTLS visualization | `http://kiali.yas.local.com` | Lock icons, 0 warnings — PASS ✓ |

---

## Lệnh hữu ích

```bash
# Kiểm tra nhanh toàn bộ Istio config
istioctl analyze -n yas

# TLS check một service
istioctl authn tls-check -n yas product.yas.svc.cluster.local

# Envoy access log (bỏ liveness probe)
kubectl logs -n yas deploy/cart -c istio-proxy --tail=50 | grep -v "kube-probe\|health"
```
