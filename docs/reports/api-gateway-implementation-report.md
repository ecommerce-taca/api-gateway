# Báo cáo triển khai — API Gateway

> Ngày: `2026-08-31` · Nhánh: `develop`, `test` · Runtime: **Kong Gateway 3.9.0 OSS** (DB-less + decK)
> Nguồn yêu cầu: `docs/api-gateway-docs/docs/{lld,api,db,test}/api-gateway.md`
> Trạng thái: **hoàn thành phạm vi đã chốt**, còn 3 điểm chờ quyết ở §7

---

## 1. Tóm tắt

API Gateway chạy trên Kong 3.9.0 OSS ở chế độ DB-less, cấu hình bằng decK trong Git, cộng với
5 plugin Lua tự viết cho những thứ Kong OSS không có: JWKS, RBAC theo claim, guard request,
connection cap WebSocket và chuẩn hoá error envelope.

| Hạng mục | Số lượng |
|---|---:|
| Plugin Lua custom | 5 (24 file, 2.198 dòng) |
| Unit test plugin (`busted`) | 213 |
| Quy tắc lint cấu hình | 12 |
| Test của chính linter | 23 |
| Upstream / Service / Route | 10 / 23 / 57 |
| Route family phủ theo API §1.3 | 19/19 |
| Mã lỗi theo API §4 | 16/16 |
| File mới | 85 (13.058 dòng) |
| Commit (không tính merge) | 15, trên 15 nhánh `feat/*` và `fix/*` |

Toàn bộ đã kiểm chứng trên Kong thật, không phải chỉ trên unit test — chi tiết ở §5.

---

## 2. Thành phần đã giao

### 2.1 Runtime

| File | Vai trò |
|---|---|
| `kong/kong.conf` | `database=off`, 3 shared dict (`taca_jwks`/`taca_locks`/`taca_metrics`), header limit 16 KiB, `proxy_next_upstream = error timeout`, `headers = off`, tắt access log của nginx |
| `Dockerfile` | Multi-stage: stage `test` (busted + toolchain) tách hẳn khỏi stage `runtime` (chỉ Kong + plugin), chạy bằng user `kong`, có `HEALTHCHECK` |

### 2.2 Năm plugin custom

| Plugin | PRIORITY | Trách nhiệm |
|---|---:|---|
| `taca-request-guard` | 2100 | Origin allowlist → `403`, validate/sinh `X-Request-ID` (UUIDv7), strip `X-User-*`/`X-Auth-*`/`X-Forwarded-*`. Kèm 3 chế độ vận hành: `liveness`, `readiness`, `metrics` |
| `taca-jwt` | 940 | Verify RS256 bằng JWKS cache 2 tầng, kiểm `iss/aud/sub/exp/iat/nbf/kid`, check marker revoke trong Redis, dựng actor header |
| `taca-rbac` | 930 | Coarse gate role/permission theo khai báo trên từng Route |
| `taca-ws-guard` | 900 | Đếm connection WebSocket theo user, vượt cap → `429` |
| `taca-error-envelope` | 1 | Chuẩn hoá mọi response lỗi về `{error:{code,message,details,trace_id}}` |

`kong/plugins/taca-lib/` giữ phần dùng chung: catalog 16 mã lỗi, dựng envelope, bọc Redis,
metric store, redaction log.

**PRIORITY được khóa theo số thật của Kong 3.9.0**, không lấy theo anchor trong LLD §2.1.3:
bản đang chạy có `cors=2000`, `request-size-limiting=951`, `rate-limiting=910`,
`correlation-id=100001` — LLD ghi `rate-limiting=901` là số của phiên bản khác. Đây chính là
điều LLD §2.1.3 dặn: *"khóa theo phiên bản đang dùng, không suy đoán từ tài liệu phiên bản khác"*.

