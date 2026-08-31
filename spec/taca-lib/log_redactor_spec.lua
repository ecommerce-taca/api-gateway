local log_redactor = require "kong.plugins.taca-lib.log_redactor"

describe("log_redactor", function()
  it("should redact the authorization header", function()
    local safe = log_redactor.redact_headers({ Authorization = "Bearer eyJ.abc", Accept = "application/json" })

    assert.equal("[REDACTED]", safe.Authorization)
    assert.equal("application/json", safe.Accept)
  end)

  it("should redact the websocket subprotocol carrying the token", function()
    local safe = log_redactor.redact_headers({ ["Sec-WebSocket-Protocol"] = "bearer, eyJ.abc" })

    assert.equal("[REDACTED]", safe["Sec-WebSocket-Protocol"])
  end)

  it("should redact access_token in a query string but keep the argument name", function()
    local safe = log_redactor.redact_query_string("access_token=eyJ.abc&cursor=10")

    assert.equal("access_token=[REDACTED]&cursor=10", safe)
  end)

  it("should redact a token inside a full uri", function()
    local safe = log_redactor.redact_uri("/ws/messages?access_token=eyJ.abc")

    assert.equal("/ws/messages?access_token=[REDACTED]", safe)
  end)

  it("should leave a uri without query string untouched", function()
    assert.equal("/api/v1/products", log_redactor.redact_uri("/api/v1/products"))
  end)

  it("should leave non sensitive query arguments untouched", function()
    assert.equal("page=1&size=20", log_redactor.redact_query_string("page=1&size=20"))
  end)
end)
