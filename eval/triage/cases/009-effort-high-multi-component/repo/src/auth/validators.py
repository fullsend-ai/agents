"""Input validators for authentication.

Centralizes validation logic so views don't duplicate regex patterns
or length checks.
"""

import re

EMAIL_PATTERN = r"^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$"
PASSWORD_MIN_LENGTH = 8
PASSWORD_MAX_LENGTH = 128


def validate_email(email: str) -> None:
    """Validate an email address format.

    Raises ValueError if the email does not match the expected pattern.
    """
    if not isinstance(email, str):
        raise TypeError("email must be a string")
    if not re.match(EMAIL_PATTERN, email):
        raise ValueError("invalid email format")


def validate_password(password: str) -> None:
    """Validate password meets minimum requirements.

    Raises ValueError if the password is too short or too long.
    """
    if not isinstance(password, str):
        raise TypeError("password must be a string")
    if len(password) < PASSWORD_MIN_LENGTH:
        raise ValueError(
            f"password must be at least {PASSWORD_MIN_LENGTH} characters"
        )
    if len(password) > PASSWORD_MAX_LENGTH:
        raise ValueError(
            f"password must be at most {PASSWORD_MAX_LENGTH} characters"
        )