Riêng `taca-request-guard` phải cao hơn `cors` (2000) chứ không chỉ cao hơn `taca-jwt`: plugin
`cors` của Kong trả `200` cho preflight của origin lạ, nên chạy sau nó thì yêu cầu
"origin ngoài allowlist phải nhận `403`" không bao giờ đạt được.

### 2.3 Cấu hình declarative

`kong/deck/kong.yaml` (2.830 dòng) + `env/{dev,staging,prod}.yaml` + `Makefile`
(`render` → `validate` → `lint` → `diff` → `sync`).

Ba quyết định định hình file này:

1. **`retries` là thuộc tính của Service, không phải Route.** Nên mỗi upstream tách
   `svc-*-read` (`retries=1`, chỉ `GET/HEAD/OPTIONS`) và `svc-*-write` (`retries=0`).
   Đây là cách duy nhất Kong cho phép "chỉ retry GET".
2. **Path chồng nhau tách bằng regex**, vì router của Kong xét regex trước prefix:
   `/products/{id}/reviews` → `rating-comment` chứ không phải `product-catalog`;
   `/orders/{id}/shipment` → `shipment` chứ không phải `order-commerce`;
   `GET /vouchers` là public còn `/vouchers/**` thì không.
3. **Hai danh sách origin sinh từ cùng 4 biến** cho cả `cors.origins` lẫn
   `taca-request-guard.allowed_origins`, đúng yêu cầu LLD §8 #16, và có quy tắc lint đối chiếu.

### 2.4 Lint cấu hình

`tools/config-lint/` — 12 quy tắc theo test doc §4.2, chạy trên file **đã render** để so được
cả giá trị chỉ xuất hiện sau khi thay biến môi trường.

| Mã | Quy tắc |
|---|---|
| R01 | Service `*-write` và `svc-message-ws` phải có `retries = 0` |
| R02 | Service `*-read` có `retries` ≤ 1 |
| R03 | Route `/api/v1/admin/**` phải có `taca-rbac` |
| R04 | Route cần danh tính (rbac / ws-guard / bucket theo user) phải có `taca-jwt` |
| R05 | Không có Route catch-all |
| R06 | Không Route nào khớp `/internal/**` |
| R07 | Không Route `/ws/**` nào ngoài `/ws/messages` |
| R08 | `rate-limiting` phải `policy=redis` và `fault_tolerant=false` |
| R09 | `cors.origins` khớp `taca-request-guard.allowed_origins` |
| R10 | `strip_path = false` trên mọi route business |
| R11 | Route WebSocket không gắn plugin đọc/ghi body |
| R12 | Không có giá trị bí mật hard-code trong config |

23 test của chính linter chạy trên 4 fixture config sai (IT-KONG-06/07/08/15) — thiếu chúng thì
một quy tắc viết hỏng sẽ im lặng cho mọi config đi qua.

### 2.5 Môi trường local và CI

- `docker-compose.yml`: **2 node Kong** + Redis + 1 container nginx đóng vai cả 10 domain service,
  JWKS của auth-user và collector OTEL (nhờ network alias). Hai node là cố ý — rate limit phân tán
  và trạng thái healthcheck per-node chỉ lộ ra khi có từ hai node trở lên (test doc §1.1).
- `Makefile`: `test`, `lint`, `render`, `dev-keys`, `token`, `up`, `down`, `clean`.
  Mọi công cụ chạy trong container; máy dev không cần cài Kong, decK, busted hay Python.
- `.github/workflows/ci.yml`: hai job rẻ chạy song song (lint cấu hình ‖ unit test plugin), rồi
  mới build image và smoke test stack. **Không có bước deploy** — sync cấu hình lên môi trường
  thật là hành động có chủ đích của DevOps.

---

## 3. Đối chiếu với tài liệu

