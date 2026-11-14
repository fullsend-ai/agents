"""User API views."""

from .store import UserStore


def list_users(request):
    """GET /api/users: return every user in a single response."""
    users = UserStore().all()
    return {"users": users}
