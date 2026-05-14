# Hướng dẫn cài đặt và sử dụng ArgoCD cho YAS

> **Mục đích:** Sử dụng ArgoCD (GitOps) để quản lý deployment cho môi trường **dev** và **staging**.

---

## Tổng quan kiến trúc

```
┌──────────────────────────────────────────────────────────────┐
│                     GitHub Repository                        │
│  ┌─────────────┐    ┌──────────────────────────────────────┐ │
│  │ Source Code  │    │ k8s/charts/                          │ │
│  │ (Java, Next) │    │  ├── cart/values-dev.yaml            │ │
│  └──────┬──────┘    │  ├── cart/values-staging.yaml        │ │
│         │           │  ├── storefront-bff/values-dev.yaml  │ │
│         │           │  └── ...                             │ │
│         │           └──────────────┬───────────────────────┘ │
└─────────┼──────────────────────────┼─────────────────────────┘
          │                          │
          ▼                          ▼
┌─────────────────┐      ┌──────────────────────┐
│  GitHub Actions  │      │      ArgoCD          │
│  (CI Pipeline)   │      │  (CD - GitOps)       │
│                  │      │                      │
│  Build Image     │      │  Watch Git Repo      │
│  Push Docker Hub │      │  Auto-sync Helm      │
│  Update values   │      │  charts → K8S        │
└─────────────────┘      └──────────┬───────────┘
                                    │
                    ┌───────────────┼───────────────┐
                    ▼               ▼               ▼
              ┌──────────┐   ┌──────────┐   ┌──────────┐
              │ NS: dev  │   │NS: staging│   │ NS: yas  │
              │ (main)   │   │ (v1.0.0) │   │ (manual) │
              └──────────┘   └──────────┘   └──────────┘
```

**Luồng hoạt động:**
1. **CI (GitHub Actions):** Push code → build Docker image → push Docker Hub
2. **CD (ArgoCD):** Watch Git repo → phát hiện thay đổi trong `k8s/charts/` → tự động sync Helm charts vào namespace tương ứng

---

## 1. Cài đặt ArgoCD

### 1.1 Cài đặt trên Minikube

```bash
# Tạo namespace
kubectl create namespace argocd

# Cài đặt ArgoCD (dùng --server-side để tránh lỗi CRD 256KB annotation limit)
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml --server-side

# Chờ pods sẵn sàng
kubectl wait --for=condition=Ready pods --all -n argocd --timeout=180s
```

> **Lưu ý:** Phải dùng `--server-side` vì CRD của ArgoCD > 256KB, nếu dùng client-side apply sẽ bị lỗi annotation limit.

### 1.2 Truy cập ArgoCD UI

```bash
# Lấy password admin
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d && echo

# Port-forward (cổng 9090)
kubectl port-forward svc/argocd-server -n argocd 9090:443 &

# Mở trình duyệt: https://localhost:9090
# Username: admin
# Password: <password ở trên>
```

### 1.3 Kiểm tra pods

```bash
kubectl get pods -n argocd
# Expected: 7 pods Running
# argocd-application-controller-0
# argocd-applicationset-controller-xxx
# argocd-dex-server-xxx
# argocd-notifications-controller-xxx
# argocd-redis-xxx
# argocd-repo-server-xxx
# argocd-server-xxx
```

---

## 2. Cấu hình ArgoCD

### 2.1 Cấu trúc file ArgoCD

```
argocd/
  applications/
    yas-project.yaml       # AppProject - định nghĩa project scope
    dev-appset.yaml        # ApplicationSet cho dev (20 apps)
    staging-appset.yaml    # ApplicationSet cho staging (20 apps)
```

### 2.2 Apply cấu hình

```bash
# Apply Project
kubectl apply -f argocd/applications/yas-project.yaml

# Apply ApplicationSet cho Dev (tự tạo 20 Applications)
kubectl apply -f argocd/applications/dev-appset.yaml

# Apply ApplicationSet cho Staging (tự tạo 20 Applications)
kubectl apply -f argocd/applications/staging-appset.yaml

# Kiểm tra
kubectl get applications -n argocd --no-headers | wc -l
# Expected: 40 (20 dev + 20 staging)
```

### 2.3 Giải thích ApplicationSet

**ApplicationSet** sử dụng **List Generator** để tạo Application cho mỗi service:

```yaml
# Mỗi entry trong list tạo 1 ArgoCD Application
generators:
  - list:
      elements:
        - name: cart
          chart: cart
        - name: order
          chart: order
        # ... 20 services

# Template cho mỗi Application
template:
  spec:
    source:
      repoURL: https://github.com/NPT-102/yas-2.git
      targetRevision: main                    # Watch main branch
      path: 'k8s/charts/{{.chart}}'          # Helm chart path
      helm:
        valueFiles:
          - values.yaml                       # Default values
          - values-dev.yaml                   # Environment overlay
    destination:
      namespace: dev                          # Deploy namespace
    syncPolicy:
      automated:                              # Auto-sync enabled
        prune: true                           # Xóa resource không còn trong Git
        selfHeal: true                        # Tự sửa nếu bị thay đổi manual
```

---

## 3. Values Overlay cho từng Environment

