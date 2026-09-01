# Bản đồ code API Gateway — đọc hiểu trong 20 phút

**Trạng thái:** Đầy đủ cho toàn bộ code đang chạy trên `develop` sau đợt refactor 2026-09-01.
**Ngày:** 2026-09-01 · **Phạm vi:** `kong/`, `spec/`, `tools/`, `mocks/`, `Dockerfile`, `docker-compose.yml`, `Makefile`

Tài liệu này viết cho người **sẽ phải sửa code này**, không phải cho người duyệt kiến trúc. Mọi con số đều đọc ra từ code/config thật tại thời điểm viết, không lấy lại từ báo cáo cũ. Thiết kế và lý do gốc nằm ở `docs/api-gateway-docs/docs/lld/api-gateway.md`; ở đây chỉ nói **code thực sự làm gì**.

---

## 1. Cần bạn xác nhận trước khi tin tài liệu này

- **[✓ Đã kiểm chứng]** Toàn bộ PRIORITY của plugin built-in trong tài liệu này đọc trực tiếp từ image `kong:3.9.0` (`grep PRIORITY /usr/local/share/lua/5.1/kong/plugins/*/handler.lua`), **không** lấy theo LLD §2.1.3 — LLD ghi `rate-limiting = 901` là số của phiên bản khác. Nâng Kong lên bản khác thì phải kiểm lại bảng ở mục 4.2 trước tiên.
- **[~ Suy luận]** Hai chỗ code **cố ý lệch tài liệu**, đã nêu ở báo cáo trước và vẫn chờ quyết: `taca-error-envelope` giữ status thật của upstream 4xx thay vì `502` (LLD §3.6), và `/api/v1/auth/**` gate ở mức family thay vì từng endpoint (LLD §2.3). Đọc code mà đối chiếu LLD sẽ thấy vênh — đó là chủ ý, không phải bug.
- **[✓ Đã kiểm chứng]** Bản ghi log của `file-log` **không còn** field `request.url` và `upstream_uri` (bỏ để chặn token lọt vào log). Nếu bạn đang tìm hai field đó trong log thì không phải log hỏng.
- **[? Giả định]** Tôi coi `develop` là nhánh nguồn sự thật. 29 file của đợt refactor **chưa commit**, đang nằm ở working tree.

---

## 2. Nếu chỉ có 10 phút

Đọc đúng 5 file này, theo thứ tự, là nắm được 80% hệ thống:

| # | File | Vì sao đọc |
|---|---|---|
| 1 | `kong/plugins/taca-lib/error_catalog.lua` (46 dòng) | 16 mã lỗi + HTTP status + message. Đây là contract đối ngoại, ngắn nhất, đọc 2 phút |
| 2 | `kong/plugins/taca-jwt/handler.lua` (77 dòng) | Luồng xác thực đầy đủ trong một hàm `access()` — đọc là hiểu cách 5 plugin phối hợp |
| 3 | `kong/plugins/taca-request-guard/handler.lua` (94 dòng) | Plugin chạy đầu tiên; kiêm cả 3 endpoint vận hành |
| 4 | `kong/plugins/taca-error-envelope/error_mapper.lua` (73 dòng) | Toàn bộ bảng ánh xạ lỗi → mã Gateway, logic thuần, không PDK |
| 5 | `kong/deck/kong.yaml` dòng 1–120 | Phần global: plugin toàn cục + thứ tự + redaction log |

**Điều quan trọng nhất phải hiểu trước:** Gateway này **không phải là một ứng dụng**. Nó là Kong 3.9.0 OSS chạy DB-less, cộng 5 plugin Lua tự viết. Phần lớn hành vi (routing, rate limit, CORS, timeout, retry, circuit breaker, metrics, trace) nằm trong **cấu hình** `kong/deck/kong.yaml`, không nằm trong code. Đọc hết 1.786 dòng Lua mà không đọc config thì vẫn không hiểu hệ thống làm gì.

---

## 3. Cách bạn tự kiểm chứng tài liệu này

Dựng stack thật rồi tự nhìn — nhanh hơn đọc:

