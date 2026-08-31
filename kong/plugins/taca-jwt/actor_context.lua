-- Dựng actor context từ claim và gắn lên request đi tới upstream (LLD §2.5).
-- Dùng kong.service.request.set_header: header chỉ tồn tại trên đường lên upstream,
-- không phản hồi ngược về client.

local ACTOR_HEADERS = {
  user_id = "X-User-ID",
  roles = "X-User-Roles",
  permissions = "X-User-Permissions",
  shop_scope = "X-User-Shop-Scope",
  auth_method = "X-Auth-Method",
}

-- Giá trị lấy từ token của bên ngoài nên phải lọc trước khi nối bằng dấu phẩy:
-- một role chứa dấu phẩy sẽ tách thành hai role khi service đích parse lại.
local SAFE_VALUE_PATTERN = "^[A-Za-z0-9_.:%-]+$"

local _M = {}

_M.headers = ACTOR_HEADERS

local function safe_list(claim)
  if type(claim) == "string" then
    claim = { claim }
  end

  if type(claim) ~= "table" then
    return {}
  end

  local values = {}
  for _, value in ipairs(claim) do
    if type(value) == "string" and string.match(value, SAFE_VALUE_PATTERN) then
      values[#values + 1] = value
    end
  end

  return values
end

function _M.build(payload)
  return {
    user_id = payload.sub,
    roles = safe_list(payload.roles),
    permissions = safe_list(payload.permissions),
    shop_scope = safe_list(payload.shop_id or payload.shop_scope),
    email_verified = payload.email_verified == true,
  }
end

function _M.apply(actor)
  local set_header = kong.service.request.set_header

  set_header(ACTOR_HEADERS.user_id, actor.user_id)
  set_header(ACTOR_HEADERS.roles, table.concat(actor.roles, ","))
  set_header(ACTOR_HEADERS.permissions, table.concat(actor.permissions, ","))
  set_header(ACTOR_HEADERS.shop_scope, table.concat(actor.shop_scope, ","))
  set_header(ACTOR_HEADERS.auth_method, "jwt")
end

return _M
