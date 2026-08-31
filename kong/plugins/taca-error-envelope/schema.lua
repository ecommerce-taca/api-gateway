-- Cấu hình taca-error-envelope (LLD §2.1.2, §2.1.6).

local typedefs = require "kong.db.schema.typedefs"

return {
  name = "taca-error-envelope",
  fields = {
    { protocols = typedefs.protocols_http },
    {
      config = {
        type = "record",
        fields = {
          -- Rỗng nghĩa là chấp nhận mọi business code đúng định dạng. Allowlist thật của
          -- từng service vẫn là câu hỏi mở trong API §5 #7; khai báo được ở đây để siết
          -- lại từng nhánh route ngay khi service chốt danh sách.
          {
            allowed_business_error_codes = {
              type = "array",
              default = {},
              elements = { type = "string" },
            },
          },
          -- Bật trên route có rate-limiting dùng Redis. Kong OSS raise Lua error trần khi
          -- Redis hỏng (rate-limiting/handler.lua:146) nên response chỉ còn là 500 vô danh;
          -- cờ này cho phép phân biệt nó với lỗi Lua khác, xem error_mapper.
          { redis_backed_rate_limit = { type = "boolean", default = false } },
        },
      },
    },
  },
}
