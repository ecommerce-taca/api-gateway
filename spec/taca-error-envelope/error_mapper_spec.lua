local error_mapper = require "kong.plugins.taca-error-envelope.error_mapper"

local function config(overrides)
  local value = { allowed_business_error_codes = {}, redis_backed_rate_limit = false }
  for name, override in pairs(overrides or {}) do
    value[name] = override
  end

  return value
end

describe("taca-error-envelope error_mapper", function()
  describe("errors produced by kong itself", function()
    it("should map an unmatched route to the route not found code", function()
      local plan = error_mapper.plan(config(), "exit", 404, true)

      assert.equal("replace", plan.action)
      assert.equal("GATEWAY_ROUTE_NOT_FOUND", plan.code)
      assert.equal(404, plan.status)
    end)

    it("should map a rate limit rejection", function()
      local plan = error_mapper.plan(config(), "exit", 429, true)

      assert.equal("GATEWAY_RATE_LIMITED", plan.code)
      assert.equal(429, plan.status)
    end)

    it("should map an oversized payload", function()
      local plan = error_mapper.plan(config(), "exit", 413, true)

      assert.equal("GATEWAY_REQUEST_TOO_LARGE", plan.code)
    end)

    it("should map an unavailable ring balancer", function()
      local plan = error_mapper.plan(config(), "error", 503, true)

      assert.equal("GATEWAY_UPSTREAM_UNAVAILABLE", plan.code)
      assert.equal(503, plan.status)
    end)

    it("should map an upstream timeout", function()
      local plan = error_mapper.plan(config(), "error", 504, true)

      assert.equal("GATEWAY_UPSTREAM_TIMEOUT", plan.code)
    end)

    it("should map an invalid upstream response", function()
      local plan = error_mapper.plan(config(), "error", 502, true)

      assert.equal("GATEWAY_UPSTREAM_BAD_RESPONSE", plan.code)
    end)

    it("should map an uncaught lua error", function()
      local plan = error_mapper.plan(config(), "error", 500, true)

      assert.equal("GATEWAY_INTERNAL_ERROR", plan.code)
      assert.equal(500, plan.status)
    end)

    it("should map a bad request", function()
      local plan = error_mapper.plan(config(), "exit", 400, true)

      assert.equal("GATEWAY_INVALID_REQUEST", plan.code)
    end)

    it("should keep the status of a client error nginx reports on its own", function()
      local plan = error_mapper.plan(config(), "error", 405, true)

      assert.equal("GATEWAY_INVALID_REQUEST", plan.code)
      assert.equal(405, plan.status)
    end)
  end)

  describe("redis failure behind the rate limiting plugin", function()
    it("should report a redis outage when the access phase never completed", function()
      local plan = error_mapper.plan(config({ redis_backed_rate_limit = true }), "error", 500, false)

      assert.equal("GATEWAY_REDIS_UNAVAILABLE", plan.code)
      assert.equal(503, plan.status)
    end)

    it("should stay an internal error when the access phase did complete", function()
      local plan = error_mapper.plan(config({ redis_backed_rate_limit = true }), "error", 500, true)

      assert.equal("GATEWAY_INTERNAL_ERROR", plan.code)
    end)

    it("should stay an internal error on a route without redis rate limiting", function()
      local plan = error_mapper.plan(config(), "error", 500, false)

      assert.equal("GATEWAY_INTERNAL_ERROR", plan.code)
    end)
  end)

  describe("responses coming from the upstream service", function()
    it("should keep a business error for a 4xx", function()
      local plan = error_mapper.plan(config(), "service", 409, true)

      assert.equal("keep_business", plan.action)
      assert.equal(409, plan.status)
    end)

    it("should never pass through a 500 from the upstream", function()
      local plan = error_mapper.plan(config(), "service", 500, true)

      assert.equal("replace", plan.action)
      assert.equal("GATEWAY_UPSTREAM_BAD_RESPONSE", plan.code)
      assert.equal(502, plan.status)
    end)

    it("should map an upstream 503 to the unavailable code", function()
      local plan = error_mapper.plan(config(), "service", 503, true)

      assert.equal("GATEWAY_UPSTREAM_UNAVAILABLE", plan.code)
      assert.equal(503, plan.status)
    end)

    it("should map an upstream 504 to the timeout code", function()
      local plan = error_mapper.plan(config(), "service", 504, true)

      assert.equal("GATEWAY_UPSTREAM_TIMEOUT", plan.code)
    end)
  end)
end)
