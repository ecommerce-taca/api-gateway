-- Làm sạch request trước khi bất kỳ plugin nào khác nhìn thấy nó (LLD §2.1.2, §2.5).
-- Logic thuần trên chuỗi + PDK request, tách khỏi handler để test được từng quy tắc.

local resty_random = require "resty.random"
local resty_string = require "resty.string"

-- Charset an toàn của REQUEST_ID (LLD §4): chỉ chữ, số và . _ : -
local REQUEST_ID_PATTERN = "^[A-Za-z0-9._:%-]+$"
local FORWARDED_PREFIX = "x-forwarded-"

local _M = {}

-- UUIDv7 theo LLD §3.7: 48 bit đầu là timestamp mili giây nên request id sắp xếp được
-- theo thời gian khi tra log. Không dùng generator của plugin correlation-id vì nó sinh v4.
function _M.generate_request_id()
  local milliseconds = math.floor(ngx.now() * 1000)
  local time_hex = string.format("%012x", milliseconds)
  local random_hex = resty_string.to_hex(resty_random.bytes(10, true))

  return string.format("%s-%s-7%s-%s%s-%s",
                       string.sub(time_hex, 1, 8),
                       string.sub(time_hex, 9, 12),
                       string.sub(random_hex, 1, 3),
                       -- Nibble biến thể phải nằm trong 8..b theo RFC 9562.
                       string.sub("89ab", math.fmod(milliseconds, 4) + 1, math.fmod(milliseconds, 4) + 1),
                       string.sub(random_hex, 4, 6),
                       string.sub(random_hex, 7, 18))
end

function _M.is_valid_request_id(value, max_length)
  if type(value) ~= "string" or value == "" or #value > max_length then
    return false
  end

  return string.match(value, REQUEST_ID_PATTERN) ~= nil
end

-- Trả về request id sẽ dùng cho toàn bộ vòng đời request.
function _M.resolve_request_id(config)
  local client_value = kong.request.get_header(config.request_id_header)
  if _M.is_valid_request_id(client_value, config.request_id_max_length) then
    return client_value, false
  end

  return _M.generate_request_id(), true
end

local function matches_stripped_prefix(header_name, prefixes)
  local lowered = string.lower(header_name)
  for _, prefix in ipairs(prefixes) do
    if string.sub(lowered, 1, #prefix) == string.lower(prefix) then
      return true
    end
  end

  return false
end

-- Client tự gửi X-User-*/X-Auth-* là dấu hiệu cố leo thang quyền; xoá trước khi taca-jwt
-- đặt lại giá trị thật từ token (SEC-GW-02).
function _M.strip_spoofed_headers(config, is_trusted_proxy)
  local stripped = {}

  for name in pairs(kong.request.get_headers()) do
    local should_strip = matches_stripped_prefix(name, config.stripped_header_prefixes)

    if not should_strip and not is_trusted_proxy then
      should_strip = string.sub(string.lower(name), 1, #FORWARDED_PREFIX) == FORWARDED_PREFIX
    end

    if should_strip then
      kong.service.request.clear_header(name)
      stripped[#stripped + 1] = name
    end
  end

  return stripped
end

return _M
