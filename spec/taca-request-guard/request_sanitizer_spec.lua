local kong_stub = require "spec.helpers.kong_stub"
local request_sanitizer = require "kong.plugins.taca-request-guard.request_sanitizer"

local function config(overrides)
  local value = {
    request_id_header = "X-Request-ID",
    request_id_max_length = 64,
    stripped_header_prefixes = { "X-User-", "X-Auth-" },
  }

  for name, override in pairs(overrides or {}) do
    value[name] = override
  end

  return value
end

describe("taca-request-guard request_sanitizer", function()
  after_each(function()
    kong_stub.uninstall()
  end)

  describe("generate_request_id", function()
    it("should produce a uuid version 7", function()
      kong_stub.install({})

      local request_id = request_sanitizer.generate_request_id()

      assert.matches("^%x%x%x%x%x%x%x%x%-%x%x%x%x%-7%x%x%x%-[89ab]%x%x%x%-%x%x%x%x%x%x%x%x%x%x%x%x$",
                     request_id)
    end)

    it("should produce a value accepted by its own validator", function()
      kong_stub.install({})

      assert.is_true(request_sanitizer.is_valid_request_id(
        request_sanitizer.generate_request_id(), 64))
    end)

    it("should not repeat itself", function()
      kong_stub.install({})

      assert.is_not.equal(request_sanitizer.generate_request_id(),
                          request_sanitizer.generate_request_id())
    end)
  end)

  describe("is_valid_request_id", function()
    it("should accept the documented charset", function()
      assert.is_true(request_sanitizer.is_valid_request_id("abc-123_x.y:z", 64))
    end)

    it("should reject a value longer than the limit", function()
      assert.is_false(request_sanitizer.is_valid_request_id(string.rep("a", 65), 64))
    end)

    it("should reject an empty value", function()
      assert.is_false(request_sanitizer.is_valid_request_id("", 64))
    end)

    it("should reject a value with a space", function()
      assert.is_false(request_sanitizer.is_valid_request_id("abc 123", 64))
    end)

    it("should reject a value with a header injection attempt", function()
      assert.is_false(request_sanitizer.is_valid_request_id("abc\r\nX-User-ID: 1", 64))
    end)
  end)

  describe("resolve_request_id", function()
    it("should keep a valid value sent by the client", function()
      kong_stub.install({ headers = { ["X-Request-ID"] = "01912f31-7a1b-7c12" } })

      local request_id, generated = request_sanitizer.resolve_request_id(config())

      assert.equal("01912f31-7a1b-7c12", request_id)
      assert.is_false(generated)
    end)

    it("should generate a new value when the client sent none", function()
      kong_stub.install({})

      local request_id, generated = request_sanitizer.resolve_request_id(config())

      assert.is_true(generated)
      assert.is_true(request_sanitizer.is_valid_request_id(request_id, 64))
    end)

    it("should replace a value with an invalid charset", function()
      kong_stub.install({ headers = { ["X-Request-ID"] = "abc 123" } })

      local request_id, generated = request_sanitizer.resolve_request_id(config())

      assert.is_true(generated)
      assert.is_not.equal("abc 123", request_id)
    end)

    it("should replace a value longer than the limit", function()
      kong_stub.install({ headers = { ["X-Request-ID"] = string.rep("a", 100) } })

      local _, generated = request_sanitizer.resolve_request_id(config())

      assert.is_true(generated)
    end)
  end)

  describe("strip_spoofed_headers", function()
    it("should strip identity headers sent by the client", function()
      local state = kong_stub.install({
        headers = {
          ["X-User-ID"] = "someone-else",
          ["X-User-Roles"] = "ADMIN",
          ["X-Auth-Method"] = "jwt",
          ["Accept"] = "application/json",
        },
      })

      request_sanitizer.strip_spoofed_headers(config(), false)

      assert.is_true(state.cleared_headers["x-user-id"])
      assert.is_true(state.cleared_headers["x-user-roles"])
      assert.is_true(state.cleared_headers["x-auth-method"])
      assert.is_nil(state.cleared_headers["accept"])
    end)

    it("should strip forwarded headers when no proxy is trusted", function()
      local state = kong_stub.install({ headers = { ["X-Forwarded-For"] = "1.2.3.4" } })

      request_sanitizer.strip_spoofed_headers(config(), false)

      assert.is_true(state.cleared_headers["x-forwarded-for"])
    end)

    it("should keep forwarded headers coming from a trusted proxy", function()
      local state = kong_stub.install({ headers = { ["X-Forwarded-For"] = "1.2.3.4" } })

      request_sanitizer.strip_spoofed_headers(config(), true)

      assert.is_nil(state.cleared_headers["x-forwarded-for"])
    end)

    it("should still strip identity headers coming from a trusted proxy", function()
      local state = kong_stub.install({ headers = { ["X-User-ID"] = "someone-else" } })

      request_sanitizer.strip_spoofed_headers(config(), true)

      assert.is_true(state.cleared_headers["x-user-id"])
    end)

    it("should report which headers it removed", function()
      kong_stub.install({ headers = { ["X-User-ID"] = "someone-else", Accept = "*/*" } })

      local stripped = request_sanitizer.strip_spoofed_headers(config(), false)

      assert.equal(1, #stripped)
    end)
  end)
end)
