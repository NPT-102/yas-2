# Kịch bản Video 6: Cấu hình Service Mesh (Istio & Kiali) (Nâng cao)

**Mục tiêu:** Chứng minh Yêu cầu Nâng cao Service Mesh:
1. *"Enable TLS (mTLS) giữa các service deploy trên K8S cho ứng dụng yas"*
2. *"Vẽ flow chart/Topology của các service (sử dụng Kiali để quan sát)"*
3. *"Chuẩn bị kịch bản test: retryable (nếu service lỗi 500 thì tự động retry), setup policy (chỉ service server cho phép mới connect được), test (vào pod khác curl để kiểm chứng cho phép hay chặn)"*

---

## 📋 Tổng quan Video
*   **Thời lượng dự kiến:** 6 phút.
*   **Màn hình hiển thị:** Kiali UI ➡️ Terminal (Tạo traffic, curl test, đọc Envoy logs, VirtualService YAML).
*   **Nội dung chính:** Khám phá chi tiết Kiali UI (Bật traffic rate, animation, click edge xem biểu đồ động) ➡️ Xem **Traces tích hợp trực tiếp trên Kiali** ➡️ Test chính sách Allowed/Denied qua curl ➡️ Đọc Envoy logs chặn RBAC ➡️ Khảo sát Retry Policy.

---

## 🎬 KỊCH BẢN TỪNG BƯỚC

### Bước 1: Mở và Thiết lập Giao diện Kiali Chi Tiết
*   **Thao tác 1:** Port-forward mở cổng Kiali:
    ```bash
    kubectl port-forward svc/kiali -n istio-system 20001:20001
    ```
*   **Thao tác 2:** Truy cập `http://localhost:20001`.
*   **Thao tác 3 (CLICK CHÍNH XÁC):** 
    - Nhấp vào menu **`Graph`** ở thanh điều hướng trái.
    - Ở ô Select Namespace phía trên, **nhấp chọn `dev`**.
    - Ở mục Graph Type, **nhấp chọn `App graph`** để gom nhóm ứng dụng.
*   **Thuyết minh:** *"Chào mừng thầy cô tới Video 6. Em đã truy cập Kiali để quan sát và kiểm chứng mạng dịch vụ mesh của namespace `dev`."*

### Bước 2: Trình diễn Sơ đồ Topology & Kích hoạt Traffic Flow Động (Yêu cầu 1 & 2)
*   **Thao tác 1 (BẬT CÁC CHẾ ĐỘ HIỂN THỊ LƯU LƯỢNG):**
    - Nhấp chuột vào nút thả xuống **`Display`** ở thanh menu trên cùng đồ thị.
    - **Tích chọn `Security`** (hiển thị khóa mTLS).
    - **Tích chọn `Traffic Animation`** (hiệu ứng luồng động).
    - **Tích chọn `Request Rate`** (hiển thị số req/s trên đường truyền).
*   **Thao tác 2:** Mở Terminal và bắn traffic liên tục:
    ```bash
    POD=$(kubectl get pods -n dev -l app.kubernetes.io/name=cart -o jsonpath='{.items[0].metadata.name}')
    for i in $(seq 1 20); do
        kubectl exec -n dev "$POD" -c cart -- curl -s http://product.dev.svc.cluster.local/actuator/health > /dev/null
        echo "Bắn Request $i..."
        sleep 0.3
    done
    ```
*   **Thao tác 3 (DEMO BIỂU ĐỒ TRÊN KIALI):**
    - Chờ đồ thị sáng lên với các mũi tên chuyển động.
    - **Nhấp chuột trực tiếp vào mũi tên (đường nối - Edge) giữa Cart và Product**.
    - Ngay lập tức nhìn sang Bảng Thông Tin (Side Panel) hiện ra bên phải màn hình.
    - **Chỉ chuột vào biểu đồ động `Inbound Traffic` và `HTTP - Request Percentiles`**.
*   **Thuyết minh:** *"Hãy xem Kiali đã phát sáng rực rỡ! Biểu tượng **Khóa Vàng** xác nhận mTLS STRICT đã bật thành công cho Yêu cầu 1. Trên đường truyền, tốc độ request hiển thị rõ rệt (ví dụ: 3.3 reqs/sec). Đặc biệt, khi em click chọn đường nối này, bảng điều khiển bên phải lập tức vẽ biểu đồ phân phối băng thông động thời gian thực. Sơ đồ Topology hoàn chỉnh và động 100% cho Yêu cầu 2!"*

