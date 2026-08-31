# Bảo mật, validate, logging & observability

---

## PHẦN A — VALIDATE & BẢO MẬT

## A1. Validate ở biên, tin tưởng ở trong

Mọi dữ liệu từ ngoài process đều **không đáng tin** cho tới khi qua một lớp validate:
HTTP body/query/param/header, message từ queue, response từ đối tác, biến môi trường, file upload.

- Validate bằng **khai báo trên DTO**, không viết `if` thủ công rải rác trong service.
  - NestJS: `class-validator` + `ValidationPipe({ whitelist: true, forbidNonWhitelisted: true, transform: true })`
  - Python: Pydantic v2 model
  - Java: Bean Validation (`@Valid`, `@NotBlank`, `@Size`, custom constraint)
- `whitelist` bắt buộc: field lạ bị **loại bỏ**, không âm thầm đi tiếp (chống mass-assignment).
- Sau lớp validate, service được quyền tin type — không validate lại lần hai cho cùng một thứ.
- **Rule nghiệp vụ khác validate cú pháp.** "Email đúng định dạng" là validate. "Email chưa tồn tại"
  là rule nghiệp vụ → nằm ở service, ném `ConflictException`.

### Luôn phải kiểm

| Kiểm | Vì sao |
|---|---|
| Độ dài chuỗi có trần | Chống payload khổng lồ |
| Số có min/max | Chống số âm, tràn |
| Enum là enum thật | Không nhận string tuỳ ý |
| Mảng có giới hạn phần tử | Chống DoS qua vòng lặp |
| `pageSize` có trần cứng | Chống rút cạn DB |
| File upload: mime + dung lượng + đuôi | Chống upload mã độc |
| Ngày tháng hợp lệ, khoảng hợp lệ | `from` không lớn hơn `to` |

---

## A2. Auth & phân quyền

- **Authentication** (anh là ai) và **authorization** (anh được làm gì) là hai lớp tách biệt.
- Kiểm quyền ở tầng có đủ ngữ cảnh:
  - Quyền theo vai trò → guard/decorator ở controller.
  - Quyền theo dữ liệu ("chỉ chủ sở hữu đơn hàng") → **service layer**, vì chỉ ở đó mới biết chủ sở hữu là ai.
- **Chống IDOR** — lỗ hổng phổ biến nhất: luôn kiểm tra tài nguyên có thuộc về người gọi không.

```ts
// ❌ Ai biết id là xem được
const order = await this.orderRepo.findById(id);

// ✅ Ràng buộc quyền sở hữu ngay trong truy vấn
const order = await this.orderRepo.findByIdAndOwner(id, currentUser.id);
if (!order) throw new NotFoundException('ORDER_NOT_FOUND'); // 404, không phải 403 — không lộ sự tồn tại
```

- Token: JWT ngắn hạn + refresh token, refresh token thu hồi được (lưu server-side).
- Không bao giờ đưa dữ liệu nhạy cảm vào JWT payload — nó chỉ được ký, **không được mã hoá**.
- Service-to-service: mTLS hoặc token nội bộ có scope. **Không** tin header `X-User-Id` do client gửi.

---

## A3. Secret & dữ liệu nhạy cảm

- Không hardcode secret, key, connection string, token. Không có giá trị mặc định cho secret.
- Secret đọc qua module config (xem `infrastructure-abstraction.md` §5), validate lúc boot, thiếu là chết ngay.
- `.env` nằm trong `.gitignore`. `.env.example` chỉ chứa key + giá trị giả.
- Mật khẩu: **bcrypt / argon2**, không bao giờ MD5/SHA tự chế. Không tự viết thuật toán mã hoá.
- PII (CMND, số thẻ, số điện thoại đầy đủ, địa chỉ) mã hoá at-rest nếu yêu cầu dự án đòi.
- Response DTO không chứa field nhạy cảm — chặn ở mức cấu trúc, không dựa vào "nhớ xoá".

---

## A4. Injection & các lỗ hổng khác

- SQL: luôn tham số hoá. **Cấm nối chuỗi** vào câu SQL, kể cả trong raw query nội bộ repository.
- Tên bảng/cột động: chỉ nhận từ **whitelist** cố định trong code, không từ input.
  (Đặc biệt là `sort` — `?sort=<cột>` là đường vào SQL injection kinh điển.)
