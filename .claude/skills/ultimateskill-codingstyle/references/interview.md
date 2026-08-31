# Giao thức phỏng vấn — BẮT BUỘC trước mọi task

> Cecilia đã chọn rõ: **"Luôn hỏi, kể cả task nhỏ."**
> Không có ngoại lệ. Không có "task này hiển nhiên quá". Nếu bạn thấy task quá rõ để hỏi,
> bạn vẫn hỏi — chỉ là hỏi ít câu hơn.

---

## Nguyên tắc

1. **Hỏi trước, code sau.** Tuyệt đối không viết code, không tạo file, không sửa file trước khi Cecilia trả lời.
2. **Tối đa 4 câu một lượt.** Nhiều hơn thì chia thành nhiều vòng.
   *Ngoại lệ duy nhất:* danh sách chốt stack ở `python/README.md` §1 và `java/README.md` §1 —
   đó là các lựa chọn **liên quan chặt với nhau** (framework quyết định ORM, ORM quyết định migration),
   nên hỏi rời từng vòng sẽ khiến Cecilia trả lời hai lần. Với chúng, gửi **một bảng gộp**
   kèm sẵn một bộ khuyến nghị hoàn chỉnh, để Cecilia chỉ cần nói "ok" hoặc sửa vài dòng:

   > *Đề xuất stack: FastAPI + Pydantic v2 + SQLAlchemy 2.0 async + Alembic + uv + pytest, Python 3.11+.
   > Cecilia duyệt cả gói, hay muốn đổi mục nào?*
3. **Câu hỏi phải có phương án sẵn.** Đừng hỏi trống ("bạn muốn thế nào?"). Luôn đưa 2–4 lựa chọn cụ thể,
   và ghi rõ cái nào bạn khuyến nghị + vì sao (1 dòng).
4. **Chỉ hỏi cái bạn không tự trả lời được.** Thứ đã có trong `SKILL.md` §3 (mặc định đã chốt) hoặc
   đọc code trong repo là biết → **đọc, đừng hỏi**. Hỏi lại thứ đã chốt là làm phiền.
5. **Đọc repo trước khi hỏi.** Quét cấu trúc thư mục, file config, module tương tự đã có. Câu hỏi
   phải cho thấy bạn đã nhìn code, ví dụ: *"Thấy `order` module đang dùng envelope kiểu X, module mới
   theo y hệt chứ?"*
6. **Ngôn ngữ hỏi = ngôn ngữ Cecilia đang nhắn.** Thuật ngữ kỹ thuật giữ nguyên tiếng Anh.
7. **Nếu Cecilia trả lời mơ hồ hoặc bỏ qua một câu** → chọn phương án bạn khuyến nghị, ghi rõ vào
   mục "Giả định đã tự quyết" trong báo cáo, và làm tiếp. Đừng hỏi lại vòng hai cùng một câu.

---

## Vòng 1 — luôn hỏi (mọi task)

Chọn ra những câu **thực sự chưa rõ** trong nhóm dưới đây, gộp tối đa 4 câu:

### A. Phạm vi
- Task này chạm vào những file/module nào? Có file nào **cấm động** không?
- Đây là thêm mới, sửa hành vi hiện có, hay refactor thuần (không đổi hành vi)?
- Có deadline / mức độ "làm nhanh cho chạy" vs "làm chuẩn để dùng lâu" không?

### B. Ngữ cảnh kỹ thuật *(bỏ qua câu nào tự đọc repo ra được)*
- Ngôn ngữ/stack: Python (stack gì?), Java (stack gì?), NestJS (đã chốt TypeORM + Postgres).
- Kiến trúc: microservices hay không? (Nếu repo có sẵn thì tự xác định, chỉ xác nhận lại một dòng.)
- Với microservices: service này giao tiếp với service khác qua gì —
  **Kafka / RabbitMQ / NATS / gRPC / REST qua gateway / TCP**?

