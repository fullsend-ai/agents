"""User database layer.

In-memory user store. In production this would be backed by a database,
but the interface is the same — the rest of the codebase depends only on
the functions exported here, not on the storage mechanism.
"""

import logging

logger = logging.getLogger(__name__)

USERS: dict[str, dict] = {
    "user-alice": {
        "id": "user-alice",
        "email": "alice@example.com",
        "name": "Alice Chen",
        "role": "admin",
        "active": True,
    },
    "user-bob": {
        "id": "user-bob",
        "email": "bob@example.com",
        "name": "Bob Martinez",
        "role": "member",
        "active": True,
    },
    "user-carol": {
        "id": "user-carol",
        "email": "carol@example.com",
        "name": "Carol Wu",
        "role": "member",
        "active": False,
    },
}


def get_all_users() -> list[dict]:
    """Return all users as a list of dicts."""
    return list(USERS.values())


def get_user_by_id(user_id: str) -> dict | None:
    """Return a user by ID, or None if not found."""
    return USERS.get(user_id)


def get_user_by_email(email: str) -> dict | None:
    """Return a user by email address, or None if not found."""
    for user in USERS.values():
        if user["email"] == email:
            return user
    return None


def update_user(user_id: str, data: dict) -> bool:
    """Update a user's fields. Returns True if the user exists.

    No validation on which fields are updated — the caller is responsible
    for checking permissions and field names.
    """
    user = USERS.get(user_id)
    if not user:
        return False
    user.update(data)
    logger.info("Updated user %s: fields=%s", user_id, list(data.keys()))
    return True


def delete_user(user_id: str) -> bool:
    """Delete a user by ID. Returns True if the user existed."""
    if user_id in USERS:
        del USERS[user_id]
        logger.info("Deleted user %s", user_id)
        return True
    return False
