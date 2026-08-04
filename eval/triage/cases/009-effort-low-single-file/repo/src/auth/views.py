"""Authentication views — login, logout, registration."""

import logging

from .validators import validate_email, validate_password, validate_username

logger = logging.getLogger(__name__)


def login_handler(request):
    """Handle user login.

    Validates the email and password, then authenticates against the
    user store. Returns a session token on success.
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

    # ... authenticate against user store ...
    return {"status": "ok", "session_token": "stub-token"}


def logout_handler(request):
    """Handle user logout."""
    return {"status": "ok"}


def register_handler(request):
    """Handle user registration.

    Validates all input fields before creating the account.
    """
    email = request.params.get("email")
    password = request.params.get("password")
    username = request.params.get("username")

    if not email or not password or not username:
        return {
            "status": "error",
            "message": "email, password, and username required",
        }, 400

    try:
        validate_email(email)
        validate_password(password)
        validate_username(username)
    except (ValueError, TypeError) as exc:
        return {"status": "error", "message": str(exc)}, 400

    # ... create user in store ...
    logger.info("Registered user: email=%s username=%s", email, username)
    return {"status": "ok", "message": "account created"}, 201
