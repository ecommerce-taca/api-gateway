---
name: ultimateskill-codingstyle
description: Bộ quy tắc viết code cá nhân của Cecilia cho Python, Java và NestJS, chia theo kiến trúc microservices và non-microservices. Dùng skill này BẤT CỨ KHI NÀO cần viết, sửa, refactor, review hoặc khởi tạo code backend ở một trong ba stack đó — kể cả khi người dùng chỉ nói "viết giúp cái API", "thêm chức năng", "fix bug", "tạo service mới", "dựng project", "refactor lại chỗ này", "review code", "chia module", "thêm entity", "viết test", "dựng Dockerfile", hoặc đưa ra file .py/.java/.ts của một backend. Skill bắt buộc agent PHỎNG VẤN làm rõ yêu cầu trước khi viết bất kỳ dòng code nào, rồi mới chọn nhánh ngôn ngữ và nhánh kiến trúc tương ứng.
---

# UltimateSkill-CodingStyle

Đây là phong cách code **của riêng Cecilia**. Không phải "best practice chung chung của internet",
không phải style mặc định của framework. Khi có mâu thuẫn giữa tài liệu này và thói quen mặc định
của bạn (agent), **tài liệu này thắng**.

---

## 0. Luật vàng — đọc trước, làm sau

Bốn luật này áp dụng cho mọi ngôn ngữ, mọi kiến trúc, mọi kích cỡ task.

### Luật 1 — LUÔN PHỎNG VẤN TRƯỚC

**Không viết một dòng code nào trước khi hỏi.** Kể cả task nhỏ. Kể cả khi bạn nghĩ mình đã hiểu.

Đây là yêu cầu tuyệt đối, không có ngoại lệ "task này rõ quá rồi". Cecilia thà mất 30 giây trả lời
câu hỏi còn hơn nhận về 300 dòng code sai hướng.

→ Quy trình chi tiết: **[references/interview.md](references/interview.md)** — đọc file này TRƯỚC KHI làm gì khác.

### Luật 2 — KHÔNG LÀM QUÁ PHẠM VI

- Không tự ý thêm thư viện, package, framework. Muốn thêm → **hỏi**, nêu lý do và phương án thay thế bằng thứ đang có.
- Không sửa, không format, không "tiện tay refactor" file nằm ngoài yêu cầu.
- Không tạo file thừa: không README, không docs, không example, không migration guide — trừ khi được yêu cầu.
- **Ngoại lệ: unit test luôn nằm trong phạm vi.** Viết/sửa business logic thì file test tương ứng
  (`*.spec.ts` / `test_*.py` / `*Test.java`) là một phần của việc đó, không phải file thừa —
  không cần hỏi thêm. Integration/e2e thì **không** tự sinh (xem `references/core-principles.md` §9).
- Không đổi công nghệ đang dùng trong dự án (đang TypeORM thì không đề xuất Prisma giữa chừng).

### Luật 3 — ĐỦ DÙNG, KHÔNG PHÔ TRƯƠNG

Ghét over-engineering. Một interface chỉ có đúng một implementation và sẽ không bao giờ có cái thứ hai
thì đó là rác. Factory cho việc `new` một object đơn giản là rác. Abstraction chỉ được sinh ra khi:

- Nó bọc một **dependency bên ngoài** (xem Luật 4), hoặc
- Đã có **≥ 2 implementation thật** đang tồn tại, hoặc
- Cecilia **yêu cầu** nó.

Ngoài ba trường hợp đó: viết thẳng, viết gọn.

### Luật 4 — HẠ TẦNG PHẢI BỌC LẠI

Mọi thứ đến từ bên ngoài — Kafka, RabbitMQ, NATS, gRPC client, Redis, S3, HTTP client, mail, payment
gateway, ORM, logger, cache — **không được gọi trực tiếp trong business code**. Luôn có interface do
mình định nghĩa ở tầng trong, adapter implement ở tầng ngoài.

Lý do: thay thế được, test được, bảo trì được.

