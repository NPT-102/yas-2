# Kịch bản Video 4: GitOps với ArgoCD cho Dev & Staging (Nâng cao)

**Mục tiêu:** Chứng minh Yêu cầu Nâng cao 6: *"Sử dụng ArgoCD để handle được 'dev' và 'staging'... main thay đổi, auto sẽ deploy đè liên tục vào trong namespace dev... Staging: trên 'main' branch sẽ có đáng tag để có dạng release... job CI/CD sẽ phát hiện và build image với tag cuối cùng... deploy vào trong namespace 'staging'"*.

---

## 📋 Tổng quan Video
*   **Thời lượng dự kiến:** 5 phút.
*   **Màn hình hiển thị:** ArgoCD Web UI ➡️ Terminal (Xóa pod test Self-heal, check logs) ➡️ Terminal Git (Tạo release tag) ➡️ GitHub Actions + ArgoCD (Deploy Staging, Diff tool).
*   **Nội dung chính:** Trình bày bảng điều khiển ArgoCD, hướng dẫn xem chi tiết tài nguyên và Đọc Log ngay trên Web Console UI ➡️ Thử thách cơ chế tự phục hồi (Self-healing) ➡️ Phát hành (release) Staging an toàn bằng tag ➡️ Trình diễn công cụ so sánh mã Diff Tool chuyên nghiệp.

---

## 🎬 KỊCH BẢN TỪNG BƯỚC

### Bước 1: Mở cổng & Truy cập Dashboard ArgoCD
*   **Thao tác 1:** Chạy lệnh port-forward trong terminal để mở dashboard:
*   **Mã lệnh:**
    ```powershell
    kubectl port-forward svc/argocd-server -n argocd 8080:443
    ```
*   **Thao tác 2:** Truy cập `https://localhost:8080` trên trình duyệt. Đăng nhập bằng tài khoản `admin`.
*   **Thuyết minh:** *"Chào mừng thầy cô tới Video 4 demo phần nâng cao 6: Tự động hóa GitOps qua công cụ ArgoCD. Em đang truy cập vào giao diện quản trị ArgoCD, nơi kết nối trực tiếp tới Git Repository của nhóm."*

### Bước 2: Giới thiệu Cấu trúc GitOps & Xem Chi Tiết Log trên Web Console
*   **Thao tác 1:** Di chuột và giới thiệu các Application gốc trên màn hình:
    - Click vào App **`dev-environment`** để xem sơ đồ cây tài nguyên.
*   **Thuyết minh:** *"Toàn bộ tài nguyên đều đang ở trạng thái màu xanh lá: **`Synced`** và **`Healthy`**. Khi click sâu vào `dev-environment`, ta thấy sơ đồ cây toàn bộ tài nguyên từ Deployment, Service cho tới các Pod chạy thực."*
*   **Thao tác 2 (TRÌNH DIỄN GIAO DIỆN ĐẸP):** Click chọn một biểu tượng **Pod** trong app dev ➡️ Chọn tab **`Logs`** ở cửa sổ chi tiết hiện ra ngay trên trình duyệt.
*   **Thuyết minh:** *"Rất tuyệt vời là ArgoCD UI cho phép em theo dõi Log thời gian thực của ứng dụng ngay tại đây mà không cần gõ lệnh. Mọi lỗi phát sinh đều có thể truy vết ngay lập tức."*

### Bước 3: Demo Tính năng Môi trường Dev (Auto-sync & Self-heal)
*   **Thao tác 1 (Demo đỉnh cao):** Mở terminal song song bên cạnh màn hình ArgoCD. Chạy lệnh xóa trắng 1 Pod của service Cart:
*   **Mã lệnh:**
    ```powershell
    kubectl delete pod -l app.kubernetes.io/name=cart -n dev --grace-period=0 --force
    ```
