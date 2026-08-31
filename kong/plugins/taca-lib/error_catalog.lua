-- Catalog mã lỗi của Gateway (LLD §7, API §4).
-- Đây là nguồn duy nhất cho cặp (HTTP status, message): nếu mỗi plugin tự viết message
-- thì cùng một lỗi đi qua hai đường sẽ hiển thị khác nhau trên frontend.
-- Message là tiếng Việt cho người dùng cuối; code là English stable cho frontend xử lý.

local ERROR_CATALOG = {
  GATEWAY_INVALID_REQUEST       = { status = 400, message = "Yêu cầu chưa đúng định dạng." },
  GATEWAY_ROUTE_NOT_FOUND       = { status = 404, message = "Không tìm thấy đường dẫn yêu cầu." },
  GATEWAY_AUTH_REQUIRED         = { status = 401, message = "Vui lòng đăng nhập để tiếp tục." },
  GATEWAY_TOKEN_INVALID         = { status = 401, message = "Phiên đăng nhập không hợp lệ." },
  GATEWAY_TOKEN_EXPIRED         = { status = 401, message = "Phiên đăng nhập đã hết hạn." },
  GATEWAY_PERMISSION_DENIED     = { status = 403, message = "Bạn không có quyền thực hiện thao tác này." },
  GATEWAY_CORS_DENIED           = { status = 403, message = "Nguồn truy cập không được phép." },
  GATEWAY_RATE_LIMITED          = { status = 429, message = "Bạn thao tác quá nhanh. Vui lòng thử lại sau." },
  GATEWAY_REQUEST_TOO_LARGE     = { status = 413, message = "Dữ liệu gửi lên vượt quá dung lượng cho phép." },
  GATEWAY_JWKS_UNAVAILABLE      = { status = 503, message = "Hệ thống xác thực đang tạm thời gián đoạn." },
  GATEWAY_REDIS_UNAVAILABLE     = { status = 503, message = "Hệ thống đang tạm thời không khả dụng." },
  GATEWAY_UPSTREAM_TIMEOUT      = { status = 504, message = "Hệ thống đang phản hồi chậm. Vui lòng thử lại sau." },
  GATEWAY_UPSTREAM_UNAVAILABLE  = { status = 503, message = "Dịch vụ đang tạm thời không khả dụng." },
  GATEWAY_UPSTREAM_BAD_RESPONSE = { status = 502, message = "Hệ thống vừa gặp lỗi. Vui lòng thử lại sau." },
  GATEWAY_CONFIG_INVALID        = { status = 503, message = "Hệ thống chưa sẵn sàng." },
  GATEWAY_INTERNAL_ERROR        = { status = 500, message = "Hệ thống đang bận. Vui lòng thử lại." },
}

local _M = {}

-- Trả về mã lỗi fallback khi gọi bằng code lạ: thà trả lỗi nội bộ chuẩn hoá còn hơn
-- để nil trôi xuống và sinh ra response không có envelope.
function _M.lookup(code)
  local entry = ERROR_CATALOG[code]
  if not entry then
    return "GATEWAY_INTERNAL_ERROR", ERROR_CATALOG.GATEWAY_INTERNAL_ERROR
  end

  return code, entry
end

function _M.is_known(code)
  return ERROR_CATALOG[code] ~= nil
end

function _M.all()
  return ERROR_CATALOG
end

return _M
