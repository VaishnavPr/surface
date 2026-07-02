import sqlite3


def create_tables(conn: sqlite3.Connection) -> None:
    conn.execute("""
        CREATE TABLE IF NOT EXISTS jira_tickets_cache (
            id         INTEGER PRIMARY KEY,
            project    TEXT    NOT NULL,
            key        TEXT    NOT NULL,
            summary    TEXT    NOT NULL,
            status     TEXT    NOT NULL,
            assignee   TEXT,
            fetched_at REAL    NOT NULL,
            UNIQUE(key)
        )
    """)


TICKETS_TTL = 120  # 2 minutes


def tickets_cache_fresh(conn: sqlite3.Connection, project: str) -> bool:
    row = conn.execute("""
        SELECT MIN(fetched_at) as oldest FROM jira_tickets_cache WHERE project = ?
    """, (project,)).fetchone()
    if not row or not row["oldest"]:
        return False
    import time
    return (time.time() - row["oldest"]) < TICKETS_TTL


def tickets_cache_get(conn: sqlite3.Connection, project: str) -> list[sqlite3.Row]:
    return conn.execute("""
        SELECT key, summary, status, assignee FROM jira_tickets_cache
        WHERE project = ? ORDER BY key
    """, (project,)).fetchall()


def tickets_cache_set(conn: sqlite3.Connection, project: str, tickets: list[dict]) -> None:
    import time
    now = time.time()
    conn.execute("DELETE FROM jira_tickets_cache WHERE project = ?", (project,))
    conn.executemany("""
        INSERT INTO jira_tickets_cache (project, key, summary, status, assignee, fetched_at)
        VALUES (?, ?, ?, ?, ?, ?)
    """, [(project, t["key"], t["summary"], t["status"], t.get("assignee"), now) for t in tickets])


def tickets_cache_clear(conn: sqlite3.Connection, project: str | None = None) -> None:
    if project:
        conn.execute("DELETE FROM jira_tickets_cache WHERE project = ?", (project,))
    else:
        conn.execute("DELETE FROM jira_tickets_cache")
