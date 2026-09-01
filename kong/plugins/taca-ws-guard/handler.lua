-- taca-ws-guard — giới hạn số WebSocket connection đang mở của mỗi user (LLD §2.1.2).
-- Không parse, không sửa, không buffer frame; chỉ đếm ở lúc handshake và lúc đóng.

local resty_sha256 = require "resty.sha256"
local resty_string = require "resty.string"
local envelope_builder = require "kong.plugins.taca-lib.envelope_builder"
local metrics_store = require "kong.plugins.taca-lib.metrics_store"
local redis_client = require "kong.plugins.taca-lib.redis_client"

local CONNECTION_KEY_PREFIX = "ws:v1:conn:"
local WS_GAUGE = "taca_ws_connections"
local RATE_LIMIT_METRIC = "taca_rate_limit_total"

local TacaWsGuardHandler = {
  -- Dưới rate-limiting (910): cap connection chỉ nên tính sau khi request đã qua
  -- rate limit handshake, để flood không làm phồng counter (LLD §2.2 bước 6-7).
  PRIORITY = 900,
  VERSION = "1.0.0",
}

-- Key chứa hash chứ không chứa user_id thô: Redis dùng chung nhiều mục đích và
-- không được chứa PII dạng đọc được (DB §5.2).
local function connection_key(user_id)
  local digest = resty_sha256:new()
  digest:update(user_id)

  return CONNECTION_KEY_PREFIX .. string.sub(resty_string.to_hex(digest:final()), 1, 32)
end

-- Chạy trong ngx.timer vì phase log của nginx không cho phép dùng cosocket.
function TacaWsGuardHandler.release_connection(premature, config, key)
  if premature then return end

  local remaining, error_code = redis_client.new(config.redis):decrement(key)
  if remaining == nil then
    -- Không có gì để làm ngoài ghi log: counter còn TTL nên sẽ tự dọn.
    kong.log.warn("ws connection counter release failed: ", error_code)
    return
  end

  metrics_store.add_to_gauge(WS_GAUGE, -1)
end

function TacaWsGuardHandler:access(config)
  local actor = kong.ctx.shared.taca_actor
  if not actor then
    kong.log.warn("taca-ws-guard reached without actor context")
    return envelope_builder.exit("GATEWAY_AUTH_REQUIRED")
  end

  local key = connection_key(actor.user_id)
  local client = redis_client.new(config.redis)

  local opened, error_code = client:increment_with_expiry(key, config.connection_counter_ttl_seconds)
  if opened == nil then
    -- Redis lỗi thì từ chối handshake: cho qua nghĩa là cap biến mất đúng lúc
    -- hệ thống đang yếu nhất (LLD §3.6).
    return envelope_builder.exit(error_code)
  end

  if opened > config.max_connections_per_user then
    -- Trả lại phần vừa cộng: handshake này không mở connection nào cả.
    client:decrement(key)
    metrics_store.increment(RATE_LIMIT_METRIC, { bucket = "ws", outcome = "blocked" })
    return envelope_builder.exit("GATEWAY_RATE_LIMITED")
  end

  metrics_store.increment(RATE_LIMIT_METRIC, { bucket = "ws", outcome = "allowed" })
  metrics_store.add_to_gauge(WS_GAUGE, 1)
  kong.ctx.shared.taca_ws_connection_key = key
end

-- Với connection đã upgrade, phase log của Kong chạy lúc connection đóng — đúng thời
-- điểm cần giảm counter, không phải lúc handshake xong.
function TacaWsGuardHandler:log(config)
  local key = kong.ctx.shared.taca_ws_connection_key
  if not key then return end

  local scheduled, err = ngx.timer.at(0, TacaWsGuardHandler.release_connection, config, key)
  if not scheduled then
    kong.log.err("cannot schedule ws counter release: ", err)
  end
end

return TacaWsGuardHandler
