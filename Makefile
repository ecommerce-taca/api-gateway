# Điểm vào cho việc chạy và kiểm API Gateway ở máy local.
# Mọi công cụ (Kong, decK, busted, linter) chạy trong container: máy dev không cần cài gì
# ngoài Docker.

ENV ?= dev
KONG_VERSION ?= 3.9.0
TEST_IMAGE ?= taca-gateway-test:local
LINT_IMAGE ?= taca-config-lint:local
JWKS_DIR := mocks/jwks

.PHONY: test lint render dev-keys up down logs clean

# Unit test của 5 plugin Lua (test doc §4.1).
test:
	docker build --target test -t $(TEST_IMAGE) .
	docker run --rm $(TEST_IMAGE)

# Lint cấu hình declarative + test của chính linter (test doc §4.2).
lint:
	$(MAKE) -C kong/deck lint ENV=$(ENV)
	docker build -q -t $(LINT_IMAGE) tools/config-lint > /dev/null
	docker run --rm -v $(CURDIR):/work -w /work/tools/config-lint \
		--entrypoint python3 $(LINT_IMAGE) -m unittest discover -p "test_*.py"

render:
	$(MAKE) -C kong/deck render ENV=$(ENV)

# Khoá dev cho JWKS mock. Sinh tại chỗ, không commit (xem .gitignore).
$(JWKS_DIR)/jwks.json:
	@mkdir -p $(JWKS_DIR)
	docker run --rm --user root -v $(CURDIR)/$(JWKS_DIR):/out -v $(CURDIR)/tools/dev-keys:/scripts \
		kong:$(KONG_VERSION) resty /scripts/generate_dev_jwks.lua
	@docker run --rm --user root -v $(CURDIR)/$(JWKS_DIR):/out alpine:3.21 \
		sh -c 'chown -R $(shell id -u):$(shell id -g) /out'

dev-keys: $(JWKS_DIR)/jwks.json

# Ký một token dev để thử tay route protected:
#   make token TOKEN_ROLES=SELLER
token: dev-keys
	@docker run --rm --user root -e TOKEN_ROLES -e TOKEN_SUB -e TOKEN_TTL \
		-v $(CURDIR)/$(JWKS_DIR):/out -v $(CURDIR)/tools/dev-keys:/scripts \
		kong:$(KONG_VERSION) resty /scripts/mint_dev_token.lua

up: render dev-keys
	docker compose up -d --build

down:
	docker compose down

logs:
	docker compose logs -f kong-node-1

clean: down
	$(MAKE) -C kong/deck clean
	rm -rf $(JWKS_DIR)
