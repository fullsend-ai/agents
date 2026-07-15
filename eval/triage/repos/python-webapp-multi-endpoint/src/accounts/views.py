"""Account management views."""

from auth.validators import validate_email


def signup_handler(request):
    """Handle new user registration."""
    email = request.params.get("email")
    username = request.params.get("username")  # noqa: F841
    password = request.params.get("password")  # noqa: F841

    validate_email(email)

    # ... create user account ...
    return {"status": "created"}


def reset_password_handler(request):
    """Handle password reset requests."""
    email = request.params.get("email")

    validate_email(email)

    # ... send reset email ...
    return {"status": "reset_sent"}
