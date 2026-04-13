# Troubleshooting - Không truy cập được các URL *.yas.local.com

## Mục lục

- [Vấn đề 1: Tất cả URL timeout khi truy cập từ browser (port 80)](#vấn-đề-1-tất-cả-url-timeout-khi-truy-cập-từ-browser-port-80)
- [Vấn đề 2: Storefront / Backoffice / Swagger trả về 502 Bad Gateway](#vấn-đề-2-storefront--backoffice--swagger-trả-về-502-bad-gateway)
- [Tổng kết các bước khắc phục](#tổng-kết-các-bước-khắc-phục)

---

## Vấn đề 1: Tất cả URL timeout khi truy cập từ browser (port 80)

### Triệu chứng

Truy cập bất kỳ URL nào từ browser đều bị **timeout** (trang trắng, loading mãi):

- `http://storefront.yas.local.com` → Timeout
- `http://backoffice.yas.local.com` → Timeout
- `http://identity.yas.local.com` → Timeout
- `http://pgadmin.yas.local.com` → Timeout
- `http://grafana.yas.local.com` → Timeout
- `http://akhq.yas.local.com` → Timeout
- `http://api.yas.local.com/swagger-ui` → Timeout

Nhưng nếu curl qua NodePort thì một số URL trả về OK:
```bash
# NodePort 32280 (HTTP port của ingress-nginx)
curl -s -o /dev/null -w "%{http_code}" http://192.168.49.2:32280 -H "Host: identity.yas.local.com"
# → 302 (OK!)

curl -s -o /dev/null -w "%{http_code}" http://192.168.49.2:80 -H "Host: identity.yas.local.com"
# → Timeout!
```

### Nguyên nhân

Ingress NGINX controller trên Minikube được expose dạng **NodePort**, không phải **LoadBalancer** hay **HostPort**:

```bash
$ kubectl get svc -n ingress-nginx ingress-nginx-controller
NAME                       TYPE       CLUSTER-IP     PORT(S)
ingress-nginx-controller   NodePort   10.101.72.97   80:32280/TCP,443:30211/TCP
```

Browser truy cập `http://storefront.yas.local.com` sẽ kết nối đến IP `192.168.49.2` (từ `/etc/hosts`) trên **port 80** → nhưng port 80 trên node minikube **không có service nào listen** → timeout.

Chỉ port **32280** (NodePort) mới route được đến ingress controller.

### Cách khắc phục

Chạy `minikube tunnel` để tạo route network, cho phép truy cập qua port 80/443 trực tiếp:

```bash
# Chạy ở background
nohup minikube tunnel > /tmp/minikube-tunnel.log 2>&1 &

# Kiểm tra tunnel đang chạy
ps aux | grep "minikube tunnel" | grep -v grep

# Kiểm tra log
cat /tmp/minikube-tunnel.log
```

`minikube tunnel` tạo network route trên máy host, cho phép traffic đến ClusterIP/NodePort services qua Minikube IP trên port gốc (80, 443).

### Kiểm tra sau khi sửa

```bash
# Phải trả về HTTP code, KHÔNG timeout
curl -s -o /dev/null -w "%{http_code}" --connect-timeout 5 http://identity.yas.local.com
# → 302 ✅
```

> ⚠️ **Quan trọng:** `minikube tunnel` cần chạy **liên tục**. Nếu tắt terminal hoặc restart máy, phải chạy lại lệnh trên. Tunnel cũng có thể cần quyền `sudo` (sẽ hỏi password khi chạy).

---

## Vấn đề 2: Storefront / Backoffice / Swagger trả về 502 Bad Gateway

### Triệu chứng

Sau khi fix tunnel (Vấn đề 1), các URL ngoài namespace `yas` truy cập được bình thường:

| URL | Namespace | Kết quả |
|-----|-----------|---------|
| http://identity.yas.local.com | keycloak | **302** ✅ |
| http://pgadmin.yas.local.com | postgres | **302** ✅ |
| http://grafana.yas.local.com | observability | **302** ✅ |
| http://akhq.yas.local.com | kafka | **307** ✅ |

Nhưng các URL trong namespace `yas` trả **502 Bad Gateway**:

| URL | Namespace | Kết quả |
|-----|-----------|---------|
| http://storefront.yas.local.com | yas | **502** ❌ |
| http://backoffice.yas.local.com | yas | **502** ❌ |
| http://api.yas.local.com/swagger-ui | yas | **502** ❌ |

### Nguyên nhân

Sau khi bật **Istio Service Mesh** (bước nâng cao), namespace `yas` có 2 cấu hình bảo mật:

**1. PeerAuthentication `default-mtls` mode STRICT:**

```yaml
# File: istio/peer-authentication.yaml
apiVersion: security.istio.io/v1beta1
kind: PeerAuthentication
metadata:
  name: default-mtls
  namespace: yas
spec:
  mtls:
    mode: STRICT   # ← Bắt buộc mọi traffic phải dùng mTLS
```

Mode `STRICT` nghĩa là **chỉ chấp nhận traffic có mTLS certificate** (mutual TLS). Ingress NGINX controller nằm **ngoài Istio mesh** (không có sidecar proxy) → gửi plaintext HTTP → bị Istio sidecar trong pod YAS từ chối.

**2. AuthorizationPolicy `deny-all`:**

```yaml
# File: istio/authorization-policy.yaml
apiVersion: security.istio.io/v1beta1
kind: AuthorizationPolicy
metadata:
  name: deny-all
  namespace: yas
spec: {}   # ← Chặn TẤT CẢ traffic (không match rule nào = deny)
```

Các ALLOW policies hiện có chỉ cho phép traffic **giữa các service trong mesh** (dùng `principals` — service account identity từ mTLS). Ingress controller không có identity trong mesh → bị chặn.

```
Luồng traffic:

Browser → Minikube IP → Ingress NGINX → [pods trong namespace yas]
                         (ngoài mesh)      (trong mesh, có sidecar)
                              ↓
                    Gửi plaintext HTTP
                              ↓
                    ❌ PeerAuthentication STRICT → từ chối (không có mTLS)
                    ❌ deny-all AuthorizationPolicy → từ chối (không có principal)
                              ↓
                         502 Bad Gateway
```

### Cách khắc phục

Cần sửa 2 file:

**Bước 1: Đổi PeerAuthentication sang PERMISSIVE**

File `istio/peer-authentication.yaml`:
```yaml
# TRƯỚC (STRICT — chỉ chấp nhận mTLS):
spec:
  mtls:
    mode: STRICT

# SAU (PERMISSIVE — chấp nhận cả mTLS và plaintext):
spec:
  mtls:
    mode: PERMISSIVE
```

> **Giải thích PERMISSIVE:** Chấp nhận **cả hai** loại traffic:
> - Traffic từ service trong mesh → tự động dùng mTLS (vẫn mã hóa)
> - Traffic từ ngoài mesh (ingress) → chấp nhận plaintext HTTP
>
> Service-to-service trong mesh vẫn an toàn vì Istio sidecar tự động upgrade sang mTLS khi cả 2 bên đều có sidecar.

**Bước 2: Thêm AuthorizationPolicy cho phép ingress**

Thêm vào file `istio/authorization-policy.yaml`:
```yaml
---
# Cho phép Ingress Controller (ngoài mesh) truy cập vào YAS services
# Ingress NGINX không có sidecar → không có mTLS principal
# Dùng notPrincipals: ["*"] để match traffic từ source KHÔNG có identity
apiVersion: security.istio.io/v1beta1
kind: AuthorizationPolicy
metadata:
  name: allow-ingress-to-yas
  namespace: yas
spec:
  action: ALLOW
  rules:
  - from:
    - source:
        notPrincipals: ["*"]
```

> **Giải thích `notPrincipals: ["*"]`:**
> - Trong Istio, `principal` là identity của source (ví dụ: `cluster.local/ns/yas/sa/order`)
> - Service trong mesh có principal (từ mTLS certificate)
> - Ingress controller **ngoài mesh** → **không có principal**
> - `notPrincipals: ["*"]` match tất cả request mà source **KHÔNG có** bất kỳ principal nào → chính xác là traffic từ ngoài mesh

**Bước 3: Apply vào cluster**

```bash
kubectl apply -f istio/peer-authentication.yaml
kubectl apply -f istio/authorization-policy.yaml
```

Kết quả mong đợi:
```
peerauthentication.security.istio.io/default-mtls configured
authorizationpolicy.security.istio.io/deny-all unchanged
authorizationpolicy.security.istio.io/allow-ingress-to-yas created
authorizationpolicy.security.istio.io/allow-bff-to-backends unchanged
...
```

### Kiểm tra sau khi sửa

```bash
# Tất cả phải trả HTTP code (không timeout, không 502)
curl -s -o /dev/null -w "%{http_code}" --connect-timeout 5 http://storefront.yas.local.com
# → 200 ✅

curl -s -o /dev/null -w "%{http_code}" --connect-timeout 5 http://backoffice.yas.local.com
# → 302 ✅

curl -s -o /dev/null -w "%{http_code}" --connect-timeout 5 http://api.yas.local.com/swagger-ui
# → 301 ✅
```

### Tại sao các service ngoài namespace `yas` không bị ảnh hưởng?

Vì PeerAuthentication và AuthorizationPolicy được tạo **trong namespace `yas`** → chỉ áp dụng cho pods trong `yas`. Các namespace khác (keycloak, postgres, observability, kafka) **không có Istio policies** → ingress truy cập bình thường.

---

## Tổng kết các bước khắc phục

Thứ tự thực hiện khi gặp lỗi không truy cập được `*.yas.local.com`:

```
1. Kiểm tra /etc/hosts có đúng IP      → grep yas /etc/hosts
2. Kiểm tra ingress controller Running  → kubectl get pods -n ingress-nginx
3. Kiểm tra minikube tunnel đang chạy   → ps aux | grep "minikube tunnel"
   Nếu chưa chạy:                       → nohup minikube tunnel > /tmp/minikube-tunnel.log 2>&1 &
4. Kiểm tra Istio policies              → kubectl get authorizationpolicy -n yas
   Nếu có deny-all mà không có          → kubectl apply -f istio/authorization-policy.yaml
   allow-ingress-to-yas:                 → kubectl apply -f istio/peer-authentication.yaml
5. Kiểm tra pods Running                → kubectl get pods -n yas
6. Test bằng curl                        → curl -s -o /dev/null -w "%{http_code}" http://storefront.yas.local.com
```

### Files đã sửa

| File | Thay đổi | Lý do |
|------|----------|-------|
| `istio/peer-authentication.yaml` | `STRICT` → `PERMISSIVE` | Cho phép ingress (ngoài mesh) gửi plaintext HTTP |
| `istio/authorization-policy.yaml` | Thêm `allow-ingress-to-yas` policy | Cho phép traffic từ source không có mTLS identity |

### Kết quả cuối cùng

| URL | Kết quả | Mô tả |
|-----|---------|-------|
| http://storefront.yas.local.com | **200** ✅ | Trang storefront hiện sản phẩm |
| http://backoffice.yas.local.com | **302** ✅ | Redirect đến trang login |
| http://identity.yas.local.com | **302** ✅ | Redirect đến Keycloak admin (admin/admin) |
| http://pgadmin.yas.local.com | **302** ✅ | Redirect đến trang login pgAdmin |
| http://grafana.yas.local.com | **302** ✅ | Redirect đến trang login Grafana (admin/admin) |
| http://akhq.yas.local.com | **307** ✅ | Redirect đến AKHQ Kafka manager |
| http://api.yas.local.com/swagger-ui | **301** ✅ | Redirect đến Swagger API docs |
