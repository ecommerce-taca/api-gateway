local cjson = require "cjson.safe"
local kong_stub = require "spec.helpers.kong_stub"
local body_rewriter = require "kong.plugins.taca-error-envelope.body_rewriter"

local TRACE_ID = "01912f31-7a1b-7c12-9c55-8b1c34a6d921"

local function upstream_error(overrides)
  local document = {
    error = {
      code = "ORDER_STOCK_UNAVAILABLE",
      message = "Sản phẩm không còn đủ tồn kho.",
      details = { item_id = "item-01912f31" },
      trace_id = TRACE_ID,
    },
  }

  for name, value in pairs(overrides or {}) do
    document.error[name] = value
  end

  return cjson.encode(document)
end

describe("taca-error-envelope body_rewriter", function()
  before_each(function()
    kong_stub.install({})
  end)

  after_each(function()
    kong_stub.uninstall()
  end)

  it("should keep a well formed business error", function()
    local kept = cjson.decode(body_rewriter.keep_business_error(upstream_error(), {}, TRACE_ID))

    assert.equal("ORDER_STOCK_UNAVAILABLE", kept.error.code)
    assert.equal("Sản phẩm không còn đủ tồn kho.", kept.error.message)
    assert.equal("item-01912f31", kept.error.details.item_id)
  end)

  it("should fill the trace id from the gateway when upstream omits it", function()
    local body = cjson.encode({
      error = { code = "ORDER_NOT_FOUND", message = "Không tìm thấy đơn hàng." },
    })

    local kept = cjson.decode(body_rewriter.keep_business_error(body, {}, TRACE_ID))

    assert.equal(TRACE_ID, kept.error.trace_id)
  end)

  it("should reject a body that is not json", function()
    assert.is_nil(body_rewriter.keep_business_error("<html>error</html>", {}, TRACE_ID))
  end)

  it("should reject a json body without the error envelope", function()
    assert.is_nil(body_rewriter.keep_business_error('{"message":"nope"}', {}, TRACE_ID))
  end)

  it("should reject a business code that is not upper snake case", function()
    assert.is_nil(body_rewriter.keep_business_error(
      upstream_error({ code = "order stock unavailable" }), {}, TRACE_ID))
  end)

  it("should reject a business code outside a configured allowlist", function()
    assert.is_nil(body_rewriter.keep_business_error(
      upstream_error(), { "ORDER_NOT_FOUND" }, TRACE_ID))
  end)

  it("should accept a business code present in the allowlist", function()
    local kept = body_rewriter.keep_business_error(
      upstream_error(), { "ORDER_STOCK_UNAVAILABLE" }, TRACE_ID)

    assert.is_not_nil(kept)
  end)

  it("should reject a message leaking an internal host", function()
    assert.is_nil(body_rewriter.keep_business_error(
      upstream_error({ message = "call to http://order-commerce.internal:8080 failed" }),
      {}, TRACE_ID))
  end)

  it("should reject a message leaking a lua stack trace", function()
    assert.is_nil(body_rewriter.keep_business_error(
      upstream_error({ message = "handler.lua:42: attempt to index nil" }), {}, TRACE_ID))
  end)

  it("should drop a detail field carrying an internal address", function()
    local kept = cjson.decode(body_rewriter.keep_business_error(
      upstream_error({ details = { item_id = "item-1", host = "10.42.0.7" } }), {}, TRACE_ID))

    assert.equal("item-1", kept.error.details.item_id)
    assert.is_nil(kept.error.details.host)
  end)

  it("should drop a detail field carrying sql", function()
    -- So khớp trên chuỗi đã encode: decode rồi encode lại sẽ biến [] thành {} vì Lua
    -- không phân biệt mảng rỗng với object rỗng.
    local encoded = body_rewriter.keep_business_error(
      upstream_error({ details = { hint = "SELECT id FROM orders" } }), {}, TRACE_ID)

    assert.matches('"details":%[%]', encoded)
  end)

  it("should render empty details as an array", function()
    local body = cjson.decode(upstream_error())
    body.error.details = nil

    local encoded = body_rewriter.keep_business_error(cjson.encode(body), {}, TRACE_ID)

    assert.matches('"details":%[%]', encoded)
  end)

  it("should build a gateway error with its documented message", function()
    local built = cjson.decode(body_rewriter.gateway_error("GATEWAY_UPSTREAM_TIMEOUT", nil, TRACE_ID))

    assert.equal("GATEWAY_UPSTREAM_TIMEOUT", built.error.code)
    assert.equal("Hệ thống đang phản hồi chậm. Vui lòng thử lại sau.", built.error.message)
    assert.equal(TRACE_ID, built.error.trace_id)
  end)

  it("should carry allowlisted details on a gateway error", function()
    local built = cjson.decode(body_rewriter.gateway_error(
      "GATEWAY_RATE_LIMITED", { retry_after_seconds = 12 }, TRACE_ID))

    assert.equal(12, built.error.details.retry_after_seconds)
  end)
end)
