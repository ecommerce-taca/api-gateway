"""Lint declarative config của Kong theo test doc §4.2.

Đây là nơi thay phần lớn RouteMatcher/RoutePolicy/RetryPolicy của bản NestJS: sau khi
chuyển sang Kong, phần lớn hành vi nằm ở cấu hình chứ không ở code, nên cấu hình phải
được kiểm bằng máy trước khi sync.

Chạy trên file đã render (đã thay biến môi trường) để so được cả những giá trị chỉ
xuất hiện sau khi render, ví dụ hai danh sách origin.
"""

from __future__ import annotations

import re
import sys
from dataclasses import dataclass
from typing import Any, Iterator

import yaml

API_PREFIX = "/api/v1"
WEBSOCKET_PATH = "/ws/messages"
CATCH_ALL_PATHS = {"/", "/api", "/api/v1", "~/.*", "~/"}
# Plugin đọc hoặc ghi body: gắn lên route WebSocket sẽ làm hỏng frame sau upgrade.
BODY_TOUCHING_PLUGINS = {
    "request-transformer",
    "request-transformer-advanced",
    "response-transformer",
    "response-transformer-advanced",
    "request-validator",
}
SECRET_KEY_PATTERN = re.compile(r"(password|secret|private_key|api_key|apikey|token)$")
SECRET_KEY_ALLOWLIST = {"token_required", "accept_query_token"}


@dataclass(frozen=True)
class Violation:
    rule: str
    where: str
    detail: str

    def __str__(self) -> str:
        return f"[{self.rule}] {self.where}: {self.detail}"


def plugin_map(entity: dict[str, Any]) -> dict[str, dict[str, Any]]:
    return {plugin["name"]: plugin.get("config") or {} for plugin in entity.get("plugins") or []}


def iter_services(config) -> Iterator[dict[str, Any]]:
    return iter(config.get("services") or [])


def iter_routes(config) -> Iterator[dict[str, Any]]:
    for service in iter_services(config):
        yield from service.get("routes") or []


def iter_route_paths(config) -> Iterator[tuple[dict[str, Any], str]]:
    for route in iter_routes(config):
        for path in route.get("paths") or []:
            yield route, path


# Mọi instance plugin, dù khai báo ở global, service hay route.
def iter_plugins(config) -> Iterator[tuple[str, str, dict[str, Any]]]:
    for plugin in config.get("plugins") or []:
        yield "global", plugin["name"], plugin.get("config") or {}
    for service in iter_services(config):
        for plugin in service.get("plugins") or []:
            yield service["name"], plugin["name"], plugin.get("config") or {}
        for route in service.get("routes") or []:
            for plugin in route.get("plugins") or []:
                yield route["name"], plugin["name"], plugin.get("config") or {}


def check_write_services_never_retry(config) -> Iterator[Violation]:
    for service in iter_services(config):
        name = service["name"]
        if (name.endswith("-write") or name == "svc-message-ws") and service.get("retries") != 0:
            yield Violation(
                "R01", name,
                f"retries={service.get('retries')} — mutation và handshake WebSocket "
                "không bao giờ được retry")


def check_read_services_retry_at_most_once(config) -> Iterator[Violation]:
    for service in iter_services(config):
        name = service["name"]
        if name.endswith("-read") and (service.get("retries") or 0) > 1:
            yield Violation(
                "R02", name, f"retries={service.get('retries')} — policy cho phép tối đa 1 lần")


def check_admin_routes_are_gated(config) -> Iterator[Violation]:
    for route in iter_routes(config):
        admin = any(f"{API_PREFIX}/admin" in path for path in route.get("paths") or [])
        if admin and "taca-rbac" not in plugin_map(route):
            yield Violation(
                "R03", route["name"], "route /admin/** thiếu taca-rbac — mất coarse gate admin")


def check_protected_routes_have_jwt(config) -> Iterator[Violation]:
    for route in iter_routes(config):
        plugins = plugin_map(route)
        needs_actor = (
            "taca-rbac" in plugins
            or "taca-ws-guard" in plugins
            or (plugins.get("rate-limiting") or {}).get("limit_by") == "header"
        )
        if needs_actor and "taca-jwt" not in plugins:
            yield Violation(
                "R04", route["name"],
                "route cần danh tính (rbac/ws-guard/bucket theo user) nhưng thiếu taca-jwt")


def check_no_catch_all_route(config) -> Iterator[Violation]:
    for route, path in iter_route_paths(config):
        if path in CATCH_ALL_PATHS:
            yield Violation(
                "R05", route["name"],
                f"path '{path}' là catch-all — nó nuốt mọi request và vô hiệu hoá "
                "gate theo từng nhánh")


