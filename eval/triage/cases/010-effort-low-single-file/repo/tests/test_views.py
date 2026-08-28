"""Tests for authentication views.

Uses a minimal request stub to test handler logic without a real
HTTP server.
"""

from src.auth.views import login_handler, register_handler


class StubRequest:
    """Minimal request object for testing."""

    def __init__(self, params=None, headers=None):
        self.params = params or {}
        self.headers = headers or {}
        self.remote_addr = "127.0.0.1"
        self.json = None

    def get(self, key, default=None):
        return self.params.get(key, default)


class TestLoginHandler:
    def test_missing_email(self):
        req = StubRequest(params={"password": "goodpassword1"})
        result, status = login_handler(req)
        assert status == 400
        assert "required" in result["message"]

    def test_missing_password(self):
        req = StubRequest(params={"email": "user@example.com"})
        result, status = login_handler(req)
        assert status == 400
        assert "required" in result["message"]

    def test_invalid_email(self):
        req = StubRequest(params={"email": "bad", "password": "goodpassword1"})
        result, status = login_handler(req)
        assert status == 400
        assert "email" in result["message"]

    def test_short_password(self):
        req = StubRequest(
            params={"email": "user@example.com", "password": "short"}
        )
        result, status = login_handler(req)
        assert status == 400
        assert "at least" in result["message"]

    def test_valid_login(self):
        req = StubRequest(
            params={"email": "user@example.com", "password": "goodpassword1"},
            headers={},
        )
        result = login_handler(req)
        # login_handler returns a dict (no status tuple) on success
        assert result["status"] == "ok"


class TestRegisterHandler:
    def test_missing_fields(self):
        req = StubRequest(params={"email": "user@example.com"})
        result, status = register_handler(req)
        assert status == 400

    def test_invalid_username(self):
        req = StubRequest(
            params={
                "email": "user@example.com",
                "password": "goodpassword1",
                "username": "123bad",
            }
        )
        result, status = register_handler(req)
        assert status == 400
        assert "must start" in result["message"]

    def test_valid_registration(self):
        req = StubRequest(
            params={
                "email": "new@example.com",
                "password": "securepassword",
                "username": "newuser",
            }
        )
        result, status = register_handler(req)
        assert status == 201
        assert result["status"] == "ok"
