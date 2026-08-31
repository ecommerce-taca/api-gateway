-- Quyết định mã lỗi Gateway cho mỗi response lỗi (LLD §2.1.6, §3.6).
-- Logic thuần, không đụng PDK, để test được toàn bộ bảng ánh xạ mà không cần dựng Kong.

local _M = {}

_M.actions = {
  REPLACE = "replace",
  KEEP_BUSINESS = "keep_business",
}

-- Lỗi do chính Kong hoặc plugin sinh ra (source = exit/error).
-- Status là nguồn tin cậy duy nhất ở đây: body mặc định của Kong chỉ là câu tiếng Anh
-- trong kong/error_handlers.lua, không có mã máy đọc được.
local GATEWAY_ORIGIN_CODES = {
  [400] = "GATEWAY_INVALID_REQUEST",
  [404] = "GATEWAY_ROUTE_NOT_FOUND",
  [413] = "GATEWAY_REQUEST_TOO_LARGE",
  [429] = "GATEWAY_RATE_LIMITED",
  [500] = "GATEWAY_INTERNAL_ERROR",
  [502] = "GATEWAY_UPSTREAM_BAD_RESPONSE",
  [503] = "GATEWAY_UPSTREAM_UNAVAILABLE",
  [504] = "GATEWAY_UPSTREAM_TIMEOUT",
}

-- Upstream trả 5xx thì không bao giờ pass-through: client chỉ nhận mã của Gateway.
local UPSTREAM_5XX_CODES = {
  [502] = "GATEWAY_UPSTREAM_BAD_RESPONSE",
  [503] = "GATEWAY_UPSTREAM_UNAVAILABLE",
  [504] = "GATEWAY_UPSTREAM_TIMEOUT",
}

local function gateway_origin_plan(config, status, access_phase_reached)
  -- Kong raise Lua error trần khi Redis của rate-limiting hỏng, nên request chết giữa
  -- phase access và plugin này (PRIORITY thấp nhất) không kịp chạy access. Thiếu dấu
  -- access trên route có rate limit Redis là dấu hiệu đủ mạnh để trả đúng mã Redis.
  if status == 500 and config.redis_backed_rate_limit and not access_phase_reached then
    return { action = _M.actions.REPLACE, code = "GATEWAY_REDIS_UNAVAILABLE", status = 503 }
  end

  local code = GATEWAY_ORIGIN_CODES[status]
  if code then
    return { action = _M.actions.REPLACE, code = code, status = status }
  end

  -- Các status còn lại của nginx (405, 408, 411, 414, 494→400...) không có mã riêng
  -- trong contract; giữ nguyên status và dùng mã định dạng request sai.
  if status < 500 then
    return { action = _M.actions.REPLACE, code = "GATEWAY_INVALID_REQUEST", status = status }
  end

  return { action = _M.actions.REPLACE, code = "GATEWAY_INTERNAL_ERROR", status = status }
end

local function upstream_plan(status)
  if status >= 500 then
    local code = UPSTREAM_5XX_CODES[status] or "GATEWAY_UPSTREAM_BAD_RESPONSE"
    local mapped_status = UPSTREAM_5XX_CODES[status] and status or 502

    return { action = _M.actions.REPLACE, code = code, status = mapped_status }
  end

  -- 4xx của service: giữ status thật và giữ business code nếu body hợp lệ.
  return { action = _M.actions.KEEP_BUSINESS, status = status }
end

-- source: giá trị của kong.response.get_source() — "exit"/"error" là lỗi do Kong/plugin
-- sinh, "service" là response thật của upstream.
function _M.plan(config, source, status, access_phase_reached)
  if source == "service" then
    return upstream_plan(status)
  end

  return gateway_origin_plan(config, status, access_phase_reached)
end

return _M
