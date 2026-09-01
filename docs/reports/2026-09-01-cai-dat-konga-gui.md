# Báo cáo: Cài Konga GUI để quan sát cấu hình Kong (read-only) vào docker-compose local

**Trạng thái:** Xong — Konga chạy được ở `http://127.0.0.1:1337`, kết nối Admin API thành công.
**Ngày:** 2026-09-01 · **Phạm vi:** `docker-compose.yml` (thêm 2 service, 1 volume, override env cho 2 node Kong). Không đụng `kong.conf`.

## 1. Cần bạn quyết định / xác nhận

- **[✓ Đã kiểm chứng] Bug có sẵn, chưa sửa:** HEALTHCHECK trong `Dockerfile` dùng `curl -sf http://127.0.0.1:8100/status`, nhưng image runtime (`kong:3.9.0` + plugin) **không có curl**. Kết quả: 2 node Kong báo `unhealthy` dù gateway vẫn chạy tốt. Đây là bug nằm sẵn trong repo, không phải do việc cài Konga. **Cần bạn quyết có muốn tôi sửa không** (đổi `curl` → `wget`, hoặc cài curl vào image).
- **[✓ Đã kiểm chứng] Nới nhẹ SEC-GW-14:** để Konga đọc được Admin API, tôi set `KONG_ADMIN_LISTEN: 0.0.0.0:8001` cho 2 node Kong **chỉ trong mạng nội bộ Docker** (cổng 8001 vẫn không publish ra host). `kong.conf` vẫn giữ `127.0.0.1:8001`. Cần bạn xác nhận chấp nhận cách này (nới lỏng trong local, giữ nguyên production).
- **[~ Suy luận] Konga 0.14.9 không còn bảo trì** (phát hành 2021, image cuối cùng). Nên chỉ giữ ở local để xem; nếu bạn muốn một GUI được bảo trì cho môi trường thật, cần chọn giải pháp khác.

## 2. Kết quả

| Việc | Trạng thái | Bằng chứng |
|---|---|---|
| Konga chạy, UI phục vụ | Xong | `curl -sL -o /dev/null -w '%{http_code}' http://127.0.0.1:1337/` → `200` |
| Konga → Admin API Kong | Xong | `wget -q -O - http://kong-node-1:8001/` trả JSON `{"node_id":...}` |
| Tự tạo schema (prepare) khi khởi động | Xong | log có `Preparing database...` + `Database migrations completed!` |
| Tái lập trên máy mới (wipe volume → up) | Xong | đã `docker volume rm` + recreate, Konga vẫn lên xanh |
| Sửa cấu hình qua Konga | Không làm được (bản chất) | Kong DB-less → Admin API read-only, Konga chỉ đọc |

## 3. Cách bạn tự kiểm chứng

Đã chạy và thấy kết quả thật:

```
curl -sL -o /dev/null -w 'HTTP %{http_code}\n' http://127.0.0.1:1337/        # 200
docker compose ps                                                            # konga + konga-db (healthy)
docker exec taca-api-gateway-konga-1 sh -c 'wget -q -O - http://kong-node-1:8001/'  # JSON topology Kong
```

Tự kiểm bằng tay: mở `http://127.0.0.1:1337` → đăng ký tài khoản admin (Konga không seed user mặc định, bảng `konga_users` rỗng) → thêm Connection URL `http://kong-node-1:8001` → xem danh sách Routes/Services/Plugins.

Lưu ý: `docker compose ps` vẫn hiển thị `kong-node-*` là `unhealthy` — đây là bug `curl` ở mục 1, không liên quan Konga. Gateway vẫn trả `200` cho `/health/live`.

## 4. Chi tiết đã làm

### 4.1 Bảng file thay đổi

| File | Loại | Thay đổi | Vì sao |
|---|---|---|---|
| `docker-compose.yml` | Sửa | Thêm service `konga` (pantsel/konga:0.14.9), port `127.0.0.1:1337` | GUI quan sát |
| `docker-compose.yml` | Sửa | Thêm service `konga-db` (mysql:5.7) + volume `konga-db-data` | Konga 0.14.9 bắt buộc có DB riêng |
| `docker-compose.yml` | Sửa | Override `KONG_ADMIN_LISTEN: 0.0.0.0:8001` cho `kong-node-1` và `kong-node-2` | Konga cần đọc Admin API qua mạng nội bộ |

