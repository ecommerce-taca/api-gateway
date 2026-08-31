-- Đọc access token từ ba nguồn được contract cho phép (API §3.12, test doc §4.1).
-- Thứ tự ưu tiên cố định: Authorization > Sec-WebSocket-Protocol > query.
-- Query đứng cuối vì đó là nguồn duy nhất bị ghi vào URL và phải redact khỏi log.

local BEARER_PATTERN = "^%s*[Bb][Ee][Aa][Rr][Ee][Rr]%s+(.+)%s*$"
local QUERY_ARG = "access_token"

local _M = {}

_M.sources = {
  HEADER = "header",
  SUBPROTOCOL = "subprotocol",
  QUERY = "query",
}

local function from_authorization_header()
  local value = kong.request.get_header("Authorization")
  if not value then
    return nil
  end

  return string.match(value, BEARER_PATTERN)
end

-- Client WebSocket không set được header Authorization nên token đi kèm subprotocol
-- dạng `bearer, <token>` (API §3.12).
local function from_websocket_subprotocol()
  local value = kong.request.get_header("Sec-WebSocket-Protocol")
  if not value then
    return nil
  end

  local protocols = {}
  for item in string.gmatch(value, "[^,]+") do
    protocols[#protocols + 1] = string.match(item, "^%s*(.-)%s*$")
  end

  if #protocols < 2 or string.lower(protocols[1]) ~= "bearer" then
    return nil
  end

  return protocols[2]
end

local function from_query_argument()
  local value = kong.request.get_query_arg(QUERY_ARG)
  if type(value) ~= "string" or value == "" then
    return nil
  end

  return value
end

function _M.read(config)
  local token = from_authorization_header()
  if token then
    return token, _M.sources.HEADER
  end

  if config.accept_websocket_subprotocol then
    token = from_websocket_subprotocol()
    if token then
      return token, _M.sources.SUBPROTOCOL
    end
  end

  if config.accept_query_token then
    token = from_query_argument()
    if token then
      return token, _M.sources.QUERY
    end
  end

  return nil
end

return _M
