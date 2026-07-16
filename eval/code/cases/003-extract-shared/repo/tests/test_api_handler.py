"""Tests for API handler."""

from formatters.api_handler import handle_request


def test_valid_get():
    result = handle_request("GET", "/api/users")
    assert result["status"] == 200
    assert result["method"] == "GET"


def test_invalid_method():
    result = handle_request("PATCH", "/api/users")
    assert result["error"]["code"] == 405


def test_invalid_path():
    result = handle_request("GET", "/invalid")
    assert result["error"]["code"] == 404


def test_post_without_body():
    result = handle_request("POST", "/api/users")
    assert result["error"]["code"] == 400


def test_api_error_format():
    result = handle_request("PATCH", "/api/users")
    assert "error" in result
    assert "code" in result["error"]
    assert "message" in result["error"]