```bash
make up                                        # 2 node Kong + Redis + 1 nginx đóng vai 10 upstream
curl -s localhost:8000/health/ready | jq       # thấy 4 dependency check
curl -s localhost:8000/api/v1/nope | jq        # thấy hình dạng error envelope
TOKEN=$(make token | tail -1)                  # ký một token dev
curl -s -D- -o /dev/null -H "Authorization: Bearer $TOKEN" \
     localhost:8000/api/v1/users/me | grep -i x-mock-seen   # thấy actor header upstream nhận được
docker compose logs kong-node-1 | tail -1 | jq # thấy một bản ghi log hoàn chỉnh
make down
```

Đọc code không cần Docker:

```bash
make test                       # 207 unit test, ~1 giây
make lint                       # 12 quy tắc cấu hình + 23 test của linter
```

**Ba chỗ đáng soi nhất nếu bạn nghi tài liệu này sai:** bảng PRIORITY ở 4.2 (soi bằng lệnh ở mục 1), bảng `kong.ctx.shared` ở 4.4 (`grep -rn "kong.ctx.shared" kong/plugins`), và bảng "muốn làm X sửa ở đâu" ở 4.8.

---

## 4. Bản đồ code

### 4.1 Thư mục nào làm gì

```
kong/
  kong.conf                 # database=off, 3 shared dict, header limit 16KiB, tắt access log nginx
  deck/
    kong.yaml               # 2.8k dòng: 10 upstream, 23 service, 57 route, 8 plugin global
    env/{dev,staging,prod}.yaml   # biến môi trường, deck render thay vào kong.yaml
    Makefile                # render → validate → lint → diff → sync
  plugins/                  # 1.786 dòng Lua — phần duy nhất là "code"
    taca-lib/               # dùng chung, KHÔNG phải plugin (không nằm trong KONG_PLUGINS)
    taca-request-guard/     # PRIORITY 2100
    taca-jwt/               # 940
    taca-rbac/              # 930
    taca-ws-guard/          # 900
    taca-error-envelope/    # 1
spec/                       # 207 unit test busted, chạy dưới `resty` để có shared dict thật
tools/config-lint/          # linter Python 12 quy tắc cho kong.yaml đã render
mocks/                      # nginx đóng vai 10 service + JWKS + OTEL collector; khoá dev JWKS
```

Quy ước đặt tên trong `kong.yaml`: upstream `up-<domain>`, service `svc-<domain>-read` / `svc-<domain>-write`, route `rt-<domain>-<family>-<read|write>`.

### 4.2 Vòng đời một request

Kong chạy plugin theo `PRIORITY` **giảm dần** trong mỗi phase. Số dưới đây đọc từ image `kong:3.9.0`:

| Thứ tự | Plugin | PRIORITY | Phase | Làm gì |
|---:|---|---:|---|---|
| 1 | `correlation-id` | 100001 | access | Sinh/giữ `X-Request-ID` (UUIDv4) |
| 2 | **`taca-request-guard`** | **2100** | access | Origin allowlist → `403`; validate `X-Request-ID`, sai thì **ghi đè** bằng UUIDv7; xoá `X-User-*`/`X-Auth-*`/`X-Forwarded-*` |
| 3 | `cors` | 2000 | access | Header CORS + preflight |
| 4 | `request-size-limiting` | 951 | access | Body ≤ 1 MiB |
| 5 | **`taca-jwt`** | **940** | access | Verify RS256 qua JWKS cache; check revoke trong Redis; đặt `X-User-*` cho upstream |
| 6 | **`taca-rbac`** | **930** | access | Gate role/permission khai báo trên Route |
| 7 | `rate-limiting` | 910 | access | 3 bucket, `policy=redis`, `fault_tolerant=false` |
| 8 | **`taca-ws-guard`** | **900** | access + log | Đếm connection WS theo user |
| 9 | `opentelemetry` / `prometheus` / `file-log` | 14 / 13 / 9 | log | Trace, metric, log |
| 10 | **`taca-error-envelope`** | **1** | access + header_filter + body_filter | Chuẩn hoá **mọi** response ≥ 400 về envelope |

Ba con số buộc phải nhớ, sai là vỡ:

- **2100 > 2000**: `taca-request-guard` phải chạy **trước** `cors`. Chạy sau thì `cors` đã trả `200` cho preflight của origin lạ, và yêu cầu "origin ngoài allowlist nhận `403`" không bao giờ đạt được.
- **940 > 910**: `taca-jwt` phải đặt `X-User-ID` **trước** khi `rate-limiting` bucket authenticated đọc header đó (`limit_by: header`, `header_name: X-User-ID`).
- **1**: `taca-error-envelope` thấp nhất để chạy **sau** mọi plugin ở `header_filter`/`body_filter`, bao được cả lỗi do chính chúng sinh ra (`file-log` là plugin built-in thấp nhất ở hai phase này, `9`).

