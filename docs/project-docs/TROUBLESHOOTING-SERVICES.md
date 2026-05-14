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

## Vấn đề 3: Payment service — Liquibase checksum mismatch → CrashLoopBackOff

### Triệu chứng
- Pod `payment` liên tục restart, trạng thái `CrashLoopBackOff`
- Log payment:
  ```
  Caused by: liquibase.exception.ValidationFailedException: 
  Validation Failed:
    1 changesets check sum
    ...was: 9:abc123... but is now: 9:def456...
  ```

### Nguyên nhân
Khi build image mới (từ CI), file migration Liquibase có thể thay đổi checksum so với database đã tồn tại. Liquibase kiểm tra checksum của mỗi changeset đã apply — nếu source code thay đổi nội dung changeset mà database đã chạy version cũ → checksum mismatch → từ chối khởi động.

Thường xảy ra khi:
- Image `latest` bị thay đổi nội dung migration giữa các lần build
- Database PostgreSQL giữ lại state cũ (PersistentVolume) nhưng image mới có migration khác

### Cách sửa
Sử dụng image tag cố định (đã test hoạt động) thay vì `latest`:

```yaml
# k8s/charts/payment/values.yaml
backend:
  image:
    tag: "fixed"   # ← Dùng tag cố định, không dùng "latest"
```

Hoặc nếu muốn reset database (mất data):
```bash
# Xóa PVC của payment database
kubectl delete pvc data-postgres-payment-0 -n postgres
# Restart postgres pod
kubectl delete pod postgres-payment-0 -n postgres
# Restart payment service
kubectl rollout restart deploy/payment -n yas
```

### Kiểm tra sau khi sửa
```bash
kubectl get pods -n yas | grep payment
# payment-xxx   1/1   Running   0   ...
```

---

## Vấn đề 4: Payment-paypal — CrashLoopBackOff (image lỗi)

### Triệu chứng
- Pod `payment-paypal` liên tục crash, trạng thái `CrashLoopBackOff`
- Log payment-paypal:
  ```
  no main manifest attribute, in /app.jar
  ```

### Nguyên nhân
Image Docker của payment-paypal bị lỗi build — file JAR không có `Main-Class` trong `MANIFEST.MF`. Đây là lỗi từ upstream (repo gốc), không phải lỗi deploy.

### Cách sửa
Scale deployment về 0 replica (service này không ảnh hưởng đến chức năng chính):

```bash
kubectl scale deploy/payment-paypal -n yas --replicas=0
```

Hoặc trong Helm values:
```yaml
# k8s/charts/payment-paypal/values.yaml (hoặc umbrella values)
payment-paypal:
  backend:
    replicaCount: 0
```

> **Lưu ý:** Payment-paypal là provider phụ, hệ thống YAS vẫn hoạt động bình thường khi tắt service này.

---

## Vấn đề 5: Helm deploy thất bại — ServiceMonitor CRD not found

### Triệu chứng
- `helm upgrade --install` cho bất kỳ backend service nào đều thất bại
- Error message:
  ```
  Error: INSTALLATION FAILED: unable to build kubernetes objects from release manifest: 
  resource mapping not found for name: "xxx" namespace: "" 
  from "": no matches for kind "ServiceMonitor" in version "monitoring.coreos.com/v1"
  ensure CRDs are installed first
  ```

### Nguyên nhân
Helm chart backend có template `servicemonitoring.yaml` tạo resource `ServiceMonitor` (thuộc Prometheus Operator CRD). Nếu cluster **không cài Prometheus Operator** (hoặc đã gỡ observability stack), CRD `monitoring.coreos.com/v1` không tồn tại → Helm không thể render manifest.

### Cách sửa
Tắt ServiceMonitor trong values:

```yaml
# k8s/charts/backend/values.yaml
serviceMonitor:
  enabled: false    # ← Tắt khi không có Prometheus Operator
```

Nếu dùng umbrella chart (yas-dev, yas-staging), cần rebuild chart sau khi sửa:
```bash
cd k8s/charts/yas-dev
helm dependency update .
helm dependency build .
```

> **Lưu ý:** Nếu sau này cài lại Prometheus Operator, chỉ cần đổi `enabled: true` và redeploy.

---

## Vấn đề 6: BFF Ingress conflict — backoffice-bff và storefront-bff dùng chung host + path

### Triệu chứng
- Deploy cả `backoffice-bff` và `storefront-bff` với cùng domain (ví dụ `dev.yas.local.com`)
- Chỉ có 1 trong 2 service hoạt động, service còn lại trả 404 hoặc route sai
- `kubectl describe ingress -n dev` cho thấy 2 ingress cùng host và path `/`

### Nguyên nhân
Cả `backoffice-bff` và `storefront-bff` đều cần path `/` (vì chúng là gateway cho frontend). Khi 2 ingress resource cùng host + path, ingress-nginx chỉ route đến 1 backend (thường là cái tạo sau cùng), gây conflict.

### Cách sửa
Tách backoffice-bff ra subdomain riêng:

```bash
# Storefront-bff: giữ domain chính
helm upgrade --install storefront-bff ./storefront-bff \
  --namespace dev \
  --set backend.ingress.host="dev.yas.local.com"

# Backoffice-bff: dùng subdomain riêng
helm upgrade --install backoffice-bff ./backoffice-bff \
  --namespace dev \
  --set backend.ingress.host="backoffice.dev.yas.local.com"
```

