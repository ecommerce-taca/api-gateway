-- Sinh cặp khoá RSA và JWKS cho môi trường local.
-- Khoá KHÔNG được commit: mỗi máy dev tự sinh khoá riêng, tránh biến khoá test thành
-- thứ có thể bị dùng nhầm ở môi trường thật.

local cjson = require "cjson.safe"
local pkey = require "resty.openssl.pkey"

local OUTPUT_DIR = "/out"
local KID = "dev-key-01"

local key = assert(pkey.new({ type = "RSA", bits = 2048 }))

local jwk = assert(cjson.decode(key:tostring("public", "JWK")))
jwk.kid = KID
jwk.alg = "RS256"
jwk.use = "sig"

local function write_file(name, content)
  local handle = assert(io.open(OUTPUT_DIR .. "/" .. name, "w"))
  handle:write(content)
  handle:close()
end

write_file("jwks.json", cjson.encode({ keys = { jwk } }))
write_file("private-key.pem", key:tostring("private", "PEM"))

print("generated " .. OUTPUT_DIR .. "/jwks.json with kid=" .. KID)