### 4.3 Năm plugin

**`taca-request-guard`** — `kong/plugins/taca-request-guard/`

Một plugin, bốn chế độ, chọn bằng `config.mode`: `proxy` (mặc định), `liveness`, `readiness`, `metrics`. Ba chế độ sau nằm trên Route nội bộ riêng (`kong.yaml` dòng ~2786/2804/2842), không dùng chung instance với route business.

| File | Vai trò |
|---|---|
| `handler.lua:52` `access()` | Điều phối theo `mode` |
| `handler.lua:26` `guard_request()` | Đường đi của route business: origin → request id → strip header |
| `origin_guard.lua` | Allowlist Origin. Không có header `Origin` = không phải trình duyệt → cho qua |
| `request_sanitizer.lua` | Sinh UUIDv7 (48 bit đầu là ms, sắp xếp được theo thời gian), validate charset request id, xoá header giả mạo |
| `ops_endpoint.lua` | Body của `/health/live`, `/health/ready`, phần metric custom nối vào `/metrics` |

`X-Forwarded-*` chỉ được giữ khi client nằm trong `trusted_proxy_cidrs`; mặc định danh sách rỗng = **không tin proxy nào**.

**`taca-jwt`** — trái tim của hệ thống, đọc kỹ nhất

`handler.lua:54` `access()` chạy đúng 4 bước: đọc token → `verify_token()` → `is_revoked()` → dựng actor.

| File | Vai trò |
|---|---|
| `token_reader.lua` | 3 nguồn token, thứ tự cố định: `Authorization` > `Sec-WebSocket-Protocol` (dạng `bearer, <token>`) > query `?access_token=`. Hai nguồn sau phải bật bằng config |
| `token_verifier.lua` | Parse base64url, chặn mọi `alg` ngoài `RS256`, verify chữ ký, validate `iss/aud/sub/exp/iat/nbf` với clock skew |
| `jwks.lua` | **File phức tạp nhất (233 dòng)** — cache JWKS 2 tầng + single-flight refresh. Xem 5.2 |
| `actor_context.lua` | Claim → `X-User-ID`, `X-User-Roles`, `X-User-Permissions`, `X-User-Shop-Scope`, `X-Auth-Method` |

`token_required = false` (route public) nghĩa là **không có token thì cho qua**, nhưng **có token sai vẫn bị từ chối** — không im lặng bỏ qua.

**`taca-rbac`** — 46 dòng, đơn giản nhất

Ngữ nghĩa **any-of**: có bất kỳ role nào trong `required_roles` là qua. Yêu cầu rỗng = không gate. Cố ý **không** làm: đọc body, suy ownership từ `shop_id`, quyết định 2FA — ba việc đó thuộc service sở hữu dữ liệu.

Có yêu cầu quyền mà không thấy actor ⇒ route thiếu `taca-jwt` ⇒ từ chối + ghi `kong.log.warn` (và quy tắc lint R04 bắt được ở CI).

**`taca-ws-guard`** — chỉ gắn trên `/ws/messages`

`access()` `INCR` counter, vượt cap thì `DECR` trả lại rồi `429`. `log()` `DECR` — với connection đã upgrade, phase `log` của Kong chạy lúc **connection đóng**, đúng thời điểm cần. `DECR` phải chạy trong `ngx.timer` vì phase `log` của nginx không cho dùng cosocket (`handler.lua:31`).

Key Redis chứa **hash** của user id, không chứa id thô: `ws:v1:conn:<sha256 32 ký tự đầu>`.

**`taca-error-envelope`** — lớp cuối cùng

Ba phase phối hợp:

1. `access()` chỉ đặt một cờ `taca_envelope_access_reached`. Cờ này là **dấu vết**: nếu request chết mà cờ không có, nghĩa là một plugin phía trước đã raise Lua error thay vì thoát có kiểm soát — dùng để nhận ra Redis của `rate-limiting` hỏng (Kong OSS raise error trần, response chỉ còn `500` vô danh).
2. `header_filter()` gọi `error_mapper.plan()` để quyết định giữ hay thay, rồi sửa status/header.
3. `body_filter()` **nuốt mọi chunk** cho tới chunk cuối rồi mới ghi body mới — vì chỉ khi có đủ body mới biết body 4xx của upstream có đúng contract hay không.

