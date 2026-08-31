local kong_stub = require "spec.helpers.kong_stub"
local envelope_builder = require "kong.plugins.taca-lib.envelope_builder"

describe("envelope_builder", function()
  after_each(function()
    kong_stub.uninstall()
  end)

  it("should build the documented envelope shape", function()
    kong_stub.install({ headers = { ["X-Request-ID"] = "01912f31-7a1b-7c12-9c55-8b1c34a6d921" } })

    local body, status = envelope_builder.build("GATEWAY_UPSTREAM_TIMEOUT")

    assert.equal(504, status)
    assert.equal("GATEWAY_UPSTREAM_TIMEOUT", body.error.code)
    assert.equal("Hệ thống đang phản hồi chậm. Vui lòng thử lại sau.", body.error.message)
    assert.equal("01912f31-7a1b-7c12-9c55-8b1c34a6d921", body.error.trace_id)
  end)

  it("should keep allowlisted details when provided", function()
    kong_stub.install({})

    local body = envelope_builder.build("GATEWAY_RATE_LIMITED", { retry_after_seconds = 12 })

    assert.equal(12, body.error.details.retry_after_seconds)
  end)

  it("should encode empty details as a JSON array", function()
    kong_stub.install({})

    local encoded = envelope_builder.encode("GATEWAY_AUTH_REQUIRED")

    assert.matches('"details":%[%]', encoded)
  end)

  it("should prefer the trace id already resolved in shared context", function()
    local state = kong_stub.install({ headers = { ["X-Request-ID"] = "from-header" } })
    state.shared.taca_trace_id = "from-context"

    local body = envelope_builder.build("GATEWAY_INTERNAL_ERROR")

    assert.equal("from-context", body.error.trace_id)
  end)

  it("should fall back to the kong request id when no route matched", function()
    kong_stub.install({})
    package.loaded["kong.observability.tracing.request_id"] = {
      get = function()
        return "kong-generated-id"
      end,
    }

    local body = envelope_builder.build("GATEWAY_INTERNAL_ERROR")
    package.loaded["kong.observability.tracing.request_id"] = nil

    assert.equal("kong-generated-id", body.error.trace_id)
  end)

  it("should return an empty trace id when even kong has no request id", function()
    kong_stub.install({})

    local body = envelope_builder.build("GATEWAY_INTERNAL_ERROR")

    assert.equal("", body.error.trace_id)
  end)

  it("should exit with the status mapped to the error code", function()
    local state = kong_stub.install({})

    envelope_builder.exit("GATEWAY_CORS_DENIED")

    assert.equal(403, state.exit_status)
    assert.equal("GATEWAY_CORS_DENIED", state.exit_body.error.code)
    assert.equal("application/json; charset=utf-8", state.exit_headers["Content-Type"])
  end)

  it("should merge extra headers into the error response", function()
    local state = kong_stub.install({})

    envelope_builder.exit("GATEWAY_RATE_LIMITED", nil, { ["Retry-After"] = "12" })

    assert.equal("12", state.exit_headers["Retry-After"])
  end)
end)