| Yêu cầu | Nơi hiện thực | Trạng thái |
|---|---|---|
| CORS header + preflight | plugin `cors` | Đủ |
| Từ chối origin lạ bằng `403` | `taca-request-guard` | Đủ |
| Body ≤ 1 MiB | `request-size-limiting` | Đủ |
| Header limit 16 KiB | `kong.conf` | Đủ |
| `X-Request-ID` giữ/sinh mới | `correlation-id` + `taca-request-guard` (UUIDv7) | Đủ |
| Strip `X-User-*`/`X-Auth-*` | `taca-request-guard` | Đủ |
| JWKS fetch/cache/rotation + RS256 | `taca-jwt` + `jwks.lua` | Đủ |
| Claim `iss/aud/exp/iat/nbf/kid` | `token_verifier.lua` | Đủ |
| Actor header | `actor_context.lua` | Đủ |
| Coarse RBAC theo route | `taca-rbac` | Đủ |
| Rate limit phân tán qua Redis | `rate-limiting` (3 bucket) | Đủ |
| Timeout connect/read/write | `Service.*_timeout` | Đủ |
| Retry chỉ GET/HEAD | tách Service `*-read`/`*-write` | Đủ |
| Circuit breaker | `Upstream.healthchecks` | Đủ, có lệch ngữ nghĩa — xem §6 |
| Error envelope thống nhất | `taca-error-envelope` | Đủ, 1 chỗ lệch — xem §7.3 |
| WebSocket proxy `/ws/messages` | `svc-message-ws` + `taca-ws-guard` | Đủ |
| `/metrics` Prometheus + metric custom | plugin `prometheus` + chế độ `metrics` | Đủ |
| Structured log + redaction | `file-log` + `custom_fields_by_lua` | Đủ |
| W3C trace propagation | plugin `opentelemetry` | Đủ |
| Liveness/readiness | chế độ `liveness`/`readiness` | Đủ |
| 16 mã lỗi API §4 | `error_catalog.lua` | Đủ 16/16 |
| 19 route family API §1.3 | `kong/deck/kong.yaml` | Đủ 19/19 |

Route registry theo **API §1.3 + LLD §2.3** (hai bảng khớp nhau). Bảng tóm tắt ở API §2 có thêm
`/shipments/**`, `/wallet/**`, `/payouts/**`, `/refunds/**`, `/inventory/**` — không khai báo,
đúng quyết định đã chốt; các path đó trả `404 GATEWAY_ROUTE_NOT_FOUND`.

---

## 4. Ba hằng số không có tương đương native

Đã chốt: **chấp nhận ngữ nghĩa của Kong OSS, không viết thêm plugin**, và ghi rõ tại chỗ trong
`kong.yaml` để không ai tin nhầm con số baseline.

| Hằng số | Hành vi thật của Kong OSS |
|---|---|
| `RATE_LIMIT_BURST` | `rate-limiting` fixed-window không có burst riêng |
| `UPSTREAM_RETRY_BACKOFF` | nginx retry ngay, không delay |
| `CIRCUIT_WINDOW` | passive healthcheck đếm lỗi **liên tiếp**, không theo cửa sổ 30s — traffic thành công/thất bại xen kẽ có thể không bao giờ chạm ngưỡng |

---

## 5. Kết quả kiểm chứng

Tất cả chạy trên máy, không phải suy đoán.

### 5.1 Tự động

| Kiểm | Kết quả |
|---|---|
| `make test` — unit test 5 plugin | **213 pass / 0 fail** |
| `make lint` — 12 quy tắc trên dev/staging/prod | **0 vi phạm** cả ba môi trường |
| Test của linter trên fixture config sai | **23 pass** |
| `deck file validate` | pass |
| `kong config parse` trên image runtime | **parse successful** — Kong 3.9.0 nạp được config kèm schema cả 5 plugin |
| Dựng lại từ số 0 (`make clean && make up`) | 2 node lên xanh |

### 5.2 Hành vi thật trên stack đang chạy