`error_mapper.lua` phân hai đường theo `kong.response.get_source()`: `"service"` (upstream thật) vs `"exit"/"error"` (Kong/plugin sinh). Upstream 5xx **không bao giờ** pass-through; upstream 4xx thì giữ status thật và giữ business code nếu body hợp lệ.

`body_rewriter.lua` có 9 pattern chặn rò rỉ nội bộ (`://`, `%.lua:%d`, `stack traceback`, `sqlstate`, câu SQL, địa chỉ IP, `/usr/`, `/etc/`). Gặp pattern nào thì **bỏ hẳn giá trị**, không "làm sạch" nửa vời.

### 4.4 Năm plugin nói chuyện với nhau bằng gì

Không có message bus, không có singleton. Chỉ 7 key trên `kong.ctx.shared` (phạm vi một request):

| Key | Ai ghi | Ai đọc | Nội dung |
|---|---|---|---|
| `taca_trace_id` | request-guard `access` | envelope_builder | Request id dùng cho `trace_id` của mọi envelope |
| `taca_actor` | jwt `access` | rbac, ws-guard | `{user_id, roles, permissions, shop_scope, email_verified}` |
| `taca_ws_connection_key` | ws-guard `access` | ws-guard `log` | Key Redis để `DECR` khi connection đóng |
| `taca_envelope_access_reached` | error-envelope `access` | error_mapper | Dấu vết phân biệt lỗi có kiểm soát với Lua error trần |
| `taca_envelope_plan` | error-envelope `header_filter` | `body_filter` | Kế hoạch viết lại body |
| `taca_envelope_buffer` | error-envelope `header_filter` | `body_filter` | Bộ đệm gom chunk |
| `taca_ops_body` | request-guard `header_filter` | `body_filter` | Body của `/health/live` |

Đây là toàn bộ trạng thái chia sẻ giữa các plugin. Muốn biết plugin A ảnh hưởng plugin B thế nào, chỉ cần tra bảng này.

### 4.5 `taca-lib` — hạ tầng dùng chung

| File | Vai trò | Ghi chú khi sửa |
|---|---|---|
| `error_catalog.lua` | 16 mã lỗi → status + message tiếng Việt | Nguồn duy nhất. Code lạ → fallback `GATEWAY_INTERNAL_ERROR`, không bao giờ trả nil |
| `envelope_builder.lua` | Dựng/encode envelope, `exit()`, `resolve_trace_id()` | **Mọi lối thoát lỗi phải đi qua đây.** Không plugin nào tự gọi `kong.response.exit` với body tự chế |
| `redis_client.lua` | Bọc `resty.redis` sau interface của mình | Business code chỉ gọi `increment_with_expiry` / `decrement` / `key_exists` / `ping`. INCR+EXPIRE là một Lua script để nguyên tử |
| `metrics_store.lua` | 3 metric custom vào shared dict `taca_metrics` | Label có allowlist cứng — API §3.3 cấm user_id/IP/token vào label |
| `schema_redis.lua` | Khối schema Redis dùng chung cho 3 plugin | Trả **bảng mới** mỗi lần gọi vì Kong mutate schema khi nạp plugin |

### 4.6 Cấu hình declarative

`kong.yaml` không sync thẳng. Vòng đời: `render` (thay biến env) → `validate` (schema của decK) → `lint` (12 quy tắc riêng) → `diff` → `sync`. Tất cả trong `kong/deck/Makefile`, chạy bằng container nên máy dev không cần cài decK.

Ba quyết định định hình file này:

1. **`retries` là thuộc tính của Service, không phải Route.** Vì vậy mỗi domain tách đôi: `svc-*-read` (`retries=1`, chỉ `GET/HEAD/OPTIONS`) và `svc-*-write` (`retries=0`). Đó là cách duy nhất Kong cho phép "chỉ retry GET". Đây là lý do có 23 service cho 10 upstream.
2. **Path chồng nhau tách bằng regex**, vì router của Kong xét regex trước prefix: `/products/{id}/reviews` → `rating-comment` chứ không phải `product-catalog`.
3. **Hai danh sách origin sinh từ cùng 4 biến** cho cả `cors.origins` lẫn `taca-request-guard.allowed_origins`; quy tắc lint R09 đối chiếu chúng.

