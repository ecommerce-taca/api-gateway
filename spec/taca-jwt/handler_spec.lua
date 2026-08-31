local kong_stub = require "spec.helpers.kong_stub"
local jwt_fixture = require "spec.helpers.jwt_fixture"
local jwks = require "kong.plugins.taca-jwt.jwks"
local handler = require "kong.plugins.taca-jwt.handler"

describe("taca-jwt handler", function()
  local signing_key, original_fetcher, original_redis_builder

  setup(function()
    signing_key = jwt_fixture.new_key("key-01")
    original_fetcher = jwks.fetch_jwks
    original_redis_builder = handler.build_redis_client
  end)

  before_each(function()
    ngx.shared.taca_jwks:flush_all()
    jwks.reset_worker_cache()
    jwks.fetch_jwks = function()
      return jwt_fixture.jwks_document({ signing_key })
    end
  end)

  after_each(function()
    jwks.fetch_jwks = original_fetcher
    handler.build_redis_client = original_redis_builder
    kong_stub.uninstall()
  end)

  local function with_token(token, config_overrides)
    local state = kong_stub.install({ headers = { Authorization = "Bearer " .. token } })
    handler:access(jwt_fixture.config(config_overrides))

    return state
  end

  local function stub_redis(behaviour)
    handler.build_redis_client = function()
      return behaviour
    end
  end

  it("should reject a protected request without a token", function()
    local state = kong_stub.install({})

    handler:access(jwt_fixture.config())

    assert.equal(401, state.exit_status)
    assert.equal("GATEWAY_AUTH_REQUIRED", state.exit_body.error.code)
    assert.is_nil(state.service_headers["X-User-ID"])
  end)

  it("should let an anonymous request pass on a route with optional auth", function()
    local state = kong_stub.install({})

    handler:access(jwt_fixture.config({ token_required = false }))

    assert.is_nil(state.exit_status)
    assert.is_nil(state.shared.taca_actor)
  end)

  it("should still reject a broken token on a route with optional auth", function()
    local state = with_token("not-a-jwt", { token_required = false })

    assert.equal(401, state.exit_status)
    assert.equal("GATEWAY_TOKEN_INVALID", state.exit_body.error.code)
  end)

  it("should build actor headers from the token claims", function()
    local payload = jwt_fixture.claims({
      roles = { "SELLER", "SELLER_STAFF" },
      permissions = { "CATALOG_WRITE" },
      shop_id = { "shop-1" },
    })

    local state = with_token(jwt_fixture.sign(signing_key, payload))

    assert.is_nil(state.exit_status)
    assert.equal(payload.sub, state.service_headers["X-User-ID"])
    assert.equal("SELLER,SELLER_STAFF", state.service_headers["X-User-Roles"])
    assert.equal("CATALOG_WRITE", state.service_headers["X-User-Permissions"])
    assert.equal("shop-1", state.service_headers["X-User-Shop-Scope"])
    assert.equal("jwt", state.service_headers["X-Auth-Method"])
  end)

  it("should expose the actor in shared context for the next plugins", function()
    local state = with_token(jwt_fixture.sign(signing_key, jwt_fixture.claims()))

    assert.same({ "BUYER" }, state.shared.taca_actor.roles)
  end)

  it("should send empty actor headers when the token carries no scope", function()
    local payload = jwt_fixture.claims()
    payload.roles = nil

    local state = with_token(jwt_fixture.sign(signing_key, payload))

    assert.equal("", state.service_headers["X-User-Roles"])
    assert.equal("", state.service_headers["X-User-Shop-Scope"])
  end)

  it("should drop a role value that would break header serialization", function()
    local payload = jwt_fixture.claims({ roles = { "BUYER", "EVIL,ADMIN" } })

    local state = with_token(jwt_fixture.sign(signing_key, payload))

    assert.equal("BUYER", state.service_headers["X-User-Roles"])
  end)

  it("should reject an expired token", function()
    local payload = jwt_fixture.claims({ exp = ngx.time() - 120 })

    local state = with_token(jwt_fixture.sign(signing_key, payload))

    assert.equal(401, state.exit_status)
    assert.equal("GATEWAY_TOKEN_EXPIRED", state.exit_body.error.code)
  end)

  it("should reject a token signed by an unknown key", function()
    local token = jwt_fixture.sign_with_wrong_key(signing_key, jwt_fixture.claims())

    local state = with_token(token)

    assert.equal(401, state.exit_status)
    assert.equal("GATEWAY_TOKEN_INVALID", state.exit_body.error.code)
  end)

  it("should reject a token declaring alg none", function()
    local token = jwt_fixture.sign(signing_key, jwt_fixture.claims(), { alg = "none" })

    local state = with_token(token)

    assert.equal(401, state.exit_status)
    assert.equal("GATEWAY_TOKEN_INVALID", state.exit_body.error.code)
  end)

  it("should reject a token without a kid header", function()
    local payload = jwt_fixture.claims()
    local unsigned_kid_key = { kid = nil, key = signing_key.key, jwk = signing_key.jwk }
    local token = jwt_fixture.sign(unsigned_kid_key, payload)

    local state = with_token(token)

    assert.equal(401, state.exit_status)
    assert.equal("GATEWAY_TOKEN_INVALID", state.exit_body.error.code)
  end)

  it("should fail closed when jwks cannot be refreshed", function()
    jwks.fetch_jwks = function()
      return nil, "auth-user is down"
    end

    local state = with_token(jwt_fixture.sign(signing_key, jwt_fixture.claims()))

    assert.equal(503, state.exit_status)
    assert.equal("GATEWAY_JWKS_UNAVAILABLE", state.exit_body.error.code)
  end)

  it("should reject a token whose user was revoked", function()
    stub_redis({
      key_exists = function()
        return true
      end,
    })

    local state = with_token(jwt_fixture.sign(signing_key, jwt_fixture.claims()),
                             { revocation_check_enabled = true })

    assert.equal(401, state.exit_status)
    assert.equal("GATEWAY_TOKEN_INVALID", state.exit_body.error.code)
  end)

  it("should accept a token whose user has no revoke marker", function()
    stub_redis({
      key_exists = function()
        return false
      end,
    })

    local state = with_token(jwt_fixture.sign(signing_key, jwt_fixture.claims()),
                             { revocation_check_enabled = true })

    assert.is_nil(state.exit_status)
  end)

  it("should fail closed when redis cannot answer the revoke check", function()
    stub_redis({
      key_exists = function()
        return nil, "GATEWAY_REDIS_UNAVAILABLE"
      end,
    })

    local state = with_token(jwt_fixture.sign(signing_key, jwt_fixture.claims()),
                             { revocation_check_enabled = true })

    assert.equal(503, state.exit_status)
    assert.equal("GATEWAY_REDIS_UNAVAILABLE", state.exit_body.error.code)
  end)

  it("should read the token from the websocket subprotocol at handshake", function()
    local token = jwt_fixture.sign(signing_key, jwt_fixture.claims())
    local state = kong_stub.install({
      headers = { ["Sec-WebSocket-Protocol"] = "bearer, " .. token },
    })

    handler:access(jwt_fixture.config({ accept_websocket_subprotocol = true }))

    assert.is_nil(state.exit_status)
    assert.is_not_nil(state.service_headers["X-User-ID"])
  end)
end)