def check_no_internal_route(config) -> Iterator[Violation]:
    for route, path in iter_route_paths(config):
        if "/internal" in path:
            yield Violation("R06", route["name"], f"path '{path}' expose nhánh /internal/**")


def check_single_websocket_path(config) -> Iterator[Violation]:
    for route, path in iter_route_paths(config):
        if path.lstrip("~").startswith("/ws") and path != WEBSOCKET_PATH:
            yield Violation(
                "R07", route["name"], f"path '{path}' — chỉ {WEBSOCKET_PATH} được phép upgrade")


def check_rate_limiting_fails_closed(config) -> Iterator[Violation]:
    for where, name, plugin_config in iter_plugins(config):
        if name != "rate-limiting":
            continue
        if plugin_config.get("policy") != "redis":
            yield Violation(
                "R08", where,
                f"policy={plugin_config.get('policy')} — local đếm riêng từng node nên "
                "tổng limit sai gấp N lần số node")
        if plugin_config.get("fault_tolerant") is not False:
            yield Violation(
                "R08", where,
                "fault_tolerant khác false — mặc định của Kong cho request đi qua khi "
                "Redis lỗi, vi phạm policy fail-closed")


def check_origin_lists_match(config) -> Iterator[Violation]:
    cors_origins, guard_origins = None, None
    for _, name, plugin_config in iter_plugins(config):
        if name == "cors":
            cors_origins = plugin_config.get("origins")
        elif name == "taca-request-guard" and plugin_config.get("mode", "proxy") == "proxy":
            guard_origins = plugin_config.get("allowed_origins")

    if cors_origins is None or guard_origins is None:
        yield Violation("R09", "global", "thiếu cors hoặc taca-request-guard chế độ proxy")
    elif sorted(cors_origins) != sorted(guard_origins):
        yield Violation(
            "R09", "global",
            f"cors.origins={cors_origins} lệch taca-request-guard.allowed_origins="
            f"{guard_origins} — hai danh sách phải sinh từ một nguồn")


def check_business_routes_keep_path(config) -> Iterator[Violation]:
    for route in iter_routes(config):
        business = any(path.lstrip("~").startswith((API_PREFIX, "/ws/"))
                       for path in route.get("paths") or [])
        if business and route.get("strip_path") is not False:
            yield Violation(
                "R10", route["name"],
                "strip_path phải là false — service đích nhận nguyên /api/v1/...")


def check_websocket_route_has_no_body_plugin(config) -> Iterator[Violation]:
    for route in iter_routes(config):
        if WEBSOCKET_PATH not in (route.get("paths") or []):
            continue
        for name in plugin_map(route):
            if name in BODY_TOUCHING_PLUGINS:
                yield Violation(
                    "R11", route["name"],
                    f"plugin '{name}' đọc/ghi body — làm hỏng frame sau khi upgrade")


def _walk_config(value: Any, path: str) -> Iterator[tuple[str, str, Any]]:
    if isinstance(value, dict):
        for key, item in value.items():
            yield from _walk_config(item, f"{path}.{key}" if path else str(key))
    elif isinstance(value, list):
        for index, item in enumerate(value):
            yield from _walk_config(item, f"{path}[{index}]")
    else:
        yield path, path.split(".")[-1], value


def check_no_hardcoded_secret(config) -> Iterator[Violation]:
    for where, key, value in _walk_config(config, ""):
        if key in SECRET_KEY_ALLOWLIST or not isinstance(value, str) or not value:
            continue
        if SECRET_KEY_PATTERN.search(key):
            yield Violation(
                "R12", where, "giá trị bí mật nằm trong config — phải đến từ env/Vault")


RULES = (
    check_write_services_never_retry,
    check_read_services_retry_at_most_once,
    check_admin_routes_are_gated,
    check_protected_routes_have_jwt,
    check_no_catch_all_route,
    check_no_internal_route,
    check_single_websocket_path,
    check_rate_limiting_fails_closed,
    check_origin_lists_match,
    check_business_routes_keep_path,
    check_websocket_route_has_no_body_plugin,
    check_no_hardcoded_secret,
)


def lint(config: dict[str, Any]) -> list[Violation]:
    return [violation for rule in RULES for violation in rule(config)]


def main(argv: list[str]) -> int:
    if len(argv) != 2:
        print("usage: kong_config_linter.py <rendered-kong.yaml>", file=sys.stderr)
        return 2

    with open(argv[1], encoding="utf-8") as handle:
        config = yaml.safe_load(handle)

    violations = lint(config)
    for violation in violations:
        print(violation, file=sys.stderr)

    if violations:
        print(f"\n{len(violations)} vi phạm cấu hình", file=sys.stderr)
        return 1

    print(f"config lint: {len(RULES)} quy tắc, không có vi phạm")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
