local cjson = require "cjson.safe"
local kong_stub = require "spec.helpers.kong_stub"
local handler = require "kong.plugins.taca-error-envelope.handler"

local TRACE_ID = "01912f31-7a1b-7c12-9c55-8b1c34a6d921"

local function config(overrides)
  local value = { allowed_business_error_codes = {}, redis_backed_rate_limit = false }
  for name, override in pairs(overrides or {}) do
    value[name] = override
  end

  return value
end

describe("taca-error-envelope handler", function()
  local original_arg

  before_each(function()
    original_arg = ngx.arg
  end)

  after_each(function()
    ngx.arg = original_arg
    kong_stub.uninstall()
  end)

  -- Chạy trọn header_filter + body_filter cho một response, trả về body cuối cùng.
  local function run(options, plugin_config, chunks)
    local state = kong_stub.install({
      headers = { ["X-Request-ID"] = TRACE_ID },
      response_status = options.status,
      response_source = options.source,
      response_headers = options.response_headers,
    })

    if options.access_phase_reached ~= false then
      handler:access(plugin_config)
    end

    handler:header_filter(plugin_config)

    local emitted = {}
    for index, chunk in ipairs(chunks or { "" }) do
      ngx.arg = { chunk, index == #(chunks or { "" }) }
      handler:body_filter(plugin_config)
      emitted[#emitted + 1] = ngx.arg[1]
    end

    return state, emitted[#emitted]
  end

  it("should leave a successful response untouched", function()
    local state, body = run({ status = 200, source = "service" }, config(), { '{"data":[]}' })

    assert.is_nil(state.shared.taca_envelope_plan)
    assert.equal('{"data":[]}', body)
  end)

  it("should leave a websocket upgrade untouched", function()
    local state = run({ status = 101, source = "service" }, config(), { "" })

    assert.is_nil(state.shared.taca_envelope_plan)
  end)

  it("should replace the kong default body on a route miss", function()
    local _, body = run({ status = 404, source = "exit" }, config(),
                        { '{"message":"Not found"}' })

    local document = cjson.decode(body)
    assert.equal("GATEWAY_ROUTE_NOT_FOUND", document.error.code)
    assert.equal("Không tìm thấy đường dẫn yêu cầu.", document.error.message)
    assert.equal(TRACE_ID, document.error.trace_id)
  end)

  it("should never leak the kong default message field", function()
    local _, body = run({ status = 503, source = "error" }, config(),
                        { '{"message":"The upstream server is currently unavailable"}' })

    assert.is_nil(cjson.decode(body).message)
  end)

  it("should force the json content type on an error response", function()
    local state = run({ status = 404, source = "exit" }, config(), { "" })

    assert.equal("application/json; charset=utf-8", state.response_headers["content-type"])
    assert.is_nil(state.response_headers["content-length"])
  end)

  it("should carry retry-after into the rate limit details", function()
    local _, body = run({
      status = 429,
      source = "exit",
      response_headers = { ["Retry-After"] = "12" },
    }, config(), { '{"message":"API rate limit exceeded"}' })

    assert.equal(12, cjson.decode(body).error.details.retry_after_seconds)
  end)

  it("should keep an allowlisted business error from the upstream", function()
    local upstream_body = cjson.encode({
      error = { code = "ORDER_STOCK_UNAVAILABLE", message = "Hết hàng.", trace_id = TRACE_ID },
    })

    local state, body = run({ status = 409, source = "service" }, config(), { upstream_body })

    assert.is_nil(state.status)
    assert.equal("ORDER_STOCK_UNAVAILABLE", cjson.decode(body).error.code)
  end)

  it("should reassemble a business error split across chunks", function()
    local upstream_body = cjson.encode({
      error = { code = "ORDER_NOT_FOUND", message = "Không tìm thấy đơn hàng." },
    })
    local half = math.floor(#upstream_body / 2)

    local _, body = run({ status = 404, source = "service" }, config(),
                        { string.sub(upstream_body, 1, half), string.sub(upstream_body, half + 1) })

    assert.equal("ORDER_NOT_FOUND", cjson.decode(body).error.code)
  end)

  it("should replace an upstream 4xx body that breaks the envelope contract", function()
    local _, body = run({ status = 400, source = "service" }, config(),
                        { "<html>bad request</html>" })

    assert.equal("GATEWAY_UPSTREAM_BAD_RESPONSE", cjson.decode(body).error.code)
  end)

  it("should replace an upstream 5xx body and change the status", function()
    local state, body = run({ status = 500, source = "service" }, config(),
                            { '{"stack":"NullPointerException at com.taca"}' })

    assert.equal(502, state.status)
    assert.equal("GATEWAY_UPSTREAM_BAD_RESPONSE", cjson.decode(body).error.code)
  end)

  it("should report a redis outage when the access phase never ran", function()
    local state, body = run({ status = 500, source = "error", access_phase_reached = false },
                            config({ redis_backed_rate_limit = true }),
                            { '{"message":"An unexpected error occurred"}' })

    assert.equal(503, state.status)
    assert.equal("GATEWAY_REDIS_UNAVAILABLE", cjson.decode(body).error.code)
  end)
end)

describe("taca-error-envelope handler with plugin generated errors", function()
  local original_arg

  before_each(function()
    original_arg = ngx.arg
  end)

  after_each(function()
    ngx.arg = original_arg
    kong_stub.uninstall()
  end)

  local function run_exit(status, body, request_headers)
    kong_stub.install({
      headers = request_headers or { ["X-Request-ID"] = TRACE_ID },
      response_status = status,
      response_source = "exit",
    })

    local plugin_config = config()
    handler:access(plugin_config)
    handler:header_filter(plugin_config)
    ngx.arg = { body, true }
    handler:body_filter(plugin_config)

    return ngx.arg[1]
  end

  it("should keep the error code produced by another taca plugin", function()
    local exit_body = cjson.encode({
      error = {
        code = "GATEWAY_TOKEN_EXPIRED",
        message = "Phiên đăng nhập đã hết hạn.",
        details = {},
        trace_id = TRACE_ID,
      },
    })

    assert.equal("GATEWAY_TOKEN_EXPIRED", cjson.decode(run_exit(401, exit_body)).error.code)
  end)

  it("should keep a permission denial produced by the rbac plugin", function()
    local exit_body = cjson.encode({
      error = {
        code = "GATEWAY_PERMISSION_DENIED",
        message = "Bạn không có quyền thực hiện thao tác này.",
        details = {},
        trace_id = TRACE_ID,
      },
    })

    assert.equal("GATEWAY_PERMISSION_DENIED", cjson.decode(run_exit(403, exit_body)).error.code)
  end)

  it("should fill a missing trace id on an envelope produced before correlation id", function()
    local exit_body = cjson.encode({
      error = { code = "GATEWAY_CORS_DENIED", message = "Nguồn truy cập không được phép.",
                details = {}, trace_id = "" },
    })

    local document = cjson.decode(run_exit(403, exit_body, { ["X-Request-ID"] = TRACE_ID }))

    assert.equal(TRACE_ID, document.error.trace_id)
  end)

  it("should still replace a body carrying an unknown error code", function()
    local exit_body = cjson.encode({ error = { code = "SOMETHING_ELSE", message = "nope" } })

    assert.equal("GATEWAY_INVALID_REQUEST", cjson.decode(run_exit(400, exit_body)).error.code)
  end)
end)
