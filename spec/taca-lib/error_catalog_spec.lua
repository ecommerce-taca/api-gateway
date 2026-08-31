local error_catalog = require "kong.plugins.taca-lib.error_catalog"

describe("error_catalog", function()
  it("should map every documented code to its HTTP status", function()
    local expected_statuses = {
      GATEWAY_INVALID_REQUEST = 400,
      GATEWAY_ROUTE_NOT_FOUND = 404,
      GATEWAY_AUTH_REQUIRED = 401,
      GATEWAY_TOKEN_INVALID = 401,
      GATEWAY_TOKEN_EXPIRED = 401,
      GATEWAY_PERMISSION_DENIED = 403,
      GATEWAY_CORS_DENIED = 403,
      GATEWAY_RATE_LIMITED = 429,
      GATEWAY_REQUEST_TOO_LARGE = 413,
      GATEWAY_JWKS_UNAVAILABLE = 503,
      GATEWAY_REDIS_UNAVAILABLE = 503,
      GATEWAY_UPSTREAM_TIMEOUT = 504,
      GATEWAY_UPSTREAM_UNAVAILABLE = 503,
      GATEWAY_UPSTREAM_BAD_RESPONSE = 502,
      GATEWAY_CONFIG_INVALID = 503,
      GATEWAY_INTERNAL_ERROR = 500,
    }

    for code, status in pairs(expected_statuses) do
      local resolved_code, entry = error_catalog.lookup(code)

      assert.equal(code, resolved_code)
      assert.equal(status, entry.status)
    end
  end)

  it("should expose exactly the documented code set", function()
    local count = 0
    for _ in pairs(error_catalog.all()) do
      count = count + 1
    end

    assert.equal(16, count)
  end)

  it("should carry a user facing message for every code", function()
    for code, entry in pairs(error_catalog.all()) do
      assert.is_string(entry.message, code)
      assert.is_true(#entry.message > 0, code)
    end
  end)

  it("should fall back to internal error for an unknown code", function()
    local resolved_code, entry = error_catalog.lookup("SOMETHING_ELSE")

    assert.equal("GATEWAY_INTERNAL_ERROR", resolved_code)
    assert.equal(500, entry.status)
  end)

  it("should report unknown codes as not known", function()
    assert.is_false(error_catalog.is_known("SOMETHING_ELSE"))
    assert.is_true(error_catalog.is_known("GATEWAY_RATE_LIMITED"))
  end)
end)
