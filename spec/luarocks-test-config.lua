-- Danh sách rocks server dùng riêng cho stage test (xem comment trong Dockerfile).
-- Mỗi namespace là nơi thật sự publish rock tương ứng:
--   lunarmodules → busted, luassert, say, term, luasystem
--   dhkolf       → dkjson
--   amireh       → lua_cliargs
--   olivine-labs → mediator_lua
--   hoelzro      → lua-term
rocks_servers = {
  "https://luarocks.org/manifests/lunarmodules",
  "https://luarocks.org/manifests/dhkolf",
  "https://luarocks.org/manifests/amireh",
  "https://luarocks.org/manifests/olivine-labs",
  "https://luarocks.org/manifests/hoelzro",
}
