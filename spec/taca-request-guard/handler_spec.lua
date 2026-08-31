local cjson = require "cjson.safe"
local kong_stub = require "spec.helpers.kong_stub"
local jwt_fixture = require "spec.helpers.jwt_fixture"
local jwks = require "kong.plugins.taca-jwt.jwks"
local ops_endpoint = require "kong.plugins.taca-request-guard.ops_endpoint"
local handler = require "kong.plugins.taca-request-guard.handler"

local function config(overrides)
  local value = {
    mode = "proxy",
    allowed_origins = { "https://buyer.example" },
    request_id_header = "X-Request-ID",
    request_id_max_length = 64,
    stripped_header_prefixes = { "X-User-", "X-Auth-" },
    trusted_proxy_cidrs = {},
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

describe("taca-request-guard handler", function()
  after_each(function()
    kong_stub.uninstall()
  end)

  describe("proxy mode", function()
    it("should reject an origin outside the allowlist", function()
      local state = kong_stub.install({ headers = { Origin = "https://evil.example" } })

      handler:access(config())

      assert.equal(403, state.exit_status)
      assert.equal("GATEWAY_CORS_DENIED", state.exit_body.error.code)
    end)

    it("should reject a preflight coming from a denied origin", function()
      local state = kong_stub.install({
        method = "OPTIONS",
        headers = {
          Origin = "https://evil.example",
          ["Access-Control-Request-Method"] = "POST",
        },
      })

      handler:access(config())

      assert.equal(403, state.exit_status)
    end)

    it("should let an allowed origin through", function()
      local state = kong_stub.install({ headers = { Origin = "https://buyer.example" } })

      handler:access(config())

      assert.is_nil(state.exit_status)
    end)

    it("should keep a valid request id sent by the client", function()
      local state = kong_stub.install({ headers = { ["X-Request-ID"] = "01912f31-7a1b" } })

      handler:access(config())

      assert.equal("01912f31-7a1b", state.shared.taca_trace_id)
      assert.is_nil(state.service_headers["X-Request-ID"])
    end)

    it("should replace an invalid request id before it reaches the upstream", function()
      local state = kong_stub.install({ headers = { ["X-Request-ID"] = "bad value" } })

      handler:access(config())

      assert.is_not.equal("bad value", state.shared.taca_trace_id)
      assert.equal(state.shared.taca_trace_id, state.service_headers["X-Request-ID"])
    end)

    it("should strip identity headers sent by the client", function()
      local state = kong_stub.install({
        headers = { ["X-User-ID"] = "someone-else", ["X-User-Roles"] = "ADMIN" },
      })

      handler:access(config())

      assert.is_true(state.cleared_headers["x-user-id"])
      assert.is_true(state.cleared_headers["x-user-roles"])
    end)

    it("should strip forwarded headers when the peer is not a trusted proxy", function()
      local state = kong_stub.install({
        headers = { ["X-Forwarded-For"] = "9.9.9.9" },
        client_ip = "203.0.113.5",
      })

      handler:access(config())

      assert.is_true(state.cleared_headers["x-forwarded-for"])
    end)

    it("should keep forwarded headers when the peer is a trusted proxy", function()
      local state = kong_stub.install({
        headers = { ["X-Forwarded-For"] = "9.9.9.9" },
        client_ip = "10.0.0.7",
      })

      handler:access(config({ trusted_proxy_cidrs = { "10.0.0.0/8" } }))

      assert.is_nil(state.cleared_headers["x-forwarded-for"])
    end)
  end)

  describe("readiness mode", function()
    local original_fetcher, original_redis_builder, original_upstream_reader, signing_key

    setup(function()
      signing_key = jwt_fixture.new_key("key-01")
      original_fetcher = jwks.fetch_jwks
      original_redis_builder = ops_endpoint.build_redis_client
      original_upstream_reader = ops_endpoint.read_upstream_health
    end)

    before_each(function()
      ngx.shared.taca_jwks:flush_all()
      jwks.reset_worker_cache()
      jwks.fetch_jwks = function()
        return jwt_fixture.jwks_document({ signing_key })
      end
      ops_endpoint.build_redis_client = function()
        return { ping = function() return true end }
      end
      ops_endpoint.read_upstream_health = function()
        return "UP"
      end
    end)

    after_each(function()
      jwks.fetch_jwks = original_fetcher
      ops_endpoint.build_redis_client = original_redis_builder
      ops_endpoint.read_upstream_health = original_upstream_reader
    end)

    it("should return the checks document when the node is ready", function()
      local state = kong_stub.install({ path = "/health/ready" })

      handler:access(config({ mode = "readiness" }))

      assert.equal(200, state.exit_status)
      assert.equal("UP", state.exit_body.status)
      assert.equal("UP", state.exit_body.checks.redis)
    end)

    it("should stay ready while only the upstreams are degraded", function()
      ops_endpoint.read_upstream_health = function()
        return "DEGRADED"
      end
      local state = kong_stub.install({ path = "/health/ready" })

      handler:access(config({ mode = "readiness" }))

      assert.equal(200, state.exit_status)
      assert.equal("DEGRADED", state.exit_body.status)
    end)

    it("should fail readiness with the jwks error code", function()
      jwks.fetch_jwks = function()
        return nil, "auth-user is down"
      end
      local state = kong_stub.install({ path = "/health/ready" })

      handler:access(config({ mode = "readiness" }))

      assert.equal(503, state.exit_status)
      assert.equal("GATEWAY_JWKS_UNAVAILABLE", state.exit_body.error.code)
    end)

    it("should fail readiness with the redis error code", function()
      ops_endpoint.build_redis_client = function()
        return { ping = function() return nil, "GATEWAY_REDIS_UNAVAILABLE" end }
      end
      local state = kong_stub.install({ path = "/health/ready" })

      handler:access(config({ mode = "readiness" }))

      assert.equal(503, state.exit_status)
      assert.equal("GATEWAY_REDIS_UNAVAILABLE", state.exit_body.error.code)
    end)

    it("should not expose an internal address in a failed readiness response", function()
      ops_endpoint.build_redis_client = function()
        return { ping = function() return nil, "GATEWAY_REDIS_UNAVAILABLE" end }
      end
      local state = kong_stub.install({ path = "/health/ready" })

      handler:access(config({ mode = "readiness" }))

      assert.is_nil(string.find(cjson.encode(state.exit_body), "127.0.0.1", 1, true))
    end)
  end)

  describe("liveness mode", function()
    local original_arg

    before_each(function()
      original_arg = ngx.arg
    end)

    after_each(function()
      ngx.arg = original_arg
    end)

    it("should rewrite the kong status body into the liveness contract", function()
      kong_stub.install({ path = "/health/live", response_status = 200 })
      local plugin_config = config({ mode = "liveness" })

      handler:header_filter(plugin_config)
      ngx.arg = { '{"memory":{"workers_lua_vms":[]}}', true }
      handler:body_filter(plugin_config)

      local body = cjson.decode(ngx.arg[1])
      assert.equal("UP", body.status)
      assert.equal("api-gateway", body.service)
      assert.is_nil(body.memory)
    end)

    it("should report the gateway as not ready when the status listener fails", function()
      local state = kong_stub.install({ path = "/health/live", response_status = 500 })
      local plugin_config = config({ mode = "liveness" })

      handler:header_filter(plugin_config)
      ngx.arg = { "", true }
      handler:body_filter(plugin_config)

      assert.equal(503, state.status)
      assert.equal("GATEWAY_CONFIG_INVALID", cjson.decode(ngx.arg[1]).error.code)
    end)
  end)

  describe("metrics mode", function()
    local original_arg

    before_each(function()
      original_arg = ngx.arg
    end)

    after_each(function()
      ngx.arg = original_arg
    end)

    it("should append the custom metrics to the prometheus output", function()
      local metrics_store = require "kong.plugins.taca-lib.metrics_store"
      metrics_store.reset()
      metrics_store.increment("taca_jwks_refresh_total", { outcome = "success" })
      kong_stub.install({ path = "/metrics", response_status = 200 })
      local plugin_config = config({ mode = "metrics" })

      handler:header_filter(plugin_config)
      ngx.arg = { "kong_http_requests_total 1\n", true }
      handler:body_filter(plugin_config)

      assert.matches("kong_http_requests_total 1", ngx.arg[1], nil, true)
      assert.matches('taca_jwks_refresh_total{outcome="success"} 1', ngx.arg[1], nil, true)
    end)
  end)
end)
