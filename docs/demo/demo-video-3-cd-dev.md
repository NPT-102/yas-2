# Kịch bản Video 3: CD cho Developer (Môi trường Sandbox & Dọn dẹp)

**Mục tiêu:**
1. Chứng minh Yêu cầu 4: *"Tạo Job CD cho developer làm việc với tên developer\_build. Với job này developer có thể input parameter là branch muốn deploy... Sau khi deploy, bạn cung cấp domain name:port (dạng service là NodePort), để developer có thể truy cập và test code của mình trực tiếp. Phần domain name, do mình không có dns, vì vậy developer sẽ tự thêm vào file hosts của mình trên máy để chỉ đến Worker node"*
2. Chứng minh Yêu cầu 5: *"Tạo Jenkins job (ở đây dùng GitHub Actions) để xóa phần triển khai ở mục 4"*

---

## 📋 Tổng quan Video
*   **Thời lượng dự kiến:** 4 - 5 phút.
*   **Màn hình hiển thị:** GitHub Actions (Nhập param) ➡️ Terminal (Chạy Helm, check pod, check log chi tiết) ➡️ Màn hình hosts file Windows ➡️ Gọi API test thành công ➡️ Chạy job Cleanup.
*   **Nội dung chính:** Demo quy trình trọn gói: Triển khai nhanh Sandbox theo nhánh tùy chọn ➡️ Kiểm tra tính ổn định của Pod thông qua LOG ➡️ Ánh xạ IP ➡️ Kiểm thử trực tiếp ➡️ Dọn dẹp sạch tài nguyên.

---

## 🎬 KỊCH BẢN TỪNG BƯỚC

### Bước 1: Khởi tạo Job CD Developer Build
*   **Thao tác:** Mở GitHub Actions ➡️ Bấm chọn Workflow: **`Developer CD - Deploy Quick Sandbox`**.
*   **Thuyết minh:** *"Xin chào thầy cô, trong Video 3 này em sẽ thực hiện kiểm thử Yêu cầu 4 và 5. Em đang truy cập vào Job CD mang tên `cd-developer-build` (trong repo là `Developer CD - Deploy Quick Sandbox`) giúp khởi tạo môi trường test nhanh cho developer."*

### Bước 2: Nhập tham số & Chạy CD (Chứng minh Parameter input)
*   **Thao tác:** Nhấp vào nút **Run workflow**, nhập các thông tin sau:
    - **Developer Name:** `tanmq`
    - **Branch for Cart Service:** `feature/demo-ci-auto` (nhánh chúng ta vừa build thành công ở Video 2).
    - **Các Service khác:** Giữ nguyên mặc định là `main`.
*   **Thao tác phụ:** Bấm nút **Run workflow** màu xanh.
*   **Thuyết minh:** *"Ở đây em nhập tham số tên developer là `tanmq`. Hệ thống sẽ tạo riêng một namespace là `dev-tanmq` để cách ly hoàn toàn dữ liệu. Dịch vụ Cart em sẽ nhập nhánh vừa test là `feature/demo-ci-auto` để lấy đúng image mới nhất, các dịch vụ còn lại em giữ nguyên nhánh `main` mặc định để lấy tag latest, đúng hệt như yêu cầu của đề bài."*

### Bước 3: Theo dõi Self-hosted Runner triển khai local
*   **Thao tác:** Click vào job đang chạy, cuộn log xuống để hiện các câu lệnh `helm upgrade --install`.
*   **Thuyết minh:** *"Vì cụm K3s đang chạy tại máy cá nhân (local), Job CD này đang được một **Self-hosted runner** (máy ảo công nhân cài local) đảm nhận, giúp tiếp nhận trực tiếp và thực thi deploy ứng dụng lên Kubernetes thông qua file Helm Chart."*

### Bước 4: Kiểm tra Pod trạng thái Running & Xem LOG Khởi Động
*   **Thao tác 1:** Khi job hoàn tất, mở terminal PowerShell để xác minh Pod đã được deploy.
*   **Mã lệnh:**
    ```powershell
    kubectl get pods -n dev-tanmq
    ```
