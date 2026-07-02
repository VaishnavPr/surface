import sqlite3


def create_tables(conn: sqlite3.Connection) -> None:
    conn.execute("""
        CREATE TABLE IF NOT EXISTS config (
            key        TEXT PRIMARY KEY,
            value      TEXT NOT NULL,
            updated_at REAL NOT NULL DEFAULT (unixepoch())
        )
    """)


def get(conn: sqlite3.Connection, key: str, default: str | None = None) -> str | None:
    row = conn.execute("SELECT value FROM config WHERE key = ?", (key,)).fetchone()
    return row["value"] if row else default


def set(conn: sqlite3.Connection, key: str, value: str) -> None:
    conn.execute("""
        INSERT INTO config (key, value, updated_at)
        VALUES (?, ?, unixepoch())
        ON CONFLICT(key) DO UPDATE SET value = excluded.value, updated_at = unixepoch()
    """, (key, value))


def delete(conn: sqlite3.Connection, key: str) -> None:
    conn.execute("DELETE FROM config WHERE key = ?", (key,))


def all_entries(conn: sqlite3.Connection) -> list[sqlite3.Row]:
    return conn.execute("SELECT key, value, updated_at FROM config ORDER BY key").fetchall()
