local kong_stub = require "spec.helpers.kong_stub"
local handler = require "kong.plugins.taca-rbac.handler"

local function config(overrides)
  local value = { required_roles = {}, required_any_permission = {} }
  for name, override in pairs(overrides or {}) do
    value[name] = override
  end

  return value
end

local function actor(roles, permissions, shop_scope)
  return {
    user_id = "01912f31-7a1b-7c12-9c55-8b1c34a6d921",
    roles = roles or {},
    permissions = permissions or {},
    shop_scope = shop_scope or {},
  }
end

describe("taca-rbac handler", function()
  after_each(function()
    kong_stub.uninstall()
  end)

  local function run(plugin_config, actor_context)
    local state = kong_stub.install({})
    state.shared.taca_actor = actor_context
    handler:access(plugin_config)

    return state
  end

  it("should let a request pass when the route declares no requirement", function()
    local state = run(config(), actor({ "BUYER" }))

    assert.is_nil(state.exit_status)
  end)

  it("should let an anonymous request pass on a route with no requirement", function()
    local state = run(config(), nil)

    assert.is_nil(state.exit_status)
  end)

  it("should accept an actor holding one of the required roles", function()
    local plugin_config = config({ required_roles = { "SELLER", "SELLER_STAFF" } })

    local state = run(plugin_config, actor({ "SELLER_STAFF" }))

    assert.is_nil(state.exit_status)
  end)

  it("should reject an actor without any required role", function()
    local plugin_config = config({ required_roles = { "SELLER" } })

    local state = run(plugin_config, actor({ "BUYER" }))

    assert.equal(403, state.exit_status)
    assert.equal("GATEWAY_PERMISSION_DENIED", state.exit_body.error.code)
  end)

  it("should reject an actor with no role at all", function()
    local plugin_config = config({ required_roles = { "ADMIN" } })

    local state = run(plugin_config, actor({}))

    assert.equal(403, state.exit_status)
  end)

  it("should accept an actor holding one of the required permissions", function()
    local plugin_config = config({ required_any_permission = { "FINANCE_OPS", "RISK_MANAGER" } })

    local state = run(plugin_config, actor({ "ADMIN" }, { "RISK_MANAGER" }))

    assert.is_nil(state.exit_status)
  end)

  it("should reject an actor missing every required permission", function()
    local plugin_config = config({ required_any_permission = { "FINANCE_OPS" } })

    local state = run(plugin_config, actor({ "ADMIN" }, { "CATALOG_ADMIN" }))

    assert.equal(403, state.exit_status)
    assert.equal("GATEWAY_PERMISSION_DENIED", state.exit_body.error.code)
  end)

  it("should require both the role and the permission gate to pass", function()
    local plugin_config = config({
      required_roles = { "ADMIN" },
      required_any_permission = { "FINANCE_OPS" },
    })

    local state = run(plugin_config, actor({ "BUYER" }, { "FINANCE_OPS" }))

    assert.equal(403, state.exit_status)
  end)

  it("should reject a gated route reached without an actor context", function()
    local plugin_config = config({ required_roles = { "ADMIN" } })

    local state = run(plugin_config, nil)

    assert.equal(403, state.exit_status)
    assert.equal("GATEWAY_PERMISSION_DENIED", state.exit_body.error.code)
  end)

  it("should not grant access from a shop scope claim", function()
    local plugin_config = config({ required_roles = { "SELLER" } })

    local state = run(plugin_config, actor({ "BUYER" }, {}, { "shop-1" }))

    assert.equal(403, state.exit_status)
  end)
end)
