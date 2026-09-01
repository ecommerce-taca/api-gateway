-- taca-rbac — coarse gate theo role/permission khai báo trên Route (LLD §2.1.2).
-- Cố ý KHÔNG làm: đọc body, suy luận ownership từ shop_id trong path/body, quyết định 2FA.
-- Ba việc đó thuộc service sở hữu dữ liệu; làm ở đây sẽ tạo hai nguồn sự thật về quyền.

local envelope_builder = require "kong.plugins.taca-lib.envelope_builder"

local TacaRbacHandler = {
  -- Sau taca-jwt (940) vì đọc actor do plugin đó đặt, trước rate-limiting (910).
  PRIORITY = 930,
  VERSION = "1.0.0",
}

-- Ngữ nghĩa any-of: yêu cầu rỗng nghĩa là không gate theo tiêu chí đó.
local function has_any(granted, required)
  if #required == 0 then return true end

  local granted_set = {}
  for _, value in ipairs(granted or {}) do
    granted_set[value] = true
  end

  for _, value in ipairs(required) do
    if granted_set[value] then return true end
  end

  return false
end

function TacaRbacHandler:access(config)
  if #config.required_roles == 0 and #config.required_any_permission == 0 then return end

  local actor = kong.ctx.shared.taca_actor
  if not actor then
    -- Route có yêu cầu quyền mà không có actor nghĩa là thiếu taca-jwt trên route đó.
    -- Từ chối và ghi log để lint/CI bắt được cấu hình sai, không im lặng cho qua.
    kong.log.warn("taca-rbac has requirements but no actor context on this route")
    return envelope_builder.exit("GATEWAY_PERMISSION_DENIED")
  end

  if not has_any(actor.roles, config.required_roles)
     or not has_any(actor.permissions, config.required_any_permission) then
    return envelope_builder.exit("GATEWAY_PERMISSION_DENIED")
  end
end

return TacaRbacHandler
