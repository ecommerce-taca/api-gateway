"""Kiểm chính linter: mỗi quy tắc phải bắt đúng cấu hình sai và bỏ qua cấu hình đúng.

Không có test này thì một quy tắc viết hỏng sẽ im lặng cho mọi config đi qua, và cả
lớp bảo vệ ở §4.2 trở thành trang trí.
"""

import pathlib
import unittest

import yaml

import kong_config_linter as linter

FIXTURES = pathlib.Path(__file__).parent / "fixtures"


def load_fixture(name):
    with open(FIXTURES / name, encoding="utf-8") as handle:
        return yaml.safe_load(handle)


def rules_triggered(config):
    return {violation.rule for violation in linter.lint(config)}


class WriteServiceRetriesTest(unittest.TestCase):
    def test_should_reject_a_write_service_that_retries(self):
        triggered = rules_triggered(load_fixture("write-service-retries.yaml"))

        self.assertIn("R01", triggered)

    def test_should_reject_a_websocket_service_that_retries(self):
        config = {"services": [{"name": "svc-message-ws", "retries": 1, "routes": []}]}

        self.assertIn("R01", rules_triggered(config))

    def test_should_accept_a_write_service_without_retries(self):
        config = {"services": [{"name": "svc-order-commerce-write", "retries": 0, "routes": []}]}

        self.assertNotIn("R01", rules_triggered(config))

    def test_should_reject_a_read_service_retrying_more_than_once(self):
        config = {"services": [{"name": "svc-search-read", "retries": 3, "routes": []}]}

        self.assertIn("R02", rules_triggered(config))


class AdminGateTest(unittest.TestCase):
    def test_should_reject_an_admin_route_without_rbac(self):
        triggered = rules_triggered(load_fixture("admin-route-without-rbac.yaml"))

        self.assertIn("R03", triggered)

    def test_should_accept_an_admin_route_carrying_rbac(self):
        config = {"services": [{"name": "svc-x-read", "retries": 1, "routes": [{
            "name": "rt-x", "paths": ["/api/v1/admin/fees"], "strip_path": False,
            "plugins": [{"name": "taca-rbac", "config": {"required_roles": ["ADMIN"]}},
                        {"name": "taca-jwt", "config": {}}],
        }]}]}

        self.assertNotIn("R03", rules_triggered(config))


class ProtectedRouteTest(unittest.TestCase):
    def test_should_reject_a_user_bucket_without_jwt(self):
        config = {"services": [{"name": "svc-x-read", "retries": 1, "routes": [{
            "name": "rt-x", "paths": ["/api/v1/users"], "strip_path": False,
            "plugins": [{"name": "rate-limiting", "config": {
                "limit_by": "header", "policy": "redis", "fault_tolerant": False}}],
        }]}]}

        self.assertIn("R04", rules_triggered(config))

    def test_should_reject_a_websocket_guard_without_jwt(self):
        config = {"services": [{"name": "svc-message-ws", "retries": 0, "routes": [{
            "name": "rt-message-ws", "paths": ["/ws/messages"], "strip_path": False,
            "plugins": [{"name": "taca-ws-guard", "config": {}}],
        }]}]}

        self.assertIn("R04", rules_triggered(config))

    def test_should_accept_a_public_route_without_jwt(self):
        config = {"services": [{"name": "svc-x-read", "retries": 1, "routes": [{
            "name": "rt-x", "paths": ["/api/v1/products"], "strip_path": False,
            "plugins": [{"name": "rate-limiting", "config": {
                "limit_by": "ip", "policy": "redis", "fault_tolerant": False}}],
        }]}]}

        self.assertNotIn("R04", rules_triggered(config))


