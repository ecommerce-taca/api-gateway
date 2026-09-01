# API Gateway — Kong 3.9.0 OSS DB-less + 5 custom plugin taca-* (LLD §2.1)
# Ghim patch version cụ thể: PRIORITY của plugin built-in và tên metric Prometheus
# phụ thuộc phiên bản, đổi tag là đổi hành vi (LLD §2.1.3, API §3.3).
ARG KONG_VERSION=3.9.0

# ---- Stage 1: test — busted + toolchain build, KHÔNG đi vào image cuối ----
FROM kong:${KONG_VERSION} AS test
USER root

# luasystem (dependency của busted) cần librt khi biên dịch; librt nằm trong libc6-dev.
# Manifest gốc của luarocks.org quá lớn, LuaJIT không nạp nổi ("more than 65536 constants"),
# nên trỏ thẳng vào manifest theo namespace của từng rock — nhỏ và nạp được.
COPY spec/luarocks-test-config.lua /etc/luarocks/taca-test-config.lua
ENV LUAROCKS_CONFIG=/etc/luarocks/taca-test-config.lua
RUN apt-get update \
    && apt-get install -y --no-install-recommends build-essential libc6-dev \
    && luarocks install busted 2.2.0-1 \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /gateway
COPY kong/plugins /usr/local/custom/kong/plugins
COPY spec ./spec
COPY .busted ./.busted

# busted chạy dưới resty để có ngx API và shared dict thật thay vì stub —
# resty.lock và lua_shared_dict là hai thứ không giả lập trung thực được.
# errlog-level=error: chạy ngoài nginx thật nên OpenResty cảnh báo mỗi lần test ghi
# biến global (kong stub); những dòng đó làm log CI không đọc được.
CMD ["resty", "--errlog-level=error", "--shdict", "taca_jwks 10m", "--shdict", "taca_locks 1m", \
     "--shdict", "taca_metrics 5m", "-I", "/gateway", "-I", "/usr/local/custom", \
     "/gateway/spec/busted_runner.lua", "--config-file=.busted"]

# ---- Stage 2: runtime — chỉ Kong + plugin, không toolchain, không spec ----
FROM kong:${KONG_VERSION} AS runtime
USER root
COPY --chown=kong:kong kong/plugins /usr/local/custom/kong/plugins
COPY --chown=kong:kong kong/kong.conf /etc/kong/kong.conf
# HEALTHCHECK cần curl để probe status listener (:8100); image Kong base (Ubuntu 24.04)
# không có curl. --no-install-recommends để không kéo thêm bloat vào image runtime.
RUN apt-get update \
    && apt-get install -y --no-install-recommends curl \
    && rm -rf /var/lib/apt/lists/*
USER kong

# Nhắc lại danh sách plugin ở ENV để `docker run` không kèm kong.conf vẫn nạp đủ plugin.
ENV KONG_PLUGINS="bundled,taca-request-guard,taca-jwt,taca-rbac,taca-ws-guard,taca-error-envelope"
ENV KONG_LUA_PACKAGE_PATH="/usr/local/custom/?.lua;/usr/local/custom/?/init.lua;;"

EXPOSE 8000 8443 8100
# Readiness thật đi qua Route nội bộ /health/ready (LLD §2.1.5); ở mức container chỉ
# kiểm status listener vì Route có thể chưa được decK sync khi container vừa lên.
HEALTHCHECK --interval=30s --timeout=3s --start-period=20s --retries=3 \
    CMD kong health && curl -sf http://127.0.0.1:8100/status > /dev/null || exit 1
CMD ["kong", "docker-start"]