*   **Thuyết minh:** *"Hệ thống báo hoàn thành, em kiểm tra Pods trong namespace `dev-tanmq`. Toàn bộ các service lõi cùng database phụ trợ đang ở trạng thái **`Running`**."*
*   **Thao tác 2 (NÂNG CAO):** Để chứng minh ứng dụng thực sự khởi động khỏe mạnh, hãy đọc log của pod Java:
*   **Mã lệnh:**
    ```powershell
    kubectl logs -n dev-tanmq -l app.kubernetes.io/name=cart --tail=30
    ```
*   **Thuyết minh:** *"Để chứng minh hệ thống chạy thực tế rất tốt, em sử dụng lệnh `kubectl logs` để xem trực tiếp dòng log khởi động của ứng dụng Java Spring Boot của service Cart. Như thầy cô quan sát, log hiển thị rõ ràng banner Spring Boot, Tomcat khởi tạo thành công trên cổng 8080 và trạng thái 'Started CartApplication'. Ứng dụng hoàn toàn sẵn sàng đón nhận dữ liệu."*

### Bước 5: Cấu hình file hosts & Truy cập NodePort (Bắt buộc)
*   **Thao tác 1:** Lấy NodePort của service Cart.
*   **Mã lệnh:**
    ```powershell
    kubectl get svc -n dev-tanmq
    ```
*   **Thuyết minh:** *"Bây giờ em lấy cổng NodePort của dịch vụ Cart (ví dụ cổng `30080`). Để truy cập bằng tên miền như yêu cầu, em sẽ cấu hình file hosts trên Windows."*
*   **Thao tác 2:** Mở Notepad Admin, mở file `C:\Windows\System32\drivers\etc\hosts`. Chỉ cho người xem dòng đã cấu hình sẵn trỏ về IP Cluster:
    ```text
    127.0.0.1    yas-cart.local
    ```
*   **Thao tác 3:** Mở terminal hoặc trình duyệt, gửi request curl để kiểm tra phản hồi API Health của service:
*   **Mã lệnh:**
    ```powershell
    curl -i http://yas-cart.local:30080/actuator/health
    ```
*   **Thuyết minh:** *"Request đã phản hồi kết quả thành công **`HTTP/1.1 200 OK`**, kèm trạng thái Health: UP. Như vậy Developer có thể tự tin test tính năng của mình trên cụm local bằng domain riêng."*

### Bước 6: Chạy Job Cleanup (Yêu cầu 5)
*   **Thao tác 1:** Trở lại GitHub Actions ➡️ Chọn workflow **`Developer CD - Cleanup Sandbox`**.
*   **Thao tác 2:** Bấm **Run workflow**, nhập tên `tanmq` ➡️ Chạy.
*   **Thuyết minh:** *"Sau khi test xong, em thực hiện Yêu cầu 5 bằng cách chạy Job Cleanup, nhập đúng tên namespace `tanmq` để hệ thống tự động dọn dẹp."*
*   **Thao tác 3:** Đợi Workflow chạy xong, quay lại terminal và kiểm tra lại danh sách namespace:
*   **Mã lệnh:**
    ```powershell
    kubectl get ns | grep tanmq
    ```
    *(Kết quả hiển thị rỗng - Empty)*
*   **Thuyết minh:** *"Namespace đã bị xóa sạch, tài nguyên đã được thu hồi hoàn hảo."*

---

## 🏁 KẾT THÚC VIDEO 3
*   **Thuyết minh:** *"Nhóm em đã minh chứng trọn vẹn khả năng deploy Sandbox tùy chọn branch, xem logs kiểm tra ứng dụng chạy thực, cấu hình dns local qua file hosts, và tự động xóa dọn dẹp tài nguyên, hoàn thành Yêu cầu 4 và 5. Tiếp theo kính mời thầy cô xem Video 4 về GitOps qua ArgoCD."*
