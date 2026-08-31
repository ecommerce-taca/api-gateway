-- Ba metric ở API §3.3 không có tương đương native trong plugin prometheus của Kong,
-- nên custom plugin tự đếm vào lua_shared_dict taca_metrics rồi expose trên cùng /metrics.
-- Label chỉ nhận giá trị trong allowlist: API §3.3 cấm user_id/email/IP/token/kid vào label.

local SHARED_DICT_NAME = "taca_metrics"

local METRIC_DEFINITIONS = {
  taca_jwks_refresh_total = {
    kind = "counter",
    help = "JWKS refresh attempts by outcome",
    labels = { "outcome" },
    allowed_values = {
      outcome = { success = true, failure = true, stale = true },
    },
  },
  taca_rate_limit_total = {
    kind = "counter",
    help = "Rate limit decisions by bucket and outcome",
    labels = { "bucket", "outcome" },
    allowed_values = {
      bucket = { auth = true, public = true, authenticated = true, ws = true },
      outcome = { allowed = true, blocked = true },
    },
  },
  taca_ws_connections = {
    kind = "gauge",
    help = "Open WebSocket connections proxied by this node",
    labels = {},
    allowed_values = {},
  },
}

local _M = {}

local function dict()
  return ngx.shared[SHARED_DICT_NAME]
end

-- Label được ghép theo thứ tự khai báo để cùng một chuỗi series không sinh ra hai key
-- khác nhau chỉ vì thứ tự pairs() khác nhau giữa hai lần chạy.
local function series_key(metric_name, label_values)
  local definition = METRIC_DEFINITIONS[metric_name]
  if not definition then
    return nil
  end

  if #definition.labels == 0 then
    return metric_name
  end

  local parts = {}
  for _, label in ipairs(definition.labels) do
    local value = (label_values or {})[label]
    if not value or not definition.allowed_values[label][value] then
      return nil
    end

    parts[#parts + 1] = string.format('%s="%s"', label, value)
  end

  return string.format("%s{%s}", metric_name, table.concat(parts, ","))
end

function _M.increment(metric_name, label_values)
  local store = dict()
  if not store then
    return
  end

  local key = series_key(metric_name, label_values)
  if not key then
    return
  end

  -- init=0 để lần đếm đầu tiên không cần đọc-ghi hai bước và không mất counter khi đua.
  store:incr(key, 1, 0)
end

function _M.set_gauge(metric_name, value)
  local store = dict()
  if not store then
    return
  end

  store:set(metric_name, value)
end

function _M.add_to_gauge(metric_name, delta)
  local store = dict()
  if not store then
    return
  end

  store:incr(metric_name, delta, 0)
end

-- Sinh đoạn text OpenMetrics để ghép vào body /metrics của plugin prometheus.
function _M.render()
  local store = dict()
  if not store then
    return ""
  end

  local lines = {}
  for metric_name, definition in pairs(METRIC_DEFINITIONS) do
    local series = {}
    for _, key in ipairs(store:get_keys(0)) do
      if key == metric_name or key:sub(1, #metric_name + 1) == metric_name .. "{" then
        series[#series + 1] = string.format("%s %s", key, store:get(key) or 0)
      end
    end

    if #series > 0 then
      lines[#lines + 1] = string.format("# HELP %s %s", metric_name, definition.help)
      lines[#lines + 1] = string.format("# TYPE %s %s", metric_name, definition.kind)
      for _, line in ipairs(series) do
        lines[#lines + 1] = line
      end
    end
  end

  if #lines == 0 then
    return ""
  end

  return table.concat(lines, "\n") .. "\n"
end

function _M.reset()
  local store = dict()
  if store then
    store:flush_all()
    store:flush_expired()
  end
end

return _M
