-- taca-error-envelope — chuẩn hoá mọi response lỗi về {error:{code,message,details,trace_id}}
-- (LLD §2.1.2). Đây là lớp cuối cùng nhìn thấy response, nên nó là nơi duy nhất bảo đảm
-- client không bao giờ nhận body mặc định của Kong hay body 5xx thô của upstream.

local body_rewriter = require "kong.plugins.taca-error-envelope.body_rewriter"
local envelope_builder = require "kong.plugins.taca-lib.envelope_builder"
local error_mapper = require "kong.plugins.taca-error-envelope.error_mapper"

local JSON_CONTENT_TYPE = "application/json; charset=utf-8"
local WEBSOCKET_SWITCHING_PROTOCOLS = 101

local TacaErrorEnvelopeHandler = {
  -- Thấp nhất trong header_filter/body_filter để chạy sau mọi plugin khác và bao được
  -- cả lỗi do chúng sinh ra. Plugin built-in thấp nhất ở hai phase này là file-log (9).
  PRIORITY = 1,
  VERSION = "1.0.0",
}

-- Dấu vết cho error_mapper: request chết trước điểm này nghĩa là một plugin trong phase
-- access đã raise Lua error thay vì thoát có kiểm soát.
function TacaErrorEnvelopeHandler:access(_)
  kong.ctx.shared.taca_envelope_access_reached = true
end

function TacaErrorEnvelopeHandler:header_filter(config)
  local status = kong.response.get_status()

  -- Response thành công và connection đã upgrade lên WebSocket không bao giờ bị đụng:
  -- ghi vào một connection đang ở chế độ tunnel sẽ làm hỏng frame (LLD §3.9).
  if status < 400 or status == WEBSOCKET_SWITCHING_PROTOCOLS then
    return
  end

  local plan = error_mapper.plan(config,
                                 kong.response.get_source(),
                                 status,
                                 kong.ctx.shared.taca_envelope_access_reached == true)

  if plan.code == "GATEWAY_RATE_LIMITED" then
    local retry_after = kong.response.get_header("Retry-After")
    if retry_after then
      plan.details = { retry_after_seconds = tonumber(retry_after) }
    end
  end

  plan.trace_id = envelope_builder.resolve_trace_id()
  kong.ctx.shared.taca_envelope_plan = plan
  kong.ctx.shared.taca_envelope_buffer = {}

  if plan.status ~= status then
    kong.response.set_status(plan.status)
  end

  kong.response.set_header("Content-Type", JSON_CONTENT_TYPE)
  -- Body luôn bị viết lại nên độ dài cũ không còn đúng.
  kong.response.clear_header("Content-Length")
end

local function final_body(config, plan, raw_body)
  if plan.action == error_mapper.actions.KEEP_BUSINESS then
    local kept = body_rewriter.keep_business_error(raw_body,
                                                   config.allowed_business_error_codes,
                                                   plan.trace_id)
    if kept then
      return kept
    end

    kong.log.warn("upstream 4xx body does not follow the error envelope contract")

    return body_rewriter.gateway_error("GATEWAY_UPSTREAM_BAD_RESPONSE", nil, plan.trace_id)
  end

  return body_rewriter.gateway_error(plan.code, plan.details, plan.trace_id)
end

function TacaErrorEnvelopeHandler:body_filter(config)
  local plan = kong.ctx.shared.taca_envelope_plan
  if not plan then
    return
  end

  local buffer = kong.ctx.shared.taca_envelope_buffer
  local chunk = ngx.arg[1]
  if chunk and chunk ~= "" then
    buffer[#buffer + 1] = chunk
  end

  -- Nuốt mọi chunk cho tới khi hết body: chỉ khi có đủ body mới biết upstream 4xx
  -- có đúng contract hay không.
  if not ngx.arg[2] then
    ngx.arg[1] = nil
    return
  end

  ngx.arg[1] = final_body(config, plan, table.concat(buffer))
end

return TacaErrorEnvelopeHandler
