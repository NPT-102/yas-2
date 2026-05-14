# Troubleshooting - Các vấn đề CI/CD (GitHub Actions)

## Vấn đề 1: Payment CI — "No test report files were found"

### Triệu chứng
- Workflow `payment-ci.yaml` chạy thất bại ở step publish test report
- Error:
  ```
  Error: No test report files were found
  ```

### Nguyên nhân
Action publish test report (`dorny/test-reporter`) cần quyền `checks: write` để tạo check run trên GitHub. Workflow mặc định chỉ có quyền `contents: read`, không đủ quyền để ghi test report.

### Cách sửa
Thêm `permissions` vào workflow file:

```yaml
# .github/workflows/payment-ci.yaml
permissions:
  contents: read
  checks: write
  pull-requests: write
```

---

## Vấn đề 2: Payment-paypal CI — "Resource not accessible by integration"

### Triệu chứng
- Workflow `payment-paypal-ci.yaml` chạy thất bại
- Error:
  ```
  HttpError: Resource not accessible by integration
  ```

### Nguyên nhân
Tương tự Vấn đề 1 — workflow thiếu quyền `checks: write` và `pull-requests: write`. GitHub Actions token mặc định không có quyền tạo check run hoặc comment trên PR.

### Cách sửa
Thêm `permissions` vào workflow file (giống Vấn đề 1):

```yaml
# .github/workflows/payment-paypal-ci.yaml
permissions:
  contents: read
  checks: write
  pull-requests: write
```

---

## Vấn đề 3: Release Charts — "origin/gh-pages not found"

### Triệu chứng
- Workflow `charts-ci.yaml` (dùng `helm/chart-releaser-action`) thất bại
- Error:
  ```
  fatal: couldn't find remote ref refs/heads/gh-pages
  ```
  hoặc:
  ```
  Error: origin/gh-pages not found
  ```

### Nguyên nhân
`chart-releaser-action` cần branch `gh-pages` để lưu trữ Helm chart index (`index.yaml`). Repo fork mới không có branch này.

### Cách sửa
Tạo branch `gh-pages` rỗng:

```bash
git checkout --orphan gh-pages
git rm -rf .
git commit --allow-empty -m "init gh-pages for chart releases"
git push origin gh-pages
git checkout main
```

Sau khi tạo xong, chạy lại workflow `charts-ci.yaml`.

---

## Vấn đề 4: Chart-releaser — "duplicate release error"

### Triệu chứng
- Workflow `charts-ci.yaml` thất bại khi chart version không thay đổi
- Error:
  ```
  Error: release already exists
  ```

### Nguyên nhân
`chart-releaser-action` tạo GitHub Release cho mỗi chart version. Nếu chart version trong `Chart.yaml` không tăng mà workflow chạy lại → release đã tồn tại → lỗi.

### Cách sửa
Thêm option `skip_existing: true`:

```yaml
# .github/workflows/charts-ci.yaml
- name: Run chart-releaser
  uses: helm/chart-releaser-action@v1.5.0
  with:
    charts_dir: k8s/charts
    skip_existing: true    # ← Bỏ qua chart đã release
  env:
    CR_TOKEN: "${{ secrets.GITHUB_TOKEN }}"
```

---

## Vấn đề 5: Staging deploy — Image tag không tồn tại trên Docker Hub

### Triệu chứng
- Deploy staging với tag `v1.0.0` → pods stuck ở `ImagePullBackOff`
- Error:
  ```
  Failed to pull image "npt102/yas-cart:v1.0.0": 
  rpc error: code = NotFound desc = failed to pull and unpack image: 
  manifest for npt102/yas-cart:v1.0.0 not found
  ```

### Nguyên nhân
Workflow staging deploy (`npt-staging-deploy.yml`) dùng image tag = version tag (ví dụ `v1.0.0`). Nếu workflow staging chưa build image với tag đó (hoặc CI thất bại), image không tồn tại trên Docker Hub.

### Cách sửa
**Cách 1:** Dùng tag `latest` (image được CI push sau mỗi push vào `main`):

```yaml
# k8s/charts/yas-staging/values.yaml
cart:
  backend:
    image:
      tag: latest    # ← Thay vì v1.0.0
```

**Cách 2:** Chạy lại staging workflow để build image với đúng tag:
1. Đảm bảo CI đã push image `latest` thành công
2. Tạo tag mới: `git tag v1.0.1 && git push origin v1.0.1`
3. Workflow staging sẽ tự build + push image với tag `v1.0.1`

---

## Vấn đề 6: Self-hosted Runner — Session conflict / Runner offline

### Triệu chứng
- Workflow queue mãi không chạy, hoặc runner hiện "offline" trên GitHub
- Khi start runner:
  ```
  A session for this runner already exists
  ```

### Nguyên nhân
Process `Runner.Listener` cũ chưa bị kill trước khi start runner mới.

### Cách sửa
```bash
# Kill process cũ
pkill -f "Runner.Listener" 2>/dev/null

# Start lại runner
cd /home/npt102/gcp/Devops2/actions-runner
nohup ./run.sh > runner.log 2>&1 &

# Kiểm tra
ps aux | grep Runner.Listener | grep -v grep
```

---

## Tổng kết

| Vấn đề | Nguyên nhân | Giải pháp nhanh |
|---|---|---|
| No test report files | Thiếu `checks: write` permission | Thêm `permissions` block |
| Resource not accessible | Thiếu `pull-requests: write` permission | Thêm `permissions` block |
| gh-pages not found | Chưa tạo branch `gh-pages` | `git checkout --orphan gh-pages` |
| Duplicate release error | Chart version không tăng | `skip_existing: true` |
| Image tag not found | Image chưa được build/push | Dùng `latest` hoặc chạy lại CI |
| Runner session conflict | Process cũ chưa kill | `pkill -f "Runner.Listener"` |
