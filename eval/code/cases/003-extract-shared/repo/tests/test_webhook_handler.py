"""Tests for webhook handler."""

from formatters.webhook_handler import handle_webhook


def test_valid_push():
    result = handle_webhook("push", {"ref": "refs/heads/main"})
    assert result["status"] == 200
    assert result["event"] == "push"


def test_missing_event():
    result = handle_webhook("", {})
    assert result["error"]["code"] == 400


def test_unsupported_event():
    result = handle_webhook("deployment", {})
    assert result["error"]["code"] == 422
    assert "supported" in result["error"]["details"]


def test_webhook_error_format():
    """This test fails because webhook_handler.format_error has a bug."""
    result = handle_webhook("deployment", {})
    assert "error" in result
    assert "code" in result["error"]
    assert "message" in result["error"]
    assert result["error"]["message"] == "Unsupported event: deployment"
