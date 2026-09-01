# Báo cáo: Tối ưu code API Gateway (5 plugin Lua + linter config)

**Trạng thái:** Xong — refactor bảo toàn hành vi, đã kiểm chứng trên Kong 3.9.0 thật, không chỉ unit test.
**Ngày:** 2026-09-01 · **Phạm vi:** `kong/plugins/**`, `spec/**`, `tools/config-lint/`, khối `custom_fields_by_lua` trong `kong/deck/kong.yaml`

Yêu cầu: code ngắn nhất có thể, theo `ultimateskill-codingstyle`, giữ nguyên nghiệp vụ, chính xác 100% với `docs/api-gateway-docs/docs/{lld,api,db,test}`.

---

## 1. Cần bạn quyết định / xác nhận

Bốn việc. Việc số 1 là việc gấp — nó là lỗ hổng bảo mật có thật đang chạy trên nhánh `develop`, tôi đã sửa nhưng cách sửa có đánh đổi cần bạn duyệt.

**1. [✓ Đã kiểm chứng] Access token đang bị ghi thẳng vào log — đã sửa, nhưng log schema đổi.**

Bản trên `develop` vi phạm SEC-GW-08 / SEC-GW-12 / API §3.12 ở hai chỗ độc lập:

- Key `request.headers[\"sec-websocket-protocol\"]` và `response.headers[\"set-cookie\"]` **không có tác dụng**. Kong tách key của `custom_fields_by_lua` **chỉ theo dấu chấm** (`kong/pdk/log.lua`, hàm `edit_result`); cú pháp ngoặc bị coi là tên field literal. Nghĩa là subprotocol WebSocket — thứ mang access token ở handshake — vẫn nằm nguyên trong log.
- Serializer của Kong sinh **bốn** field từ cùng một request: `request.uri`, `request.url`, `request.querystring`, `upstream_uri` (`kong/pdk/log.lua:895–905`). Config cũ chỉ redact `request.url`, nên `?access_token=` vẫn lộ ở ba field còn lại.

Bằng chứng thật, chạy trên stack local trước khi sửa:

```json
"querystring": {"page":"2","refresh_token":"RT456","access_token":"SUPERSECRET123"}
```

Sau khi sửa, cùng một request:

```json
"querystring": {"access_token":"[REDACTED]","otp":"[REDACTED]","refresh_token":"[REDACTED]","page":"2"}
"uri": "/api/v1/products?access_token=[REDACTED]&page=2&refresh_token=[REDACTED]&otp=[REDACTED]"
```

`grep` toàn bộ log của 2 node cho 6 chuỗi bí mật thử nghiệm: **0 dòng lộ**.

**Đánh đổi cần bạn duyệt:** để không phải viết cùng một vòng redact ở ba chỗ, tôi giữ đúng một field URL đã redact (`request.uri`) và **bỏ hẳn `request.url` + `upstream_uri`** khỏi bản ghi log. Nếu dashboard/alert nào của DevOps đang đọc hai field đó thì sẽ mất dữ liệu — cần bạn hoặc DevOps xác nhận. Muốn giữ lại thì nói, tôi thêm vòng redact cho từng field (dài thêm ~10 dòng YAML).

**2. [~ Suy luận] §7.3 báo cáo cũ — upstream trả 4xx với body sai contract.** LLD §3.6 ghi phải trả `502`, code đang giữ status thật của upstream và chỉ thay body.
**Đề xuất của tôi: giữ nguyên như hiện tại, và sửa LLD §3.6 cho khớp code.** Lý do: ở `header_filter` Kong chưa đọc body nên chưa thể biết body có đúng contract; muốn biết phải bật response buffering, mà buffering phá tunnel WebSocket ở LLD §3.9 — đánh đổi một tính năng đang chạy để lấy một mã status. Ngoài ra `502` cho một lỗi nghiệp vụ 4xx (ví dụ `409` hết hàng) làm client mất khả năng phân biệt "lỗi của tôi" với "lỗi hệ thống", và sẽ kích healthcheck eject target oan. Client vẫn luôn nhận đúng hình dạng envelope nên contract đối ngoại không vỡ.

