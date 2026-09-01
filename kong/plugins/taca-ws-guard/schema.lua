-- Cấu hình taca-ws-guard (LLD §2.1.2, §4). Plugin này chỉ được gắn trên Route /ws/messages.

local typedefs = require "kong.db.schema.typedefs"
local redis_field = require "kong.plugins.taca-lib.schema_redis"

return {
  name = "taca-ws-guard",
  fields = {
    { protocols = typedefs.protocols_http },
    {
      config = {
        type = "record",
        fields = {
          { max_connections_per_user = { type = "integer", default = 10 } },
          -- TTL phải dài hơn WS_IDLE_TIMEOUT (1800s), nếu không counter hết hạn trong khi
          -- socket còn mở và cap mất tác dụng. Gấp đôi idle timeout là biên an toàn để
          -- counter tự dọn khi node chết mà phase log không kịp chạy (DB §3.1.2).
          { connection_counter_ttl_seconds = { type = "integer", default = 3600 } },
          redis_field(),
        },
      },
    },
  },
}