class RouteSurfaceTest(unittest.TestCase):
    def test_should_reject_a_catch_all_route(self):
        self.assertIn("R05", rules_triggered(load_fixture("catch-all-route.yaml")))

    def test_should_reject_a_route_exposing_internal_paths(self):
        config = {"services": [{"name": "svc-x-read", "retries": 1, "routes": [{
            "name": "rt-x", "paths": ["/api/v1/inventory/internal/reserve"], "strip_path": False,
        }]}]}

        self.assertIn("R06", rules_triggered(config))

    def test_should_reject_a_second_websocket_path(self):
        config = {"services": [{"name": "svc-x-read", "retries": 1, "routes": [{
            "name": "rt-x", "paths": ["/ws/notifications"], "strip_path": False,
        }]}]}

        self.assertIn("R07", rules_triggered(config))

    def test_should_accept_the_single_allowed_websocket_path(self):
        config = {"services": [{"name": "svc-message-ws", "retries": 0, "routes": [{
            "name": "rt-message-ws", "paths": ["/ws/messages"], "strip_path": False,
            "plugins": [{"name": "taca-jwt", "config": {}}, {"name": "taca-ws-guard", "config": {}}],
        }]}]}

        self.assertNotIn("R07", rules_triggered(config))

    def test_should_reject_a_business_route_stripping_its_path(self):
        config = {"services": [{"name": "svc-x-read", "retries": 1, "routes": [{
            "name": "rt-x", "paths": ["/api/v1/products"], "strip_path": True,
        }]}]}

        self.assertIn("R10", rules_triggered(config))


class RateLimitTest(unittest.TestCase):
    def test_should_reject_a_local_policy(self):
        config = {"plugins": [{"name": "rate-limiting", "config": {
            "policy": "local", "fault_tolerant": False}}]}

        self.assertIn("R08", rules_triggered(config))

    def test_should_reject_the_fault_tolerant_default(self):
        config = {"plugins": [{"name": "rate-limiting", "config": {
            "policy": "redis", "fault_tolerant": True}}]}

        self.assertIn("R08", rules_triggered(config))

    def test_should_reject_a_missing_fault_tolerant_field(self):
        config = {"plugins": [{"name": "rate-limiting", "config": {"policy": "redis"}}]}

        self.assertIn("R08", rules_triggered(config))


class OriginListTest(unittest.TestCase):
    def test_should_reject_two_origin_lists_out_of_sync(self):
        self.assertIn("R09", rules_triggered(load_fixture("origin-lists-out-of-sync.yaml")))

    def test_should_accept_two_identical_origin_lists(self):
        config = {"plugins": [
            {"name": "cors", "config": {"origins": ["https://a.example", "https://b.example"]}},
            {"name": "taca-request-guard", "config": {
                "mode": "proxy", "allowed_origins": ["https://b.example", "https://a.example"]}},
        ]}

        self.assertNotIn("R09", rules_triggered(config))

    def test_should_reject_a_config_missing_the_guard_entirely(self):
        config = {"plugins": [{"name": "cors", "config": {"origins": ["https://a.example"]}}]}

        self.assertIn("R09", rules_triggered(config))


class WebsocketBodyPluginTest(unittest.TestCase):
    def test_should_reject_a_body_transformer_on_the_websocket_route(self):
        config = {"services": [{"name": "svc-message-ws", "retries": 0, "routes": [{
            "name": "rt-message-ws", "paths": ["/ws/messages"], "strip_path": False,
            "plugins": [{"name": "taca-jwt", "config": {}},
                        {"name": "response-transformer", "config": {}}],
        }]}]}

        self.assertIn("R11", rules_triggered(config))


class SecretTest(unittest.TestCase):
    def test_should_reject_a_redis_password_written_in_the_config(self):
        config = {"plugins": [{"name": "rate-limiting", "config": {
            "policy": "redis", "fault_tolerant": False,
            "redis": {"host": "redis", "password": "s3cr3t"}}}]}

        self.assertIn("R12", rules_triggered(config))

    def test_should_not_confuse_a_boolean_token_flag_with_a_secret(self):
        config = {"plugins": [{"name": "taca-jwt", "config": {"token_required": "true"}}]}

        self.assertNotIn("R12", rules_triggered(config))


if __name__ == "__main__":
    unittest.main()
