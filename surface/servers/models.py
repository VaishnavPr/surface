import sqlite3


def create_tables(conn: sqlite3.Connection) -> None:
    conn.execute("""
        CREATE TABLE IF NOT EXISTS servers (
            name       TEXT PRIMARY KEY,
            host       TEXT NOT NULL,
            user       TEXT NOT NULL DEFAULT 'root',
            port       INTEGER NOT NULL DEFAULT 22,
            ssh_key    TEXT,
            profile    TEXT NOT NULL DEFAULT 'work',
            notes      TEXT
        )
    """)


def seed_defaults(conn: sqlite3.Connection) -> None:
    """Pre-seed known servers. Skips existing rows."""
    defaults = [
        # name         host                    user      port  ssh_key                                    profile
        ("thin-160",   "160.thin.env",         "root",   222,  None,                                      "work"),
        ("thin-179",   "179.thin.env",         "root",   222,  None,                                      "work"),
        ("thin-71",    "71.thin.env",           "root",   222,  None,                                      "work"),
        ("ecom",       "161.118.181.27",        "ubuntu", 22,   "~/.ssh/personal/id_eCom.key",             "personal"),
        ("ra",         "140.245.10.233",        "ubuntu", 22,   "~/.ssh/personal/ra_id.key",               "personal"),
    ]
    conn.executemany("""
        INSERT OR IGNORE INTO servers (name, host, user, port, ssh_key, profile)
        VALUES (?, ?, ?, ?, ?, ?)
    """, defaults)


def list_all(conn: sqlite3.Connection) -> list[sqlite3.Row]:
    return conn.execute("SELECT * FROM servers ORDER BY profile, name").fetchall()


def list_for_profile(conn: sqlite3.Connection, profile: str) -> list[sqlite3.Row]:
    return conn.execute(
        "SELECT * FROM servers WHERE profile = ? ORDER BY name", (profile,)
    ).fetchall()


def add(conn: sqlite3.Connection, name: str, host: str, user: str, port: int,
        ssh_key: str | None, profile: str, notes: str | None) -> None:
    conn.execute("""
        INSERT INTO servers (name, host, user, port, ssh_key, profile, notes)
        VALUES (?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(name) DO UPDATE SET
            host = excluded.host, user = excluded.user, port = excluded.port,
            ssh_key = excluded.ssh_key, profile = excluded.profile, notes = excluded.notes
    """, (name, host, user, port, ssh_key, profile, notes))


def remove(conn: sqlite3.Connection, name: str) -> None:
    conn.execute("DELETE FROM servers WHERE name = ?", (name,))


def get(conn: sqlite3.Connection, name: str) -> sqlite3.Row | None:
    return conn.execute("SELECT * FROM servers WHERE name = ?", (name,)).fetchone()