*   **Thao tác 2:** Nhanh tay nhìn lại màn hình ArgoCD. Show hiệu ứng Pod cũ chuyển đỏ/xóa đi và Pod mới tự động sinh ra chuyển sang màu Xanh.
*   **Thuyết minh:** *"Em vừa cố tình xóa đột ngột Pod Cart trên Cluster. Nhìn sang màn hình, cơ chế **Self-healing** của ArgoCD lập tức phát hiện ra sự cố, ra lệnh khởi chạy ngay Pod mới thay thế để duy trì hiện trạng đúng như thiết kế trong Git."*
*   **Thao tác 3 (Check LOG Pod mới trên terminal):** Gõ lệnh xem logs của pod vừa sinh ra:
*   **Mã lệnh:**
    ```powershell
    kubectl logs -n dev -l app.kubernetes.io/name=cart --tail=20
    ```
*   **Thuyết minh:** *"Em kiểm tra Logs của Pod mới sinh ra. Hệ thống ghi nhận thời gian khởi động chỉ tính bằng giây, ứng dụng hoàn toàn phục hồi trạng thái khỏe mạnh."*

### Bước 4: Demo Quy trình Phát hành Staging qua Tag
*   **Thao tác 1:** Trên terminal, em thực hiện đánh dấu phiên bản (Tag) release trên nhánh main:
*   **Mã lệnh:**
    ```bash
    git tag v1.0.0-staging-test
    git push origin v1.0.0-staging-test
    ```
*   **Thuyết minh:** *"Đối với Yêu cầu Staging, em tạo một Git Tag là `v1.0.0-staging-test` trên nhánh main."*
*   **Thao tác 2:** Mở GitHub Actions, chỉ vào workflow `release-staging` đang chạy để cập nhật file staging lên Git.
*   **Thao tác 3:** Trở lại ArgoCD, nhấp vào Application **`staging-environment`**. Bấm nút **`Sync`** ➡️ Bấm **`Synchronize`** trên menu hiện ra (hoặc để nó Auto-sync).
*   **Thuyết minh:** *"ArgoCD bắt được tag `v1.0.0-staging-test` mới nhất được cập nhật trong Git. Nó tự động tiến hành Rollout cập nhật phiên bản mới nhất cho toàn bộ pods trong namespace `staging`."*
*   **Thao tác 4 (Kiểm tra Manifest):** Click chọn Deployment của Cart trong app Staging ➡️ Chọn tab **`Live Manifest`** ➡️ Cuộn xuống và chỉ chuột vào dòng `image: ...:v1.0.0-staging-test`.
*   **Thuyết minh:** *"Thầy cô có thể kiểm chứng tại Live Manifest, Image đã được đổi sang đúng tag phiên bản staging mà chúng em vừa release. Ổn định và minh bạch."*

### Bước 5: Trình diễn Công cụ So Sánh Khác Biệt (ArgoCD Diff Tool - Mới)
*   **Thuyết minh:** *"Đặc biệt, em xin demo công cụ so sánh thông minh bậc nhất của ArgoCD: Diff Tool."*
*   **Thao tác 1:** Chọn một Deployment bất kỳ trên Resource Tree của App `staging-environment`.
*   **Thao tác 2:** Nhấp chọn tab **`Diff`** ở cửa sổ chi tiết.
*   **Thuyết minh:** *"Màn hình Diff hiện ra dưới dạng split-screen màu xanh đỏ, so sánh chính xác giữa thiết kế mong muốn trong Git và hiện trạng thực thi trong Cluster. Nhờ đó, nếu ai đó lén lút sửa cấu hình bằng tay, ArgoCD sẽ vạch trần sự sai lệch ngay lập tức. Một tính năng quản trị hạ tầng cực kỳ mạnh mẽ!"*

---

## 🏁 KẾT THÚC VIDEO 4
*   **Thuyết minh:** *"Hệ thống đã quản trị GitOps toàn vẹn cho cả hai môi trường Dev (Tự khôi phục) và Staging (Deploy theo thẻ phiên bản), đáp ứng trọn vẹn yêu cầu Nâng cao số 6. Em xin chuyển sang Video 5 để demo phần Giám sát Observability."*
