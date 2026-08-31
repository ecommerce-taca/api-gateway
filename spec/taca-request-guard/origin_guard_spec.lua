local kong_stub = require "spec.helpers.kong_stub"
local origin_guard = require "kong.plugins.taca-request-guard.origin_guard"

local ALLOWED = { "https://buyer.example", "https://seller.example" }

describe("taca-request-guard origin_guard", function()
  after_each(function()
    kong_stub.uninstall()
  end)

  it("should allow an origin present in the allowlist", function()
    assert.is_true(origin_guard.is_allowed("https://buyer.example", ALLOWED))
  end)

  it("should deny an origin outside the allowlist", function()
    assert.is_false(origin_guard.is_allowed("https://evil.example", ALLOWED))
  end)

  it("should deny an origin differing only by scheme", function()
    assert.is_false(origin_guard.is_allowed("http://buyer.example", ALLOWED))
  end)

  it("should deny an origin differing only by port", function()
    assert.is_false(origin_guard.is_allowed("https://buyer.example:8443", ALLOWED))
  end)

  it("should allow a request that carries no origin at all", function()
    assert.is_true(origin_guard.is_allowed(nil, ALLOWED))
  end)

  it("should allow every origin when the wildcard is configured", function()
    assert.is_true(origin_guard.is_allowed("https://anything.example", { "*" }))
  end)

  it("should read the origin from the request header", function()
    kong_stub.install({ headers = { Origin = "https://buyer.example" } })

    assert.equal("https://buyer.example", origin_guard.read_origin())
  end)
end)
