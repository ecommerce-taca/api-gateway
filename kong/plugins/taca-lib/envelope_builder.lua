-- Dựng error envelope {error:{code,message,details,trace_id}} (API §1.2, §6.5).
-- Mọi lối thoát lỗi của 5 plugin đều đi qua đây; không plugin nào tự gọi
-- kong.response.exit với body tự chế.

local cjson = require "cjson.safe"
local error_catalog = require "kong.plugins.taca-lib.error_catalog"

local REQUEST_ID_HEADER = "X-Request-ID"
local JSON_CONTENT_TYPE = "application/json; charset=utf-8"

local _M = {}

-- trace_id lấy từ X-Request-ID do plugin correlation-id sinh ở đầu chuỗi access.
-- Nếu chưa có (lỗi xảy ra trước correlation-id) thì để rỗng còn hơn bịa giá trị mới
-- không khớp với id đã ghi trong log.
function _M.resolve_trace_id()
  local ctx_trace_id = kong.ctx.shared.taca_trace_id
  if ctx_trace_id then
    return ctx_trace_id
  end

  return kong.request.get_header(REQUEST_ID_HEADER) or ""
end

function _M.build(code, details, trace_id)
  local resolved_code, entry = error_catalog.lookup(code)

  return {
    error = {
      code = resolved_code,
      message = entry.message,
      -- details rỗng phải là mảng [] đúng như contract mẫu, không phải object {}.
      details = details or cjson.empty_array,
      trace_id = trace_id or _M.resolve_trace_id(),
    },
  }, entry.status
end

-- Dừng request ngay tại plugin đang chạy. Chỉ dùng trong phase access/rewrite;
-- ở header_filter/body_filter phải sửa body tại chỗ vì response đã bắt đầu gửi.
function _M.exit(code, details, extra_headers)
  local body, status = _M.build(code, details)

  local headers = { ["Content-Type"] = JSON_CONTENT_TYPE }
  if extra_headers then
    for name, value in pairs(extra_headers) do
      headers[name] = value
    end
  end

  return kong.response.exit(status, body, headers)
end

function _M.encode(code, details, trace_id)
  local body = _M.build(code, details, trace_id)

  return cjson.encode(body)
end

return _M
