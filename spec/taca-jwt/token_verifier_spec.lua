local kong_stub = require "spec.helpers.kong_stub"
local jwt_fixture = require "spec.helpers.jwt_fixture"
local token_verifier = require "kong.plugins.taca-jwt.token_verifier"

describe("taca-jwt token_verifier", function()
  local signing_key

  setup(function()
    signing_key = jwt_fixture.new_key("key-01")
  end)

  before_each(function()
    kong_stub.install({})
  end)

  after_each(function()
    kong_stub.uninstall()
  end)

  describe("parse", function()
    it("should expose header, payload and signing input", function()
      local payload = jwt_fixture.claims()
      local parsed = token_verifier.parse(jwt_fixture.sign(signing_key, payload))

      assert.equal("RS256", parsed.header.alg)
      assert.equal("key-01", parsed.header.kid)
      assert.equal(payload.sub, parsed.payload.sub)
      assert.is_string(parsed.signing_input)
    end)

    it("should reject a token without three segments", function()
      local parsed, error_code = token_verifier.parse("abc.def")

      assert.is_nil(parsed)
      assert.equal("GATEWAY_TOKEN_INVALID", error_code)
    end)

    it("should reject a token whose segments are not base64url json", function()
      local parsed, error_code = token_verifier.parse("aaa.bbb.ccc")

      assert.is_nil(parsed)
      assert.equal("GATEWAY_TOKEN_INVALID", error_code)
    end)
  end)

  describe("check_algorithm", function()
    it("should accept RS256", function()
      assert.is_true(token_verifier.check_algorithm({ alg = "RS256" }, { "RS256" }))
    end)

    it("should reject alg none", function()
      local ok, error_code = token_verifier.check_algorithm({ alg = "none" }, { "RS256" })

      assert.is_nil(ok)
      assert.equal("GATEWAY_TOKEN_INVALID", error_code)
    end)

    it("should reject HS256", function()
      local ok = token_verifier.check_algorithm({ alg = "HS256" }, { "RS256" })

      assert.is_nil(ok)
    end)

    it("should reject a header without an algorithm", function()
      local ok = token_verifier.check_algorithm({}, { "RS256" })

      assert.is_nil(ok)
    end)
  end)

  describe("verify_signature", function()
    it("should accept a signature made by the matching key", function()
      local parsed = token_verifier.parse(jwt_fixture.sign(signing_key, jwt_fixture.claims()))

      assert.is_true(token_verifier.verify_signature(signing_key.key, parsed))
    end)

    it("should reject a signature made by another key", function()
      local token = jwt_fixture.sign_with_wrong_key(signing_key, jwt_fixture.claims())
      local parsed = token_verifier.parse(token)

      local ok, error_code = token_verifier.verify_signature(signing_key.key, parsed)

      assert.is_nil(ok)
      assert.equal("GATEWAY_TOKEN_INVALID", error_code)
    end)
  end)

  describe("validate_claims", function()
    local config

    before_each(function()
      config = jwt_fixture.config()
    end)

    it("should accept claims that match the configured issuer and audience", function()
      assert.is_true(token_verifier.validate_claims(jwt_fixture.claims(), config, ngx.time()))
    end)

    it("should accept an audience array containing the configured audience", function()
      local payload = jwt_fixture.claims({ aud = { "other-api", "taca-marketplace-api" } })

      assert.is_true(token_verifier.validate_claims(payload, config, ngx.time()))
    end)

    it("should reject a wrong issuer", function()
      local payload = jwt_fixture.claims({ iss = "https://evil.example" })

      local ok, error_code = token_verifier.validate_claims(payload, config, ngx.time())

      assert.is_nil(ok)
      assert.equal("GATEWAY_TOKEN_INVALID", error_code)
    end)

    it("should reject a wrong audience", function()
      local payload = jwt_fixture.claims({ aud = "another-api" })

      local ok = token_verifier.validate_claims(payload, config, ngx.time())

      assert.is_nil(ok)
    end)

    it("should reject a missing subject", function()
      local payload = jwt_fixture.claims({ sub = "" })

      local ok = token_verifier.validate_claims(payload, config, ngx.time())

      assert.is_nil(ok)
    end)

    it("should report an expired token with its own error code", function()
      local now = ngx.time()
      local payload = jwt_fixture.claims({ exp = now - 60 })

      local ok, error_code = token_verifier.validate_claims(payload, config, now)

      assert.is_nil(ok)
      assert.equal("GATEWAY_TOKEN_EXPIRED", error_code)
    end)

    it("should still accept a token that expired inside the clock skew", function()
      local now = ngx.time()
      local payload = jwt_fixture.claims({ exp = now - 10 })

      assert.is_true(token_verifier.validate_claims(payload, config, now))
    end)

    it("should reject an issue time too far in the future", function()
      local now = ngx.time()
      local payload = jwt_fixture.claims({ iat = now + 120 })

      local ok, error_code = token_verifier.validate_claims(payload, config, now)

      assert.is_nil(ok)
      assert.equal("GATEWAY_TOKEN_INVALID", error_code)
    end)

    it("should accept an issue time inside the clock skew", function()
      local now = ngx.time()
      local payload = jwt_fixture.claims({ iat = now + 10 })

      assert.is_true(token_verifier.validate_claims(payload, config, now))
    end)

    it("should reject a not-before in the future beyond the clock skew", function()
      local now = ngx.time()
      local payload = jwt_fixture.claims({ nbf = now + 120 })

      local ok = token_verifier.validate_claims(payload, config, now)

      assert.is_nil(ok)
    end)

    it("should accept a not-before inside the clock skew", function()
      local now = ngx.time()
      local payload = jwt_fixture.claims({ nbf = now + 10 })

      assert.is_true(token_verifier.validate_claims(payload, config, now))
    end)

    it("should reject a token without an expiry as malformed", function()
      local payload = jwt_fixture.claims()
      payload.exp = nil

      local ok, error_code = token_verifier.validate_claims(payload, config, ngx.time())

      assert.is_nil(ok)
      assert.equal("GATEWAY_TOKEN_INVALID", error_code)
    end)

    it("should reject a token without an issued-at claim", function()
      local payload = jwt_fixture.claims()
      payload.iat = nil

      local ok, error_code = token_verifier.validate_claims(payload, config, ngx.time())

      assert.is_nil(ok)
      assert.equal("GATEWAY_TOKEN_INVALID", error_code)
    end)
  end)
end)