**3. [~ Suy luận] §7.2 báo cáo cũ — `/api/v1/auth/**` chưa tách public/protected theo endpoint.** Vẫn chưa có danh sách endpoint từ auth-user.
**Đề xuất: giữ `token_required=false` ở mức family cho tới khi có danh sách, KHÔNG đoán path.** Lý do: đoán sai theo hướng "protected" thì chặn nhầm luồng đăng nhập (sự cố nhìn thấy ngay), đoán sai theo hướng "public" thì mở nhầm endpoint nhạy cảm (sự cố không nhìn thấy). Hiện tại auth-user vẫn tự kiểm token và Gateway vẫn dựng actor context, nên rủi ro thấp hơn cả hai hướng đoán. Việc cần làm là đòi API spec của auth-user, không phải sửa code.

**4. [✓ Đã kiểm chứng] Đã xoá `kong/plugins/taca-lib/log_redactor.lua` (80 dòng) + spec của nó (36 dòng).** Module này **chưa từng được `require` ở đâu** — redaction thật nằm ở `custom_fields_by_lua`, đúng như LLD §2.1.1 phân công. Nó là code chết duplicate danh sách field nhạy cảm ở nơi thứ hai. Số test vì vậy giảm 213 → 207. Nếu bạn muốn giữ lại để dùng sau, nói tôi khôi phục — nhưng khi đó nên wire nó vào chỗ thật, không để nằm không.

---

## 2. Kết quả

| Việc | Trạng thái | Bằng chứng |
|---|---|---|
| Rút gọn 5 plugin Lua | Xong | `kong/plugins`: **2.198 → 1.786 dòng (−412, −18,7%)** |
| Rút gọn linter config | Xong | `kong_config_linter.py`: **285 → 253 dòng**, 12 quy tắc giữ nguyên |
| Giữ nguyên hành vi | Xong | 207/207 unit test; 12 quy tắc lint sạch trên dev+staging+prod; 14 kịch bản thật trên stack (mục 3) |
| Schema nạp được trên Kong thật | Xong | `kong config parse` → `parse successful` với cả 5 plugin |
| Sửa lỗ hổng token lọt vào log | Xong | mục 1, việc 1 — grep 0 dòng lộ |
| Xoá code chết | Xong | `log_redactor.lua`, `metrics_store.set_gauge` (không nơi nào gọi) |
| Rút gọn `kong/deck/kong.yaml` (2.830 dòng) | **Không làm** | Ngoài phạm vi tôi chọn — xem mục 4.3 |
| Gộp test trùng lặp trong `spec/` | **Không làm** | Làm mỏng lưới an toàn của chính đợt refactor này — xem mục 4.3 |

Tổng: `29 files changed, 382 insertions(+), 853 deletions(-)`.

---

## 3. Cách bạn tự kiểm chứng

**Đã chạy và pass:**

```bash
make test                 # 207 successes / 0 failures / 0 errors  (trước refactor: 213/0/0)
make lint ENV=dev         # config lint: 12 quy tắc, không có vi phạm
make lint ENV=staging     # 12 quy tắc, không có vi phạm
make lint ENV=prod        # 12 quy tắc, không có vi phạm
                          # kèm 23 test của chính linter: OK
docker run --rm -v "$PWD/kong/deck/.build:/cfg:ro" taca-gw:refactor \
  kong config parse /cfg/kong.dev.yaml       # parse successful
```

**Đã chạy trên stack thật** (`make up`, 2 node Kong + Redis + 10 mock upstream), 14 kịch bản, tất cả khớp hành vi mô tả trong báo cáo triển khai cũ §5.2:

| Kịch bản | Quan sát được |
|---|---|
| `GET /health/live` | `200 {"status":"UP",...}` |
| `GET /health/ready` | `200`, `checks: {config:UP, jwks:UP, redis:UP, upstreams:UP}` |
| `GET /api/v1/nope` | `404 GATEWAY_ROUTE_NOT_FOUND`, có `trace_id` |
| `GET /api/v1/users/me` không token | `401 GATEWAY_AUTH_REQUIRED` |
| Token hợp lệ | `200`; upstream nhận `X-User-ID=01912f31-…`, `X-User-Roles=BUYER`, `X-Auth-Method=jwt` |
| Client bơm `X-User-ID: attacker` (route public) | Upstream **không** nhận header đó |
| Origin ngoài allowlist | `403 GATEWAY_CORS_DENIED` |
| Token BUYER vào `POST /api/v1/seller/products` | `403 GATEWAY_PERMISSION_DENIED` |
| Token SELLER vào route trên | `200` |
| 12 request vào `/api/v1/auth/signin` | 10×`200` rồi `429` + `Retry-After: 31` + `details.retry_after_seconds: 31` |
| Tắt Redis → route business | `503 GATEWAY_REDIS_UNAVAILABLE` (fail-closed) |
| Tắt Redis → readiness | `503`; → liveness | vẫn `200 UP` |
| `GET /ws/messages` không token | `401`, không upgrade |
| Log sau khi sửa redaction | 0 dòng chứa token/cookie/subprotocol |

