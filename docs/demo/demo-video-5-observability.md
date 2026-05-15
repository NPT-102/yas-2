# Kịch bản Video 5: Tích hợp Hệ thống Giám sát (Observability)

**Mục tiêu:** Chứng minh Yêu cầu bổ sung: *"Thay vào đó các bạn triển khai chung phần 'Observability' vào trong project 02 của mình luôn (Chỉ cần deploy lên và truy cập được vào Observability là được - như trong hình của repo)"*.

---

## 📋 Tổng quan Video
*   **Thời lượng dự kiến:** 5 phút.
*   **Màn hình hiển thị:** Terminal (Port-forward) ➡️ Grafana Dashboard UI ➡️ Prometheus Targets UI.
*   **Nội dung chính:** Kích hoạt kết nối UI ➡️ Hướng dẫn Click chi tiết để xem **Metrics (Chỉ số tải)** ➡️ **Logs (Nhật ký hệ thống)** ➡️ **Trace (Truy vết đường đi request)** ➡️ Trình diễn sức khỏe bộ máy thu thập **Prometheus Targets**.

---

## 🎬 KỊCH BẢN TỪNG BƯỚC

### Bước 1: Khởi động Cổng kết nối Dashboard Giám sát
*   **Thao tác:** Chạy lệnh port-forward trong terminal để mở Grafana:
*   **Mã lệnh:**
    ```powershell
    kubectl port-forward svc/prometheus-grafana -n observability 3000:80
    ```
*   **Thuyết minh:** *"Kính chào thầy cô, trong Video 5 này nhóm em sẽ demo trọn vẹn 3 trụ cột của giám sát hiện đại: Metrics, Logs và Tracing. Em đang thực hiện mở cổng kết nối tới cổng 3000 để truy cập Dashboard Grafana."*

### Bước 2: Đăng nhập & Xác minh Kết nối Data Sources
*   **Thao tác 1:** Mở trình duyệt truy cập `http://localhost:3000`. Đăng nhập user `admin`.
*   **Thao tác 2:** Click vào biểu tượng **`Menu chính (3 dấu gạch ngang ở góc trên bên trái)`** ➡️ Chọn **`Connections`** ➡️ Chọn **`Data sources`**.
*   **Thuyết minh:** *"Đây là trung tâm cấu hình. Nhóm em đã kết nối thành công cả 3 nguồn dữ liệu: **`Prometheus`** (cho Metrics), **`Loki`** (cho Logs) và **`Tempo`** (cho Distributed Tracing)."*

### Bước 3: Xem METRICS - Sức khỏe Tài nguyên (Trụ cột 1)
*   **Thao tác 1:** Bấm vào Menu chính ➡️ Chọn mục **`Dashboards`** ➡️ Click chọn thư mục có sẵn hoặc mục **`Recent`** ➡️ Nhấp chuột chọn Dashboard mang tên **`Kubernetes / Compute Resources / Node (Pods)`**.
*   **Thao tác 2 (THAO TÁC TRỰC QUAN):** 
    - Chỉ chuột vào đồ thị **`CPU Usage`** (sử dụng vi xử lý).
    - Chỉ chuột vào đồ thị **`Memory Usage`** (sử dụng RAM).
*   **Thuyết minh:** *"Trụ cột đầu tiên là Metrics. Dashboard hiển thị tần suất làm việc thời gian thực của hệ thống. Khi em di chuyển chuột qua biểu đồ, các con số tải động nhảy liên tục, phản ánh chính xác lượng tài nguyên RAM và CPU mà toàn bộ K3s Cluster đang tiêu thụ."*

### Bước 4: Xem LOGS - Nhật ký Tập trung qua LOKI (Trụ cột 2)
*   **Thao tác 1:** Bấm chọn mục **`Explore`** (Biểu tượng la bàn) trên thanh Menu trái.
*   **Thao tác 2:** Tại hộp thoại thả xuống đầu tiên trên góc trái, **click chọn `Loki`** làm Data Source.
*   **Thao tác 3:** Bấm vào nút **`Builder`** (hoặc chuyển sang chế độ gõ code) và nhập dòng truy vấn để lấy log của namespace `dev`:
    ```text
    {namespace="dev"}
    ```
