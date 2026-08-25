"""Order repository backed by SQLite."""

import sqlite3


def get_order(conn: sqlite3.Connection, order_id: str) -> dict | None:
    """Fetch an order by id using a parameterized query."""
    cur = conn.execute("SELECT id, customer, total_cents FROM orders WHERE id = ?", (order_id,))
    row = cur.fetchone()
    if row is None:
        return None
    return {"id": row[0], "customer": row[1], "total_cents": row[2]}