Ba bucket rate limit (`policy: redis`, `fault_tolerant: false` ở mọi chỗ):

| Bucket | Giới hạn | Tính theo | Dùng ở |
|---|---|---|---|
| auth | 10/phút | IP | `/api/v1/auth/**` |
| public | 120/phút | IP | Route public (products, categories, search…) |
| authenticated | 300/phút | header `X-User-ID` | Mọi route cần đăng nhập |

### 4.7 Test

`make test` build stage `test` của Dockerfile rồi chạy busted **dưới `resty`**, không dưới `lua` trần:

```
resty --shdict "taca_jwks 10m" --shdict "taca_locks 1m" --shdict "taca_metrics 5m" ...
```

Lý do: `resty.lock` và `lua_shared_dict` là hai thứ không giả lập trung thực được. Còn lại PDK của Kong được stub trong `spec/helpers/kong_stub.lua` — chỉ stub đúng hàm plugin thật sự gọi.

Điểm nối để test thay implementation (biết chỗ này là viết test được ngay):

- `jwks.fetch_jwks` — điểm ra HTTP duy nhất, test gán fixture vào
- `redis_client.new` — **seam duy nhất cho cả 5 plugin**, test gán hàm trả object giả
- `ops_endpoint.read_upstream_health` — tránh phụ thuộc balancer thật
- `jwks.reset_worker_cache()` — xoá lrucache theo worker giữa các case

### 4.8 Muốn làm X thì sửa file nào

| Việc | Sửa ở đâu | Nhớ làm kèm |
|---|---|---|
| Thêm/đổi route, đổi upstream | `kong/deck/kong.yaml` | `make lint` cả 3 môi trường; nhớ `strip_path: false` (R10) |
| Đổi quyền của một nhánh route | Config `taca-rbac` trên Route trong `kong.yaml` | Không phải sửa code, không cần build lại image |
| Thêm mã lỗi mới | `taca-lib/error_catalog.lua` | Cập nhật API §4; spec đang assert đủ 16 mã |
| Đổi giới hạn rate limit | `kong.yaml`, plugin `rate-limiting` của route | Giữ `fault_tolerant: false` (R08) |
| Đổi cách đọc token | `taca-jwt/token_reader.lua` | `read()` trả **2 giá trị**, spec kiểm giá trị thứ hai |
| Thêm claim vào actor header | `taca-jwt/actor_context.lua` | Giá trị phải qua `SAFE_VALUE_PATTERN` trước khi nối bằng dấu phẩy |
| Đổi ánh xạ status → mã lỗi | `taca-error-envelope/error_mapper.lua` | Logic thuần, test không cần Kong |
| Thêm field cần redact khỏi log | `kong.yaml`, khối `custom_fields_by_lua` | Xem cạm bẫy ở mục 6 |
| Thêm quy tắc lint cấu hình | `tools/config-lint/kong_config_linter.py` + thêm vào tuple `RULES` | Thêm fixture config sai vào `tools/config-lint/fixtures/` |
| Thêm biến môi trường | `kong/deck/env/*.yaml` cả 3 file | R12 chặn giá trị bí mật hard-code |

---

## 5. Tám quyết định giải thích vì sao code trông như vậy

**5.1 Vì sao phải tự viết plugin thay vì dùng plugin của Kong.** Kong OSS không có JWKS (chỉ có plugin `jwt` với khoá tĩnh) và không có RBAC theo claim. Ba plugin còn lại sinh ra vì: `cors` của Kong chỉ bỏ header chứ không trả `403`; Kong không có connection cap cho WebSocket; và body lỗi mặc định của Kong là câu tiếng Anh không có mã máy đọc được. Ngoài 5 thứ đó, mọi thứ khác đều dùng plugin built-in — đây là chủ ý, không phải thiếu sót.

