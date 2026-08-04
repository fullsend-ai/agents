"""Input validators for authentication.

Centralizes validation logic for email, password, and username fields.
All validators raise ValueError on invalid input.
"""

import re

EMAIL_PATTERN = r"^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$"
PASSWORD_MIN_LENGTH = 8
PASSWORD_MAX_LENGTH = 128
USERNAME_PATTERN = r"^[a-zA-Z][a-zA-Z0-9_-]{2,29}$"


def validate_email(email: str) -> None:
    """Validate an email address format.

    Raises ValueError if the email does not match the expected pattern.
    Raises TypeError if the input is not a string.
    """
    if not isinstance(email, str):
        raise TypeError("email must be a string")
    if not re.match(EMAIL_PATTERN, email):
        raise ValueError("invalid email format")


def validate_password(password: str) -> None:
    """Validate password meets minimum requirements.

    Checks length only — no complexity requirements (those belong in
    a password policy layer, not a format validator).
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


def validate_username(username: str) -> None:
    """Validate a username.

    Usernames must start with a letter, contain only letters, digits,
    hyphens, and underscores, and be 3-30 characters long.
    """
    if not isinstance(username, str):
        raise TypeError("username must be a string")
    if not re.match(USERNAME_PATTERN, username):
        raise ValueError(
            "username must start with a letter, be 3-30 characters, "
            "and contain only letters, digits, hyphens, and underscores"
        )