| Kịch bản | Kết quả quan sát được |
|---|---|
| `GET /health/live` | `{"status":"UP","service":"api-gateway","time":"..."}` |
| `GET /health/ready` | `200`, `checks: {config:UP, jwks:UP, redis:UP, upstreams:UP}` |
| `GET /api/v1/nope` | `404 GATEWAY_ROUTE_NOT_FOUND`, có `trace_id` |
| `GET /api/v1/users/me` không token | `401 GATEWAY_AUTH_REQUIRED` |
| Token hợp lệ | `200`; upstream nhận `X-User-ID` = `sub`, `X-User-Roles=BUYER`, `X-Auth-Method=jwt` |
| Client gửi `X-User-ID: attacker` trên route public | Upstream **không** nhận header đó |
| Origin ngoài allowlist | `403 GATEWAY_CORS_DENIED` |
| Token buyer vào `POST /api/v1/seller/products` | `403 GATEWAY_PERMISSION_DENIED` |
| Token seller vào route trên | `200` |
| 12 request vào `/api/v1/auth/signin` | 10 × `200`, rồi `429` + `Retry-After: 45` + `details.retry_after_seconds: 45` |
| Tắt Redis → route business | `503 GATEWAY_REDIS_UNAVAILABLE` (fail-closed) |
| Tắt Redis → readiness | `503 GATEWAY_REDIS_UNAVAILABLE` |
| Tắt Redis → liveness | vẫn `200 UP` |
| `GET /ws/messages` không token | `401 GATEWAY_AUTH_REQUIRED`, không upgrade |
| `GET /metrics` | metric của Kong + `taca_jwks_refresh_total{outcome="success"}` |

### 5.3 Hai lỗi thật bị bắt nhờ chạy stack

Cả hai đều thuộc loại unit test không thể thấy — lý do job `stack-smoke` được thêm vào CI:

1. `balancer.get_all_upstreams` đã chuyển sang module con từ sau Kong 2.5 → `/health/ready` chết
   với lỗi Lua, trả `500`. Đã fallback đúng như plugin `prometheus` của Kong vẫn làm.
2. Khi không Route nào khớp, chuỗi `access` không chạy nên không có `X-Request-ID` nào, response
   `404` mang `trace_id` rỗng — vi phạm contract "mọi response lỗi đều có `trace_id`". Đã fallback
   sang request id của chính Kong.

---

## 6. Lệch đã biết so với thiết kế NestJS cũ

Không phải lỗi, là hệ quả của việc chuyển sang Kong và đã được LLD lường trước:

- **Healthcheck theo target, không theo `route_group`**, và trạng thái là **per-node** — mỗi node
  Kong tự phát hiện upstream lỗi, thời gian phát hiện toàn cụm không đồng thời. Đừng cảnh báo
  "mất đồng bộ circuit state".
- **Format key rate limit do plugin của Kong quản lý.** Không viết dashboard/script nào phụ thuộc
  format cũ `rl:v1:...`; quan sát bằng metric. Chỉ key của custom plugin (`ws:v1:conn:*`) giữ quy ước cũ.
- **Tên metric Prometheus đổi**: `kong_http_requests_total`, `kong_request_latency_ms`,
  `kong_upstream_target_health`… Alert viết theo tên `gateway_*` cũ sẽ im lặng không bao giờ kêu.
- `opentelemetry.header_type` bị Kong 3.9 cảnh báo deprecated (bỏ sau 4.0). Vẫn dùng vì LLD §2.1.1
  chốt như vậy; khi lên Kong 4.x phải đổi sang `propagation`.

---

## 7. Ba điểm cần quyết

### 7.1 Khóa dev JWKS đã lọt vào lịch sử git

`.gitignore` gốc thiếu newline cuối file nên dòng thêm vào bị nối thành
`.claude/kong/deck/.build/` — không khớp gì cả. Hệ quả: `kong/deck/.build/` lọt vào commit, và
trong một lần checkout nhánh fix (nhánh đó chưa có dòng `mocks/jwks/`) thì
`mocks/jwks/private-key.pem` cũng bị commit theo.

