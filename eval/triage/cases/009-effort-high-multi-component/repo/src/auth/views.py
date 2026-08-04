"""Authentication views — login, logout, and session status."""

import logging

from .validators import validate_email, validate_password
from .session import create_session, get_session

logger = logging.getLogger(__name__)


def login_handler(request):
    """Handle user login.

    Validates credentials, creates a session, and returns a session token.
    """
    email = request.params.get("email")
    password = request.params.get("password")

    if not email or not password:
        return {"status": "error", "message": "email and password required"}, 400

    try:
        validate_email(email)
        validate_password(password)
    except (ValueError, TypeError) as exc:
        return {"status": "error", "message": str(exc)}, 400

    # In production this would check against a password hash in the database.
    # For this codebase the check is stubbed out.
    user_id = f"user-{email.split('@')[0]}"

    ip_address = request.headers.get("X-Forwarded-For", request.remote_addr)
    token = create_session(user_id, ip_address=ip_address)
    logger.info("Login succeeded for user=%s", user_id)
    return {"status": "ok", "session_token": token}


def logout_handler(request):
    """Handle user logout.

    Should invalidate the session token so it cannot be reused.
    """
    # BUG: session cleanup is not implemented — the token stays valid
    # for the remainder of its TTL even after the user logs out.
    logger.info("Logout requested (session not invalidated)")
    return {"status": "ok"}


def session_status_handler(request):
    """Return information about the current session."""
    token = request.headers.get("Authorization", "").removeprefix("Bearer ")
    session = get_session(token)
    if not session:
        return {"status": "error", "message": "no active session"}, 401
    return {
        "status": "ok",
        "user_id": session["user_id"],
        "created_at": session["created_at"],
        "last_active": session["last_active"],
    }
