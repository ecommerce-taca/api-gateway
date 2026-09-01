-- Khối cấu hình Redis dùng chung cho taca-jwt, taca-ws-guard và taca-request-guard.
-- Khai báo một lần: ba plugin nói chuyện với cùng một Redis, lệch field giữa chúng là
-- lỗi cấu hình im lặng. Trả bảng mới mỗi lần gọi vì Kong mutate schema khi nạp plugin.

return function()
  return {
    redis = {
      type = "record",
      fields = {
        { host = { type = "string", default = "127.0.0.1" } },
        { port = { type = "integer", default = 6379 } },
        { database = { type = "integer", default = 0 } },
        { password = { type = "string", encrypted = true } },
        { timeout_ms = { type = "number", default = 500 } },
      },
    },
  }
end
