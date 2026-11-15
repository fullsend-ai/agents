"""Database connection."""

import os
import sqlite3


def connect():
    conn = sqlite3.connect(os.environ.get("DATABASE_PATH", "app.db"))
    conn.row_factory = sqlite3.Row
    return conn