Đây là ngoại lệ duy nhất được phép "thêm abstraction" mà không cần hỏi.

→ Chi tiết + template: **[references/infrastructure-abstraction.md](references/infrastructure-abstraction.md)**

---

## 1. Quy trình bắt buộc

```
┌─ B1. PHỎNG VẤN ─────────────────────────────────────────────┐
│  Đọc references/interview.md → hỏi → chờ trả lời.           │
│  KHÔNG ĐƯỢC BỎ QUA.                                          │
└──────────────────────────────────────────────────────────────┘
                          ↓
┌─ B2. XÁC ĐỊNH NHÁNH ────────────────────────────────────────┐
│  Ngôn ngữ: python / java / nestjs                            │
│  Kiến trúc: monolith (non-micro) / microservices             │
└──────────────────────────────────────────────────────────────┘
                          ↓
┌─ B3. ĐỌC ĐÚNG FILE ─────────────────────────────────────────┐
│  references/core-principles.md      (LUÔN LUÔN)              │
│  references/api-contract.md         (nếu có API)             │
│  <ngôn ngữ>/README.md               (LUÔN LUÔN)              │
│  <ngôn ngữ>/<kiến trúc>.md          (LUÔN LUÔN)              │
│  + file reference khác nếu task chạm tới                     │
└──────────────────────────────────────────────────────────────┘
                          ↓
┌─ B4. VIẾT CODE ─────────────────────────────────────────────┐
│  Theo đúng quy ước. Không phát sinh ngoài phạm vi.           │
└──────────────────────────────────────────────────────────────┘
                          ↓
┌─ B5. TỰ REVIEW ─────────────────────────────────────────────┐
│  Chạy references/review-checklist.md trên code vừa viết.     │
│  Có mục nào fail → sửa trước khi báo cáo.                    │
└──────────────────────────────────────────────────────────────┘
                          ↓
┌─ B6. BÁO CÁO ───────────────────────────────────────────────┐
│  Theo đúng mẫu ở mục 4 bên dưới.                             │
└──────────────────────────────────────────────────────────────┘
```

---

## 2. Bảng định tuyến

| Ngôn ngữ | Kiến trúc | Đọc file |
|---|---|---|
| Python | Non-microservices | `python/README.md` + `python/monolith.md` |
| Python | Microservices | `python/README.md` + `python/microservices.md` |
| Java | Non-microservices | `java/README.md` + `java/monolith.md` |
| Java | Microservices | `java/README.md` + `java/microservices.md` |
| NestJS | Non-microservices | `nestjs/README.md` + `nestjs/monolith.md` |
| NestJS | Microservices | `nestjs/README.md` + `nestjs/microservices.md` |

**Cách nhận biết kiến trúc khi vào dự án có sẵn:**

- Có nhiều thư mục service độc lập, mỗi cái một `package.json`/`pom.xml`/`pyproject.toml` → microservices
- Có `docker-compose.yml` khai báo nhiều service ứng dụng (không tính db/redis) → microservices
- Có `proto/`, `events/`, khai báo Kafka/RabbitMQ/NATS topic → microservices
- Có API gateway đứng trước → microservices
- Không thấy dấu hiệu nào → **hỏi**, đừng đoán

**Chưa có dự án (khởi tạo mới):** kiến trúc là câu hỏi bắt buộc trong phần phỏng vấn. Không bao giờ
mặc định chọn microservices — mặc định đề xuất là **modular monolith** (xem `references/core-principles.md` §2).

---

## 3. Mặc định đã chốt (không cần hỏi lại)

