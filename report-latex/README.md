# Báo cáo LaTeX — Đồ án 2

## Cấu trúc thư mục

```
report-latex/
├── main.tex                    # File chính, kết nối tất cả sections
└── sections/
    ├── 01-tong-quan.tex        # Chapter 1: Tổng quan đồ án (kiến trúc, sơ đồ)
    ├── 02-cau-hinh.tex         # Chapter 2: Cấu hình (CI/CD flows, Istio, ArgoCD)
    ├── 03-kiem-thu.tex         # Chapter 3: Kiểm thử
    └── 04-van-de.tex           # Chapter 4: Vấn đề gặp phải và cách khắc phục
```

## Cách compile

### Yêu cầu

Cần cài LaTeX distribution với các package:
- **Linux**: `texlive-full` hoặc `texlive-xetex`
- **Windows**: MikTeX hoặc TeX Live
- **macOS**: MacTeX

Package cần thiết:
- `babel` với Vietnamese (`babel-vietnamese`)
- `fontenc` (T5)
- `listings`, `tcolorbox`, `booktabs`, `tabularx`
- `hyperref`, `geometry`, `fancyhdr`, `titlesec`

### Compile bằng pdflatex (khuyến nghị)

```bash
cd report-latex

# Compile 2 lần để Table of Contents đúng
pdflatex main.tex
pdflatex main.tex

# Output: main.pdf
```

### Compile bằng lualatex (hỗ trợ Unicode tốt hơn)

```bash
lualatex main.tex
lualatex main.tex
```

### Nếu không có ảnh kiến trúc

File `main.tex` tham chiếu đến `../yas-architecture-local.png` (nằm ở thư mục gốc repo).
Nếu không tìm thấy file ảnh, comment dòng `\includegraphics` trong `01-tong-quan.tex`.

## Nội dung báo cáo

| Chapter | Nội dung |
|---------|----------|
| **1. Tổng quan** | Giới thiệu YAS, yêu cầu đồ án, kiến trúc K3s cluster, kiến trúc CI/CD, kiến trúc Istio Service Mesh, sơ đồ namespace và traffic flow |
| **2. Cấu hình** | Lý do chọn K3s, cài đặt K3s + worker nodes, GitHub Secrets, self-hosted runner, workflow CI (YC3), developer\_build (YC4), cleanup (YC5), dev/staging deploy (YC6), ArgoCD ApplicationSet, Istio mTLS + AuthorizationPolicy + Retry |
| **3. Kiểm thử** | Test CI pipeline, developer\_build, cleanup, dev/staging deploy, mTLS verification, AuthorizationPolicy test (allow/deny), retry policy, Kiali topology |
| **4. Vấn đề** | 15 vấn đề gặp phải, nguyên nhân gốc, các bước đã thử, cách khắc phục |

## Yêu cầu đồ án được trình bày

- ✅ YC2: K3s cluster (1 master + 2 worker)
- ✅ YC3: CI pipeline — build image với commit\_id tag
- ✅ YC4: developer\_build workflow
- ✅ YC5: cleanup workflow  
- ✅ YC6: dev/staging deploy với ArgoCD
- ✅ NC Istio: mTLS STRICT, AuthorizationPolicy, Retry Policy, Kiali
- ✅ NC ArgoCD: GitOps ApplicationSet cho dev + staging
