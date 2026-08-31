-- Cấu hình taca-request-guard (LLD §2.1.2, §2.1.5, §4.1).

local typedefs = require "kong.db.schema.typedefs"

return {
  name = "taca-request-guard",
  fields = {
    { protocols = typedefs.protocols_http },
    {
      config = {
        type = "record",
        fields = {
          -- Ngoài vai trò guard, LLD §2.1.5 giao cho plugin này ba endpoint vận hành.
          -- Chúng nằm trên Route nội bộ riêng, không dùng chung instance với route business.
          {
            mode = {
              type = "string",
              default = "proxy",
              one_of = { "proxy", "liveness", "readiness", "metrics" },
            },
          },
          -- Phải khớp với cors.config.origins; hai danh sách lệch nhau là lỗ hổng
          -- hoặc chặn nhầm frontend (LLD §8 #16) — lint CI đối chiếu hai nơi này.
          { allowed_origins = { type = "array", default = {}, elements = { type = "string" } } },
          { request_id_header = { type = "string", default = "X-Request-ID" } },
          { request_id_max_length = { type = "integer", default = 64 } },
          {
            stripped_header_prefixes = {
              type = "array",
              default = { "X-User-", "X-Auth-" },
              elements = { type = "string" },
            },
          },
          -- Rỗng nghĩa là không tin bất kỳ proxy nào: mọi X-Forwarded-* do client gửi
          -- đều bị xoá. Đây là mặc định an toàn cho rate limit theo IP (LLD §2.5).
          { trusted_proxy_cidrs = { type = "array", default = {}, elements = { type = "string" } } },
          { service_name = { type = "string", default = "api-gateway" } },
          {
            jwks = {
              type = "record",
              fields = {
                { jwks_uri = { type = "string" } },
                { jwks_shared_dict = { type = "string", default = "taca_jwks" } },
                { lock_shared_dict = { type = "string", default = "taca_locks" } },
                { jwks_ttl_seconds = { type = "number", default = 600 } },
                { jwks_max_stale_seconds = { type = "number", default = 1800 } },
                { jwks_request_timeout_ms = { type = "number", default = 2000 } },
              },
            },
          },
          {
            redis = {
              type = "record",
              fields = {
                { host = { type = "string", default = "127.0.0.1" } },
                { port = { type = "integer", default = 6379 } },
                { database = { type = "integer", default = 0 } },
                { password = { type = "string", encrypted = true } },
                { timeout_ms = { type = "number", default = 500 } },
              },
            },
          },
        },
      },
    },
  },
}
