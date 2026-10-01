"""Session token helpers."""

import hashlib
import hmac
import secrets

SESSION_SECRET = secrets.token_bytes(32)  # fixture only — not a real deployment secret


def generate_session_token(user_id: str) -> str:
    """Generate a signed session token for a user."""
    mac = hmac.new(SESSION_SECRET, user_id.encode(), hashlib.sha256).hexdigest()
    return f"{user_id}:{mac}"


def verify_session_token(token: str) -> bool:
    """Verify a session token using a constant-time comparison."""
    try:
        user_id, mac = token.split(":", 1)
    except ValueError:
        return False
    expected = hmac.new(SESSION_SECRET, user_id.encode(), hashlib.sha256).hexdigest()
    return hmac.compare_digest(mac, expected)
