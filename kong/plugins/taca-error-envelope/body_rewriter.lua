-- Dựng body cuối cùng cho response lỗi (API §1.2, §3.11, §6.4).
-- Logic thuần trên chuỗi: không đọc PDK, không phụ thuộc phase, nên test được đủ nhánh.

local cjson = require "cjson.safe"
local envelope_builder = require "kong.plugins.taca-lib.envelope_builder"

local BUSINESS_CODE_PATTERN = "^[A-Z][A-Z0-9_]*$"
local MAX_CODE_LENGTH = 64
local MAX_MESSAGE_LENGTH = 500

-- Dấu hiệu nội dung nội bộ bị rò ra ngoài. Gặp bất kỳ dấu nào thì bỏ giá trị đó,
-- không cố gắng "làm sạch" chuỗi — sửa nửa vời còn nguy hiểm hơn bỏ hẳn.
local INTERNAL_LEAK_PATTERNS = {
  "://",                    -- URL nội bộ
  "%.lua:%d",               -- vị trí file Lua
  "stack traceback",
  "traceback",
  "sqlstate",
  "%f[%w]select%f[%W].-%f[%w]from%f[%W]",   -- câu SQL
  "%d+%.%d+%.%d+%.%d+",     -- địa chỉ IP
  "/usr/",
  "/etc/",
}

local _M = {}

-- Chỉ hạ chữ thường phía giá trị: hạ cả pattern sẽ biến %W thành %w và làm hỏng
-- frontier pattern của câu SQL.
local function looks_internal(value)
  local lowered = string.lower(value)
  for _, pattern in ipairs(INTERNAL_LEAK_PATTERNS) do
    if string.find(lowered, pattern) then
      return true
    end
  end

  return false
end

local function is_allowed_code(code, allowlist)
  if type(code) ~= "string" or #code > MAX_CODE_LENGTH then
    return false
  end

  if not string.match(code, BUSINESS_CODE_PATTERN) then
    return false
  end

  if #allowlist == 0 then
    return true
  end

  for _, allowed in ipairs(allowlist) do
    if allowed == code then
      return true
    end
  end

  return false
end

local function sanitize_details(details)
  if type(details) ~= "table" then
    return cjson.empty_array
  end

  local safe = {}
  local has_field = false
  for name, value in pairs(details) do
    if type(value) == "string" and looks_internal(value) then
      safe[name] = nil
    elseif type(value) == "string" or type(value) == "number" or type(value) == "boolean" then
      safe[name] = value
      has_field = true
    end
  end

  if not has_field then
    return cjson.empty_array
  end

  return safe
end

local function sanitize_message(message)
  if type(message) ~= "string" or #message > MAX_MESSAGE_LENGTH or looks_internal(message) then
    return nil
  end

  return message
end

-- Trả về body đã hợp lệ hoá, hoặc nil nếu upstream không tuân contract envelope.
function _M.keep_business_error(raw_body, allowlist, trace_id)
  local document = cjson.decode(raw_body or "")
  if type(document) ~= "table" or type(document.error) ~= "table" then
    return nil
  end

  local upstream_error = document.error
  if not is_allowed_code(upstream_error.code, allowlist) then
    return nil
  end

  local message = sanitize_message(upstream_error.message)
  if not message then
    return nil
  end

  return cjson.encode({
    error = {
      code = upstream_error.code,
      message = message,
      details = sanitize_details(upstream_error.details),
      -- Upstream thiếu trace_id thì lấy request id của Gateway (API §6.4).
      trace_id = upstream_error.trace_id or trace_id,
    },
  })
end

function _M.gateway_error(code, details, trace_id)
  return envelope_builder.encode(code, details, trace_id)
end

return _M