Lệnh dựng lại để tự xem:

```bash
make up
TOKEN=$(make token | tail -1)
curl -s -D- -o /dev/null -H "Authorization: Bearer $TOKEN" -H "X-User-ID: attacker" \
     localhost:8000/api/v1/users/me | grep -i x-mock-seen      # phải thấy sub thật, không phải "attacker"
curl -s -o /dev/null "localhost:8000/api/v1/products?access_token=LEAK001"
docker compose logs kong-node-1 | grep -c LEAK001              # phải là 0
make down
```

**Chưa chạy được:** bộ integration `IT-GW-*` / `IT-KONG-*` (test doc §3) vẫn chưa tồn tại — không phải do đợt này, đã ghi ở báo cáo cũ §12. Kịch bản WebSocket cap connection (`taca-ws-guard` vượt `max_connections_per_user`) chỉ được phủ bằng unit test, tôi không dựng client WS thật.

---

## 4. Chi tiết đã làm

### 4.1 Bảng file thay đổi

| File | Loại | Thay đổi | Vì sao |
|---|---|---|---|
| `kong/plugins/taca-lib/schema_redis.lua` | Mới (18) | Khối schema Redis dùng chung, trả bảng mới mỗi lần gọi | Cùng 11 dòng đó bị copy ở 3 schema; lệch một field giữa chúng là lỗi cấu hình im lặng. Trả bảng mới vì Kong mutate schema khi nạp plugin |
| `kong/plugins/taca-lib/redis_client.lua` | Sửa (141→126) | Gộp `_run`/`key_exists`/`ping` về một `_call`; `_acquire` gộp 3 nhánh lỗi thành một | Ba hàm lặp y hệt chuỗi acquire → chạy → close/keepalive |
| `kong/plugins/taca-lib/metrics_store.lua` | Sửa (137→118) | Gộp guard `dict()` vào một `add()`; bỏ `set_gauge` | `set_gauge` không nơi nào gọi ngoài spec |
| `kong/plugins/taca-lib/envelope_builder.lua` | Sửa (71→64) | Export `JSON_CONTENT_TYPE`; gộp 2 nhánh đầu của `resolve_trace_id` | Hằng số đó bị khai báo lại ở 3 file |
| `kong/plugins/taca-lib/log_redactor.lua` | **Xoá** (80) | — | Code chết, xem mục 1 việc 4 |
| `kong/plugins/taca-jwt/handler.lua` | Sửa (112→77) | Bỏ `build_redis_client`, gọi thẳng `redis_client.new(config.redis)` | `new()` đã nhận đúng shape của block `redis` trong schema; wrapper chỉ để làm seam test |
| `kong/plugins/taca-jwt/jwks.lua` | Sửa (278→233) | Gộp 2 nhánh log lỗi refresh thành `refresh_failed`; guard một dòng | Hai nhánh chỉ khác câu log |
| `kong/plugins/taca-jwt/token_verifier.lua` | Sửa (137→103) | `contains()` dùng chung cho `check_algorithm` + `audience_matches`; `decode_base64url` gộp nhánh pad | Cùng một vòng lặp viết hai lần |
| `kong/plugins/taca-jwt/token_reader.lua`, `actor_context.lua` | Sửa (77→59, 60→55) | Guard một dòng, bỏ biến trung gian | — |
| `kong/plugins/taca-rbac/handler.lua` | Sửa (58→46) | Gộp `has_requirements` vào điều kiện; gộp 2 nhánh deny | Hai nhánh trả cùng một mã lỗi |
| `kong/plugins/taca-ws-guard/handler.lua` | Sửa (100→85) | Như taca-jwt: bỏ wrapper Redis | — |
| `kong/plugins/taca-request-guard/handler.lua` | Sửa (110→94) | `header_filter` gộp nhánh liveness OK/lỗi; `body_filter` bỏ một tầng if | Ba nhánh cùng kết thúc bằng `clear_header("Content-Length")` |
| `kong/plugins/taca-request-guard/ops_endpoint.lua` | Sửa (142→100) | Bỏ wrapper Redis; `check_redis` inline; gộp 3 tầng vòng lặp health | — |
| `kong/plugins/taca-request-guard/request_sanitizer.lua` | Sửa (80→74) | Rút `math.fmod` tính 2 lần thành biến `variant`; `has_prefix` dùng chung | — |
| `kong/plugins/taca-request-guard/origin_guard.lua` | Sửa (33→25) | Gộp 2 điều kiện "cho qua" | — |
| `kong/plugins/taca-error-envelope/body_rewriter.lua` | Sửa (149→120) | `decode_envelope` dùng chung cho 2 hàm; `sanitize_details` bỏ nhánh gán nil vô nghĩa | Hai hàm mở đầu bằng cùng 5 dòng decode + type check |
| `kong/plugins/taca-error-envelope/error_mapper.lua` | Sửa (76→73) | Helper `replace()` thay 5 chỗ dựng bảng plan tay | — |
| `kong/plugins/taca-error-envelope/handler.lua` | Sửa (103→92) | `final_body` dùng `or` thay 4 dòng if | — |
| 3 × `schema.lua` | Sửa | Thay khối `redis` bằng `redis_field()` | — |
| `tools/config-lint/kong_config_linter.py` | Sửa (285→253) | 12 rule đổi thành generator; thêm `iter_services`/`iter_route_paths` dùng chung | Mỗi rule đang lặp `violations = []` … `return violations`; 4 rule lặp cùng một vòng route×path |
| `kong/deck/kong.yaml` | Sửa | Viết lại khối `custom_fields_by_lua` | Mục 1 việc 1 |
| 5 file spec | Sửa | Đổi seam stub `handler.build_redis_client` → `redis_client.new` | Theo thay đổi ở handler; số assertion giữ nguyên |

