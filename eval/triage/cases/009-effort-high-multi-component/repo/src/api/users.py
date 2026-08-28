"""User management API endpoints.

All endpoints require authentication via the require_auth middleware.
Rate limiting is applied at the router level (see main.py).
"""

import logging

from ..middleware.auth import require_auth
from ..db.users import get_all_users, get_user_by_id, update_user, delete_user

logger = logging.getLogger(__name__)


@require_auth
def list_users(request):
    """Return all users.

    No pagination — returns the full list. This is fine for small
    deployments but will need cursor-based pagination eventually.
    """
    users = get_all_users()
    return {"users": users, "count": len(users)}


@require_auth
def get_user(request, user_id):
    """Return a single user by ID."""
    user = get_user_by_id(user_id)
    if not user:
        return {"status": "error", "message": "user not found"}, 404
    return {"user": user}


@require_auth
def update_user_handler(request, user_id):
    """Update user fields.

    Accepts a JSON body with the fields to update. Does not validate
    which fields are being changed — the caller can overwrite anything
    including the role.
    """
    data = request.json
    if not data:
        return {"status": "error", "message": "request body required"}, 400

    existing = get_user_by_id(user_id)
    if not existing:
        return {"status": "error", "message": "user not found"}, 404

    update_user(user_id, data)
    logger.info("User %s updated by %s", user_id, request.user_id)
    return {"status": "ok"}


@require_auth
def delete_user_handler(request, user_id):
    """Delete a user by ID."""
    existing = get_user_by_id(user_id)
    if not existing:
        return {"status": "error", "message": "user not found"}, 404

    delete_user(user_id)
    logger.info("User %s deleted by %s", user_id, request.user_id)
    return {"status": "ok"}
