# Checklist tự review — chạy TRƯỚC khi báo cáo

Đọc lại từng dòng code vừa viết và tick từng mục. **Có mục nào fail → sửa ngay, đừng báo cáo.**

---

## 1. Quy trình (fail ở đây là nghiêm trọng nhất)

- [ ] Đã **phỏng vấn Cecilia trước khi viết dòng code đầu tiên**
- [ ] Không đụng file nào nằm ngoài phạm vi đã thống nhất
- [ ] Không thêm dependency nào mà chưa hỏi
- [ ] Không tạo file thừa (README, docs, example, migration guide không được yêu cầu)
- [ ] Không đổi công nghệ/thư viện đang dùng trong dự án
- [ ] Không xoá file/bảng/endpoint nào mà chưa hỏi

## 2. Ngôn ngữ & đặt tên

- [ ] Định danh tiếng Anh, comment tiếng Việt
- [ ] **Mọi file có hậu tố vai trò**, dấu phân cách theo chuẩn ngôn ngữ:
      TS `kebab-case` (`user-profile.service.ts`) · Python `snake_case` (`user_profile_service.py`) · Java `PascalCase` (`UserProfileService.java`)
- [ ] Không có tên vô nghĩa: `data`, `temp`, `res2`, `obj`, `doStuff`
- [ ] Boolean có tiền tố `is/has/can/should`
- [ ] `errorCode` là `UPPER_SNAKE_CASE`, có ngữ cảnh, nằm trong catalog chung

## 3. Comment

- [ ] Mỗi comment giải thích **tại sao**, không giải thích **cái gì**
- [ ] Không có comment lặp lại điều code đã nói
- [ ] Không có docstring/JSDoc sinh hàng loạt cho hàm hiển nhiên
- [ ] Không còn code bị comment-out
- [ ] `TODO`/`FIXME` còn lại đều đã được **khai báo trong báo cáo**

## 4. Cấu trúc hàm

- [ ] Không hàm nào vượt ~30 dòng mà chưa tách
- [ ] Mỗi hàm làm đúng một việc
- [ ] Early return / guard clause; không lồng điều kiện quá 2 tầng
- [ ] Không quá 3 tham số rời (nhiều hơn thì gom object)
- [ ] Không boolean flag làm tham số điều khiển nhánh
- [ ] Không mutate tham số đầu vào

## 5. Type

- [ ] **Không có `any`** (TS) / `Dict[str, Any]` cho payload có cấu trúc (Python) / `Map<String,Object>` DTO (Java)
- [ ] Không dùng `as` / cast bừa để qua mặt compiler
- [ ] Type hint đầy đủ cho tham số và return (Python)
- [ ] Không raw generic type (Java); `Optional<T>` thay vì trả `null`
- [ ] Dữ liệu từ ngoài đã qua lớp validate trước khi thành type nội bộ

## 6. SOLID & mức abstraction

- [ ] Không có interface nào chỉ có 1 implementation mà **không** phải để bọc hạ tầng
- [ ] Không có factory/builder/strategy dựng ra cho việc đơn giản
- [ ] Class không phình ra nhiều trách nhiệm không liên quan
- [ ] Tầng trong không phụ thuộc tầng ngoài (domain không import framework/ORM)

## 7. Repository & dữ liệu

- [ ] Service **không** chứa QueryBuilder / Session / EntityManager / raw SQL
- [ ] Interface repository ở tầng trong, implementation ở infrastructure
- [ ] Method repository đặt tên theo ý định nghiệp vụ
- [ ] Repository không trả object thô của ORM lên tầng trên
- [ ] Transaction do tầng application quyết định, không do repository tự mở
- [ ] Có migration nếu schema thay đổi
- [ ] Không N+1 query trong vòng lặp

## 8. Hạ tầng đã bọc