### Bước 3: Tích hợp Distributed Tracing trực tiếp trên Kiali (ĐỈNH CAO THUYẾT TRÌNH)
*   **Thao tác 1:** Nhấp chuột chọn **Node hình tròn mang tên `product`** trên đồ thị.
*   **Thao tác 2:** Tại cửa sổ chi tiết ở góc phải, **nhấp vào tab `Traces`**.
*   **Thao tác 3:** Bấm vào nút **`Run Query`** hiện ra.
*   **Thao tác 4:** Một danh sách các dấu chấm xanh (Spans) hiện ra. Nhấp chọn một chấm bất kỳ để hiện sơ đồ Gantt chart của vết request ngay bên dưới.
*   **Thuyết minh:** *"Không chỉ dừng lại ở đó, Kiali còn tích hợp sâu rộng với Tempo. Em click vào node Product, mở tab Traces và tải dữ liệu. Toàn bộ các vết request được phân bổ trực tiếp ngay tại giao diện Mesh, giúp DevOps phát hiện sự cố mạng cực kỳ chuyên nghiệp."*

### Bước 4: Thực chiến Kịch bản Test Authorization Policy (Yêu cầu 3)
*   **Thuyết minh:** *"Tiếp theo là kịch bản test phân quyền bảo mật AuthorizationPolicy."*

#### 🛡️ Kịch bản 4A: Chặn Pod lạ (Denied Case - HTTP 403)
*   **Thao tác:** Chạy Pod lạ và cố ý curl sang Product:
    ```bash
    kubectl -n dev run curl-unauthorized --image=curlimages/curl --restart=Never -- sleep 3600
    # Thực hiện lệnh curl sau khi pod running
    kubectl -n dev exec curl-unauthorized -- curl -i http://product.dev.svc.cluster.local/actuator/health
    ```
*   **Thuyết minh:** *"Em dùng pod curl-unauthorized lạ. Kết quả trả về chuẩn xác là **`HTTP/1.1 403 Forbidden`** cùng thông báo RBAC access denied. Mesh chặn rất nghiêm!"*

#### 🔍 Đọc LOGS Envoy Sidecar (Xem chặn thực tế)
*   **Thao tác:** Đọc logs của proxy container nằm ngay trong Pod để chỉ ra bằng chứng thép:
    ```bash
    kubectl logs -n dev -l app.kubernetes.io/name=product -c istio-proxy --tail=30 | grep "RBAC"
    ```
*   **Thuyết minh:** *"Em kiểm tra log của container `istio-proxy` ngay tại cửa ngõ Pod Product. Dòng log 'RBAC: access denied' xuất hiện rõ nét, ghi lại bằng chứng thép hệ thống đã ngăn chặn thành công."*

#### ✅ Kịch bản 4B: Cho phép Pod whitelist (Allowed Case - HTTP 200)
*   **Thao tác:** Dùng chính pod Cart chuẩn để gọi Product:
    ```bash
    kubectl exec -n dev "$POD" -c cart -- curl -i http://product.dev.svc.cluster.local/actuator/health
    ```
*   **Thuyết minh:** *"Đứng tại Pod Cart chính chủ, kết quả trả về là **`HTTP/1.1 200 OK`**. Rất trơn tru và tuyệt đối an toàn."*
*   **Thao tác phụ:** Dọn dẹp pod test: `kubectl -n dev delete pod curl-unauthorized`.

### Bước 5: Giải trình Cấu hình Retry Policy
*   **Thao tác:** In YAML VirtualService của Product để show cấu hình thực tế:
    ```bash
    kubectl get virtualservice product -n dev -o yaml | grep -A 5 "retries:"
    ```
*   **Thuyết minh:** *"Về Yêu cầu Retry khi lỗi 500, em in file YAML cấu hình thực tế. Block `retries` khai báo rõ: thử lại tối đa `attempts: 3` lần, chờ mỗi lần 2 giây khi gặp mã lỗi 5xx. Sidecar Proxy sẽ gánh vác trách nhiệm tự động thử lại cho hệ thống, tăng cường tối đa khả năng chịu lỗi."*

---

## 🏁 TỔNG KẾT KẾT THÚC TOÀN BỘ VIDEO DEMO
*   **Thuyết minh:** *"Nhóm em đã chứng minh thành công 100% các yêu cầu từ cơ bản đến cực kỳ nâng cao của đồ án, kết hợp nhuần nhuyễn K3s, GitHub Actions, ArgoCD, Grafana Observability và Istio Service Mesh. Em xin chân thành cảm ơn sự lắng nghe của thầy cô!"*
