"""Session management for authenticated users.

Sessions are stored in-memory in a global dict keyed by token. Each session
tracks the owning user, creation time, and last activity timestamp. Sessions
expire after SESSION_TTL seconds from creation.

Expiration is checked lazily on lookup — there is no background reaper.
"""

import os
import time
import hashlib
import logging

logger = logging.getLogger(__name__)

SESSIONS: dict[str, dict] = {}
SESSION_TTL = int(os.environ.get("SESSION_TTL", "3600"))


def create_session(user_id: str, ip_address: str = "unknown") -> str:
    """Create a new session and return the session token.

    The token is a SHA-256 hash of the user ID, current timestamp, and a
    monotonic counter to avoid collisions when two requests arrive in the
    same clock tick.
    """
    raw = f"{user_id}:{time.time()}:{len(SESSIONS)}".encode()
    token = hashlib.sha256(raw).hexdigest()
    SESSIONS[token] = {
        "user_id": user_id,
        "created_at": time.time(),
        "last_active": time.time(),
        "ip_address": ip_address,
    }
    logger.info("Session created for user=%s from ip=%s", user_id, ip_address)
    return token


def get_session(token: str) -> dict | None:
    """Look up a session by token.

    Returns None if the session does not exist or has expired. Expired
    sessions are removed from the store on access (lazy eviction).
    """
    session = SESSIONS.get(token)
    if not session:
        return None
    if time.time() - session["created_at"] > SESSION_TTL:
        logger.info(
            "Session expired for user=%s (age=%ds, ttl=%ds)",
            session["user_id"],
            int(time.time() - session["created_at"]),
            SESSION_TTL,
        )
        del SESSIONS[token]
        return None
    return session


def refresh_session(token: str) -> None:
    """Update the last_active timestamp for a session.

    Called by the auth middleware on every authenticated request so the
    session metadata reflects actual usage.
    """
    session = SESSIONS.get(token)
    if session:
        session["last_active"] = time.time()


def active_session_count() -> int:
    """Return the number of sessions currently in the store.

    Note: this includes expired sessions that have not been lazily evicted.
    """
    return len(SESSIONS)
