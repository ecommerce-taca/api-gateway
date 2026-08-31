local metrics_store = require "kong.plugins.taca-lib.metrics_store"

describe("metrics_store", function()
  before_each(function()
    metrics_store.reset()
  end)

  it("should render a counter with its allowlisted label", function()
    metrics_store.increment("taca_jwks_refresh_total", "success")
    metrics_store.increment("taca_jwks_refresh_total", "success")

    local rendered = metrics_store.render()

    assert.matches("# TYPE taca_jwks_refresh_total counter", rendered, nil, true)
    assert.matches('taca_jwks_refresh_total{outcome="success"} 2', rendered, nil, true)
  end)

  it("should drop a label value outside the allowlist", function()
    metrics_store.increment("taca_rate_limit_total", "user-01912f31")

    assert.equal("", metrics_store.render())
  end)

  it("should render a gauge without labels", function()
    metrics_store.set_gauge("taca_ws_connections", 3)

    local rendered = metrics_store.render()

    assert.matches("# TYPE taca_ws_connections gauge", rendered, nil, true)
    assert.matches("taca_ws_connections 3", rendered, nil, true)
  end)

  it("should keep a gauge consistent when adding and removing connections", function()
    metrics_store.add_to_gauge("taca_ws_connections", 1)
    metrics_store.add_to_gauge("taca_ws_connections", 1)
    metrics_store.add_to_gauge("taca_ws_connections", -1)

    assert.matches("taca_ws_connections 1", metrics_store.render(), nil, true)
  end)

  it("should render nothing when no metric was recorded", function()
    assert.equal("", metrics_store.render())
  end)

  it("should ignore an unknown metric name", function()
    metrics_store.increment("something_else_total", "success")

    assert.equal("", metrics_store.render())
  end)
end)
