"""Authentication middleware.

Wraps request handlers to enforce that a valid session token is present
in the Authorization header. Refreshes the session's last_active timestamp
on each authenticated request.
"""

import logging

from ..auth.session import get_session, refresh_session

logger = logging.getLogger(__name__)


def require_auth(handler):
    """Middleware decorator that requires a valid session token.

    Expects the token in an Authorization: Bearer <token> header.
    Returns 401 if the token is missing, invalid, or expired.
    """
    def wrapper(request, *args, **kwargs):
        auth_header = request.headers.get("Authorization", "")
        if not auth_header.startswith("Bearer "):
            return {"status": "error", "message": "missing auth token"}, 401

        token = auth_header.removeprefix("Bearer ")
        session = get_session(token)
        if not session:
            logger.warning("Auth failed: invalid or expired token")
            return {"status": "error", "message": "unauthorized"}, 401

        refresh_session(token)
        request.user_id = session["user_id"]
        logger.debug("Authenticated user=%s", session["user_id"])
        return handler(request, *args, **kwargs)
    return wrapper
