-- Giả lập PDK của Kong đủ để chạy plugin ngoài nginx của Kong (test doc §1.1:
-- unit test phải chạy độc lập, không cần Kong đầy đủ).
-- Chỉ giả lập những hàm plugin thật sự gọi — thêm hàm không dùng chỉ làm test kém trung thực.

local _M = {}

local function lower_keys(source)
  local result = {}
  for name, value in pairs(source or {}) do
    result[string.lower(name)] = value
  end

  return result
end

function _M.install(options)
  options = options or {}

  local state = {
    request_headers = lower_keys(options.headers),
    exit_status = nil,
    exit_body = nil,
    exit_headers = nil,
    service_headers = {},
    cleared_headers = {},
    response_headers = lower_keys(options.response_headers),
    logs = {},
    shared = {},
  }

  local request = {
    get_header = function(name)
      return state.request_headers[string.lower(name)]
    end,
    get_headers = function()
      return state.request_headers
    end,
    get_method = function()
      return options.method or "GET"
    end,
    get_path = function()
      return options.path or "/"
    end,
    get_raw_query = function()
      return options.query or ""
    end,
    get_query_arg = function(name)
      return (options.query_args or {})[name]
    end,
    get_scheme = function()
      return options.scheme or "https"
    end,
  }

  local response = {
    exit = function(status, body, headers)
      state.exit_status = status
      state.exit_body = body
      state.exit_headers = headers
      return nil
    end,
    get_status = function()
      return options.response_status or 200
    end,
    get_source = function()
      return options.response_source or "service"
    end,
    get_header = function(name)
      return state.response_headers[string.lower(name)]
    end,
    set_header = function(name, value)
      state.response_headers[string.lower(name)] = value
    end,
    clear_header = function(name)
      state.response_headers[string.lower(name)] = nil
    end,
  }

  local service_request = {
    set_header = function(name, value)
      state.service_headers[name] = value
    end,
    clear_header = function(name)
      state.cleared_headers[name] = true
      state.request_headers[string.lower(name)] = nil
    end,
  }

  local function record_log(level)
    return function(...)
      state.logs[#state.logs + 1] = { level = level, args = { ... } }
    end
  end

  _G.kong = {
    request = request,
    response = response,
    service = { request = service_request },
    client = {
      get_ip = function()
        return options.client_ip or "127.0.0.1"
      end,
      get_forwarded_ip = function()
        return options.forwarded_ip or options.client_ip or "127.0.0.1"
      end,
    },
    router = {
      get_route = function()
        return options.route or { id = "route-test", name = "rt-test" }
      end,
      get_service = function()
        return options.service or { id = "service-test", name = "svc-test" }
      end,
    },
    log = {
      debug = record_log("debug"),
      info = record_log("info"),
      notice = record_log("notice"),
      warn = record_log("warn"),
      err = record_log("err"),
      crit = record_log("crit"),
    },
    ctx = { shared = state.shared },
    configuration = options.configuration or { database = "off" },
  }

  return state
end

function _M.uninstall()
  _G.kong = nil
end

return _M