### 4.2 Thay đổi logic đáng chú ý

**Không có thay đổi hành vi nào ở 5 plugin.** Ba chỗ dễ hiểu nhầm khi review diff:

- `redis_client:key_exists` — `EXISTS` trả `0` khi vắng mặt, và `0` là **truthy** trong Lua. `_call` chỉ coi `nil` là lỗi nên `0` vẫn đi qua đúng như bản cũ. Nếu ai đó sau này đổi `if not value` thành `if not value or value == 0` là hỏng.
- `jwks.get_public_key` — nhánh "refresh xong mà vẫn không có kid" vẫn trả đúng **một** giá trị `nil` + `GATEWAY_TOKEN_INVALID`. Tôi đã viết hụt chỗ này một lần (trả kèm giá trị thừa) và sửa lại trước khi chạy test.
- `token_reader.read` — tôi đã thử bỏ giá trị trả về thứ hai (`sources`), 3 test đỏ ngay: spec có kiểm token đến từ header / subprotocol / query. Đã trả lại nguyên trạng. Đó là contract thật, không phải code thừa.

**Thay đổi hợp đồng dữ liệu:** chỉ một chỗ, và **không** tương thích ngược — bản ghi log của `file-log` không còn field `request.url` và `upstream_uri`, `request.querystring` có giá trị nhạy cảm thành `[REDACTED]`. Xem mục 1 việc 1. Không đụng schema DB (không có DB), không đụng shape response API, không thêm biến môi trường.

### 4.3 Những gì cố ý KHÔNG làm

- **`kong/deck/kong.yaml` (2.830 dòng)** — rút gọn được bằng YAML anchor, nhưng file này đi qua `deck file render --populate-env-vars` rồi mới tới Kong; một anchor đặt sai làm lệch cấu hình 57 route mà unit test không bắt được. Lợi ít, rủi ro cao. Chỉ sửa đúng khối redaction vì đó là lỗi bảo mật.
- **Gộp test trong `spec/`** — 213 test chính là thứ chứng minh đợt refactor này không đổi hành vi. Làm mỏng nó trong cùng một lần sửa là tự bỏ lưới an toàn.
- **`error_catalog.lua`, `.busted`, `Dockerfile`, `docker-compose.yml`, CI** — không có gì để rút; `error_catalog` gần như toàn dữ liệu.
- **`jwks.loaded_at()`, `error_catalog.all()`** — chỉ spec gọi, nhưng mỗi hàm 3 dòng và đang phục vụ test có giá trị (đếm đủ 16 mã lỗi theo API §4). Giữ.
- **Hai đầu mục §7.2 / §7.3** — chờ bạn quyết, không tự sửa.

---

## 5. Lý do & đánh đổi

**Guard clause một dòng.** Đổi `if not x then\n  return nil, err\nend` thành một dòng là nguồn giảm dòng lớn nhất (~150 dòng). Quy tắc tôi áp: chỉ gộp khi thân lệnh có **đúng một câu lệnh ngắn và không có comment**; chỗ nào có comment giải thích "tại sao" thì giữ nguyên dạng nhiều dòng để comment còn chỗ đứng. Đánh đổi: diff nhìn to hơn thực tế vì gần như file nào cũng đụng.

