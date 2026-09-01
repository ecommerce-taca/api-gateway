-- Cache JWKS của auth-user theo kid (LLD §2.4, DB §3.2).
-- Hai tầng cache là cố ý: lua_shared_dict giữ PEM dùng chung giữa các worker của một node,
-- lrucache giữ object đã parse cho từng worker để không parse PEM lại trên mỗi request.
-- Shared dict chỉ lưu string nên không thể giữ thẳng object pkey.

local cjson = require "cjson.safe"
local http = require "resty.http"
local lrucache = require "resty.lrucache"
local pkey = require "resty.openssl.pkey"
local resty_lock = require "resty.lock"
local metrics_store = require "kong.plugins.taca-lib.metrics_store"

local KEY_PREFIX = "jwk:"
local LOADED_AT_KEY = "meta:loaded_at"
local LOCK_KEY = "jwks-refresh"
local METRIC_NAME = "taca_jwks_refresh_total"

local JWKS_UNAVAILABLE = "GATEWAY_JWKS_UNAVAILABLE"
local TOKEN_INVALID = "GATEWAY_TOKEN_INVALID"

-- 64 kid là thừa cho cửa sổ rotation overlap (thường 2 key), phần dư dành cho lúc
-- auth-user rotate dồn dập mà node chưa restart.
local parsed_keys = lrucache.new(64)

local _M = {}

_M.states = {
  AVAILABLE = "AVAILABLE",
  REFRESHING = "REFRESHING",
  STALE = "STALE",
  UNAVAILABLE = "UNAVAILABLE",
}

-- Điểm nối duy nhất ra HTTP. Test thay hàm này bằng fixture thay vì dựng server thật;
-- runtime giữ nguyên implementation dưới đây.
function _M.fetch_jwks(config)
  local client, err = http.new()
  if not client then return nil, err end

  client:set_timeout(config.jwks_request_timeout_ms)

  local response, request_err = client:request_uri(config.jwks_uri, {
    method = "GET",
    headers = { ["Accept"] = "application/json" },
  })
  if not response then return nil, request_err end
  if response.status ~= 200 then
    return nil, "jwks endpoint returned status " .. response.status
  end

  local document = cjson.decode(response.body)
  if type(document) ~= "table" or type(document.keys) ~= "table" then
    return nil, "jwks document has no keys array"
  end

  return document
end

local function store_of(config)
  return ngx.shared[config.jwks_shared_dict]
end

local function is_signing_key(jwk)
  return jwk.kty == "RSA" and jwk.kid and (jwk.use == nil or jwk.use == "sig")
end

-- Trả về số key đã ghi được, hoặc nil + lỗi khi dict đầy: dict đầy phải fail-closed
-- (IT-KONG-18), tuyệt đối không được coi như refresh thành công.
local function write_keys(store, document, ttl_seconds)
  local written = 0

  for _, jwk in ipairs(document.keys) do
    if is_signing_key(jwk) then
      local key, parse_err = pkey.new(cjson.encode(jwk), { format = "JWK" })
      if not key then
        kong.log.warn("skipping unusable jwk kid=", jwk.kid, " err=", parse_err)
      else
        -- Giữ TTL dài hơn max_stale để bản thân key không biến mất trước khi
        -- logic stale kịp quyết định; hạn dùng do loaded_at quyết định, không do TTL.
        local stored, store_err, forcible = store:set(KEY_PREFIX .. jwk.kid,
                                                      key:tostring("public", "PEM"),
                                                      ttl_seconds)
        -- forcible = shared dict đã phải đuổi entry khác để có chỗ, tức dict quá nhỏ so với
        -- số kid trong cửa sổ rotation. Coi như thất bại và fail-closed (IT-KONG-18):
        -- ghi tiếp nghĩa là key của kid khác vừa bị xoá và request kế tiếp sẽ verify hụt.
        if not stored or forcible then
          return nil, store_err or "shared dict is full"
        end

        written = written + 1
      end
    end
  end

  return written
end

local function refresh_failed(reason, err)
  metrics_store.increment(METRIC_NAME, { outcome = "failure" })
  kong.log.err(reason, err)

  return nil, JWKS_UNAVAILABLE
