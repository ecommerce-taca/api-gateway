-- Parse và verify access token RS256 (LLD §2.4).
-- Không dùng thư viện JWT tổng quát: ở đây cần từ chối tuyệt đối mọi thuật toán khác
-- RS256 và tự quyết định mã lỗi trả về, không để validator mặc định của thư viện chọn hộ.

local cjson = require "cjson.safe"

local TOKEN_INVALID = "GATEWAY_TOKEN_INVALID"
local TOKEN_EXPIRED = "GATEWAY_TOKEN_EXPIRED"

local _M = {}

local function decode_base64url(input)
  local normalized = string.gsub(string.gsub(input, "-", "+"), "_", "/")

  local padding = #normalized % 4
  if padding == 2 then
    normalized = normalized .. "=="
  elseif padding == 3 then
    normalized = normalized .. "="
  elseif padding == 1 then
    return nil
  end

  return ngx.decode_base64(normalized)
end

_M.decode_base64url = decode_base64url

function _M.parse(token)
  if type(token) ~= "string" then
    return nil, TOKEN_INVALID
  end

  local header_segment, payload_segment, signature_segment =
    string.match(token, "^([^%.]+)%.([^%.]+)%.([^%.]+)$")
  if not header_segment then
    return nil, TOKEN_INVALID
  end

  local header = cjson.decode(decode_base64url(header_segment) or "")
  local payload = cjson.decode(decode_base64url(payload_segment) or "")
  local signature = decode_base64url(signature_segment)

  if type(header) ~= "table" or type(payload) ~= "table" or not signature then
    return nil, TOKEN_INVALID
  end

  return {
    header = header,
    payload = payload,
    signature = signature,
    signing_input = header_segment .. "." .. payload_segment,
  }
end

-- alg=none và HS256 phải chết ở đây: nếu để lọt, khoá công khai trong JWKS trở thành
-- khoá HMAC và bất kỳ ai cũng ký được token hợp lệ (SEC-GW-03).
function _M.check_algorithm(header, allowed_algorithms)
  if type(header.alg) ~= "string" then
    return nil, TOKEN_INVALID
  end

  for _, algorithm in ipairs(allowed_algorithms) do
    if header.alg == algorithm then
      return true
    end
  end

  return nil, TOKEN_INVALID
end

function _M.verify_signature(public_key, parsed)
  local verified = public_key:verify(parsed.signature, parsed.signing_input, "sha256")
  if not verified then
    return nil, TOKEN_INVALID
  end

  return true
end

local function audience_matches(claim, expected)
  if type(claim) == "string" then
    return claim == expected
  end

  if type(claim) ~= "table" then
    return false
  end

  for _, value in ipairs(claim) do
    if value == expected then
      return true
    end
  end

  return false
end

function _M.validate_claims(payload, config, now)
  if payload.iss ~= config.issuer then
    return nil, TOKEN_INVALID
  end

  if not audience_matches(payload.aud, config.audience) then
    return nil, TOKEN_INVALID
  end

  if type(payload.sub) ~= "string" or payload.sub == "" then
    return nil, TOKEN_INVALID
  end

  local skew = config.clock_skew_seconds

  -- Thiếu exp là token sai định dạng, không phải hết hạn: hai mã lỗi này dẫn frontend
  -- tới hai hành vi khác nhau (đăng nhập lại vs báo lỗi phiên).
  if type(payload.exp) ~= "number" then
    return nil, TOKEN_INVALID
  end

  if payload.exp + skew <= now then
    return nil, TOKEN_EXPIRED
  end

  -- iat ở tương lai quá clock skew nghĩa là đồng hồ lệch hoặc token bị chế; cả hai
  -- đều không nên cho qua.
  if type(payload.iat) ~= "number" or payload.iat - skew > now then
    return nil, TOKEN_INVALID
  end

  if payload.nbf ~= nil and (type(payload.nbf) ~= "number" or payload.nbf - skew > now) then
    return nil, TOKEN_INVALID
  end

  return true
end

return _M