**Bỏ wrapper `build_redis_client` ở 3 nơi.** Ba hàm này tồn tại chỉ để test monkeypatch được. Nhưng `redis_client.new()` vốn đã nhận đúng shape của block `redis` trong schema, nên wrapper là ba bản sao của một phép gán. Tôi dời seam về đúng một chỗ: spec stub `redis_client.new`. Đánh đổi: 4 file spec phải sửa; đổi lại chỉ còn một seam cho cả 5 plugin. Bạn đã duyệt hướng này ở phần phỏng vấn.

**Vẫn giữ comment tiếng Việt dài.** Theo lựa chọn của bạn. Kết quả là 221/1.786 dòng còn lại là comment thuần (12%) — đó là cố ý: những đoạn giải thích `forcible` của shared dict, thứ tự PRIORITY so với `cors`, hay vì sao fail-closed, đều là thứ mất đi thì người sau sẽ "sửa cho gọn" rồi tạo lỗ hổng.

**Rule của linter đổi thành generator.** Bỏ được `violations = []` / `return violations` ở 12 chỗ. An toàn vì test chỉ gọi qua `linter.lint()`, không gọi từng rule. Đánh đổi: ai muốn gọi trực tiếp một rule phải bọc `list()`.

**Vì sao `request.querystring` phải dựng bảng MỚI.** Bản đầu tôi viết sửa tại chỗ bảng của `kong.request.get_query()` — chạy không lỗi nhưng **không có tác dụng**, token vẫn nằm nguyên trong log. Tôi đã dò trên stack thật bằng probe: trả về bảng literal mới thì Kong ghi đè field, trả về chính bảng của `get_query()` thì không (kể cả khi thêm key mới vào đó). Đã ghi lại lý do ngay tại chỗ trong `kong.yaml` để người sau không "tối ưu" ngược lại. Đây là ví dụ rõ nhất cho việc unit test không thay được một lần chạy thật.

---

## 6. Rủi ro & tác động

| Rủi ro | Mức | Kịch bản | Giảm thiểu |
|---|---|---|---|
| **Breaking change** — log mất `request.url`, `upstream_uri` | Trung bình | DevOps có dashboard/alert đọc hai field này thì im lặng không có dữ liệu, không báo lỗi | Cần xác nhận ở mục 1 việc 1; muốn giữ thì thêm vòng redact cho từng field |
| **Bảo mật** — nếu ai thêm query arg nhạy cảm mới (ví dụ `?otp_secret=`) mà quên thêm vào danh sách | Trung bình | Giá trị mới lọt vào log như `access_token` đã từng | Danh sách nằm đúng 2 chỗ trong `kong.yaml`; đề xuất thêm quy tắc lint R13 đối chiếu — chưa làm, ngoài phạm vi |
| **Chia sẻ schema** — `redis_field()` dùng chung cho 3 plugin | Thấp | Nếu Kong mutate bảng schema, một plugin làm bẩn hai plugin kia | Đã trả **bảng mới mỗi lần gọi**, và `kong config parse` trên Kong 3.9.0 thật đã pass |
| **Mất 6 test** (213 → 207) | Thấp | Không mất độ phủ nghiệp vụ — 6 test đó kiểm module chưa từng được gọi | Độ phủ thật do 14 kịch bản ở mục 3 bảo chứng |
| Hiệu năng | Thấp | Không có query/vòng lặp/lời gọi mạng nào mới. `_call` thêm một closure mỗi lệnh Redis — không đáng kể so với round-trip mạng | — |
| Đồng thời & trạng thái | Thấp | Không đụng logic lock, TTL, counter, single-flight của JWKS | 207 test phủ nguyên các nhánh đó |

---

## 7. Phụ lục

**Số dòng theo thư mục**

| Thư mục | Trước | Sau | Chênh |
|---|---:|---:|---:|
| `kong/plugins` | 2.198 | 1.786 | −412 (−18,7%) |
| `tools/config-lint` | 475 | 443 | −32 |
| `spec` | 2.678 | 2.646 | −32 |

**Chưa commit.** 29 file đang ở working tree trên nhánh `develop`. Theo git flow của repo, nên tách ít nhất 2 nhánh: `refactor/plugin-slimming` và `fix/log-redaction-token-leak` — nhánh thứ hai là bản vá bảo mật, đáng đứng riêng để review và cherry-pick được.
