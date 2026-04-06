# Troubleshooting - Các vấn đề khi truy cập dịch vụ YAS trên Minikube

## Vấn đề 1: Storefront trả về 500 Internal Server Error

### Triệu chứng
- Truy cập `http://storefront.yas.local.com` → Whitelabel Error Page, HTTP 500
- Log `storefront-bff`:
  ```
  java.net.UnknownHostException: Failed to resolve 'storefront-nextjs'
  Query failed with NXDOMAIN
  ```

### Nguyên nhân
File `storefront-bff/src/main/resources/application-prod.yaml` hardcode route:
```yaml
- id: nextjs
  uri: http://storefront-nextjs:3000
  predicates:
    - Path=/**
```
Nhưng trong K8s, service tên là `storefront-ui`, không phải `storefront-nextjs`.

### Cách sửa
Tạo ExternalName Service để alias `storefront-nextjs` → `storefront-ui`:
```bash
kubectl apply -f - <<EOF
apiVersion: v1
kind: Service
metadata:
  name: storefront-nextjs
  namespace: yas
spec:
  type: ExternalName
  externalName: storefront-ui.yas.svc.cluster.local
  ports:
    - port: 3000
EOF

kubectl rollout restart deploy/storefront-bff -n yas
```

---

## Vấn đề 2: Storefront load trang nhưng sau đó hiện "Application error: a client-side exception has occurred"

### Triệu chứng
- Trang chính (`/`) load bình thường ban đầu (HTML render OK)
- Sau vài giây, hiện lỗi: `Application error: a client-side exception has occurred (see the browser console for more information)`
- Browser console hiện nhiều lỗi:
  ```
  TypeError: m.map is not a function
  Uncaught (in promise) TypeError: e is not iterable
  Error: unknown
  ```
- Trang `/cart` bị lỗi ngay lập tức

### Nguyên nhân
File `storefront-bff/src/main/resources/application-prod.yaml` hardcode route:
```yaml
- id: api
  uri: http://nginx
  predicates:
    - Path=/api/**
```
Tất cả API calls (`/api/product/*`, `/api/cart/*`, `/api/customer/*`) được route qua hostname `nginx`, nhưng **không có service `nginx` trong namespace `yas`**.

Khi API trả về lỗi (502/503) thay vì JSON array, frontend Next.js cố gắng `.map()` trên response không phải array → `TypeError: m.map is not a function`.

Log `storefront-bff`:
```
java.net.UnknownHostException: Failed to resolve 'nginx' [A(1)]
*__checkpoint ⇢ HTTP GET "/api/product/storefront/categories" [ExceptionHandlingWebHandler]
*__checkpoint ⇢ HTTP GET "/api/cart/storefront/cart/items" [ExceptionHandlingWebHandler]
*__checkpoint ⇢ HTTP GET "/api/customer/storefront/customer/profile" [ExceptionHandlingWebHandler]
```

### Cách sửa
Deploy nginx reverse proxy trong namespace `yas`:
```bash
kubectl apply -f k8s/deploy/nginx/nginx-proxy.yaml
kubectl rollout restart deploy/storefront-bff -n yas
```

File `k8s/deploy/nginx/nginx-proxy.yaml` gồm:
- **ConfigMap** `nginx-proxy-config`: Cấu hình nginx route `/product/` → `http://product`, `/cart/` → `http://cart`, v.v.
- **Deployment** `nginx`: Chạy `nginx:1.27-alpine` với config trên
- **Service** `nginx`: ClusterIP service port 80

### Kiểm tra sau khi sửa
```bash
# Kiểm tra nginx pod running
kubectl get pods -n yas | grep nginx

# Test API qua storefront-bff
curl -s -o /dev/null -w "%{http_code}\n" -m 10 \
  -H "Host: storefront.yas.local.com" \
  http://192.168.49.2:30557/api/product/storefront/categories
# Expect: 200

# Test trang chính
curl -s -o /dev/null -w "%{http_code}\n" -m 10 \
  -H "Host: storefront.yas.local.com" \
  http://192.168.49.2:30557/
# Expect: 200
```

---

## Tổng kết: Các service bổ sung cần tạo trong K8s

Khi deploy YAS trên K8s (thay vì docker-compose), một số service name bị khác so với config hardcode trong Docker image:

| Config hardcode | Service thực tế trong K8s | Giải pháp |
|---|---|---|
| `storefront-nextjs:3000` | `storefront-ui:3000` | ExternalName Service |
| `nginx:80` | Không có | Deploy nginx reverse proxy (`k8s/deploy/nginx/nginx-proxy.yaml`) |

> **Lưu ý:** Các fix này tạo bằng `kubectl apply` trực tiếp, không nằm trong Helm chart. Nếu redeploy toàn bộ bằng Helm, cần apply lại:
> ```bash
> kubectl apply -f k8s/deploy/nginx/nginx-proxy.yaml
> # ExternalName service storefront-nextjs (nếu chưa có trong nginx-proxy.yaml)
> ```
