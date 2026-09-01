local kong_stub = require "spec.helpers.kong_stub"
local metrics_store = require "kong.plugins.taca-lib.metrics_store"
local handler = require "kong.plugins.taca-ws-guard.handler"
local redis_client = require "kong.plugins.taca-lib.redis_client"

local function config(overrides)
  local value = {
    max_connections_per_user = 10,
    connection_counter_ttl_seconds = 3600,
    redis = { host = "127.0.0.1", port = 6379, database = 0, timeout_ms = 500 },
  }

  for name, override in pairs(overrides or {}) do
    value[name] = override
  end

  return value
end

local function actor()
  return {
    user_id = "01912f31-7a1b-7c12-9c55-8b1c34a6d921",
    roles = { "BUYER" },
    permissions = {},
    shop_scope = {},
  }
end

describe("taca-ws-guard handler", function()
  local original_redis_builder, redis_calls

  setup(function()
    original_redis_builder = redis_client.new
  end)

  before_each(function()
    metrics_store.reset()
    redis_calls = { increment = 0, decrement = 0, keys = {}, ttl = nil }
  end)

  after_each(function()
    redis_client.new = original_redis_builder
    kong_stub.uninstall()
  end)

  local function stub_redis(counter_value, error_code)
    redis_client.new = function()
      return {
        increment_with_expiry = function(_, key, ttl)
          redis_calls.increment = redis_calls.increment + 1
          redis_calls.keys[#redis_calls.keys + 1] = key
          redis_calls.ttl = ttl
          if error_code then
            return nil, error_code
          end

          return counter_value
        end,
        decrement = function(_, key)
          redis_calls.decrement = redis_calls.decrement + 1
          redis_calls.keys[#redis_calls.keys + 1] = key
          return counter_value - 1
        end,
      }
    end
  end

  local function run_access(plugin_config, actor_context)
    local state = kong_stub.install({ path = "/ws/messages" })
    state.shared.taca_actor = actor_context
    handler:access(plugin_config)

    return state
  end

  it("should count the handshake and let it through under the cap", function()
    stub_redis(3)

    local state = run_access(config(), actor())

    assert.is_nil(state.exit_status)
    assert.equal(1, redis_calls.increment)
    assert.equal(0, redis_calls.decrement)
    assert.is_not_nil(state.shared.taca_ws_connection_key)
  end)

  it("should hash the user id into the connection key", function()
    stub_redis(1)

    run_access(config(), actor())

    local key = redis_calls.keys[1]
    assert.matches("^ws:v1:conn:%x+$", key)
    assert.is_nil(string.find(key, "01912f31-7a1b-7c12-9c55-8b1c34a6d921", 1, true))
  end)

  it("should expire the counter later than the websocket idle timeout", function()
    stub_redis(1)

    run_access(config(), actor())

    assert.is_true(redis_calls.ttl > 1800)
  end)

  it("should reject a handshake above the connection cap", function()
    stub_redis(11)

    local state = run_access(config(), actor())

    assert.equal(429, state.exit_status)
    assert.equal("GATEWAY_RATE_LIMITED", state.exit_body.error.code)
  end)

  it("should give back the counter slot when the handshake is rejected", function()
    stub_redis(11)

    run_access(config(), actor())

    assert.equal(1, redis_calls.decrement)
  end)

  it("should not mark a rejected handshake for release in the log phase", function()
    stub_redis(11)

    local state = run_access(config(), actor())

    assert.is_nil(state.shared.taca_ws_connection_key)
  end)

  it("should accept a handshake landing exactly on the cap", function()
    stub_redis(10)

    local state = run_access(config(), actor())

    assert.is_nil(state.exit_status)
  end)

  it("should fail closed when redis cannot count the handshake", function()
    stub_redis(nil, "GATEWAY_REDIS_UNAVAILABLE")

    local state = run_access(config(), actor())

    assert.equal(503, state.exit_status)
    assert.equal("GATEWAY_REDIS_UNAVAILABLE", state.exit_body.error.code)
  end)

  it("should reject a handshake that arrived without an actor context", function()
    stub_redis(1)

    local state = run_access(config(), nil)

    assert.equal(401, state.exit_status)
    assert.equal("GATEWAY_AUTH_REQUIRED", state.exit_body.error.code)
    assert.equal(0, redis_calls.increment)
  end)

  it("should count blocked handshakes in the websocket rate limit bucket", function()
    stub_redis(11)

    run_access(config(), actor())

    assert.matches('taca_rate_limit_total{bucket="ws",outcome="blocked"} 1',
                   metrics_store.render(), nil, true)
  end)

  it("should track open connections in a gauge", function()
    stub_redis(1)

    run_access(config(), actor())

    assert.matches("taca_ws_connections 1", metrics_store.render(), nil, true)
  end)

  describe("log phase", function()
    local original_timer_at, scheduled

    before_each(function()
      original_timer_at = ngx.timer.at
      scheduled = {}
      ngx.timer.at = function(delay, callback, ...)
        scheduled[#scheduled + 1] = { delay = delay, callback = callback, args = { ... } }
        return true
      end
    end)

    after_each(function()
      ngx.timer.at = original_timer_at
    end)

    it("should schedule the counter release outside the log phase", function()
      stub_redis(1)
      local state = run_access(config(), actor())

      handler:log(config())

      assert.equal(1, #scheduled)
      assert.equal(state.shared.taca_ws_connection_key, scheduled[1].args[2])
    end)

    it("should schedule nothing when the handshake was never counted", function()
      kong_stub.install({ path = "/ws/messages" })

      handler:log(config())

      assert.equal(0, #scheduled)
    end)

    it("should decrement the counter when the release runs", function()
      stub_redis(1)
      local state = run_access(config(), actor())

      handler.release_connection(false, config(), state.shared.taca_ws_connection_key)

      assert.equal(1, redis_calls.decrement)
      assert.matches("taca_ws_connections 0", metrics_store.render(), nil, true)
    end)

    it("should do nothing when the timer fired prematurely on worker exit", function()
      stub_redis(1)

      handler.release_connection(true, config(), "ws:v1:conn:abc")

      assert.equal(0, redis_calls.decrement)
    end)
  end)
end)
