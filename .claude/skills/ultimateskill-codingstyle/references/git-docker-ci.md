# Git, Docker & CI/CD

> Nguyên tắc xuyên suốt: **tự viết theo nhu cầu dự án, không copy template mặc định.**
> Mỗi lựa chọn không hiển nhiên phải có một dòng comment giải thích tại sao — để 6 tháng sau còn bảo trì được.

---

## PHẦN A — GIT

## A1. Commit — Conventional Commits, tiếng Anh

```
<type>(<scope>): <mô tả ngắn, thức mệnh lệnh, không dấu chấm cuối>

<thân — TẠI SAO thay đổi, không phải THAY ĐỔI GÌ (diff đã nói rồi)>

<footer — refs #123, BREAKING CHANGE: ...>
```

| type | Dùng cho |
|---|---|
| `feat` | Tính năng mới |
| `fix` | Sửa lỗi |
| `refactor` | Đổi cấu trúc, **không đổi hành vi** |
| `perf` | Tối ưu hiệu năng |
| `test` | Thêm/sửa test |
| `docs` | Tài liệu |
| `chore` | Việc vặt, dependency, config |
| `build` | Build system, Dockerfile |
| `ci` | Pipeline |

`scope` = module/service bị đụng: `feat(order): ...`, `fix(auth-service): ...`

```
✅ feat(order): add idempotency key to checkout endpoint
✅ fix(auth): reject refresh token after password change
✅ refactor(billing): extract invoice numbering into domain service

❌ update code
❌ fix bug
❌ WIP
❌ feat: added new stuff and fixed some things and refactored
```

## A2. Quy tắc commit

- **Một commit = một ý định logic.** Không trộn refactor với feature trong cùng commit.
- Commit phải **build được và test pass**. Không commit code gãy vào nhánh chung.
- Không commit: file `.env`, secret, `node_modules/`, thư mục build, file IDE, file tạm.
- Không commit code đã comment-out. Git nhớ hộ rồi.
- **Agent không tự commit và không tự push** trừ khi Cecilia yêu cầu rõ.

## A3. Branch

```
main            # production, luôn deploy được
develop         # tích hợp (nếu dự án dùng git-flow)
feat/<scope>-<mô-tả-ngắn>      feat/order-idempotency
fix/<scope>-<mô-tả-ngắn>       fix/auth-refresh-token
hotfix/<mô-tả-ngắn>            hotfix/payment-timeout
refactor/<scope>-<mô-tả-ngắn>
```

kebab-case, tiếng Anh, ngắn. Không dùng tên riêng người làm trong tên nhánh.

## A4. Pull request

```markdown
## Mục đích
<1–2 câu: giải quyết vấn đề gì>

## Thay đổi chính
- <thay đổi 1>
- <thay đổi 2>

## Điểm cần review kỹ
- <chỗ có đánh đổi, chỗ rủi ro>

## Cách kiểm thử
```bash
<lệnh>
```

## Ảnh hưởng
- [ ] Có breaking change API
- [ ] Có migration DB
- [ ] Cần biến môi trường mới
```

PR nhỏ, một mục đích. PR trên ~400 dòng thay đổi nên tách.

---

## PHẦN B — DOCKER

## B1. Dockerfile — multi-stage, tự viết

Yêu cầu bắt buộc cho mọi Dockerfile:

- **Multi-stage**: stage build tách khỏi stage runtime. Image cuối không chứa toolchain, source, dev dependency.
- **Base image ghim phiên bản cụ thể**, không dùng `latest`. Ưu tiên `-slim` / `-alpine` / distroless.
- **Chạy bằng user non-root.** Tạo user riêng, `USER app`.
- **Tận dụng cache layer**: copy file manifest (`package.json` / `pom.xml` / `pyproject.toml`) và cài
  dependency **trước**, copy source sau. Đây là điểm quyết định tốc độ build.
- **`.dockerignore`** đầy đủ: `node_modules`, `.git`, `.env`, `dist`, `target`, `__pycache__`, test fixtures.
- Có `HEALTHCHECK` trỏ tới endpoint readiness.
- Xử lý signal đúng để graceful shutdown hoạt động (`exec` form của `CMD`, hoặc `tini` nếu cần).
- **Không** nhét secret vào image, kể cả ở stage build (dùng build secret nếu thật sự cần).
- Comment tiếng Việt cho các dòng không hiển nhiên.