*   **Thao tác 4:** Nhấp chuột vào nút xanh đậm **`Run query`** ở góc phải phía trên.
*   **Thao tác 5:** Khi log hiện ra, **nhấp chuột vào một dòng Log bất kỳ** để mở rộng hiển thị các nhãn (Labels) như: `pod`, `container`, `stream: stdout`.
*   **Thuyết minh:** *"Trụ cột thứ 2 là Logs. Em chuyển sang chế độ Explore và chọn nguồn Loki. Với câu lệnh lọc namespace `dev`, toàn bộ log từ các pod Java khác nhau đều đổ về đây theo dòng thời gian thực. Khi click mở rộng một bản ghi log, ta có thể truy xuất tường tận log này thuộc container nào, sinh ra lúc mấy giờ, hỗ trợ giám sát tập trung tuyệt đối."*

### Bước 5: Xem TRACE - Truy vết đường đi của Request qua TEMPO (Trụ cột 3)
*   **Thao tác 1:** Giữ nguyên màn hình Explore, click vào ô chọn Data Source ban nãy, chuyển sang **chọn nguồn `Tempo`**.
*   **Thao tác 2:** Dưới phần Query Type, click chọn tab **`Search`**.
*   **Thao tác 3:** Tại trường thả xuống **`Service Name`**, nhấp chọn một service như `cart` hoặc `product` (hoặc để `All`).
*   **Thao tác 4:** Nhấp chuột vào nút **`Run query`** (hoặc Search).
*   **Thao tác 5 (ĐỈNH CAO):** Ở bảng kết quả bên dưới, **nhấp chuột vào mã một `Trace ID`** màu xanh.
*   **Hiệu ứng:** Màn hình hiển thị sơ đồ Timeline (các thanh ngang biểu thị độ trễ thời gian gọi từ service Cart sang Product).
*   **Thuyết minh:** *"Cuối cùng, đỉnh cao của Observability là Distributed Tracing với Tempo. Em truy vấn vết các cuộc gọi của service Cart. Khi click chọn vào một Trace ID bất kỳ, thầy cô sẽ thấy sơ đồ hình thang (Gantt Chart) biểu thị trọn vẹn hành trình của 1 yêu cầu HTTP: nó đi từ client vào Cart Service, mất bao nhiêu mili-giây để xử lý, sau đó tiếp tục gọi sang Product Service mất bao lâu. Mọi điểm thắt nút cổ chai về độ trễ đều được phát hiện dễ dàng qua giao diện trực quan này!"*

### Bước 6: Trình diễn Gốc Rễ Thu Thập - Prometheus Targets (Mới)
*   **Thuyết minh:** *"Để chứng minh tính nhất quán, em xin mở thêm giao diện thô của Prometheus - cỗ máy thu thập dữ liệu cốt lõi."*
*   **Thao tác 1:** Trong terminal, mở thêm cổng port-forward cho Prometheus:
    ```powershell
    kubectl port-forward svc/prometheus-operated -n observability 9090:9090
    ```
*   **Thao tác 2:** Truy cập `http://localhost:9090/targets` trên trình duyệt.
*   **Thuyết minh:** *"Em truy cập trực tiếp vào danh mục Status Targets. Thầy cô thấy toàn bộ danh sách dịch vụ của Kubernetes đang hiển thị trạng thái **`UP`** màu xanh lục, chứng tỏ Prometheus đang cào chỉ số rất đều đặn và ổn định."*

---

## 🏁 KẾT THÚC VIDEO 5
*   **Thuyết minh:** *"Sự kết hợp của Metrics, Logs, Tracing và hạ tầng cào dữ liệu Prometheus lành mạnh đã tạo nên một bộ Observability cực kỳ hoàn thiện. Kính mời thầy cô theo dõi Video 6 về Service Mesh."*
