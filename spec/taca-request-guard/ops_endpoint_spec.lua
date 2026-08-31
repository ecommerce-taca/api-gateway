local cjson = require "cjson.safe"
local kong_stub = require "spec.helpers.kong_stub"
local jwt_fixture = require "spec.helpers.jwt_fixture"
local jwks = require "kong.plugins.taca-jwt.jwks"
local ops_endpoint = require "kong.plugins.taca-request-guard.ops_endpoint"

local function config(overrides)
  local value = {
    service_name = "api-gateway",
    jwks = {
      jwks_uri = "http://auth-user.internal:8080/.well-known/jwks.json",
      jwks_shared_dict = "taca_jwks",
      lock_shared_dict = "taca_locks",
      jwks_ttl_seconds = 600,
      jwks_max_stale_seconds = 1800,
      jwks_request_timeout_ms = 2000,
    },
    redis = { host = "127.0.0.1", port = 6379, database = 0, timeout_ms = 500 },
  }

  for name, override in pairs(overrides or {}) do
    value[name] = override
  end

  return value
end

describe("taca-request-guard ops_endpoint", function()
  local original_fetcher, original_redis_builder, original_upstream_reader, signing_key

  setup(function()
    signing_key = jwt_fixture.new_key("key-01")
    original_fetcher = jwks.fetch_jwks
    original_redis_builder = ops_endpoint.build_redis_client
    original_upstream_reader = ops_endpoint.read_upstream_health
  end)

  before_each(function()
    kong_stub.install({})
    ngx.shared.taca_jwks:flush_all()
    jwks.reset_worker_cache()
  end)

  after_each(function()
    jwks.fetch_jwks = original_fetcher
    ops_endpoint.build_redis_client = original_redis_builder
    ops_endpoint.read_upstream_health = original_upstream_reader
    kong_stub.uninstall()
  end)

  local function stub_dependencies(options)
    jwks.fetch_jwks = function()
      if options.jwks_up == false then
        return nil, "auth-user is down"
      end

      return jwt_fixture.jwks_document({ signing_key })
    end

    ops_endpoint.build_redis_client = function()
      return {
        ping = function()
          if options.redis_up == false then
            return nil, "GATEWAY_REDIS_UNAVAILABLE"
          end

          return true
        end,
      }
    end

    ops_endpoint.read_upstream_health = function()
      return options.upstreams or "UP"
    end
  end

  it("should report every dependency up on a healthy node", function()
    stub_dependencies({})

    local checks = ops_endpoint.collect_checks(config())

    assert.same({ config = "UP", jwks = "UP", redis = "UP", upstreams = "UP" }, checks)
  end)

  it("should report jwks down when the key set cannot be loaded", function()
    stub_dependencies({ jwks_up = false })

    assert.equal("DOWN", ops_endpoint.collect_checks(config()).jwks)
  end)

  it("should report redis down when the ping fails", function()
    stub_dependencies({ redis_up = false })

    assert.equal("DOWN", ops_endpoint.collect_checks(config()).redis)
  end)

  it("should report upstreams degraded when a target is unhealthy", function()
    stub_dependencies({ upstreams = "DEGRADED" })

    assert.equal("DEGRADED", ops_endpoint.collect_checks(config()).upstreams)
  end)

  it("should report jwks down when the route carries no jwks uri", function()
    stub_dependencies({})
    local without_jwks = config()
    without_jwks.jwks = nil

    assert.equal("DOWN", ops_endpoint.collect_checks(without_jwks).jwks)
  end)

  describe("first_failure_code", function()
    it("should report an invalid config first", function()
      local code = ops_endpoint.first_failure_code({
        config = "DOWN", jwks = "DOWN", redis = "DOWN", upstreams = "UP",
      })

      assert.equal("GATEWAY_CONFIG_INVALID", code)
    end)

    it("should report jwks before redis", function()
      local code = ops_endpoint.first_failure_code({
        config = "UP", jwks = "DOWN", redis = "DOWN", upstreams = "UP",
      })

      assert.equal("GATEWAY_JWKS_UNAVAILABLE", code)
    end)

    it("should report redis when it is the only failure", function()
      local code = ops_endpoint.first_failure_code({
        config = "UP", jwks = "UP", redis = "DOWN", upstreams = "UP",
      })

      assert.equal("GATEWAY_REDIS_UNAVAILABLE", code)
    end)

    it("should not fail readiness for degraded upstreams alone", function()
      local code = ops_endpoint.first_failure_code({
        config = "UP", jwks = "UP", redis = "UP", upstreams = "DEGRADED",
      })

      assert.is_nil(code)
    end)
  end)

  describe("response bodies", function()
    it("should report the node up when every check passes", function()
      local body = ops_endpoint.readiness_body(config(), {
        config = "UP", jwks = "UP", redis = "UP", upstreams = "UP",
      }, "trace-1")

      assert.equal("UP", body.status)
      assert.equal("api-gateway", body.service)
      assert.equal("trace-1", body.trace_id)
    end)

    it("should report the node degraded when an upstream is degraded", function()
      local body = ops_endpoint.readiness_body(config(), {
        config = "UP", jwks = "UP", redis = "UP", upstreams = "DEGRADED",
      }, "trace-1")

      assert.equal("DEGRADED", body.status)
    end)

    it("should build the documented liveness body", function()
      local body = cjson.decode(ops_endpoint.liveness_body(config()))

      assert.equal("UP", body.status)
      assert.equal("api-gateway", body.service)
      assert.matches("^%d%d%d%d%-%d%d%-%d%dT%d%d:%d%d:%d%dZ$", body.time)
    end)

    it("should not expose any dependency detail in the liveness body", function()
      local body = cjson.decode(ops_endpoint.liveness_body(config()))

      assert.is_nil(body.checks)
      assert.is_nil(body.redis)
    end)
  end)
end)