**5.2 Vì sao JWKS cache hai tầng.** `lua_shared_dict` dùng chung giữa các worker của một node nhưng **chỉ lưu được string**, nên nó giữ PEM. `lrucache` giữ object `pkey` đã parse cho từng worker để không parse lại PEM mỗi request. Ba trạng thái theo tuổi cache: `AVAILABLE` (< `jwks_ttl_seconds`), `STALE` (< `jwks_max_stale_seconds`, vẫn dùng key cũ nhưng đếm metric `outcome="stale"` để vận hành thấy trước khi vỡ), `UNAVAILABLE`. Refresh chạy dưới `resty.lock` (single-flight): nhiều request cùng gặp `kid` lạ sẽ chờ trên lock thay vì cùng bắn request tới auth-user.

**5.3 Vì sao `write_keys` coi `forcible` là thất bại.** `shared_dict:set` trả cờ `forcible = true` khi nó đã phải **đuổi entry khác** để lấy chỗ. Ghi tiếp trong tình huống đó nghĩa là key của `kid` khác vừa bị xoá và request kế tiếp sẽ verify hụt. Nên code fail-closed: coi cả lần refresh là hỏng (`jwks.lua`, hàm `write_keys`). Đây là chỗ dễ bị "sửa cho gọn" nhất và cũng nguy hiểm nhất.

**5.4 Vì sao mọi thứ fail-closed khi Redis chết.** Ba chỗ: revoke check trong `taca-jwt`, connection cap trong `taca-ws-guard`, và `fault_tolerant: false` của `rate-limiting`. Lý do chung: cho qua khi Redis chết nghĩa là mất cap và mất khả năng khoá user **đúng lúc hệ thống yếu nhất**. Đánh đổi: Redis là single point of failure cho toàn bộ route business — đã biết và chấp nhận (LLD §3.6).

**5.5 Vì sao request id tự sinh UUIDv7 mà không dùng `correlation-id`.** Plugin `correlation-id` sinh UUIDv4. UUIDv7 có 48 bit đầu là timestamp mili giây nên **sắp xếp được theo thời gian** khi tra log — thứ quyết định khi debug sự cố. `taca-request-guard` chạy sau `correlation-id` và ghi đè giá trị khi client gửi id sai charset/độ dài.

**5.6 Vì sao `taca-error-envelope` phải buffer body.** Với upstream 4xx, phải đọc **hết** body mới biết nó có đúng contract envelope hay không. Ở `header_filter` thì Kong chưa có body. Hệ quả đã biết: không đổi được status sau khi đã đọc body — đây chính là gốc của điểm lệch LLD §3.6 nêu ở mục 1. Cách duy nhất để làm khác là bật response buffering, mà buffering phá tunnel WebSocket.

**5.7 Vì sao hạ tầng ngoài luôn bị bọc.** `resty.redis` chỉ xuất hiện trong `taca-lib/redis_client.lua`; `resty.http` chỉ xuất hiện trong `jwks.lua`. Business code nói ý định (`key_exists`, `increment_with_expiry`), không biết driver nào ở dưới. Nhờ vậy test không cần Redis thật — chỉ cần thay `redis_client.new`.

**5.8 Vì sao có linter Python riêng cho config.** Sau khi chuyển sang Kong, phần lớn hành vi nằm ở cấu hình chứ không ở code, mà `deck file validate` chỉ kiểm cấu trúc/schema. 12 quy tắc R01–R12 kiểm những thứ schema không biết: service `*-write` phải `retries=0`, route `/admin/**` phải có `taca-rbac`, không có route catch-all, hai danh sách origin phải khớp… Linter chạy trên file **đã render** để so được cả giá trị chỉ xuất hiện sau khi thay biến môi trường. Bản thân linter có 23 test trên 4 fixture config sai — thiếu chúng thì một quy tắc viết hỏng sẽ im lặng cho mọi config đi qua.

---

## 6. Cạm bẫy khi sửa code này

