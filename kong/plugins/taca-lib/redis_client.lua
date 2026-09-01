-- Bọc Redis sau interface của mình: plugin nghiệp vụ chỉ nói ý định
-- (increment_with_expiry / key_exists), không biết resty.redis tồn tại.
-- Lỗi của driver được dịch ngay tại đây sang mã lỗi Gateway, không để lỗi thô trôi lên.
-- Gateway chỉ dùng Redis cho counter và marker có TTL, không lưu business state (DB §3.1).

local redis = require "resty.redis"

local REDIS_UNAVAILABLE = "GATEWAY_REDIS_UNAVAILABLE"

-- INCR và EXPIRE phải nguyên tử: nếu tách hai lệnh, node chết giữa chừng sẽ để lại
-- key không TTL và khoá vĩnh viễn khả năng kết nối của user đó (DB §3.1.2).
-- EXPIRE được làm mới mỗi lần INCR để counter không hết hạn khi socket vẫn đang mở.
local INCREMENT_SCRIPT = [[
  local value = redis.call('INCR', KEYS[1])
  redis.call('EXPIRE', KEYS[1], ARGV[1])
  return value
]]

-- DECR không được xuống âm: một lần phase log chạy thừa sẽ làm cap của user bị nới ra.
local DECREMENT_SCRIPT = [[
  local value = redis.call('DECR', KEYS[1])
  if value < 0 then
    redis.call('SET', KEYS[1], 0)
    return 0
  end
  return value
]]

local RedisClient = {}
RedisClient.__index = RedisClient

local _M = {}

-- options nhận thẳng block `redis` trong schema của plugin: ba plugin khai báo giống
-- hệt nhau nên không cần hàm map riêng ở từng handler.
function _M.new(options)
  return setmetatable({
    host = options.host,
    port = options.port,
    database = options.database or 0,
    password = options.password,
    timeout_ms = options.timeout_ms,
    keepalive_idle_timeout_ms = options.keepalive_idle_timeout_ms or 60000,
    keepalive_pool_size = options.keepalive_pool_size or 100,
  }, RedisClient)
end

function RedisClient:_acquire()
  local connection = redis:new()
  -- Mọi lời gọi ra ngoài phải có timeout; thiếu nó thì Redis chậm sẽ kéo cả gateway treo.
  connection:set_timeouts(self.timeout_ms, self.timeout_ms, self.timeout_ms)

  local ok, err = connection:connect(self.host, self.port)
  if ok and self.password then
    ok, err = connection:auth(self.password)
  end

  if ok and self.database ~= 0 then
    ok, err = connection:select(self.database)
  end

  if not ok then
    return nil, REDIS_UNAVAILABLE, err
  end

  return connection
end

-- Một đường vào duy nhất cho mọi lệnh: acquire → chạy → trả connection về pool thay vì
-- đóng, vì handshake TCP mỗi request là chi phí vô ích trên đường đi nóng.
function RedisClient:_call(command)
  local connection, code, err = self:_acquire()
  if not connection then
    return nil, code, err
  end

  local value, command_err = command(connection)
  if not value then
    connection:close()
    return nil, REDIS_UNAVAILABLE, command_err
  end

  if not connection:set_keepalive(self.keepalive_idle_timeout_ms, self.keepalive_pool_size) then
    connection:close()
  end

  return value
end

function RedisClient:increment_with_expiry(key, ttl_seconds)
  return self:_call(function(connection)
    return connection:eval(INCREMENT_SCRIPT, 1, key, ttl_seconds)
  end)
end

function RedisClient:decrement(key)
  return self:_call(function(connection)
    return connection:eval(DECREMENT_SCRIPT, 1, key, 0)
  end)
end

function RedisClient:key_exists(key)
  -- EXISTS trả 0 khi vắng mặt: 0 vẫn là giá trị hợp lệ nên chỉ nil mới là lỗi.
  local exists, code, err = self:_call(function(connection)
    return connection:exists(key)
  end)
  if exists == nil then
    return nil, code, err
  end

  return exists == 1
end

function RedisClient:ping()
  local pong, code, err = self:_call(function(connection)
    return connection:ping()
  end)

  if not pong then
    return nil, code, err
  end

  return true
end

return _M
