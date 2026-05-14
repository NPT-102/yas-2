# Tối Ưu Hóa: Chỉ Deploy Services Cần Thiết

## Phân Tích Yêu Cầu Đồ Án (Hướng Nâng Cao)

Theo file `Project02_2026.pdf`, đồ án yêu cầu:

| # | Yêu cầu | Điểm | Trạng thái |
|---|---------|------|-----------|
| 1 | K8S cluster (1 Master + 1 Worker) | 6đ (cơ bản) | ✅ Đã có |
| 2 | CI: Build image với tag = commit ID, push Docker Hub | 6đ | ✅ GitHub Actions |
| 3 | CD: Job `developer_build` (input branch → deploy) | 6đ | ✅ |
| 4 | Job xóa phần triển khai developer | 6đ | ✅ |
| 5 | **Nâng cao: ArgoCD cho "dev" và "staging"** | **+2đ** | ✅ Đã cài |
| 6 | **Nâng cao: Service Mesh (mTLS, AuthorizationPolicy, retry, Kiali)** | **+2đ** | ✅ Đã cài Istio |

> [!IMPORTANT]
> Đồ án ghi rõ dòng 46: **"bạn không cần triển khai Grafana và Prometheus (Observability)"**
> → Việc chúng ta gỡ bỏ Observability stack là **đúng 100% yêu cầu đề bài!**

---

## Phân Loại Services: GIỮ vs TẮT

### 🟢 PHẢI GIỮ — Cốt lõi cho demo E-commerce + Service Mesh

| Service | Lý do giữ |
|---------|-----------|
| `product` | Sản phẩm — trung tâm của shop |
| `cart` | Giỏ hàng — demo flow mua hàng |
| `order` | Đơn hàng — demo flow đặt hàng, test **retry policy** (order→cart/payment/inventory/tax) |
| `customer` | Thông tin khách hàng |
| `inventory` | Kho hàng — order phụ thuộc |
| `tax` | Thuế — order phụ thuộc, demo **VirtualService retry** |
| `media` | Upload hình ảnh sản phẩm |
| `search` | Tìm kiếm — phụ thuộc product, demo **AuthorizationPolicy** |
| `storefront-bff` | BFF cho giao diện người dùng |
| `storefront-ui` | Giao diện cửa hàng — demo cho giảng viên |
| `backoffice-bff` | BFF cho quản trị |
| `backoffice-ui` | Giao diện quản trị |
| `swagger-ui` | API documentation |

**Tổng: 13 services**

### 🔴 TẮT — Không cần thiết cho demo

| Service | Lý do tắt |
|---------|-----------|
| `payment` | ❌ Đang CrashLoopBackOff (lỗi image gốc) |
| `payment-paypal` | ❌ Đang CrashLoopBackOff (lỗi JAR manifest) |
| `debezium-connect` | ❌ Đang CrashLoopBackOff (Kafka version mismatch) |
| `promotion` | Khuyến mãi — không cần cho flow cơ bản |
| `rating` | Đánh giá — không cần cho flow cơ bản |
| `recommendation` | Gợi ý — không cần cho demo |
| `sampledata` | Dữ liệu mẫu — chỉ chạy 1 lần |
| `webhook` | Webhook — không cần cho demo |
| `location` | Vị trí — không cần cho demo |

**Tiết kiệm: 9 services = ~4-5GB RAM + rất nhiều CPU**

---

## Kế Hoạch Thực Hiện

### Bước 1: Scale down services không cần thiết (namespace `yas`)
```bash
for svc in payment payment-paypal promotion rating recommendation sampledata webhook location; do
  kubectl scale deployment/$svc --replicas=0 -n yas
done
```

### Bước 2: Scale down debezium (namespace `kafka`)
```bash
kubectl scale deployment --all -l strimzi.io/kind=KafkaConnect --replicas=0 -n kafka 2>/dev/null || true
# Hoặc trực tiếp:
kubectl delete kafkaconnect debezium-connect-cluster -n kafka 2>/dev/null || true
```

### Bước 3: Giữ dev=0, staging=0 (ArgoCD chỉ hiện cây, không chạy pods)
```bash
kubectl patch application yas-dev -n argocd --type merge -p '{"spec":{"syncPolicy":null}}'
kubectl patch application yas-staging -n argocd --type merge -p '{"spec":{"syncPolicy":null}}'
kubectl scale deployment --all -n dev --replicas=0
kubectl scale deployment --all -n staging --replicas=0
```

### Bước 4: Verify
```bash
kubectl get pods -n yas --no-headers | grep -v "0/.*Running"
# Expected: 13 pods Running (2/2 nếu có sidecar)
```

## Tóm Tắt Tài Nguyên Sau Tối Ưu

| Hạng mục | Trước | Sau |
|----------|-------|-----|
| Pods namespace `yas` | 22 | 13 |
| Pods namespace `dev` | 20 | 0 (tree ArgoCD vẫn hiện) |
| Pods namespace `staging` | 20 | 0 (tree ArgoCD vẫn hiện) |
| Problem pods | 3 CrashLoop | 0 |
| RAM ước tính | ~24GB | ~14-16GB |

## Khi Nào Demo Cho Giảng Viên

Nếu muốn demo ArgoCD staging "sống" (pods chạy thật), chỉ cần:
```bash
kubectl scale deployment --all -n staging --replicas=1
```
Chờ 3-5 phút → ArgoCD hiện cây xanh lá đầy đủ deploy→rs→pod.