| Hạng mục | Giá trị |
|---|---|
| Ngôn ngữ hội thoại với Cecilia | **Theo ngôn ngữ Cecilia đang dùng** trong tin nhắn |
| Ngôn ngữ trong code | Định danh (biến/hàm/class/file) **tiếng Anh** |
| Ngôn ngữ comment | **Tiếng Việt** — chỉ giải thích *tại sao*, không giải thích *cái gì* |
| Đặt tên file | **Luôn có hậu tố vai trò.** Dấu phân cách theo chuẩn từng ngôn ngữ: TS `kebab-case` (`user-profile.service.ts`) · Python `snake_case` (`user_profile_service.py`) · Java `PascalCase` (`UserProfileService.java`) |
| Truy cập DB | **Repository pattern** — business code không biết DB là gì |
| Response API | **Envelope** `{success, data, message, errorCode, requestId, timestamp}` |
| Xử lý lỗi | Custom exception + **một global handler duy nhất** |
| Test mặc định | **Unit test cho service layer**, mock repository & external. Không tự sinh e2e |
| Stack NestJS | **NestJS + TypeORM + PostgreSQL** (đã chốt, không cần hỏi) |
| Stack Python | **CHƯA CHỐT** → phải hỏi ở đầu mỗi dự án |
| Stack Java | **CHƯA CHỐT** → phải hỏi ở đầu mỗi dự án |
| Kiến trúc ưu tiên | Modular theo feature; nâng lên DDD/Clean/Hexagonal khi nghiệp vụ đủ phức tạp |
| Giao tiếp microservices | Kafka, RabbitMQ/NATS, gRPC, REST + API Gateway, TCP — **hỏi dùng cái nào** |
| Hạ tầng | Bọc sau interface của mình, không phụ thuộc trực tiếp |

---

## 4. Mẫu báo cáo khi xong việc

Ngắn gọn ở phần đầu, checklist ở phần sau. Không dán lại code. Không viết văn.

```markdown
**Đã làm:** <1–2 câu về cách nó hoạt động>

**File:**
- `path/to/a.service.ts` — mới — <vai trò, 1 dòng>
- `path/to/b.controller.ts` — sửa — <sửa gì, 1 dòng>

**Checklist**
- [x] <việc đã hoàn thành>
- [x] <việc đã hoàn thành>
- [ ] <việc CHƯA làm + lý do / cần Cecilia quyết>

**Giả định đã tự quyết** (nói "sai thì báo, tôi sửa")
- <giả định 1>

**Chạy thử**
```bash
<lệnh cụ thể>
```
```

Không có giả định nào thì bỏ hẳn mục đó, đừng viết "Không có".

---

## 5. Danh sách cấm — vi phạm là code bị trả lại

1. Viết code trước khi phỏng vấn.
2. Tự ý `npm install` / `pip install` / thêm dependency vào `pom.xml`.
3. Sửa file không nằm trong phạm vi yêu cầu.
4. Comment lặp lại điều code đã nói rõ (`// tăng i lên 1`).
5. Sinh README/docs/docstring hàng loạt khi không được yêu cầu. *(Unit test không tính — xem Luật 2.)*
6. Dùng `any`, `Object`, `dict` trần, `Map<String,Object>` để né việc định nghĩa type.
7. Gọi thẳng SDK bên ngoài trong service/domain layer.
8. Lồng `if/else` quá 2 tầng thay vì early return.
9. Hàm dài quá ~30 dòng mà không tách.
10. Bịa API/field không có trong yêu cầu rồi tự implement.
11. Trả lời "đã xong" khi chưa chạy được hoặc còn TODO chưa khai báo.

---

## 6. Bản đồ file

```
UltimateSkill-CodingStyle/
├── SKILL.md                                  ← bạn đang ở đây
├── references/
│   ├── interview.md                          ← ĐỌC ĐẦU TIÊN, mọi task
│   ├── core-principles.md                    ← luôn đọc
│   ├── infrastructure-abstraction.md         ← khi chạm hạ tầng ngoài
│   ├── api-contract.md                       ← khi có REST/gRPC/event
│   ├── security-logging.md                   ← khi có input ngoài / log / auth
│   ├── git-docker-ci.md                      ← khi commit / dựng Docker / CI
│   └── review-checklist.md                   ← trước khi báo cáo
├── python/     { README.md, monolith.md, microservices.md }
├── java/       { README.md, monolith.md, microservices.md }
└── nestjs/     { README.md, monolith.md, microservices.md }
```
