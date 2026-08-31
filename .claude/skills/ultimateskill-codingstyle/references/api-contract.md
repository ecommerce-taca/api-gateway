# Contract API — envelope, lỗi, requestId

---

## 1. Envelope response — bắt buộc, mọi endpoint

**Mọi** response HTTP đều bọc trong envelope này. Không có ngoại lệ, kể cả `204`-style thao tác không trả dữ liệu (dùng `data: null`).

### Thành công

```json
{
  "success": true,
  "data": { "id": "usr_01H8X", "email": "cecilia@example.com" },
  "message": "OK",
  "errorCode": null,
  "requestId": "req_01H8XKPM3QF9",
  "timestamp": "2026-08-30T09:14:22.117Z"
}
```

### Thất bại

```json
{
  "success": false,
  "data": null,
  "message": "Không tìm thấy người dùng",
  "errorCode": "USER_NOT_FOUND",
  "requestId": "req_01H8XKPM3QF9",
  "timestamp": "2026-08-30T09:14:22.117Z"
}
```

### Lỗi validate — `data` chứa chi tiết từng field

```json
{
  "success": false,
  "data": {
    "fields": [
      { "field": "email",    "code": "INVALID_FORMAT", "message": "Email không hợp lệ" },
      { "field": "password", "code": "TOO_SHORT",      "message": "Mật khẩu tối thiểu 8 ký tự" }
    ]
  },
  "message": "Dữ liệu không hợp lệ",
  "errorCode": "VALIDATION_FAILED",
  "requestId": "req_01H8XKPM3QF9",
  "timestamp": "2026-08-30T09:14:22.117Z"
}
```

### Danh sách có phân trang — `data` giữ 2 khoá cố định

```json
{
  "success": true,
  "data": {
    "items": [],
    "pagination": { "page": 1, "pageSize": 20, "totalItems": 137, "totalPages": 7 }
  },
  "message": "OK",
  "errorCode": null,
  "requestId": "req_01H8XKPM3QF9",
  "timestamp": "2026-08-30T09:14:22.117Z"
}
```

### Quy tắc về các trường

| Trường | Kiểu | Quy tắc |
|---|---|---|
| `success` | boolean | `true` ⟺ HTTP 2xx. Không bao giờ `success: true` kèm status 4xx/5xx |
| `data` | object \| array \| null | `null` khi lỗi. Không nhét message vào đây |
| `message` | string | Dành cho **người đọc**. Có thể i18n. Không phải để code parse |
| `errorCode` | string \| null | Dành cho **máy đọc**. `null` khi thành công. `UPPER_SNAKE_CASE` |
| `requestId` | string | **Luôn có**, kể cả thành công. Xem §3 |
| `timestamp` | string | ISO 8601 UTC, có mili giây |

**Quan trọng:** envelope được sinh bởi **interceptor / filter dùng chung**, không phải do từng
controller tự bọc. Controller trả về `data` thuần, hạ tầng bọc lại.

---

## 2. Mã lỗi — `errorCode`

Quy ước: `<DOMAIN>_<TÌNH_HUỐNG>`, chữ hoa, gạch dưới. Đọc là hiểu, không cần tra bảng.

| errorCode | HTTP | Khi nào |
|---|---|---|
| `VALIDATION_FAILED` | 400 | Input sai định dạng/thiếu field |
| `UNAUTHENTICATED` | 401 | Không có/hết hạn token |
| `PERMISSION_DENIED` | 403 | Có danh tính nhưng không đủ quyền |
| `USER_NOT_FOUND` | 404 | Không tìm thấy tài nguyên |
| `EMAIL_ALREADY_EXISTS` | 409 | Xung đột dữ liệu |
| `ORDER_ALREADY_PAID` | 409 | Xung đột trạng thái |
| `INSUFFICIENT_BALANCE` | 422 | Vi phạm rule nghiệp vụ |
| `RATE_LIMIT_EXCEEDED` | 429 | Quá giới hạn gọi |
| `INTERNAL_ERROR` | 500 | Lỗi không lường trước |
| `PAYMENT_GATEWAY_UNAVAILABLE` | 502 | Đối tác lỗi |
| `SERVICE_TIMEOUT` | 504 | Gọi ra ngoài quá hạn |

Quy tắc:

- Tập hợp `errorCode` sống trong **một file catalog duy nhất** (enum/const), không rải rác string literal.
- Mỗi `errorCode` gắn cứng một HTTP status. Cùng code mà lúc 400 lúc 409 là bug.
- **Không đổi `errorCode` đã public** — client đang if theo nó. Muốn đổi phải hỏi.
- Lỗi 5xx: `message` chỉ nói chung chung, **không lộ** stack trace, câu SQL, tên bảng, đường dẫn file.
  Chi tiết nằm trong log, tra bằng `requestId`.

---

## 3. `requestId` — xương sống của việc truy vết

Cecilia yêu cầu cụ thể trường này: *"requestID để theo dõi lỗi hay thông tin"*.

### Luồng

