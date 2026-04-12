# Việc cần làm tiếp theo — Đồ án 2

> **Trạng thái hiện tại:** Đã hoàn tất cài đặt toàn bộ hệ thống (cluster, infrastructure, CI/CD workflows, Istio).  
> **File này:** Liệt kê các việc cần làm để hoàn thiện đồ án và chuẩn bị bảo vệ.

---

## Tổng quan yêu cầu đồ án

| # | Yêu cầu | Trạng thái | Ghi chú |
|---|---------|-----------|---------|
| 2 | K8S cluster (1 master + 1 worker) | ✅ Xong | Minikube 2 nodes |
| 3 | CI: Push branch → build image tag=commit_id → push Docker Hub | ✅ Workflow có | Cần demo |
| 4 | CD Developer Build: Chọn service + branch → deploy K8S | ✅ Workflow có | Cần demo |
| 5 | Cleanup: Xóa developer deployment | ✅ Workflow có | Cần demo |
| 6a | Dev deploy: Push main → auto deploy namespace dev | ✅ Workflow có | Cần demo |
| 6b | Staging deploy: Tag v* → build + deploy namespace staging | ✅ Workflow có | Cần demo |
| NC | Istio Service Mesh (mTLS, AuthZ, Retry) | ✅ Đã cài | Cần test + screenshot |

---

## A. Việc cần làm NGAY (demo pipeline)

### A1. Test CI Pipeline (Yêu cầu 3)

**Mục đích:** Chứng minh CI hoạt động — push code → tự build image → push Docker Hub.

```bash
# Đang ở branch dev_tax_service
# Sửa 1 file nhỏ trong service bất kỳ (ví dụ: cart)
echo "// trigger CI $(date +%s)" >> cart/src/main/java/com/yas/cart/CartApplication.java

git add cart/
git commit -m "test: trigger CI for cart service"
git push origin dev_tax_service
```

**Kiểm tra:**
1. Vào GitHub → Actions → "CI Build and Push" → xem workflow run
2. Chờ xong → vào Docker Hub kiểm tra image `<DOCKER_USER>/cart:<commit_id>` đã được push
3. **Chụp screenshot:** workflow run thành công + Docker Hub có image mới

---

### A2. Test Developer Build (Yêu cầu 4)

**Mục đích:** Chứng minh developer có thể deploy 1 branch riêng lên K8S.

1. Vào GitHub → Actions → **developer_build** → **Run workflow**
2. Chọn:
   - `service_name`: `cart`
   - `branch_name`: `dev_tax_service`
3. Click **Run workflow**
4. Chờ workflow xong

**Kiểm tra:**
```bash
# Kiểm tra namespace developer đã được tạo
kubectl get pods -n developer

# Kiểm tra service cart đang chạy image từ branch
kubectl describe pod -n developer -l app=cart | grep Image
```

5. **Chụp screenshot:** workflow run + pods running trong namespace developer

---

### A3. Test Cleanup (Yêu cầu 5)

**Mục đích:** Chứng minh có thể xóa developer deployment.

1. Vào GitHub → Actions → **cleanup_developer_build** → **Run workflow**
2. Nhập `yes` vào ô confirm
3. Click **Run workflow**

**Kiểm tra:**
```bash
kubectl get ns developer
# Expected: namespace "developer" not found
```

4. **Chụp screenshot:** workflow run + namespace đã bị xóa

---

### A4. Test Dev Deploy (Yêu cầu 6a)

**Mục đích:** Chứng minh push vào main → tự động deploy namespace dev.

```bash
# Merge dev_tax_service vào main
git checkout main
git merge dev_tax_service
git push origin main
```

**Kiểm tra:**
1. Vào GitHub → Actions → "Deploy to Dev" → xem workflow tự chạy
2. Chờ xong:
```bash
kubectl get pods -n dev
kubectl get ingress -n dev
```
3. Thêm vào `/etc/hosts` (nếu chưa có):
```
<MINIKUBE_IP> dev.yas.local.com api.dev.yas.local.com
```
4. Truy cập: `http://dev.yas.local.com`
5. **Chụp screenshot:** workflow run + pods running + trang web

---

### A5. Test Staging Deploy (Yêu cầu 6b)

**Mục đích:** Chứng minh tạo tag → build image + deploy staging.

```bash
git checkout main
git tag v1.0.0
git push origin v1.0.0
```

**Kiểm tra:**
1. Vào GitHub → Actions → "Deploy to Staging" → xem workflow tự chạy
2. Chờ xong:
```bash
kubectl get pods -n staging
```
3. Docker Hub: kiểm tra image `<DOCKER_USER>/<service>:v1.0.0`
4. Thêm vào `/etc/hosts` (nếu chưa có):
```
<MINIKUBE_IP> staging.yas.local.com api.staging.yas.local.com
```
5. **Chụp screenshot:** workflow run + pods running + Docker Hub images

---

## B. Việc cần làm cho Istio (Nâng cao)

### B1. Chụp screenshot mTLS

```bash
# Xác nhận mTLS STRICT đang bật
kubectl get peerauthentication -n yas

# Describe 1 pod để thấy mTLS status
istio-1.24.3/bin/istioctl x describe pod $(kubectl get pod -n yas -l app=tax -o jsonpath='{.items[0].metadata.name}') -n yas
```

**Chụp screenshot:** output cho thấy mTLS STRICT enabled.

### B2. Test Authorization Policy