- [ ] Business code không `import` SDK bên ngoài (kafka, redis, axios, s3, stripe...)
- [ ] Interface đặt tên theo nghiệp vụ, đổi công nghệ không phải sửa interface
- [ ] Adapter dịch lỗi SDK → exception của mình
- [ ] Mọi lời gọi ra ngoài có **timeout**
- [ ] `process.env` / `os.environ` chỉ xuất hiện trong module config
- [ ] `Date.now()` / `random()` / `uuid()` được inject, không gọi thẳng trong business logic

## 9. API & lỗi

- [ ] Response đúng envelope `{success, data, message, errorCode, requestId, timestamp}`
- [ ] Envelope do interceptor/filter chung sinh ra, không do controller tự bọc
- [ ] `requestId` có trong cả body lẫn header, lấy từ context (không truyền tay)
- [ ] Custom exception theo domain, không ném `Error`/`RuntimeException` trần
- [ ] Một global handler duy nhất; controller không try/catch để format lỗi
- [ ] Không `catch {}` rỗng, không nuốt lỗi
- [ ] Lỗi 5xx không lộ stack trace / SQL / tên bảng / đường dẫn file ra client
- [ ] Entity không bị nhận trực tiếp từ body, không bị trả thẳng ra response
- [ ] DTO response không chứa field nhạy cảm

## 10. Bảo mật

- [ ] Validate khai báo trên DTO, có `whitelist` loại field lạ
- [ ] Kiểm quyền sở hữu tài nguyên (chống IDOR), không chỉ kiểm vai trò
- [ ] SQL tham số hoá; cột `sort`/`filter` động lấy từ whitelist cố định
- [ ] Không hardcode secret; không có default cho secret
- [ ] `pageSize` và độ dài chuỗi/mảng có trần cứng

## 11. Logging

- [ ] Log có cấu trúc (JSON), message tiếng Anh
- [ ] Mỗi dòng log có `requestId` (tự động từ context)
- [ ] Dữ liệu nhạy cảm bị che ở tầng logger, không dựa vào việc nhớ xoá
- [ ] Không log trong vòng lặp nóng, không log từng bước nhỏ của một hàm
- [ ] Lỗi được log kèm đủ ngữ cảnh để tra lại

## 12. Test

- [ ] Có unit test cho service/use case vừa viết
- [ ] Mock repository và mọi external, không chạm hạ tầng thật
- [ ] Phủ happy path + mọi nhánh ném exception + biên (rỗng/null/0/âm)
- [ ] Tên test mô tả hành vi (`should reject refund when order already settled`)
- [ ] Arrange–Act–Assert rõ ràng
- [ ] Không assert vào chi tiết implementation
- [ ] Test **chạy pass thật**, không phải "chắc là pass"

## 13. Bất đồng bộ & hiệu năng

- [ ] Nhất quán một phong cách async
- [ ] Việc độc lập chạy song song, không `await` tuần tự trong vòng lặp
- [ ] Retry chỉ cho thao tác idempotent, có backoff và giới hạn
- [ ] Không chặn event loop bằng thao tác nặng đồng bộ

## 14. Microservices (bỏ qua nếu là monolith)

- [ ] Không service nào truy cập trực tiếp DB của service khác
- [ ] Consumer idempotent, chống xử lý lặp bằng `eventId`
- [ ] Event chỉ thêm field, không xoá/đổi kiểu; có `eventVersion`
- [ ] `requestId`/`traceId` truyền xuyên qua broker/gRPC/TCP
- [ ] Lời gọi đồng bộ giữa service có timeout + circuit breaker
- [ ] Ghi DB + publish event dùng outbox pattern (không publish trong transaction DB)
- [ ] Có dead-letter queue và chiến lược xử lý message chết

## 15. Báo cáo

- [ ] Ngắn gọn ở đầu (1–2 câu + danh sách file), checklist ở sau
- [ ] Không dán lại code trong báo cáo
- [ ] Đã liệt kê giả định tự quyết
- [ ] Đã liệt kê rõ việc **chưa** làm + lý do
- [ ] Đã nêu biến môi trường / secret / migration mới nếu có
- [ ] Có lệnh chạy thử cụ thể
- [ ] Trả lời bằng đúng ngôn ngữ Cecilia đang dùng