```
Client / Gateway
   │  header: X-Request-Id (nếu có)
   ▼
Middleware  ── có header? dùng lại : sinh mới (uuid v7 / ulid)
   │         ── lưu vào context xuyên suốt request
   │            (AsyncLocalStorage · contextvars · MDC)
   ├─► mọi dòng log của request này đều mang requestId
   ├─► mọi lời gọi HTTP ra ngoài đính header X-Request-Id
   ├─► mọi message publish đính requestId vào header của message
   ▼
Response  ── envelope.requestId + header X-Request-Id
```

### Yêu cầu bắt buộc

- Sinh ở **biên vào** (middleware), không sinh trong service.
- Truyền ngầm qua context, **không** truyền thủ công qua tham số hàm.
  - NestJS/Node: `AsyncLocalStorage`
  - Python: `contextvars`
  - Java: `MDC` (nhớ propagate khi sang thread khác / `@Async`)
- Trả cả trong **body** (envelope) lẫn **header** `X-Request-Id`.
- Trong microservices: `requestId` đi xuyên toàn hệ, kể cả qua Kafka/RabbitMQ/gRPC/TCP.
  Một `requestId` phải truy được toàn bộ hành trình.
- Nếu dự án có OpenTelemetry: dùng `traceId` làm `requestId` để nối được với tracing backend.

---

## 4. REST — quy ước endpoint

- Đường dẫn: danh từ **số nhiều**, kebab-case: `/api/v1/user-profiles/{id}/orders`
- Có version trong path: `/api/v1/...`. Breaking change → tăng version, không sửa tại chỗ.
- Method: `GET` (đọc, không side effect) · `POST` (tạo/hành động) · `PATCH` (sửa một phần) ·
  `PUT` (thay toàn bộ) · `DELETE` (xoá).
- Status: `200` OK · `201` tạo mới · `202` nhận để xử lý bất đồng bộ · `204` **không dùng**
  (vì luôn phải có envelope → dùng `200` + `data: null`).
- Phân trang qua query: `?page=1&pageSize=20&sort=createdAt:desc`. `pageSize` có trần cứng (vd 100).
- Lọc qua query có tên rõ: `?status=ACTIVE&createdFrom=2026-01-01`.
- **Idempotency**: thao tác tạo có tác dụng phụ tiền bạc → nhận header `Idempotency-Key`.
- Hành động không map được vào CRUD → `POST /orders/{id}/cancel`, đừng bẻ cong REST.

---

## 5. DTO — biên vào và biên ra

- **Không bao giờ** nhận entity trực tiếp từ request body, và **không bao giờ** trả entity ra response.
  Luôn có DTO riêng cho mỗi chiều.
- DTO request có **validate khai báo ngay trên nó** (class-validator / Pydantic / Bean Validation).
- DTO response chỉ chứa field cần lộ. Field nhạy cảm (`passwordHash`, `internalNote`, `costPrice`)
  không được có mặt trong DTO response — đây là cách chống rò rỉ ở mức cấu trúc, không dựa vào việc "nhớ xoá".
- Mapping entity ↔ DTO nằm trong mapper riêng (MapStruct / hàm `toDto` / Pydantic `model_validate`),
  không nhét trong controller.
- Field ngày giờ: ISO 8601 UTC. Tiền: số nguyên đơn vị nhỏ nhất (cent/đồng) + `currency`, **không dùng float**.
- Id: string. Không lộ id tự tăng của DB ra ngoài nếu có yêu cầu bảo mật (dùng uuid/ulid).

---

## 6. Contract giữa các service (microservices)

Ngoài REST, mỗi kênh có contract riêng:

### Event (Kafka / RabbitMQ / NATS)

```json
{
  "eventId": "evt_01H8XKPM3QF9",
  "eventType": "billing.invoice.created",
  "eventVersion": 1,
  "occurredAt": "2026-08-30T09:14:22.117Z",
  "requestId": "req_01H8XKPM3QF9",
  "producer": "billing-service",
  "payload": { }
}
```

- `eventType` = `<domain>.<entity>.<action>`, quá khứ (đã xảy ra rồi).
- **Chỉ thêm field, không xoá/đổi kiểu.** Breaking change → tăng `eventVersion`, chạy song song hai version.
- Consumer phải **idempotent** — dựa vào `eventId` để chống xử lý lặp.
- Payload chứa đủ dữ liệu để consumer làm việc, không bắt consumer gọi ngược lại producer.

### gRPC

- File `.proto` là nguồn sự thật, để trong thư mục dùng chung hoặc repo contract riêng.
- Chỉ thêm field mới với số thứ tự mới. **Không tái sử dụng số field đã bỏ** — đánh dấu `reserved`.
- Lỗi dùng gRPC status code chuẩn, kèm `errorCode` của mình trong metadata/detail.
- `requestId` truyền qua metadata.

### REST nội bộ / TCP

- Vẫn dùng đúng envelope ở §1 để đồng nhất toàn hệ.
- Bắt buộc timeout + circuit breaker. Xem `<ngôn ngữ>/microservices.md`.

---

## 7. Tài liệu API

- Sinh từ code (OpenAPI/Swagger qua decorator, springdoc, FastAPI tự động) — **không viết tay file yaml rời**,
  nó sẽ lệch với code trong hai tuần.
- Mỗi endpoint khai báo: mô tả ngắn, các `errorCode` có thể trả, ví dụ request/response.
- Không tự sinh trang tài liệu/README bổ sung nếu Cecilia không yêu cầu.