**Đã xử lý:** sửa `.gitignore`, bỏ tracking cả hai, sinh lại khóa dev mới.
**Mức rủi ro:** thấp — khóa đó chỉ ký token cho nginx mock ở máy local, không có giá trị ở môi
trường thật, và JWKS mock cũng chỉ chạy trong compose.
**Còn lại:** khóa cũ vẫn nằm trong lịch sử các commit trước. Xóa hẳn cần rewrite lịch sử và
force-push 3 nhánh — **quyết định của Cecilia**, tôi không tự làm.

### 7.2 `/api/v1/auth/**` chưa tách được public/protected theo từng endpoint

LLD §2.3 ghi *"Public tùy endpoint; signout/2FA protected"* nhưng danh sách endpoint chính xác
thuộc API spec của auth-user (API §5 #1), chưa có. Tôi để policy ở mức family với `taca-jwt`
`token_required=false` thay vì bịa path: endpoint protected vẫn nhận actor context, và auth-user
vẫn tự kiểm token. **Cần danh sách endpoint để siết lại thành route riêng.**

### 7.3 Upstream trả 4xx với body sai contract → giữ status thật thay vì `502`

LLD §3.6 ghi *"body không đúng JSON contract → 502"*. Ở `header_filter` Kong chưa có body nên
chưa biết body có đúng contract hay không; chỉ biết sau khi đọc xong body, lúc đó không đổi status
được nữa. Cách duy nhất là bật response buffering, mà việc đó phá tunnel WebSocket ở §3.9.

**Đã chọn:** giữ status thật của upstream, thay body bằng envelope
`GATEWAY_UPSTREAM_BAD_RESPONSE` và ghi log schema violation. Client vẫn luôn nhận đúng hình dạng
envelope, status vẫn trung thực. **Đây là chỗ duy nhất lệch tài liệu**, cần Architecture owner xác nhận.

---

## 8. Giả định đã tự quyết

| # | Giả định | Cần ai xác nhận |
|---|---|---|
| 1 | Thêm `kong/plugins/taca-lib/` và module con trong mỗi thư mục plugin (`token_reader.lua`, `error_mapper.lua`…). Cây thư mục LLD §2.1 chỉ liệt kê `handler.lua`/`schema.lua` nhưng đã có sẵn `jwks.lua`, nên tách thêm là hợp lệ | Gateway owner |
| 2 | Tên role admin `ADMIN`, `RISK_MANAGER`, `CATALOG_ADMIN`, `VOUCHER_MANAGE`, `FINANCE_OPS` suy từ fixture token ở test doc §1.2 | Auth-user owner |
| 3 | `GATEWAY_REDIS_UNAVAILABLE`: Kong raise Lua error trần khi Redis hỏng nên response chỉ còn `500` vô danh. Plugin đánh dấu ở phase `access` — với PRIORITY thấp nhất, dấu vắng mặt nghĩa là request chết ở plugin access phía trước. Đã kiểm thật: tắt Redis → đúng `503` | Gateway owner |
| 4 | Không thêm bucket rate limit "global IP guard" thứ tư vì LLD §3.4 không cho con số; ba bucket theo bảng baseline là contract | Architecture owner |
| 5 | Job `stack-smoke` trong CI (8 assertion) nằm ngoài phạm vi đã chốt, thêm vào vì hai bug ở §5.3 thuộc loại unit test không thấy được | Cecilia |
| 6 | Linter dùng `unittest` của stdlib + PyYAML đóng trong image riêng, không cài gì lên máy dev | Cecilia |

**Hai lỗi cosmetic không sửa được nếu không rewrite lịch sử:** commit `feat(deck)` ghi nhầm
"37 route" (số thật 57); một commit có `author name` = email.

---

## 9. Biến môi trường cần điền trước khi lên staging/prod

Giá trị trong `kong/deck/env/{staging,prod}.yaml` hiện là **tên host nội bộ mẫu theo LLD §2.6**,
không phải địa chỉ thật. DevOps nạp giá trị thật qua biến môi trường của CI hoặc secret manager.

| Biến | Ghi chú |
|---|---|
| `DECK_{AUTH_USER,PRODUCT_CATALOG,SEARCH,ORDER_COMMERCE,INVENTORY,PAYMENT_WALLET,SHIPMENT,RATING_COMMENT,NOTIFICATION,MESSAGE}_TARGET` | `host:port` nội bộ của 10 domain service |
| `DECK_REDIS_HOST` / `_PORT` / `_DATABASE` | Redis dùng chung cho rate limit + `taca-ws-guard` |
| Redis password | Chưa khai báo trong config; nạp qua secret manager, **không** ghi vào `kong.yaml` (lint R12 sẽ chặn) |
| `DECK_JWT_ISSUER` / `_AUDIENCE` / `_JWKS_URI` | Từ auth-user |
| `DECK_CORS_ORIGIN_MFE_{SHELL,BUYER,SELLER,ADMIN}` | Origin thật của 4 Micro-Frontend |
| `DECK_OTEL_TRACES_ENDPOINT` | Collector OpenTelemetry |
| `KONG_TRUSTED_IPS` | Dải IP của ingress; để trống nghĩa là không tin `X-Forwarded-For` |

---

## 10. Git flow và rollback

```
main (không đụng, giữ nguyên 6857204)
 └── develop ──► test
      ├── feat/gateway-skeleton, feat/test-harness
      ├── feat/plugin-{jwt,rbac,ws-guard,error-envelope,request-guard}
      ├── feat/{deck-config,config-lint,local-stack,ci-pipeline}
      └── fix/{error-envelope-preserve-plugin-codes, readiness-and-trace-id,
               gitignore-and-leaked-dev-key, rendered-config-permissions}
```

15 nhánh, mỗi nhánh một ý định, merge `--no-ff` vào `develop` rồi `test`, đã push đủ.

**Rollback:**

- Lỗi ở cấu hình → `git revert <commit merge>` rồi `make -C kong/deck sync`. Không có database
  nên không có migration để rollback (DB §6).
- Lỗi ở plugin Lua → rollback image về tag trước.
- `make -C kong/deck diff` chạy định kỳ trên môi trường thật: khác biệt so với Git là sự cố cấu
  hình phải điều tra, **không được sync đè im lặng**.

---

## 11. Cách chạy

```bash
make test                      # 213 unit test của 5 plugin
make lint                      # 12 quy tắc cấu hình + 23 test của linter
make up                        # 2 node Kong + Redis + 10 mock upstream

curl -s localhost:8000/health/live
curl -s localhost:8000/health/ready
curl -s localhost:8000/api/v1/users/me                      # 401 GATEWAY_AUTH_REQUIRED
curl -s localhost:8000/api/v1/users/me \
     -H "Authorization: Bearer $(make token | tail -1)"     # 200
TOKEN_ROLES=SELLER make token                               # token seller để thử route role-gated

make down
```

Đổi môi trường: `make lint ENV=staging`, `make render ENV=prod`.
Sync lên môi trường thật: `make -C kong/deck diff ENV=prod` rồi `sync` — chạy từ máy có đường tới
Admin API (`kubectl port-forward`), vì Admin API chỉ bind loopback và không được expose ra ingress.

---

## 12. Việc chưa làm

| Việc | Lý do |
|---|---|
| Bộ integration test `IT-GW-*`, `IT-KONG-*`, `IT-JWT-*`, `IT-RL-*` (test doc §3) | Ngoài phạm vi đã chốt. CI có job smoke 8 assertion, **không** thay thế được suite đầy đủ |
| Test thủ công `TC-GW-01..22` (test doc §2) | Thuộc QA, cần frontend thật |
| Security/performance test `SEC-GW-*`, `RES-GW-*` (test doc §5) | Cần môi trường staging và load tool |
| Push image lên registry | Chưa chốt registry; CI chỉ build, không push (không tự thêm bước deploy) |