### 3.1 Cấu trúc

Mỗi Helm chart có 3 file values:

```
k8s/charts/cart/
  values.yaml              # Giá trị mặc định (dùng cho yas namespace)
  values-dev.yaml          # Override cho dev
  values-staging.yaml      # Override cho staging
```

### 3.2 Ví dụ values-dev.yaml

```yaml
# Backend services
backend:
  image:
    tag: latest

# BFF services (có thêm ingress host)
backend:
  image:
    tag: latest
  ingress:
    host: dev.yas.local.com
```

### 3.3 Ví dụ values-staging.yaml

```yaml
# Image tag được cập nhật bởi CI khi tạo release
backend:
  image:
    tag: v1.0.0

# BFF services
backend:
  image:
    tag: v1.0.0
  ingress:
    host: staging.yas.local.com
```

---

## 4. Luồng CI/CD với ArgoCD

### 4.1 Dev Deploy (Push main → ArgoCD auto-sync)

```
Developer push code → main branch
    ↓
GitHub Actions CI: Build image → Push Docker Hub (tag: latest)
    ↓
Code thay đổi trên main branch
    ↓
ArgoCD phát hiện thay đổi (poll mỗi 3 phút mặc định)
    ↓
ArgoCD sync Helm charts → namespace dev
    ↓
Pods trong namespace dev được cập nhật
```

**Workflow:** `npt-dev-deploy.yml` trigger ArgoCD sync ngay lập tức (không chờ 3 phút).

### 4.2 Staging Deploy (Tag v* → Build → Update values → ArgoCD sync)

```
Developer tạo tag: git tag v1.0.0 && git push origin v1.0.0
    ↓
GitHub Actions: Build image (tag: v1.0.0) → Push Docker Hub
    ↓
CI cập nhật values-staging.yaml với tag mới → commit → push main
    ↓
ArgoCD phát hiện values-staging.yaml thay đổi
    ↓
ArgoCD sync Helm charts → namespace staging
    ↓
Pods trong namespace staging chạy image v1.0.0
```

---

## 5. Demo và kiểm tra

### 5.1 Kiểm tra ArgoCD Dashboard

```bash
# Port-forward
kubectl port-forward svc/argocd-server -n argocd 9090:443 &

# Mở browser: https://localhost:9090
# Login: admin / <password>
```

Trên Dashboard sẽ thấy:
- **40 Applications** (20 dev + 20 staging)
- Mỗi app hiển thị: Sync Status, Health Status
- Click vào 1 app → xem chi tiết resources (Deployment, Service, ConfigMap...)

### 5.2 Kiểm tra Applications

```bash
# Liệt kê tất cả
kubectl get applications -n argocd

# Xem chi tiết 1 app
kubectl describe application dev-cart -n argocd

# Xem status
kubectl get applications -n argocd -l environment=dev
kubectl get applications -n argocd -l environment=staging
```

### 5.3 Manual Sync (nếu cần)

```bash
# Cài ArgoCD CLI
curl -sSL -o /usr/local/bin/argocd https://github.com/argoproj/argo-cd/releases/latest/download/argocd-linux-amd64
chmod +x /usr/local/bin/argocd

# Login
ARGOCD_PASS=$(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d)
argocd login localhost:9090 --username admin --password "$ARGOCD_PASS" --insecure

# Sync 1 app
argocd app sync dev-cart

# Sync tất cả dev apps
argocd app list -l environment=dev -o name | xargs -I{} argocd app sync {}
```

---

## 6. So sánh trước và sau ArgoCD

| Aspect | Trước (Helm trực tiếp) | Sau (ArgoCD GitOps) |
|--------|----------------------|---------------------|
| Deployment | `helm upgrade --install` trong CI | ArgoCD auto-sync từ Git |
| Source of Truth | CI script + manual kubectl | Git repository |
| Rollback | `helm rollback` hoặc redeploy | ArgoCD revert Git commit |
| Visibility | kubectl commands | ArgoCD Dashboard (UI) |
| Drift Detection | Không có | ArgoCD tự phát hiện + self-heal |
| Multi-env | Mỗi workflow deploy riêng | ApplicationSet tự quản lý |

---

## 7. Troubleshooting

### Lỗi CRD 256KB
```bash
# Nếu gặp "metadata.annotations: Too long"
kubectl apply -n argocd -f <manifest> --server-side
```

### App status Unknown
```bash
# App Unknown = chưa kết nối được Git repo
# Kiểm tra repo đã push lên GitHub chưa
git push origin main

# Kiểm tra ArgoCD repo-server logs
kubectl logs -n argocd deploy/argocd-repo-server --tail=20
```

### App OutOfSync
```bash
# Bình thường nếu có thay đổi chưa sync
# Nếu auto-sync enabled, sẽ tự sync sau 3 phút
# Hoặc manual sync:
argocd app sync <app-name>
```

### Không đủ RAM
```bash
# ArgoCD cần ~1-2GB RAM
# Nếu thiếu RAM, có thể scale down ArgoCD:
kubectl scale deploy -n argocd argocd-dex-server --replicas=0
kubectl scale deploy -n argocd argocd-notifications-controller --replicas=0
```
