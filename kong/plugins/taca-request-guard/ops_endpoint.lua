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

function _M.build_redis_client(config)
  return redis_client.new({
    host = config.redis.host,
    port = config.redis.port,
    database = config.redis.database,
    password = config.redis.password,
    timeout_ms = config.redis.timeout_ms,
  })
end

-- Đọc trạng thái target qua API in-process của balancer — cùng nguồn mà plugin prometheus
-- dùng cho kong_upstream_target_health. Không gọi Admin API lúc runtime (LLD §8 #18).
function _M.read_upstream_health()
  local loaded, balancer = pcall(require, "kong.runloop.balancer")
  if not loaded then
    return nil
  end

  local upstreams = balancer.get_all_upstreams()
  if not upstreams then
    return nil
  end

  for _, upstream_id in pairs(upstreams) do
    local health = balancer.get_upstream_health(upstream_id)
    for _, target in pairs(health or {}) do
      if target.addresses then
        for _, address in ipairs(target.addresses) do
          if address.health == "UNHEALTHY" then
            return DEGRADED
          end
        end
      end
    end
  end

  return UP
end

function _M.now_iso8601()
  return os.date("!%Y-%m-%dT%H:%M:%SZ")
end

local function check_jwks(config)
  if not config.jwks or not config.jwks.jwks_uri then
    return DOWN
  end

  local loaded = jwks.ensure_loaded(config.jwks)

  return loaded and UP or DOWN
end

local function check_redis(config)
  local reachable = _M.build_redis_client(config):ping()

  return reachable and UP or DOWN
end

-- Route này chỉ tồn tại khi declarative config đã nạp xong, nên chạy được tới đây
-- là bằng chứng config UP; không có cách kiểm nào chặt hơn ở phía plugin.
function _M.collect_checks(config)
  return {
    config = UP,
    jwks = check_jwks(config),
    redis = check_redis(config),
    upstreams = _M.read_upstream_health() or DEGRADED,
  }
end

-- Mã lỗi tương ứng dependency hỏng đầu tiên, theo thứ tự ảnh hưởng (IT-GW-04..06).
function _M.first_failure_code(checks)
  if checks.config ~= UP then
    return "GATEWAY_CONFIG_INVALID"
  end

  if checks.jwks ~= UP then
    return "GATEWAY_JWKS_UNAVAILABLE"
  end

  if checks.redis ~= UP then
    return "GATEWAY_REDIS_UNAVAILABLE"
  end

  return nil
end

function _M.readiness_body(config, checks, trace_id)
  local status = DEGRADED
  if checks.upstreams == UP then
    status = UP
  end

  return {
    status = status,
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
