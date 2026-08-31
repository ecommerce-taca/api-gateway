local kong_stub = require "spec.helpers.kong_stub"
local jwt_fixture = require "spec.helpers.jwt_fixture"
local token_reader = require "kong.plugins.taca-jwt.token_reader"

describe("taca-jwt token_reader", function()
  after_each(function()
    kong_stub.uninstall()
  end)

  it("should read a bearer token from the authorization header", function()
    kong_stub.install({ headers = { Authorization = "Bearer abc.def.ghi" } })

    local token, source = token_reader.read(jwt_fixture.config())

    assert.equal("abc.def.ghi", token)
    assert.equal("header", source)
  end)

  it("should accept a lowercase bearer scheme", function()
    kong_stub.install({ headers = { Authorization = "bearer abc.def.ghi" } })

    assert.equal("abc.def.ghi", token_reader.read(jwt_fixture.config()))
  end)

  it("should ignore an authorization header without the bearer scheme", function()
    kong_stub.install({ headers = { Authorization = "Basic dXNlcjpwYXNz" } })

    assert.is_nil(token_reader.read(jwt_fixture.config()))
  end)

  it("should read the token from the websocket subprotocol when enabled", function()
    kong_stub.install({ headers = { ["Sec-WebSocket-Protocol"] = "bearer, abc.def.ghi" } })

    local token, source = token_reader.read(
      jwt_fixture.config({ accept_websocket_subprotocol = true }))

    assert.equal("abc.def.ghi", token)
    assert.equal("subprotocol", source)
  end)

  it("should ignore the websocket subprotocol when the route does not allow it", function()
    kong_stub.install({ headers = { ["Sec-WebSocket-Protocol"] = "bearer, abc.def.ghi" } })

    assert.is_nil(token_reader.read(jwt_fixture.config()))
  end)

  it("should ignore a subprotocol that does not start with bearer", function()
    kong_stub.install({ headers = { ["Sec-WebSocket-Protocol"] = "graphql-ws" } })

    assert.is_nil(token_reader.read(
      jwt_fixture.config({ accept_websocket_subprotocol = true })))
  end)

  it("should read the token from the query argument when enabled", function()
    kong_stub.install({ query_args = { access_token = "abc.def.ghi" } })

    local token, source = token_reader.read(jwt_fixture.config({ accept_query_token = true }))

    assert.equal("abc.def.ghi", token)
    assert.equal("query", source)
  end)

  it("should prefer the authorization header over the other sources", function()
    kong_stub.install({
      headers = {
        Authorization = "Bearer from.header.token",
        ["Sec-WebSocket-Protocol"] = "bearer, from.subprotocol.token",
      },
      query_args = { access_token = "from.query.token" },
    })

    assert.equal("from.header.token", token_reader.read(jwt_fixture.config({
      accept_websocket_subprotocol = true,
      accept_query_token = true,
    })))
  end)

  it("should prefer the subprotocol over the query argument", function()
    kong_stub.install({
      headers = { ["Sec-WebSocket-Protocol"] = "bearer, from.subprotocol.token" },
      query_args = { access_token = "from.query.token" },
    })

    assert.equal("from.subprotocol.token", token_reader.read(jwt_fixture.config({
      accept_websocket_subprotocol = true,
      accept_query_token = true,
    })))
  end)

  it("should return nothing when no source carries a token", function()
    kong_stub.install({})

    assert.is_nil(token_reader.read(jwt_fixture.config({
      accept_websocket_subprotocol = true,
      accept_query_token = true,
    })))
  end)
end)
