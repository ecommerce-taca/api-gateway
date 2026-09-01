-- Ba endpoint vận hành mà LLD §2.1.5 và API §3.1–3.3 giao cho plugin này.
-- Chúng nằm trên Route nội bộ riêng: Kong không có cách nào khác để trả đúng body
-- contract cho /health/live và để ghép metric custom vào output của plugin prometheus.

local cjson = require "cjson.safe"
local jwks = require "kong.plugins.taca-jwt.jwks"
local metrics_store = require "kong.plugins.taca-lib.metrics_store"
local redis_client = require "kong.plugins.taca-lib.redis_client"

local UP = "UP"
local DOWN = "DOWN"
local DEGRADED = "DEGRADED"

local _M = {}

-- Đọc trạng thái target qua API in-process của balancer — cùng nguồn mà plugin prometheus
-- dùng cho kong_upstream_target_health. Không gọi Admin API lúc runtime (LLD §8 #18).
function _M.read_upstream_health()
  local loaded, balancer = pcall(require, "kong.runloop.balancer")
  if not loaded then return nil end

  -- get_all_upstreams đã chuyển sang module con từ sau Kong 2.5; plugin prometheus của
  -- Kong cũng phải fallback đúng như vậy.
  local list_upstreams = balancer.get_all_upstreams
  if not list_upstreams then
    local submodule_loaded, upstreams_module = pcall(require, "kong.runloop.balancer.upstreams")
    if not submodule_loaded then return nil end

    list_upstreams = upstreams_module.get_all_upstreams
  end

  local upstreams = list_upstreams and list_upstreams()
  if not upstreams then return nil end

  for _, upstream_id in pairs(upstreams) do
    for _, target in pairs(balancer.get_upstream_health(upstream_id) or {}) do
      for _, address in ipairs(target.addresses or {}) do
        if address.health == "UNHEALTHY" then return DEGRADED end
      end
    end
  end

  return UP
end

function _M.now_iso8601()
  return os.date("!%Y-%m-%dT%H:%M:%SZ")
end

local function check_jwks(config)
  if not config.jwks or not config.jwks.jwks_uri then return DOWN end

  return jwks.ensure_loaded(config.jwks) and UP or DOWN
end

-- Route này chỉ tồn tại khi declarative config đã nạp xong, nên chạy được tới đây
-- là bằng chứng config UP; không có cách kiểm nào chặt hơn ở phía plugin.
function _M.collect_checks(config)
  return {
    config = UP,
    jwks = check_jwks(config),
    redis = redis_client.new(config.redis):ping() and UP or DOWN,
    upstreams = _M.read_upstream_health() or DEGRADED,
  }
end

-- Mã lỗi tương ứng dependency hỏng đầu tiên, theo thứ tự ảnh hưởng (IT-GW-04..06).
function _M.first_failure_code(checks)
  if checks.config ~= UP then return "GATEWAY_CONFIG_INVALID" end
  if checks.jwks ~= UP then return "GATEWAY_JWKS_UNAVAILABLE" end
  if checks.redis ~= UP then return "GATEWAY_REDIS_UNAVAILABLE" end

  return nil
end

function _M.readiness_body(config, checks, trace_id)
  return {
    -- Upstream hỏng không làm gateway mất khả năng phục vụ: readiness vẫn 200 nhưng
    -- trạng thái tổng là DEGRADED để bảng theo dõi thấy được (IT-GW-06).
    status = checks.upstreams == UP and UP or DEGRADED,
    service = config.service_name,
    checks = checks,
    time = _M.now_iso8601(),
    trace_id = trace_id,
  }
end

function _M.liveness_body(config)
  return cjson.encode({
    status = UP,
    service = config.service_name,
    time = _M.now_iso8601(),
  })
end

function _M.metrics_supplement()
  return metrics_store.render()
end

return _M
