-- Điểm vào cho busted khi chạy dưới `resty`.
-- Không gọi trực tiếp /usr/local/bin/busted được: đó là shell wrapper, còn script Lua
-- thật thì nằm sau đường dẫn có gắn version của luarocks — ghim vào Dockerfile sẽ vỡ
-- mỗi lần đổi version busted.
require("busted.runner")({ standalone = false })
