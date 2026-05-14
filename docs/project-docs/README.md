# Project Docs

Thư mục này gom toàn bộ tài liệu Markdown nội bộ của project, ngoại trừ các file `README.md` vốn được giữ lại ở vị trí gốc của từng module để mô tả nhanh module đó.

## Khi nào dùng file nào

| File | Dùng khi nào |
|---|---|
| `HUONG-DAN-DO-AN.md` | Cần nhìn tổng thể yêu cầu đồ án, cấu trúc phần CI/CD, phần Istio, và các bước triển khai để báo cáo hoặc bàn giao. |
| `VIEC-CAN-LAM.md` | Cần checklist công việc còn lại, theo dõi tiến độ demo, hoặc biết bước tiếp theo cần làm cho đồ án. |
| `CAI-DAT-TU-DAU.md` | Cần dựng lại toàn bộ môi trường từ đầu sau khi `minikube delete` hoặc trên máy mới. |
| `KHOI-PHUC-CLUSTER.md` | Cần khởi động lại, cứu cluster sau `minikube stop`, reboot máy, hoặc xử lý tình huống cluster chạy lỗi. |
| `TROUBLESHOOTING-SERVICES.md` | Gặp lỗi ở từng service ứng dụng, lỗi DNS nội bộ, lỗi route, lỗi 500 hoặc lỗi service-to-service thông thường. |
| `TROUBLESHOOTING-INGRESS-ISTIO.md` | Gặp lỗi truy cập từ browser, lỗi ingress-nginx, lỗi timeout, lỗi 502/503, hoặc xung đột giữa ingress-nginx và Istio. |
| `SESSION-STRICT-MTLS-INGRESS.md` | Cần xem riêng phần việc đã làm trong phiên xử lý `mTLS STRICT` với `ingress-nginx`, gồm root cause, fix đã thử, fix đã áp dụng, và kết quả test hiện tại. |
| `CHANGES.md` | Cần đối chiếu repo này đã thay đổi gì so với repo gốc, phục vụ báo cáo hoặc giải thích phần custom hóa. |
| `developer-guidelines.md` | Cần xem coding guideline và quy ước phát triển của dự án gốc. |

## Quy ước sử dụng

- Ưu tiên mở `VIEC-CAN-LAM.md` nếu chưa biết bước tiếp theo là gì.
- Ưu tiên mở `CAI-DAT-TU-DAU.md` khi môi trường bị xóa hoàn toàn.
- Ưu tiên mở `KHOI-PHUC-CLUSTER.md` khi cluster đã có sẵn nhưng đang lỗi hoặc bị dừng.
- Ưu tiên mở `TROUBLESHOOTING-INGRESS-ISTIO.md` khi lỗi nằm ở truy cập từ browser, ingress, gateway, Istio hoặc mTLS.
- Ưu tiên mở `SESSION-STRICT-MTLS-INGRESS.md` khi cần nhắc lại phần thay đổi mới nhất trong phiên làm việc này.

## Ghi chú

- Các file `README.md` của từng module vẫn được giữ tại chỗ để không làm mất entry point mặc định của module đó.
- Nếu phát sinh thêm tài liệu nội bộ mới, đặt vào thư mục này thay vì để ở root repo.