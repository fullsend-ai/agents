"""API request handler with error formatting."""


def format_error(code, message, details=None):
    """Format an error response dict."""
    err = {"error": {"code": code, "message": message}}
    if details:
        err["error"]["details"] = details
    return err


def handle_request(method, path, body=None):
    """Process an incoming API request."""
    if method not in ("GET", "POST", "PUT", "DELETE"):
        return format_error(405, f"Method {method} not allowed")

    if not path.startswith("/api/"):
        return format_error(404, f"Path {path} not found")

    if method == "POST" and body is None:
        return format_error(400, "POST requires a body")

    return {"status": 200, "path": path, "method": method}