```bash
# Test ALLOW: order → tax (phải thành công)
kubectl exec -n yas deploy/order -c order -- curl -s -o /dev/null -w "%{http_code}" http://tax.yas.svc.cluster.local/tax/actuator/health
# Expected: 200

# Test DENY: search → tax (phải bị chặn)
kubectl exec -n yas deploy/search -c search -- curl -s -o /dev/null -w "%{http_code}" http://tax.yas.svc.cluster.local/tax/actuator/health
# Expected: 403 (RBAC: access denied)
```

**Chụp screenshot:** 1 lệnh trả 200, 1 lệnh trả 403.

### B3. Test Retry Policy

```bash
# Xem VirtualService retry config
kubectl get virtualservice -n yas -o yaml | grep -A5 retries

# Hoặc dùng istioctl
istio-1.24.3/bin/istioctl x describe svc tax -n yas
```

**Chụp screenshot:** output cho thấy retry 3 attempts cho 5xx.

### B4. Kiali Topology (nếu đã cài)

```bash
# Check Kiali đã cài chưa
kubectl get svc kiali -n istio-system

# Nếu chưa cài:
kubectl apply -f https://raw.githubusercontent.com/istio/istio/release-1.24/samples/addons/kiali.yaml

# Port forward
kubectl port-forward svc/kiali -n istio-system 20001:20001 &

# Mở browser: http://localhost:20001
# Graph → Namespace: yas → xem topology
```

**Chụp screenshot:** Kiali graph hiển thị service mesh topology.

---

## C. Screenshots cần chụp cho báo cáo

| # | Nội dung | File đề xuất |
|---|---------|-------------|
| 1 | `kubectl get nodes` — cluster 2 nodes Ready | `screenshots/cluster-nodes.png` |
| 2 | `kubectl get pods -A` — tất cả pods Running | `screenshots/all-pods.png` |
| 3 | CI workflow run thành công | `screenshots/ci-success.png` |
| 4 | Docker Hub — images đã push | `screenshots/dockerhub-images.png` |
| 5 | Developer Build workflow run | `screenshots/developer-build.png` |
| 6 | Developer namespace pods | `screenshots/developer-pods.png` |
| 7 | Cleanup workflow run | `screenshots/cleanup-success.png` |
| 8 | Dev Deploy workflow run | `screenshots/dev-deploy.png` |
| 9 | Dev namespace pods + web | `screenshots/dev-running.png` |
| 10 | Staging Deploy workflow run | `screenshots/staging-deploy.png` |
| 11 | Staging namespace pods + Docker Hub tag | `screenshots/staging-running.png` |
| 12 | Storefront web chạy OK | `screenshots/yas-storefront.png` ✅ có |
| 13 | Backoffice web chạy OK | `screenshots/yas-backoffice.png` ✅ có |
| 14 | Swagger UI | `screenshots/yas-swagger.png` ✅ có |
| 15 | Grafana metrics | `screenshots/yas-grafana-metrics.png` ✅ có |
| 16 | Grafana tracing | `screenshots/yas-grafana-tracing.png` ✅ có |
| 17 | Istio mTLS status | `screenshots/istio-mtls.png` |
| 18 | Istio AuthZ allow + deny | `screenshots/istio-authz.png` |
| 19 | Istio retry config | `screenshots/istio-retry.png` |
| 20 | Kiali topology graph | `screenshots/kiali-topology.png` |
| 21 | Self-hosted runner Idle/Active | `screenshots/runner-status.png` |

---

## D. Thứ tự thực hiện khuyến nghị

```
1. [10 phút] Commit code hiện tại → push lên GitHub
2. [15 phút] A1: Test CI pipeline → chụp screenshot
3. [15 phút] A2: Test Developer Build → chụp screenshot  
4. [ 5 phút] A3: Test Cleanup → chụp screenshot
5. [15 phút] A4: Test Dev Deploy (merge main + push) → chụp screenshot
6. [20 phút] A5: Test Staging Deploy (tag v1.0.0) → chụp screenshot
7. [15 phút] B1-B3: Test Istio (mTLS, AuthZ, Retry) → chụp screenshot
8. [10 phút] B4: Kiali topology → chụp screenshot
9. [30 phút] Viết/hoàn thiện báo cáo với screenshots
```

---

## E. Lưu ý quan trọng

### RAM & Resource
- Khi chạy dev/staging deploy, cluster sẽ thêm 20+ pods mới cho mỗi namespace
- Minikube 2 nodes × 12GB = 24GB tổng, có thể không đủ chạy đồng thời yas + dev + staging
- **Khuyến nghị:** Test từng namespace, xong cleanup trước khi test namespace tiếp

### Self-hosted Runner
- Runner phải đang chạy khi trigger workflow: `cd ~/actions-runner && ./run.sh`
- Kiểm tra: GitHub → Settings → Actions → Runners → trạng thái **Idle**

### Nếu cluster restart
- Xem file [KHOI-PHUC-CLUSTER.md](KHOI-PHUC-CLUSTER.md) để khôi phục
- Nhớ chạy lại: `sudo sysctl -w fs.inotify.max_user_instances=1024 && sudo sysctl -w fs.inotify.max_user_watches=65536`
- Nếu Keycloak crash (startup storm): scale yas về 0, chờ Keycloak Ready, rồi scale lại 1

### Git workflow
- Đang ở branch `dev_tax_service`
- Cần merge về `main` trước khi test Dev Deploy và Staging Deploy
- Workflow CI chạy trên mọi branch, Developer Build/Cleanup/Dev/Staging chạy trên self-hosted runner