### C. Nghiệp vụ
- Input gì vào, output gì ra? Trường nào bắt buộc, trường nào optional?
- Các case lỗi cần xử lý riêng là gì? Mã lỗi (`errorCode`) đặt thế nào?
- Có ràng buộc nghiệp vụ ẩn nào không (unique, quyền, trạng thái hợp lệ, idempotency)?

### D. Dữ liệu
- Bảng/collection nào bị đụng? Có cần migration không?
- Có cần transaction bao nhiều thao tác không?

---

## Vòng 2 — hỏi khi dự án MỚI hoặc task lớn

- Quy mô dự kiến: CRUD đơn giản, hay nghiệp vụ phức tạp nhiều rule?
  → quyết định **modular gọn** vs **full DDD/Clean/Hexagonal**.
  Luôn kèm khuyến nghị của bạn: *"Nhìn yêu cầu tôi nghĩ modular là đủ, chưa cần domain layer riêng — Cecilia thấy sao?"*
- Auth/authz: có không? Cơ chế gì (JWT / session / API key / service-to-service token)?
- Có cần background job / scheduler / retry không?
- Môi trường triển khai: Docker? K8s? Cần Dockerfile + compose luôn không?
- Có convention nào của team đang áp mà tôi phải theo không (naming, branch, lint config)?

---

## Vòng 3 — hỏi khi có ĐIỂM PHẢI ĐÁNH ĐỔI

Không hỏi cho đủ số. Chỉ hỏi khi bạn thật sự đứng giữa hai hướng và cả hai đều hợp lý:

> *"Chỗ này có 2 cách:
> **(A)** ... — ưu: ..., nhược: ...
> **(B)** ... — ưu: ..., nhược: ...
> Tôi nghiêng về (A) vì ... Cecilia chốt giúp."*

**Bắt buộc phải hỏi, không được tự quyết:**

- Thêm bất kỳ thư viện / package / framework nào.
- Đổi schema DB theo cách phá vỡ dữ liệu cũ (drop/rename cột, đổi kiểu).
- Đổi contract API đã public (bỏ field, đổi kiểu, đổi status code).
- Thêm một service mới vào hệ microservices.
- Đổi cơ chế giao tiếp giữa các service.
- Xoá file, xoá bảng, xoá endpoint.
- Bất cứ thứ gì không thể hoàn tác dễ dàng.

---

## Cấu trúc một lượt hỏi tốt

```markdown
Trước khi code, tôi cần chốt vài điểm:

**Đã đọc repo và tự xác định được** (Cecilia chỉ cần nói "sai" nếu có gì lệch):
- Stack: NestJS 10 + TypeORM + Postgres, kiến trúc modular monolith
- Envelope response đang dùng ở `common/interceptors/response.interceptor.ts`
- Module tương tự gần nhất: `src/modules/order/`

**Cần Cecilia quyết:**
1. <câu hỏi> — (A) ... / (B) ... — tôi nghiêng về (A) vì ...
2. <câu hỏi> — ...
3. <câu hỏi> — ...
```

Ba phần này khiến câu hỏi ngắn mà vẫn đủ, và cho thấy bạn đã làm bài tập về nhà.

---

## Chống mẫu — đừng làm thế này

| Sai | Đúng |
|---|---|
| "Bạn muốn tôi làm thế nào?" | "(A) tạo module mới / (B) thêm vào module `user` sẵn có — tôi nghiêng (B) vì cùng aggregate." |
| Hỏi 12 câu một lượt | Tối đa 4 câu, ưu tiên câu chặn tiến độ nhất |
| Hỏi thứ đã ghi trong SKILL.md §3 | Đọc §3, dùng luôn |
| Hỏi xong không chờ, code luôn | Hỏi → **dừng** → chờ trả lời |
| "Tôi sẽ dùng Prisma nhé?" khi repo đang TypeORM | Không đề xuất đổi stack trừ khi Cecilia mở lời |
| Vừa hỏi vừa đã tạo sẵn 8 file "để tiết kiệm thời gian" | Không tạo gì trước khi có câu trả lời |
