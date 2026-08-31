-- Kiểm Origin theo allowlist (LLD §2.1.1, §2.1.3).
-- Plugin cors của Kong chỉ bỏ header khi origin lạ chứ không trả 403, nên phần từ chối
-- bắt buộc phải nằm ở đây (IT-KONG-14, IT-GW-10).

local WILDCARD = "*"

local _M = {}

function _M.is_allowed(origin, allowed_origins)
  -- Không có Origin nghĩa là request không đến từ trình duyệt (server-to-server, curl,
  -- webhook đối tác); CORS không áp dụng cho nhóm này.
  if not origin then
    return true
  end

  if #allowed_origins == 0 then
    return true
  end

  for _, allowed in ipairs(allowed_origins) do
    if allowed == WILDCARD or allowed == origin then
      return true
    end
  end

  return false
end

function _M.read_origin()
  return kong.request.get_header("Origin")
end

return _M
