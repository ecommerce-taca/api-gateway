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


def iter_routes(config: dict[str, Any]) -> Iterator[tuple[dict[str, Any], dict[str, Any]]]:
    for service in config.get("services") or []:
        for route in service.get("routes") or []:
            yield service, route


def route_paths(route: dict[str, Any]) -> list[str]:
    return route.get("paths") or []


def is_business_route(route: dict[str, Any]) -> bool:
    return any(path.lstrip("~").startswith((API_PREFIX, "/ws/")) for path in route_paths(route))


def check_write_services_never_retry(config) -> list[Violation]:
    violations = []
    for service in config.get("services") or []:
        name = service["name"]
        expects_zero = name.endswith("-write") or name == "svc-message-ws"
        if expects_zero and service.get("retries") != 0:
            violations.append(Violation(
                "R01", name,
                f"retries={service.get('retries')} — mutation và handshake WebSocket "
                "không bao giờ được retry"))
    return violations


def check_read_services_retry_at_most_once(config) -> list[Violation]:
    violations = []
    for service in config.get("services") or []:
        name = service["name"]
        if name.endswith("-read") and (service.get("retries") or 0) > 1:
            violations.append(Violation(
                "R02", name, f"retries={service.get('retries')} — policy cho phép tối đa 1 lần"))
    return violations


def check_admin_routes_are_gated(config) -> list[Violation]:
    violations = []
    for _, route in iter_routes(config):
        admin_paths = [path for path in route_paths(route) if f"{API_PREFIX}/admin" in path]
        if admin_paths and "taca-rbac" not in plugin_map(route):
            violations.append(Violation(
                "R03", route["name"], "route /admin/** thiếu taca-rbac — mất coarse gate admin"))
    return violations


def check_protected_routes_have_jwt(config) -> list[Violation]:
    violations = []
    for _, route in iter_routes(config):
        plugins = plugin_map(route)
        rate_limit = plugins.get("rate-limiting") or {}
        needs_actor = (
            "taca-rbac" in plugins
            or "taca-ws-guard" in plugins
            or rate_limit.get("limit_by") == "header"
        )
        if needs_actor and "taca-jwt" not in plugins:
            violations.append(Violation(
                "R04", route["name"],
                "route cần danh tính (rbac/ws-guard/bucket theo user) nhưng thiếu taca-jwt"))
    return violations


def check_no_catch_all_route(config) -> list[Violation]:
    violations = []
    for _, route in iter_routes(config):
        for path in route_paths(route):
            if path in CATCH_ALL_PATHS:
                violations.append(Violation(
                    "R05", route["name"],
                    f"path '{path}' là catch-all — nó nuốt mọi request và vô hiệu hoá "
                    "gate theo từng nhánh"))
    return violations


def check_no_internal_route(config) -> list[Violation]:
    violations = []
    for _, route in iter_routes(config):
        for path in route_paths(route):
            if "/internal" in path:
                violations.append(Violation(
                    "R06", route["name"], f"path '{path}' expose nhánh /internal/**"))
    return violations


def check_single_websocket_path(config) -> list[Violation]:
    violations = []
    for _, route in iter_routes(config):
        for path in route_paths(route):
            if path.lstrip("~").startswith("/ws") and path != WEBSOCKET_PATH:
                violations.append(Violation(
                    "R07", route["name"],
                    f"path '{path}' — chỉ {WEBSOCKET_PATH} được phép upgrade"))
    return violations


def _iter_plugin_instances(config) -> Iterator[tuple[str, str, dict[str, Any]]]:
    for plugin in config.get("plugins") or []:
        yield "global", plugin["name"], plugin.get("config") or {}
    for service in config.get("services") or []:
        for plugin in service.get("plugins") or []:
            yield service["name"], plugin["name"], plugin.get("config") or {}
        for route in service.get("routes") or []:
            for plugin in route.get("plugins") or []:
                yield route["name"], plugin["name"], plugin.get("config") or {}


def check_rate_limiting_fails_closed(config) -> list[Violation]:
    violations = []
    for where, name, plugin_config in _iter_plugin_instances(config):
        if name != "rate-limiting":
            continue
        if plugin_config.get("policy") != "redis":
            violations.append(Violation(
                "R08", where,
                f"policy={plugin_config.get('policy')} — local đếm riêng từng node nên "
                "tổng limit sai gấp N lần số node"))
        if plugin_config.get("fault_tolerant") is not False:
            violations.append(Violation(
                "R08", where,
                "fault_tolerant khác false — mặc định của Kong cho request đi qua khi "
                "Redis lỗi, vi phạm policy fail-closed"))
    return violations


def check_origin_lists_match(config) -> list[Violation]:
    cors_origins, guard_origins = None, None
    for _, name, plugin_config in _iter_plugin_instances(config):
        if name == "cors":
            cors_origins = plugin_config.get("origins")
        elif name == "taca-request-guard" and plugin_config.get("mode", "proxy") == "proxy":
            guard_origins = plugin_config.get("allowed_origins")

    if cors_origins is None or guard_origins is None:
        return [Violation("R09", "global", "thiếu cors hoặc taca-request-guard chế độ proxy")]

    if sorted(cors_origins) != sorted(guard_origins):
        return [Violation(
            "R09", "global",
            f"cors.origins={cors_origins} lệch taca-request-guard.allowed_origins="
            f"{guard_origins} — hai danh sách phải sinh từ một nguồn")]

    return []


def check_business_routes_keep_path(config) -> list[Violation]:
    violations = []
    for _, route in iter_routes(config):
        if is_business_route(route) and route.get("strip_path") is not False:
            violations.append(Violation(
                "R10", route["name"],
                "strip_path phải là false — service đích nhận nguyên /api/v1/..."))
    return violations


def check_websocket_route_has_no_body_plugin(config) -> list[Violation]:
    violations = []
    for _, route in iter_routes(config):
        if WEBSOCKET_PATH not in route_paths(route):
            continue
        for name in plugin_map(route):
            if name in BODY_TOUCHING_PLUGINS:
                violations.append(Violation(
                    "R11", route["name"],
                    f"plugin '{name}' đọc/ghi body — làm hỏng frame sau khi upgrade"))
    return violations


def _walk_config(value: Any, path: str) -> Iterator[tuple[str, str, Any]]:
    if isinstance(value, dict):
        for key, item in value.items():
            yield from _walk_config(item, f"{path}.{key}" if path else str(key))
    elif isinstance(value, list):
        for index, item in enumerate(value):
            yield from _walk_config(item, f"{path}[{index}]")
    else:
        yield path, path.split(".")[-1], value


def check_no_hardcoded_secret(config) -> list[Violation]:
    violations = []
    for where, key, value in _walk_config(config, ""):
        if key in SECRET_KEY_ALLOWLIST or not isinstance(value, str) or not value:
            continue
        if SECRET_KEY_PATTERN.search(key):
            violations.append(Violation(
                "R12", where, "giá trị bí mật nằm trong config — phải đến từ env/Vault"))
    return violations


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
    violations = []
    for rule in RULES:
        violations.extend(rule(config))

    return violations


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
