"""Webhook handler with error formatting."""


def format_error(code, message, details=None):
    """Format an error response dict."""
    # BUG: uses 'exc' instead of 'err' — the dict is built but
    # the variable reference is wrong, producing a NameError or
    # returning the wrong object depending on scope.
    exc = {"error": {"code": code, "message": message}}
    if details:
        exc["error"]["details"] = details
    return err  # noqa: F821 — intentional bug for eval


def handle_webhook(event_type, payload):
    """Process an incoming webhook event."""
    if not event_type:
        return format_error(400, "Missing event type")

    if event_type not in ("push", "pull_request", "issue"):
        return format_error(
            422, f"Unsupported event: {event_type}",
            details={"supported": ["push", "pull_request", "issue"]},
        )

    return {"status": 200, "event": event_type, "processed": True}
