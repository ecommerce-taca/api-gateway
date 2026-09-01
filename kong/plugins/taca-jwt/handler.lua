-- taca-jwt — verify RS256 bằng JWKS cache và dựng actor context (LLD §2.1.2).
-- Kong OSS không có plugin JWKS nên phần này bắt buộc phải tự viết.

local envelope_builder = require "kong.plugins.taca-lib.envelope_builder"
local redis_client = require "kong.plugins.taca-lib.redis_client"
local actor_context = require "kong.plugins.taca-jwt.actor_context"
local jwks = require "kong.plugins.taca-jwt.jwks"
local token_reader = require "kong.plugins.taca-jwt.token_reader"
local token_verifier = require "kong.plugins.taca-jwt.token_verifier"

local REVOKED_KEY_PREFIX = "revoked_user:"

local TacaJwtHandler = {
  -- Nằm dưới request-size-limiting (951) và trên rate-limiting (910) của Kong 3.9.0:
  -- header X-User-ID phải được đặt trước khi bucket authenticated đọc nó (LLD §2.1.3).
  PRIORITY = 940,
  VERSION = "1.0.0",
}

-- Auth User đẩy marker khi suspend/revoke user (DB §3.1.2). Redis lỗi thì fail-closed:
-- cho qua nghĩa là user vừa bị khoá vẫn dùng được tiếp cho tới khi access token hết hạn.
local function is_revoked(config, user_id)
  if not config.revocation_check_enabled then return false end

  local client = redis_client.new(config.redis)
  local exists, error_code = client:key_exists(REVOKED_KEY_PREFIX .. user_id)
  if exists == nil then return nil, error_code end

  return exists
end

local function verify_token(config, token)
  local parsed, parse_error = token_verifier.parse(token)
  if not parsed then return nil, parse_error end

  local algorithm_ok, algorithm_error =
    token_verifier.check_algorithm(parsed.header, config.allowed_algorithms)
  if not algorithm_ok then return nil, algorithm_error end

  if type(parsed.header.kid) ~= "string" then return nil, "GATEWAY_TOKEN_INVALID" end

  local public_key, key_error = jwks.get_public_key(config, parsed.header.kid)
  if not public_key then return nil, key_error end

  local signature_ok, signature_error = token_verifier.verify_signature(public_key, parsed)
  if not signature_ok then return nil, signature_error end

  local claims_ok, claims_error = token_verifier.validate_claims(parsed.payload, config, ngx.time())
  if not claims_ok then return nil, claims_error end

  return parsed.payload
end

function TacaJwtHandler:access(config)
  local token = token_reader.read(config)
  if not token then
    if config.token_required then
      return envelope_builder.exit("GATEWAY_AUTH_REQUIRED")
    end

    return
  end

  local payload, verify_error = verify_token(config, token)
  if not payload then return envelope_builder.exit(verify_error) end

  local revoked, revocation_error = is_revoked(config, payload.sub)
  if revoked == nil then return envelope_builder.exit(revocation_error) end
  if revoked then return envelope_builder.exit("GATEWAY_TOKEN_INVALID") end

  -- taca-rbac và taca-ws-guard đọc lại actor ở đây thay vì parse token lần nữa.
  local actor = actor_context.build(payload)
  actor_context.apply(actor)
  kong.ctx.shared.taca_actor = actor
end

return TacaJwtHandler
