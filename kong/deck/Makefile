# Vòng đời cấu hình Kong: render → validate → lint → diff → sync (LLD §2.6, DB §6).
# Mọi target chạy decK trong container để không ai phải cài decK cục bộ và để phiên bản
# decK được ghim đúng như CI.

ENV ?= dev
DECK_IMAGE ?= kong/deck:v1.65.3
# Admin API chỉ bind loopback (kong.conf). diff/sync phải chạy từ máy có đường tới nó,
# ví dụ qua `kubectl port-forward`; không mở Admin API ra ingress (SEC-GW-14).
KONG_ADDR ?= http://127.0.0.1:8001

ENV_FILE := env/$(ENV).yaml
BUILD_DIR := .build
ENV_VARS := $(BUILD_DIR)/$(ENV).env
RENDERED := $(BUILD_DIR)/kong.$(ENV).yaml
# --user: file render ghi ra .build của host, chạy bằng root sẽ để lại file không xoá được.
DECK_RUN = docker run --rm --network host --user $$(id -u):$$(id -g) \
	--env-file $(ENV_VARS) -v $(CURDIR):/deck -w /deck $(DECK_IMAGE)

.PHONY: render validate lint diff sync clean

# env/<môi trường>.yaml là YAML phẳng; chuyển thành dạng KEY=VALUE cho docker --env-file.
$(ENV_VARS): $(ENV_FILE)
	@mkdir -p $(BUILD_DIR)
	@sed -n 's/^\([A-Z][A-Z0-9_]*\):[[:space:]]*\(.*[^[:space:]]\)[[:space:]]*$$/\1=\2/p' $(ENV_FILE) > $@

$(RENDERED): kong.yaml $(ENV_VARS)
	$(DECK_RUN) file render --populate-env-vars kong.yaml -o $(RENDERED)

render: $(RENDERED)

# Kiểm cấu trúc và schema của plugin built-in.
validate: $(ENV_VARS)
	$(DECK_RUN) file validate kong.yaml

# Các quy tắc mà deck validate không biết: retries của Service write, taca-rbac trên
# nhánh admin, route catch-all, fault_tolerant, hai danh sách origin... (test doc §4.2).
lint: $(RENDERED)
	python3 ../../tools/config-lint/kong_config_linter.py $(RENDERED)

diff: $(ENV_VARS)
	$(DECK_RUN) gateway diff --kong-addr $(KONG_ADDR) kong.yaml

sync: $(ENV_VARS)
	$(DECK_RUN) gateway sync --kong-addr $(KONG_ADDR) kong.yaml

clean:
	rm -rf $(BUILD_DIR)
