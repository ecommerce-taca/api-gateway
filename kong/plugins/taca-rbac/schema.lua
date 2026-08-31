-- Cấu hình taca-rbac (LLD §2.1.2). Yêu cầu quyền khai báo trên từng Route trong decK,
-- không nằm trong code: đổi quyền của một nhánh route là đổi config, không phải deploy image.

local typedefs = require "kong.db.schema.typedefs"

return {
  name = "taca-rbac",
  fields = {
    { protocols = typedefs.protocols_http },
    {
      config = {
        type = "record",
        fields = {
          -- Ngữ nghĩa "any-of": route admin chỉ cần bất kỳ role admin nào (LLD §2.3),
          -- permission chi tiết do service sở hữu dữ liệu enforce.
          { required_roles = { type = "array", default = {}, elements = { type = "string" } } },
          { required_any_permission = { type = "array", default = {}, elements = { type = "string" } } },
        },
      },
    },
  },
}