| Cạm bẫy | Mức | Chuyện gì xảy ra |
|---|---|---|
| Đổi `PRIORITY` của plugin custom | **Cao** | Không có test nào bắt được. Hạ `taca-request-guard` xuống dưới 2000 là mất `403` cho origin lạ; hạ `taca-jwt` xuống dưới 910 là bucket authenticated đếm nhầm sang IP |
| Sửa `custom_fields_by_lua` trong `kong.yaml` | **Cao** | Hai bẫy đã trả giá: (a) key chỉ tách theo **dấu chấm**, cú pháp ngoặc `["x-y"]` im lặng không có tác dụng; (b) trả về chính bảng của `kong.request.get_query()` thì Kong **không** ghi đè field — phải dựng bảng mới. Cả hai đều không báo lỗi, chỉ âm thầm không redact |
| Đổi `if not value` trong `redis_client:key_exists` | Trung bình | `EXISTS` trả `0` khi vắng mặt, và `0` là **truthy** trong Lua. Thêm `or value == 0` là biến "user không bị revoke" thành lỗi Redis |
| Coi `forcible` của shared dict là thành công | Trung bình | Xem 5.3 |
| Thêm plugin đọc/ghi body lên route `/ws/messages` | Trung bình | Hỏng frame sau khi upgrade. Quy tắc lint R11 chặn, nhưng chỉ với danh sách plugin đã biết |
| Sinh route mới mà quên `strip_path: false` | Trung bình | Service đích nhận path đã bị cắt `/api/v1`. R10 bắt được |
| Tin bảng PRIORITY trong LLD | Trung bình | LLD ghi `rate-limiting = 901`, số thật của 3.9.0 là `910` |
| Nâng Kong lên 4.x | Trung bình | `opentelemetry.header_type` bị bỏ sau 4.0, phải đổi sang `propagation`. PRIORITY built-in cũng phải kiểm lại |
| Sửa `spec/helpers/kong_stub.lua` cho "đầy đủ hơn" | Thấp | Stub cố ý chỉ có hàm plugin thật sự gọi; thêm hàm không dùng làm test kém trung thực |

**Nợ kỹ thuật đã biết, không phải bug:** healthcheck của Kong là **per-node** và đếm lỗi **liên tiếp**, không theo cửa sổ 30s như `CIRCUIT_WINDOW` trong thiết kế; `RATE_LIMIT_BURST` và `UPSTREAM_RETRY_BACKOFF` không có tương đương native trong Kong OSS. Ba hằng số đó trong LLD không được thực thi — đã ghi chú tại chỗ trong `kong.yaml`.

---

## 7. Phụ lục

**Số liệu code** (2026-09-01, sau refactor)

| Phần | Dòng | Ghi chú |
|---|---:|---|
| `kong/plugins` | 1.786 | 24 file Lua, 221 dòng comment |
| `kong/deck/kong.yaml` | 2.830 | 10 upstream · 23 service · 57 route · 8 plugin global |
| `spec` | 2.646 | 207 test |
| `tools/config-lint` | 443 | 12 quy tắc · 23 test |

**16 mã lỗi** (`taca-lib/error_catalog.lua`) — `GATEWAY_` + `INVALID_REQUEST` 400 · `ROUTE_NOT_FOUND` 404 · `AUTH_REQUIRED` 401 · `TOKEN_INVALID` 401 · `TOKEN_EXPIRED` 401 · `PERMISSION_DENIED` 403 · `CORS_DENIED` 403 · `RATE_LIMITED` 429 · `REQUEST_TOO_LARGE` 413 · `JWKS_UNAVAILABLE` 503 · `REDIS_UNAVAILABLE` 503 · `UPSTREAM_TIMEOUT` 504 · `UPSTREAM_UNAVAILABLE` 503 · `UPSTREAM_BAD_RESPONSE` 502 · `CONFIG_INVALID` 503 · `INTERNAL_ERROR` 500.

**Hình dạng envelope** — `{"error":{"code","message","details","trace_id"}}`. `details` rỗng là mảng `[]`, không phải object.

**Key Redis do code này tạo** — `revoked_user:<sub>` (marker do auth-user đẩy, Gateway chỉ đọc) · `ws:v1:conn:<sha256 32 ký tự>` (counter có TTL 3600s). Key của `rate-limiting` do plugin Kong quản lý, format riêng của nó, đừng viết script phụ thuộc.

**Shared dict** (`kong/kong.conf:43`) — `taca_jwks 10m` (PEM theo kid + `meta:loaded_at`) · `taca_locks 1m` (single-flight refresh) · `taca_metrics 5m` (3 metric custom).

**Tài liệu gốc** — `docs/api-gateway-docs/docs/{lld,api,db,test}/api-gateway.md`. Báo cáo triển khai: `docs/reports/api-gateway-implementation-report.md`. Báo cáo refactor gần nhất: `docs/reports/2026-09-01-toi-uu-code-gateway.md`.
