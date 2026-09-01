-- taca-request-guard — hàng rào đầu tiên của mọi request (LLD §2.1.2).
-- Phải chạy trước cors (PRIORITY 2000) và trước taca-jwt: chạy sau cors thì origin lạ
-- đã được cors trả 200 cho preflight; chạy sau taca-jwt thì nó xoá đúng header actor
-- mà taca-jwt vừa đặt.

local ipmatcher = require "resty.ipmatcher"
local envelope_builder = require "kong.plugins.taca-lib.envelope_builder"
local ops_endpoint = require "kong.plugins.taca-request-guard.ops_endpoint"
local origin_guard = require "kong.plugins.taca-request-guard.origin_guard"
local request_sanitizer = require "kong.plugins.taca-request-guard.request_sanitizer"

local TacaRequestGuardHandler = {
  -- Trên cors (2000), dưới correlation-id (100001) của đúng Kong 3.9.0.
  PRIORITY = 2100,
  VERSION = "1.0.0",
}

local function is_trusted_proxy(config)
  if #config.trusted_proxy_cidrs == 0 then return false end

  local matcher = ipmatcher.new(config.trusted_proxy_cidrs)

  return matcher and matcher:match(kong.client.get_ip()) == true
end

local function guard_request(config)
  if not origin_guard.is_allowed(origin_guard.read_origin(), config.allowed_origins) then
    return envelope_builder.exit("GATEWAY_CORS_DENIED")
  end

  local request_id, generated = request_sanitizer.resolve_request_id(config)
  kong.ctx.shared.taca_trace_id = request_id
  if generated then
    -- Ghi đè giá trị correlation-id vừa đặt: giá trị client gửi sai charset/độ dài
    -- không được đi tiếp tới upstream và vào log.
    kong.service.request.set_header(config.request_id_header, request_id)
  end

  request_sanitizer.strip_spoofed_headers(config, is_trusted_proxy(config))
end

local function serve_readiness(config)
  local checks = ops_endpoint.collect_checks(config)
  local failure_code = ops_endpoint.first_failure_code(checks)
  if failure_code then return envelope_builder.exit(failure_code) end

  local body = ops_endpoint.readiness_body(config, checks, envelope_builder.resolve_trace_id())

  return kong.response.exit(200, body, { ["Content-Type"] = envelope_builder.JSON_CONTENT_TYPE })
end

function TacaRequestGuardHandler:access(config)
  if config.mode == "readiness" then return serve_readiness(config) end
  if config.mode == "proxy" then return guard_request(config) end
end

-- Chế độ liveness và metrics viết lại body của response lấy từ status listener của Kong,
-- nên phải chuẩn bị header trước khi body chảy qua. Body luôn bị thay nên Content-Length
-- cũ không còn đúng.
function TacaRequestGuardHandler:header_filter(config)
  if config.mode == "metrics" then
    kong.response.clear_header("Content-Length")
    return
  end

  if config.mode ~= "liveness" then return end

  -- Status listener trả khác 200 nghĩa là chính node này chưa nạp được config.
  local unhealthy = kong.response.get_status() ~= 200
  if unhealthy then
    kong.ctx.shared.taca_ops_body = envelope_builder.encode("GATEWAY_CONFIG_INVALID")
    kong.response.set_status(503)
  else
    kong.ctx.shared.taca_ops_body = ops_endpoint.liveness_body(config)
  end

  kong.response.set_header("Content-Type", envelope_builder.JSON_CONTENT_TYPE)
  kong.response.clear_header("Content-Length")
end

function TacaRequestGuardHandler:body_filter(config)
  if config.mode == "liveness" then
    ngx.arg[1] = ngx.arg[2] and kong.ctx.shared.taca_ops_body or nil
    return
  end

  -- Metric custom được nối vào cuối output của plugin prometheus trên cùng route
  -- /metrics (API §3.3); phần Kong sinh ra giữ nguyên.
  if config.mode == "metrics" and ngx.arg[2] then
    ngx.arg[1] = (ngx.arg[1] or "") .. ops_endpoint.metrics_supplement()
  end
end

return TacaRequestGuardHandler
