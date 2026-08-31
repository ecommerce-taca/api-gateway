local kong_stub = require "spec.helpers.kong_stub"
local jwt_fixture = require "spec.helpers.jwt_fixture"
local jwks = require "kong.plugins.taca-jwt.jwks"

local LOADED_AT_KEY = "meta:loaded_at"

describe("taca-jwt jwks cache", function()
  local first_key, rotated_key, original_fetcher, fetch_count

  setup(function()
    first_key = jwt_fixture.new_key("key-01")
    rotated_key = jwt_fixture.new_key("key-02")
    original_fetcher = jwks.fetch_jwks
  end)

  before_each(function()
    kong_stub.install({})
    ngx.shared.taca_jwks:flush_all()
    jwks.reset_worker_cache()
    fetch_count = 0
  end)

  after_each(function()
    jwks.fetch_jwks = original_fetcher
    kong_stub.uninstall()
  end)

  local function serve(keys)
    jwks.fetch_jwks = function()
      fetch_count = fetch_count + 1
      return jwt_fixture.jwks_document(keys)
    end
  end

  -- loaded_at là dữ liệu nội bộ của module; test ghi thẳng vào đó để mô phỏng thời gian
  -- trôi mà không phải chờ thật.
  local function age_cache_by(seconds)
    ngx.shared.taca_jwks:set(LOADED_AT_KEY, ngx.time() - seconds)
  end

  it("should fetch the key set on the first lookup", function()
    serve({ first_key })

    local key = jwks.get_public_key(jwt_fixture.config(), "key-01")

    assert.is_not_nil(key)
    assert.equal(1, fetch_count)
  end)

  it("should serve later lookups from cache without fetching again", function()
    serve({ first_key })
    local config = jwt_fixture.config()

    jwks.get_public_key(config, "key-01")
    jwks.get_public_key(config, "key-01")
    jwks.get_public_key(config, "key-01")

    assert.equal(1, fetch_count)
  end)

  it("should refresh once when an unknown kid appears", function()
    serve({ first_key })
    local config = jwt_fixture.config()
    jwks.get_public_key(config, "key-01")

    serve({ first_key, rotated_key })
    fetch_count = 0
    local key = jwks.get_public_key(config, "key-02")

    assert.is_not_nil(key)
    assert.equal(1, fetch_count)
  end)

  it("should keep both keys valid during a rotation overlap", function()
    serve({ first_key, rotated_key })
    local config = jwt_fixture.config()

    assert.is_not_nil(jwks.get_public_key(config, "key-01"))
    assert.is_not_nil(jwks.get_public_key(config, "key-02"))
  end)

  it("should report an unknown kid as an invalid token after a successful refresh", function()
    serve({ first_key })

    local key, error_code = jwks.get_public_key(jwt_fixture.config(), "key-unknown")

    assert.is_nil(key)
    assert.equal("GATEWAY_TOKEN_INVALID", error_code)
  end)

  it("should fail closed when the jwks endpoint is unreachable", function()
    jwks.fetch_jwks = function()
      fetch_count = fetch_count + 1
      return nil, "connection refused"
    end

    local key, error_code = jwks.get_public_key(jwt_fixture.config(), "key-01")

    assert.is_nil(key)
    assert.equal("GATEWAY_JWKS_UNAVAILABLE", error_code)
  end)

  it("should refresh when the cache passed its ttl", function()
    serve({ first_key })
    local config = jwt_fixture.config()
    jwks.get_public_key(config, "key-01")
    age_cache_by(config.jwks_ttl_seconds + 60)

    fetch_count = 0
    jwks.get_public_key(config, "key-01")

    assert.equal(1, fetch_count)
  end)

  it("should keep serving a known key while stale when refresh fails", function()
    serve({ first_key })
    local config = jwt_fixture.config()
    jwks.get_public_key(config, "key-01")
    age_cache_by(config.jwks_ttl_seconds + 60)
    jwks.reset_worker_cache()

    jwks.fetch_jwks = function()
      return nil, "auth-user is down"
    end

    assert.is_not_nil(jwks.get_public_key(config, "key-01"))
  end)

  it("should fail closed once the cache is older than max stale", function()
    serve({ first_key })
    local config = jwt_fixture.config()
    jwks.get_public_key(config, "key-01")
    age_cache_by(config.jwks_max_stale_seconds + 60)
    jwks.reset_worker_cache()

    jwks.fetch_jwks = function()
      return nil, "auth-user is down"
    end

    local key, error_code = jwks.get_public_key(config, "key-01")

    assert.is_nil(key)
    assert.equal("GATEWAY_JWKS_UNAVAILABLE", error_code)
  end)

  -- Dict đầy thật sẽ làm nginx crit "no memory" và giết cả tiến trình test, nên thay
  -- shared dict bằng một dict giả trả forcible=true — đúng tín hiệu mà OpenResty phát ra
  -- khi phải đuổi entry để lấy chỗ.
  it("should fail closed when the shared dict has to evict to store a key", function()
    ngx.shared.taca_test_full = {
      get = function() return nil end,
      set = function() return true, nil, true end,
      incr = function() return 1 end,
      get_keys = function() return {} end,
      flush_all = function() end,
    }
    serve({ first_key })

    local key, error_code = jwks.get_public_key(
      jwt_fixture.config({ jwks_shared_dict = "taca_test_full" }), "key-01")

    assert.is_nil(key)
    assert.equal("GATEWAY_JWKS_UNAVAILABLE", error_code)
  end)

  it("should fail closed when the configured shared dict does not exist", function()
    serve({ first_key })

    local key, error_code = jwks.get_public_key(
      jwt_fixture.config({ jwks_shared_dict = "taca_missing_dict" }), "key-01")

    assert.is_nil(key)
    assert.equal("GATEWAY_JWKS_UNAVAILABLE", error_code)
  end)

  it("should report state as unavailable before the first refresh", function()
    assert.equal("UNAVAILABLE", jwks.state(jwt_fixture.config()))
  end)

  it("should report state as available right after a refresh", function()
    serve({ first_key })
    local config = jwt_fixture.config()

    assert.is_true(jwks.ensure_loaded(config))
    assert.equal("AVAILABLE", jwks.state(config))
    assert.is_number(jwks.loaded_at(config))
  end)

  it("should report state as stale between ttl and max stale", function()
    serve({ first_key })
    local config = jwt_fixture.config()
    jwks.ensure_loaded(config)
    age_cache_by(config.jwks_ttl_seconds + 60)

    assert.equal("STALE", jwks.state(config))
  end)

  it("should not fetch again when ensure_loaded finds a fresh cache", function()
    serve({ first_key })
    local config = jwt_fixture.config()
    jwks.ensure_loaded(config)

    fetch_count = 0
    jwks.ensure_loaded(config)

    assert.equal(0, fetch_count)
  end)
end)
