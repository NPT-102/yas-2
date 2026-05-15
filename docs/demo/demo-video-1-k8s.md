# Kịch bản Video 1: Xây dựng Hạ tầng K8S Cluster (K3s)

**Mục tiêu:** Chứng minh Yêu cầu 2: *"Xây dựng K8S cluster với 1 Master node và 1 worker Node (Hoặc Minikube, hoặc bất kỳ mô hình K8S nào)"*.

---

## 📋 Tổng quan Video
*   **Thời lượng dự kiến:** 2 - 3 phút.
*   **Màn hình hiển thị:** Cửa sổ Terminal (PowerShell Admin hoặc WSL2 Ubuntu).
*   **Nội dung chính:** Giới thiệu mô hình, kiểm tra các Node đang chạy, xem chi tiết thông số của Node, liệt kê namespace, và kiểm tra LOG của một pod nền tảng để chứng minh K8s hoạt động mượt mà.

---

## 🎬 KỊCH BẢN TỪNG BƯỚC

### Bước 1: Giới thiệu mô hình Cluster
*   **Thao tác:** Mở sẵn Terminal. 
*   **Thuyết minh:** *"Kính chào thầy cô, đây là Video 1 demo Yêu cầu số 2 về xây dựng hạ tầng Kubernetes. Để tối ưu hóa tài nguyên nhưng vẫn đảm bảo tính chân thực, nhóm em đã lựa chọn cài đặt hệ thống K3s (một phiên bản Kubernetes rút gọn chuyên dụng) trên nền tảng WSL2. Cụm K3s này được thiết kế với 1 Node đóng vai trò vừa làm Server (Master) vừa làm Agent (Worker) để xử lý toàn bộ tải của hệ thống."*

### Bước 2: Kiểm tra các Node đang hoạt động
*   **Thao tác:** Gõ câu lệnh liệt kê các node:
*   **Mã lệnh:**
    ```powershell
    kubectl get nodes -o wide
    ```
*   **Thuyết minh:** *"Lệnh `kubectl get nodes` hiển thị rõ Node mang tên máy chủ của em (ví dụ: `wsl2-ubuntu`) đang ở trạng thái **`Ready`**. Phiên bản K3s đang chạy là v1.29+. Hệ điều hành nền là Ubuntu 22.04 LTS. Mọi thành phần lõi của Kubernetes đã sẵn sàng."*

### Bước 3: Show chi tiết tài nguyên của Node
*   **Thao tác:** Gõ lệnh `describe node` để show thông số CPU/RAM và khẳng định khả năng chịu tải:
*   **Mã lệnh:**
    ```powershell
    kubectl describe node | grep -E "Name:|cpu|memory" -A 2
    ```
*   **Thuyết minh:** *"Em thực hiện Describe node để thầy cô xem chi tiết lượng tài nguyên CPU và RAM ảo hóa cấp phát cho cụm. Việc này giúp đảm bảo cluster của em có đủ năng lực vận hành 3-4 ứng dụng Java Microservice nặng nề cùng lúc cùng hệ thống Service Mesh."*

### Bước 4: Kiểm tra các Namespace cốt lõi
*   **Thao tác:** Gõ lệnh xem các namespace đã khởi tạo:
*   **Mã lệnh:**
    ```powershell
    kubectl get ns
    ```
*   **Thuyết minh:** *"Cụm cluster đã được cấu hình phân ranh giới rõ ràng thông qua các namespaces bao gồm: `dev`, `staging` phục vụ CD, `argocd` cho GitOps, `istio-system` cho Service Mesh, và `observability` cho giám sát."*

### Bước 5: Kiểm tra LOG của dịch vụ nền tảng (PostgreSQL hoặc Keycloak)
*   **Thao tác:** Xem trạng thái các Pod và kiểm tra Logs của cơ sở dữ liệu dùng chung để khẳng định ứng dụng nền chạy khỏe mạnh.
*   **Mã lệnh:**
    ```powershell
    # Lấy danh sách Pod trong hạ tầng chung
    kubectl get pods -n shared
    
    # Đọc logs của pod Postgresql (hoặc Keycloak)
    kubectl logs -n shared -l app.kubernetes.io/name=postgresql --tail=20
    ```
*   **Thuyết minh:** *"Để chứng minh sâu hơn khả năng vận hành tải của K3s, em truy cập vào namespace hạ tầng `shared`. Các Pod cơ sở dữ liệu Postgresql đang chạy rất ổn định. Em truy xuất Log của Postgresql, màn hình hiển thị rõ ràng: 'database system is ready to accept connections'. Mọi luồng đọc/ghi của hạ tầng K8s đã hoạt động hoàn hảo."*

---

## 🏁 KẾT THÚC VIDEO 1
*   **Thuyết minh:** *"Như vậy, cụm hạ tầng K3s đã được cấu hình và hoạt động trơn tru, đáp ứng hoàn hảo Yêu cầu 2. Em xin phép khép lại Video 1 và chuyển sang Video 2 để demo quy trình CI."*
