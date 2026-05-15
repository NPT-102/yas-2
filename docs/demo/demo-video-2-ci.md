# Kịch bản Video 2: Tự động hóa Quy trình CI (Xây dựng & Đẩy Image)

**Mục tiêu:** 
1. Chứng minh Yêu cầu 1: *"Mặc định, có 1 image cho tất cả các service với tag là main hoặc latest"*.
2. Chứng minh Yêu cầu 3: *"Phần CI, với mỗi branch của user tạo, sau khi user commit code thay đổi, bạn phải build ra một image với tag là commit id cuối cùng của branch đó, và push image đó lên Docker Hub"*.

---

## 📋 Tổng quan Video
*   **Thời lượng dự kiến:** 3 - 4 phút.
*   **Màn hình hiển thị:** IDE code (VS Code) ➡️ Trình duyệt (GitHub Actions) ➡️ Trình duyệt (Docker Hub).
*   **Nội dung chính:** Sửa đổi mã nguồn trên nhánh Git tùy ý, đẩy code kích hoạt Auto-build trên GitHub Actions, và kiểm chứng ảnh mới trên Docker Hub.

---

## 🎬 KỊCH BẢN TỪNG BƯỚC

### Bước 1: Kiểm tra Ảnh mặc định (latest) trên Docker Hub
*   **Thao tác:** Mở trình duyệt truy cập Docker Hub của bạn. Nhấp vào tab **Repositories**, tìm đến dự án `yas-k3s-cart`.
*   **Thuyết minh:** *"Video 2 này em xin demo luồng CI tự động. Đầu tiên, chứng minh Yêu cầu 1, trên Docker Hub cá nhân của em đã có sẵn các image cơ bản dành cho dịch vụ với tag mặc định là `latest` (hoặc `main`). Thầy cô có thể thấy tag này được cập nhật thường xuyên sau mỗi chu kỳ build."*

### Bước 2: Tạo nhánh mới & Thay đổi mã nguồn
*   **Thao tác:** Mở VS Code. Gõ lệnh tạo nhánh mới `feature/demo-ci-auto` và sửa một file code của `cart`.
*   **Mã lệnh:**
    ```bash
    git checkout -b feature/demo-ci-auto
    ```
*   **Thao tác phụ:** Hãy mở một file Java bất kỳ (ví dụ: `CartController.java`) hoặc đơn giản là file `pom.xml` của module `cart`, thêm một dòng log/comment ngẫu nhiên như `// Fix CI test branch`.
*   **Thuyết minh:** *"Bây giờ em sẽ đóng vai trò là Developer, tạo một nhánh phát triển tính năng mới tên là `feature/demo-ci-auto` và tiến hành sửa đổi một số dòng code trong module Cart Service."*

### Bước 3: Commit và Đẩy code lên GitHub
*   **Thao tác:** Thực hiện commit và push nhánh mới lên Repo.
*   **Mã lệnh:**
    ```bash
    git add .
    git commit -m "test: trigger automatic GitHub Actions CI"
    git push origin feature/demo-ci-auto
    ```
*   **Thuyết minh:** *"Em lưu lại thay đổi, thực hiện commit lên Git và đẩy nhánh này lên kho chứa GitHub. Lệnh log hiển thị commit của em có mã ngắn SHA là `a1b2c3d` (đọc mã SHA thật trên máy của bạn)."*

### Bước 4: Kiểm tra GitHub Actions tự động Kích hoạt
*   **Thao tác:** Mở tab **Actions** trên GitHub Web. Chỉ chuột vào Workflow đang chạy: `ci-cart` (hoặc tên workflow build cart).
*   **Thuyết minh:** *"Em chuyển sang giao diện GitHub Actions. Ngay lập tức, một job CI mang tên `ci-cart` đã tự động được kích hoạt để giám sát nhánh `feature/demo-ci-auto` vừa được đẩy lên. Hệ thống đang tự động khởi chạy máy chủ build của GitHub, cài đặt môi trường JDK 21, và bắt đầu quy trình build dự án."*
*   **Thao tác phụ:** Bấm click vào job để mở xem log chi tiết (đặc biệt là đoạn Maven Build và Docker push log). Có thể Pause video chờ build xong.

### Bước 5: Xác minh Kết quả trên Docker Hub (Yêu cầu then chốt)
*   **Thao tác:** Khi Workflow kết thúc thành công, quay lại Docker Hub. Tải lại (Refresh) trang Tags của repo `yas-k3s-cart`.
*   **Thuyết minh:** *"Workflow CI đã thông báo xanh hoàn tất thành công 100%. Bây giờ em reload lại trang Docker Hub. Như thầy cô có thể quan sát trên màn hình, danh sách Tag đã xuất hiện một phiên bản ảnh hoàn toàn mới. Tag của ảnh này trùng khớp chính xác 100% với mã **Commit SHA** `a1b2c3d` vừa được commit từ nhánh của em."*
*   **Thao tác phụ:** Rê chuột highlight tag SHA đó trên màn hình.
*   **Thuyết minh:** *"Bên cạnh đó, tag `latest` cũng vừa được cập nhật lại ngay lập tức. Quy trình CI hoàn toàn khép kín và tự động."*

---

## 🏁 KẾT THÚC VIDEO 2
*   **Thuyết minh:** *"Nhóm em đã chứng minh thành công việc tự động build image theo commit SHA trên từng nhánh và đẩy lên Docker Hub, hoàn thành 100% Yêu cầu 3. Em xin khép lại Video 2 và chuyển qua Video 3 về CD Developer."*