Khung chung (chi tiết theo stack nằm trong `<ngôn ngữ>/*.md`):

```dockerfile
# ---- Stage 1: build ----
FROM <base>:<version-cụ-thể> AS builder
WORKDIR /app
# Copy manifest trước để tận dụng cache layer khi source đổi mà dependency không đổi
COPY <manifest> ./
RUN <cài dependency>
COPY . .
RUN <build>

# ---- Stage 2: runtime ----
FROM <base-slim>:<version-cụ-thể> AS runtime
WORKDIR /app
RUN addgroup -S app && adduser -S app -G app
COPY --from=builder --chown=app:app /app/<artifact> ./
USER app
EXPOSE 3000
HEALTHCHECK --interval=30s --timeout=3s --start-period=20s --retries=3 \
  CMD <lệnh gọi /health/ready>
CMD ["<entrypoint>"]
```

## B2. docker-compose cho local

- Chỉ dùng cho môi trường local/dev, không dùng làm cấu hình production.
- Khai báo đủ hạ tầng phụ thuộc: db, redis, kafka/rabbitmq, mailhog...
- Có `healthcheck` cho hạ tầng và `depends_on: condition: service_healthy` — tránh app khởi động
  trước khi DB sẵn sàng.
- Biến môi trường đọc từ `.env`, không hardcode trong compose file.
- Volume cho dữ liệu để không mất khi `down`.
- Đặt tên service, network, volume theo dự án — không để tên mặc định `db`, `app`.

## B3. Microservices

- Mỗi service một Dockerfile riêng, nằm cùng thư mục service.
- Compose local dựng đủ hệ: các service + broker + db (mỗi service **db riêng**, không chung schema).
- Tag image theo commit SHA hoặc semver, **không** deploy bằng tag `latest`.

---

## PHẦN C — CI/CD

## C1. Pipeline tối thiểu

```
lint ──► typecheck ──► unit test ──► build ──► docker build ──► push
```

Nguyên tắc:

- **Fail fast**: lint và typecheck chạy trước, rẻ và nhanh, chặn sớm.
- Cache dependency giữa các lần chạy.
- Build image một lần, tái sử dụng cho mọi môi trường. Không build lại cho từng env.
- Secret lấy từ secret store của CI, không nằm trong file pipeline.
- Có bước quét dependency (`npm audit`, `pip-audit`, `mvn dependency-check`) — cảnh báo, không nhất thiết chặn.
- Migration DB là **bước deploy riêng**, không nhét vào lệnh khởi động app (nhiều replica cùng chạy migration sẽ vỡ).

## C2. Viết pipeline như thế nào

- Tự viết theo nhu cầu dự án, không dán template mặc định của GitHub/GitLab.
- Mỗi job có tên nói rõ mục đích. Mỗi bước không hiển nhiên có comment.
- Tách job thay vì một job khổng lồ, để nhìn log biết ngay chỗ nào hỏng.
- Ghim phiên bản của action/image dùng trong pipeline.

## C3. Giới hạn của agent

- **Không tự sửa file CI** khi task không nói tới nó.
- **Không tự thêm bước deploy** hay đụng vào môi trường production.
- Cần thêm secret / biến môi trường mới → **liệt kê ra trong báo cáo** cho Cecilia tự thêm, không tự đoán giá trị.

---

## PHẦN D — QUẢN LÝ DEPENDENCY

- **Hỏi trước khi thêm bất kỳ package nào.** Đây là điều Cecilia ghét nhất khi agent tự làm.
- Khi đề xuất thêm, nêu đủ 4 điều: (1) giải quyết vấn đề gì, (2) cách làm không cần package đó,
  (3) mức độ duy trì của package (lần release gần nhất, số issue mở), (4) kích thước / số dependency kéo theo.
- Ghim phiên bản chính xác. Commit lockfile (`package-lock.json`, `poetry.lock`, `uv.lock`).
- Không nâng version dependency ngoài phạm vi task.
