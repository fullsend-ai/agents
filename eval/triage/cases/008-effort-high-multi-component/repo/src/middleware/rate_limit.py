"""Rate limiting middleware.

Tracks per-IP request timestamps in an in-memory dict and rejects
requests that exceed the configured threshold. The sliding window is
cleaned on each check — old entries outside the window are discarded.

Note: the cleanup only runs when a request arrives for that IP. IPs
that stop sending requests leave stale entries in RATE_LIMITS
indefinitely (same lazy-eviction pattern as the session store).
"""

import os
import time
import logging

logger = logging.getLogger(__name__)

RATE_LIMITS: dict[str, list[float]] = {}
WINDOW = int(os.environ.get("RATE_LIMIT_WINDOW", "60"))
MAX_REQUESTS = int(os.environ.get("RATE_LIMIT_MAX", "100"))


def check_rate_limit(client_ip: str) -> bool:
    """Return True if the request is within rate limits.

    Cleans up timestamps outside the current window before checking.
    """
    now = time.time()
    if client_ip not in RATE_LIMITS:
        RATE_LIMITS[client_ip] = []

    # Remove entries outside the window
    RATE_LIMITS[client_ip] = [
        t for t in RATE_LIMITS[client_ip] if now - t < WINDOW
    ]

    if len(RATE_LIMITS[client_ip]) >= MAX_REQUESTS:
        logger.warning(
            "Rate limit exceeded for ip=%s (%d requests in %ds window)",
            client_ip,
            len(RATE_LIMITS[client_ip]),
            WINDOW,
        )
        return False

    RATE_LIMITS[client_ip].append(now)
    return True


def rate_limit_middleware(handler):
    """Wrap a handler with rate limiting."""
    def wrapper(request):
        client_ip = request.headers.get("X-Forwarded-For", request.remote_addr)
        if not check_rate_limit(client_ip):
            return {"status": "error", "message": "rate limit exceeded"}, 429
        return handler(request)
    return wrapper
