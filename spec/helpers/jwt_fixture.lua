-- Sinh khoá RSA và token thật cho test (test doc §1.2: kid=key-01, rotation key-02...).
-- Không commit key vào repo: mỗi lần chạy test sinh khoá mới, tránh biến key test
-- thành thứ có thể bị dùng nhầm ở môi trường thật.

local cjson = require "cjson.safe"
local pkey = require "resty.openssl.pkey"

local _M = {}

local function base64url(input)
  local encoded = ngx.encode_base64(input, true)

  return (string.gsub(string.gsub(encoded, "%+", "-"), "/", "_"))
end

function _M.new_key(kid)
  local key = assert(pkey.new({ type = "RSA", bits = 2048 }))
  local jwk = assert(cjson.decode(key:tostring("public", "JWK")))
  jwk.kid = kid
  jwk.alg = "RS256"
  jwk.use = "sig"

  return { kid = kid, key = key, jwk = jwk }
end

function _M.jwks_document(keys)
  local document = { keys = {} }
  for _, entry in ipairs(keys) do
    document.keys[#document.keys + 1] = entry.jwk
  end

  return document
end

function _M.claims(overrides)
  local now = ngx.time()
  local payload = {
    iss = "https://auth-user.internal",
    aud = "taca-marketplace-api",
    sub = "01912f31-7a1b-7c12-9c55-8b1c34a6d921",
    exp = now + 900,
    iat = now,
    roles = { "BUYER" },
  }

  for name, value in pairs(overrides or {}) do
    payload[name] = value
  end

  return payload
end

function _M.sign(entry, payload, header_overrides)
  local header = { typ = "JWT", alg = "RS256", kid = entry.kid }
  for name, value in pairs(header_overrides or {}) do
    header[name] = value
  end

  local signing_input = base64url(cjson.encode(header)) .. "." .. base64url(cjson.encode(payload))
  local signature = assert(entry.key:sign(signing_input, "sha256"))

  return signing_input .. "." .. base64url(signature)
end

-- Token có chữ ký rác: dùng cho case sai signature mà vẫn đúng cấu trúc.
function _M.sign_with_wrong_key(entry, payload)
  local other = _M.new_key(entry.kid)

  return _M.sign(other, payload)
end

function _M.config(overrides)
  local config = {
    issuer = "https://auth-user.internal",
    audience = "taca-marketplace-api",
    jwks_uri = "http://auth-user.internal:8080/.well-known/jwks.json",
    allowed_algorithms = { "RS256" },
    clock_skew_seconds = 30,
    jwks_ttl_seconds = 600,
    jwks_max_stale_seconds = 1800,
    jwks_request_timeout_ms = 2000,
    jwks_shared_dict = "taca_jwks",
    lock_shared_dict = "taca_locks",
    token_required = true,
    accept_websocket_subprotocol = false,
    accept_query_token = false,
    revocation_check_enabled = false,
    redis = { host = "127.0.0.1", port = 6379, database = 0, timeout_ms = 500 },
  }

  for name, value in pairs(overrides or {}) do
    config[name] = value
  end

  return config
end

return _M
