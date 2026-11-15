"""Read access to the users table."""

from ..db import connect


class UserStore:
    def __init__(self, conn=None):
        self._conn = conn or connect()

    def all(self):
        """Return every user, ordered by id."""
        rows = self._conn.execute(
            "SELECT id, email, name, created_at FROM users ORDER BY id"
        ).fetchall()
        return [dict(row) for row in rows]