Thêm domain mới vào `/etc/hosts`:
```bash
echo "192.168.49.2 backoffice.dev.yas.local.com" | sudo tee -a /etc/hosts
```

### Kiểm tra sau khi sửa
```bash
curl -s -o /dev/null -w "%{http_code}" http://dev.yas.local.com
# → 200 (storefront)

curl -s -o /dev/null -w "%{http_code}" http://backoffice.dev.yas.local.com
# → 302 (backoffice → login)
```

---

## Vấn đề 7: Elasticsearch 9.x — ECK không tương thích, phải deploy standalone

### Triệu chứng
- Deploy Elasticsearch 9.2.3 bằng ECK (Elastic Cloud on Kubernetes) operator 3.3.2
- Pod ES không khởi động được, hoặc bị lỗi:
  ```
  spec.version: Forbidden: 
  attempted to downgrade from [9.2.3] to unsupported version
  ```
  hoặc DNS race conditions khi init cluster.

### Nguyên nhân
ECK 3.3.2 chưa hỗ trợ đầy đủ Elasticsearch 9.x:
- Upgrade path validation bị reject
- DNS race conditions khi tạo cluster mới (node chưa kịp resolve nhau)
- Health check endpoint thay đổi giữa 8.x và 9.x

### Cách sửa
Bỏ ECK, deploy ES standalone bằng StatefulSet:

```bash
kubectl create namespace elasticsearch 2>/dev/null || true
kubectl apply -f k8s/deploy/elasticsearch/es-standalone.yaml
```

File `k8s/deploy/elasticsearch/es-standalone.yaml` gồm:
- **Service** `elasticsearch-es-http`: ClusterIP port 9200 (giữ tên cũ để tương thích)
- **StatefulSet** `elasticsearch-standalone`: Single-node ES 9.2.3
  - Init container fix permissions (`chown 1000:1000`)
  - `xpack.security.enabled=false` (local dev)
  - JVM heap: 512MB
  - PVC: 1Gi

### Kiểm tra sau khi sửa
```bash
kubectl get pods -n elasticsearch
# elasticsearch-standalone-0   1/1   Running   0   ...

# Test API
kubectl exec -n elasticsearch elasticsearch-standalone-0 -- \
  curl -s http://localhost:9200/_cluster/health | python3 -m json.tool
# → "status": "green"
```

> **Lưu ý:** Service name `elasticsearch-es-http` được giữ nguyên để các service khác (search, product) không cần đổi config kết nối.

---

## Vấn đề 8: Kafka broker — Permission denied trên Minikube

### Triệu chứng
- Pod Kafka broker không khởi động, trạng thái `CrashLoopBackOff`
- Log:
  ```
  java.io.IOException: Permission denied
  ```
  hoặc:
  ```
  ERROR: Unable to write to /var/lib/kafka/data-0/...
  ```

### Nguyên nhân
Minikube sử dụng `hostPath` provisioner — khi tạo PersistentVolume, thư mục trên host được tạo với quyền `755 root:root`. Kafka container chạy với `uid 1001 (gid 0)` → không có quyền ghi.

### Cách sửa
Chạy script fix permissions:

```bash
bash k8s/deploy/fix-kafka-permissions.sh
```

Script này:
1. Chờ PVC `data-0-kafka-cluster-dual-role-0` bound
2. Tạo pod tạm với quyền root, mount volume
3. Chạy `chown -R 1001:0 /var/lib/kafka/data-0`
4. Xóa pod tạm
5. Restart Kafka broker pod

### Kiểm tra sau khi sửa
```bash
kubectl get pods -n kafka | grep kafka-cluster
# kafka-cluster-dual-role-0   1/1   Running   0   ...
```

---

## Tổng kết: Các service bổ sung cần tạo trong K8s

Khi deploy YAS trên K8s (thay vì docker-compose), một số service name bị khác so với config hardcode trong Docker image:

| Vấn đề | Nguyên nhân | Giải pháp |
|---|---|---|
| `storefront-nextjs:3000` không resolve | Service tên là `storefront-ui` trong K8s | ExternalName Service |
| `nginx:80` không resolve | Không có service nginx | Deploy nginx reverse proxy (`k8s/deploy/nginx/nginx-proxy.yaml`) |
| Payment Liquibase checksum mismatch | Image mới + DB cũ | Dùng image tag cố định |
| Payment-paypal CrashLoopBackOff | Image lỗi (no main manifest) | Scale to 0 |
| ServiceMonitor CRD not found | Không cài Prometheus Operator | `serviceMonitor.enabled: false` |
| BFF ingress conflict | 2 BFF cùng host + path `/` | Tách backoffice-bff ra subdomain riêng |
| ES 9.x không tương thích ECK | ECK 3.3.2 chưa hỗ trợ ES 9.x | Deploy standalone StatefulSet |
| Kafka Permission denied | hostPath provisioner tạo volume root-owned | Chạy `fix-kafka-permissions.sh` |

> **Lưu ý:** Các fix này tạo bằng `kubectl apply` trực tiếp, không nằm trong Helm chart. Nếu redeploy toàn bộ bằng Helm, cần apply lại:
> ```bash
> kubectl apply -f k8s/deploy/nginx/nginx-proxy.yaml
> # ExternalName service storefront-nextjs (nếu chưa có trong nginx-proxy.yaml)
> ```
