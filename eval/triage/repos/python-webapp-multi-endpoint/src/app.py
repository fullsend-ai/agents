"""Application entry point and route registration."""

from auth.views import login_handler
from accounts.views import signup_handler, reset_password_handler

ROUTES = {
    "POST /login": login_handler,
    "POST /signup": signup_handler,
    "POST /reset-password": reset_password_handler,
}


def dispatch(method, path, request):
    """Route a request to the appropriate handler."""
    key = f"{method} {path}"
    handler = ROUTES.get(key)
    if handler is None:
        return {"error": "not found"}, 404
    return handler(request), 200