- NoSQL: ép kiểu input trước khi đưa vào query object (chống operator injection `{$ne: null}`).
- Command injection: không nối input người dùng vào lệnh shell.
- SSRF: URL do người dùng cung cấp phải qua whitelist domain, chặn IP nội bộ.
- Path traversal: chuẩn hoá đường dẫn file, chặn `..`.
- CORS: liệt kê origin cụ thể, **không** `*` ở môi trường production có credentials.
- Rate limit ở gateway hoặc middleware cho endpoint đăng nhập / gửi OTP / tạo tài nguyên tốn kém.
- Bật security header cơ bản (helmet hoặc tương đương).
- Timing attack: so sánh token/chữ ký bằng hàm so sánh constant-time.

---

## PHẦN B — LOGGING & OBSERVABILITY

## B1. Log có cấu trúc, không log chuỗi thô

Log là JSON, để máy đọc và tìm kiếm được.

```ts
// ❌ Không grep nổi, không lọc nổi
console.log('User ' + userId + ' created order ' + orderId);

// ✅ Có cấu trúc, có ngữ cảnh
logger.info('order created', { userId, orderId, amount, requestId });
```

Trường bắt buộc mỗi dòng log:

| Trường | Ghi chú |
|---|---|
| `timestamp` | ISO 8601 UTC |
| `level` | debug / info / warn / error |
| `service` | tên service (quan trọng trong microservices) |
| `requestId` | tự động lấy từ context, **không truyền tay** |
| `message` | tiếng Anh, ngắn, viết thường, mô tả sự kiện |
| `context` | object các field liên quan |

Trong microservices thêm: `traceId`, `spanId`, `eventId` (khi xử lý message).

## B2. Log ở đâu, mức nào

| Mức | Dùng khi | Ví dụ |
|---|---|---|
| `debug` | Chi tiết chỉ bật khi điều tra | payload trung gian, giá trị tính toán |
| `info` | Sự kiện nghiệp vụ đáng ghi nhận | tạo đơn, thanh toán thành công, publish event |
| `warn` | Bất thường nhưng vẫn xử lý được | retry lần 2, fallback, dữ liệu thiếu nhưng có default |
| `error` | Thất bại cần người xem | exception không lường trước, đối tác chết, mất kết nối |

Vị trí log:

- **Biên vào**: một dòng mỗi request (method, path, status, thời gian) — do middleware làm, không log tay trong controller.
- **Biên ra**: mỗi lời gọi hạ tầng ngoài (HTTP, DB chậm, publish message) — do adapter làm.
- **Điểm quyết định nghiệp vụ quan trọng**: chuyển trạng thái, từ chối giao dịch, áp dụng khuyến mãi.

**Không** log:

- Trong vòng lặp nóng.
- Mỗi bước nhỏ của một hàm ("bắt đầu", "đã lấy user", "đã tính giá", "kết thúc") — đây là rác.
- Cả entity/response body chỉ để "cho chắc".

## B3. Che dữ liệu nhạy cảm — bắt buộc

Danh sách **cấm xuất hiện trong log dưới dạng rõ**:

password, passwordHash, token, accessToken, refreshToken, apiKey, secret, authorization header,
số thẻ đầy đủ, CVV, OTP, số CMND/CCCD, cookie phiên.

- Cài **redaction ở tầng logger wrapper**, theo danh sách key — không dựa vào việc từng developer nhớ.
- Cần log để đối chiếu → log dạng che: `user@***.com`, `****1234`, hoặc hash.
- Stack trace được log đầy đủ **ở server**, nhưng không bao giờ trả về client.

## B4. Nối chuỗi truy vết

- `requestId` xuyên suốt mọi tầng và mọi service (xem `api-contract.md` §3).
- Health check: `/health` (liveness) và `/health/ready` (readiness — kiểm DB, broker, cache).
  Liveness không được phụ thuộc DB, nếu không container sẽ bị restart vô nghĩa khi DB nghẽn.
- Metric tối thiểu nếu dự án có Prometheus/OTel: số request theo endpoint + status, độ trễ p95/p99,
  độ trễ lời gọi ra ngoài, lag của consumer, kích thước dead-letter queue.
- Không tự dựng dashboard/alert nếu Cecilia không yêu cầu — nhưng phải để lại điểm cắm (metric có tên rõ).

## B5. Bắt lỗi không lường trước

- Có handler cho `unhandledRejection` / `uncaughtException` (Node), `sys.excepthook` (Python),
  `UncaughtExceptionHandler` (Java) — log rồi thoát có kiểm soát.
- Graceful shutdown: nhận `SIGTERM` → ngừng nhận request/message mới → xử nốt việc đang chạy →
  đóng kết nối DB/broker → thoát. Đây là điều kiện để deploy không mất dữ liệu.
