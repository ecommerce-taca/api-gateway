-- Che dữ liệu nhạy cảm trước khi bất kỳ giá trị nào đi vào log/metric/trace
-- (LLD §3.7, SEC-GW-08, SEC-GW-12). Redaction làm ở tầng này chứ không dựa vào
-- việc từng chỗ gọi nhớ xoá — quên một chỗ là lộ token.

local REDACTED = "[REDACTED]"

local SENSITIVE_HEADERS = {
  ["authorization"] = true,
  ["cookie"] = true,
  ["set-cookie"] = true,
  ["proxy-authorization"] = true,
  ["x-api-key"] = true,
  -- WS handshake mang access token trong subprotocol (API §3.12).
  ["sec-websocket-protocol"] = true,
}

local SENSITIVE_QUERY_ARGS = {
  ["access_token"] = true,
  ["refresh_token"] = true,
  ["token"] = true,
  ["password"] = true,
  ["otp"] = true,
  ["code"] = true,
}

local _M = {}

_M.REDACTED = REDACTED

function _M.is_sensitive_header(name)
  return SENSITIVE_HEADERS[string.lower(name)] == true
end

function _M.redact_headers(headers)
  local safe = {}
  for name, value in pairs(headers) do
    if _M.is_sensitive_header(name) then
      safe[name] = REDACTED
    else
      safe[name] = value
    end
  end

  return safe
end

-- Thay giá trị của query arg nhạy cảm nhưng giữ nguyên tên arg: log vẫn cho biết
-- client đã dùng đường nào (query vs subprotocol) mà không lộ token.
function _M.redact_query_string(query_string)
  if not query_string or query_string == "" then
    return query_string
  end

  local parts = {}
  for pair in string.gmatch(query_string, "[^&]+") do
    local name = string.match(pair, "^([^=]+)=")
    if name and SENSITIVE_QUERY_ARGS[string.lower(name)] then
      parts[#parts + 1] = name .. "=" .. REDACTED
    else
      parts[#parts + 1] = pair
    end
  end

  return table.concat(parts, "&")
end

function _M.redact_uri(uri)
  if not uri then
    return uri
  end

  local path, query_string = string.match(uri, "^([^?]*)%?(.*)$")
  if not path then
    return uri
  end

  return path .. "?" .. _M.redact_query_string(query_string)
end

return _M