end

local function refresh_now(config)
  local store = store_of(config)
  if not store then return nil, JWKS_UNAVAILABLE end

  local document, fetch_err = _M.fetch_jwks(config)
  if not document then return refresh_failed("jwks refresh failed: ", fetch_err) end

  local written, write_err = write_keys(store, document, config.jwks_max_stale_seconds * 2)
  if not written then
    return refresh_failed("jwks shared dict write failed: ", write_err)
  end

  store:set(LOADED_AT_KEY, ngx.time())
  metrics_store.increment(METRIC_NAME, { outcome = "success" })

  return written
end

-- Refresh một lần dưới lock: nhiều request cùng gặp kid lạ sẽ chờ trên lock thay vì
-- mỗi request bắn một lời gọi tới auth-user (LLD §2.4 bước 3, RES-GW-02).
local function refresh_single_flight(config)
  local timeout_seconds = config.jwks_request_timeout_ms / 1000
  local lock, lock_err = resty_lock:new(config.lock_shared_dict, {
    timeout = timeout_seconds,
    exptime = timeout_seconds * 2,
  })
  if not lock then
    kong.log.err("cannot create jwks refresh lock: ", lock_err)
    return refresh_now(config)
  end

  local elapsed = lock:lock(LOCK_KEY)
  if not elapsed then return nil, JWKS_UNAVAILABLE end

  -- elapsed > 0 nghĩa là đã chờ người khác refresh xong; đọc lại cache trước khi
  -- tự gọi lần nữa.
  local result, err = true, nil
  if elapsed == 0 then
    result, err = refresh_now(config)
  end

  lock:unlock()

  return result, err
end

local function read_key(config, kid)
  local cached = parsed_keys:get(kid)
  if cached then return cached end

  local store = store_of(config)
  local pem = store and store:get(KEY_PREFIX .. kid)
  if not pem then return nil end

  local key = pkey.new(pem)
  if not key then return nil end

  parsed_keys:set(kid, key)

  return key
end

local function loaded_age(config)
  local store = store_of(config)
  local loaded_at = store and store:get(LOADED_AT_KEY)
  if not loaded_at then return nil end

  return ngx.time() - loaded_at, loaded_at
end

function _M.state(config)
  local age = loaded_age(config)
  if not age or age > config.jwks_max_stale_seconds then return _M.states.UNAVAILABLE end
  if age > config.jwks_ttl_seconds then return _M.states.STALE end

  return _M.states.AVAILABLE
end

-- Lấy public key cho kid. Trả về nil + mã lỗi Gateway để handler khỏi tự đoán status.
function _M.get_public_key(config, kid)
  local state = _M.state(config)

  if state == _M.states.AVAILABLE then
    local key = read_key(config, kid)
    if key then return key end
  end

  local refreshed, refresh_err = refresh_single_flight(config)
  if not refreshed then
    -- Còn trong cửa sổ stale thì vẫn dùng key đã biết, nhưng phải ghi metric
    -- để vận hành thấy JWKS đang hỏng trước khi nó vượt max_stale (LLD §5.3).
    local key = state == _M.states.STALE and read_key(config, kid)
    if key then
      metrics_store.increment(METRIC_NAME, { outcome = "stale" })
      return key
    end

    return nil, refresh_err or JWKS_UNAVAILABLE
  end

  local key = read_key(config, kid)
  -- Refresh thành công mà vẫn không có kid: token không do issuer này ký.
  if not key then return nil, TOKEN_INVALID end

  return key
end

-- Dùng cho readiness (DB §6: JWKS bootstrap khi startup/readiness).
function _M.ensure_loaded(config)
  if _M.state(config) == _M.states.AVAILABLE then return true end

  local refreshed, err = refresh_single_flight(config)
  if not refreshed then return nil, err or JWKS_UNAVAILABLE end

  return true
end

function _M.loaded_at(config)
  local _, loaded_at = loaded_age(config)

  return loaded_at
end

-- Chỉ dùng trong test: xoá cache theo worker để mỗi case bắt đầu từ trạng thái sạch.
function _M.reset_worker_cache()
  parsed_keys:flush_all()
end

return _M
