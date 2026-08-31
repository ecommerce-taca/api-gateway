-- Ký một access token bằng khoá dev để thử tay route protected.
-- Claim lấy từ biến môi trường để thử được nhiều vai: TOKEN_SUB, TOKEN_ROLES, TOKEN_TTL.

local cjson = require "cjson.safe"
local pkey = require "resty.openssl.pkey"

local KEY_PATH = "/out/private-key.pem"
local KID = "dev-key-01"

local function base64url(input)
  return (string.gsub(string.gsub(ngx.encode_base64(input, true), "%+", "-"), "/", "_"))
end

local function read_private_key()
  local handle = assert(io.open(KEY_PATH, "r"), "chưa có khoá dev, chạy `make dev-keys` trước")
  local pem = handle:read("*a")
  handle:close()

  return assert(pkey.new(pem))
end

local function split_roles(value)
  local roles = {}
  for role in string.gmatch(value or "BUYER", "[^,]+") do
    roles[#roles + 1] = role
  end

  return roles
end

local key = read_private_key()
local now = ngx.time()
local payload = {
  iss = os.getenv("TOKEN_ISSUER") or "http://mock-auth-user:8080",
  aud = os.getenv("TOKEN_AUDIENCE") or "taca-marketplace-api",
  sub = os.getenv("TOKEN_SUB") or "01912f31-7a1b-7c12-9c55-8b1c34a6d921",
  iat = now,
  exp = now + tonumber(os.getenv("TOKEN_TTL") or "900"),
  roles = split_roles(os.getenv("TOKEN_ROLES")),
}

local header = { typ = "JWT", alg = "RS256", kid = KID }
local signing_input = base64url(cjson.encode(header)) .. "." .. base64url(cjson.encode(payload))

print(signing_input .. "." .. base64url(assert(key:sign(signing_input, "sha256"))))
