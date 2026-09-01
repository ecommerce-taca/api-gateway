-- Cấu hình taca-jwt (LLD §2.4, §4.1). Mọi giá trị đến từ decK, không hard-code trong code:
-- thiếu field bắt buộc thì `deck validate` fail trước khi sync (LLD §2.1.2).

local typedefs = require "kong.db.schema.typedefs"
local redis_field = require "kong.plugins.taca-lib.schema_redis"

return {
  name = "taca-jwt",
  fields = {
    { protocols = typedefs.protocols_http },
    {
      config = {
        type = "record",
        fields = {
          { issuer = { type = "string", required = true } },
          { audience = { type = "string", required = true } },
          { jwks_uri = { type = "string", required = true } },
          -- Chỉ RS256. Để dạng mảng vì schema cần chỗ mở rộng, nhưng giá trị nào ngoài
          -- RS256 phải bị chặn ở đây, không phải ở runtime (SEC-GW-03).
          {
            allowed_algorithms = {
              type = "array",
              default = { "RS256" },
              elements = { type = "string", one_of = { "RS256" } },
            },
          },
          { clock_skew_seconds = { type = "number", default = 30 } },
          { jwks_ttl_seconds = { type = "number", default = 600 } },
          { jwks_max_stale_seconds = { type = "number", default = 1800 } },
          { jwks_request_timeout_ms = { type = "number", default = 2000 } },
          { jwks_shared_dict = { type = "string", default = "taca_jwks" } },
          { lock_shared_dict = { type = "string", default = "taca_locks" } },
          -- Route public có thể nhận token tuỳ chọn để service cá nhân hoá response
          -- (LLD §3.1); token sai vẫn bị từ chối, không âm thầm bỏ qua.
          { token_required = { type = "boolean", default = true } },
          { accept_websocket_subprotocol = { type = "boolean", default = false } },
          { accept_query_token = { type = "boolean", default = false } },
          { revocation_check_enabled = { type = "boolean", default = true } },
          redis_field(),
        },
      },
    },
  },
}