### 4.2 Thay đổi logic đáng chú ý

- **Konga tự chạy `prepare` trước khi nâng app**, qua `entrypoint: ["/bin/sh","-c"]` + `command` dạng list một phần tử. Lý do phải dùng list (không dùng string): compose split string theo khoảng trắng làm hỏng `&&`, khiến `sh -c` chỉ nhận `/app/start.sh` mà không có tham số → bỏ qua prepare. Image Konga có `ENTRYPOINT=/app/start.sh` nên phải override cả entrypoint.
- **Chọn MySQL 5.7 thay vì Postgres**: Konga 0.14.9 bó driver `pg` quá cũ, không hợp Postgres 16 (lỗi `Unknown authenticationOk message type`) lẫn Postgres 12 (`sails-postgresql` collections undefined). MySQL 5.7 là backend được test kỹ nhất cho bản này.
- **Override nằm ở compose local, không đụng `kong.conf`**: file production vẫn `admin_listen = 127.0.0.1:8001`. Override `KONG_ADMIN_LISTEN` là biến môi trường ghi đè lúc chạy, chỉ áp trong `docker-compose.yml` (file vốn đã ghi "KHÔNG dùng cho production").

### 4.3 Những gì cố ý KHÔNG làm

- **Không sửa bug `curl` trong HEALTHCHECK** — nằm ngoài phạm vi cài Konga, để bạn quyết (mục 1).
- **Không dùng Postgres cho Konga** dù sạch hơn về hạ tầng — vì driver cũ của Konga không chạy được; chọn cái chạy được thay vì cái "đúng lý thuyết".
- **Không publish cổng 8001 ra host** — giữ đúng tinh thần SEC-GW-14 (Admin API không lộ ra host/ingress).

## 5. Lý do & đánh đổi

**Konga cần DB riêng là bắt buộc, không phải lựa chọn.** Ban đầu tôi thử adapter `local` (không cần DB) cho đúng ý "không cần database", nhưng bản 0.14.9 đã bỏ adapter này → lỗi `references a datastore which cannot be found (local)`. Vậy nên phải kèm một DB riêng; chọn MySQL 5.7 vì là backend tương thích duy nhất với driver đóng băng trong image. Đánh đổi: thêm 1 container MySQL (~370MB image, chỉ phục vụ Konga) vào môi trường local — cái giá của việc dùng một GUI đã ngừng bảo trì.

**Tự động `prepare` trong `command` thay vì chạy tay.** Nếu không nhúng, máy mới clone về chạy `make up` sẽ dính lại lỗi `Table 'konga.konga_users' doesn't exist`. Nhúng `prepare` (idempotent, create-if-not-exists) vào command làm cho việc cài trở nên tái lập được, đổi lại là chuỗi `entrypoint`/`command` kém tự nhiên hơn bình thường.

## 6. Rủi ro & tác động

- **Bảo mật — nới rộng bề mặt Admin API (Thấp).** Kịch bản: container khác trên cùng mạng `taca-gateway` giờ có thể gọi `kong-node-1:8001` (đọc topology). Giảm thiểu: 8001 không publish ra host, Admin API ở DB-less vốn read-only, và đây chỉ là môi trường local.
- **Nợ kỹ thuật — image không bảo trì (Thấp, local-only).** Konga 0.14.9 dùng Node 12 cũ, có thể có CVE. Giảm thiểu: chỉ bind loopback `127.0.0.1:1337`, không dùng cho production.
- **Nhầm lẫn trạng thái — node Kong báo `unhealthy` (Trung bình).** Bug `curl` có sẵn làm `docker compose ps` hiển thị sai, dễ khiến người khác tưởng gateway hỏng. Không do thay đổi này gây ra nhưng nên xử lý để tránh hiểu nhầm.

## 7. Phụ lục

Lệnh `prepare` thủ công (nếu cần chạy tách, không qua compose):

```
docker run --rm --network taca-gateway --entrypoint /app/start.sh pantsel/konga:0.14.9 \
  -c prepare -a mysql -u mysql://konga:konga@konga-db:3306/konga
```
