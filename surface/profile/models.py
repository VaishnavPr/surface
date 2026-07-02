import sqlite3


def create_tables(conn: sqlite3.Connection) -> None:
    conn.execute("""
        CREATE TABLE IF NOT EXISTS profiles (
            name              TEXT PRIMARY KEY,
            jenkins_instance  TEXT NOT NULL DEFAULT 'prod',
            jira_project      TEXT,
            created_at        REAL NOT NULL DEFAULT (unixepoch())
        )
    """)
    conn.execute("""
        CREATE TABLE IF NOT EXISTS active_profile (
            id           INTEGER PRIMARY KEY CHECK (id = 1),
            profile_name TEXT REFERENCES profiles(name) ON DELETE SET NULL
        )
    """)
    conn.execute("INSERT OR IGNORE INTO active_profile (id, profile_name) VALUES (1, NULL)")


def create(conn: sqlite3.Connection, name: str, jenkins_instance: str = "prod", jira_project: str | None = None) -> None:
    conn.execute("""
        INSERT INTO profiles (name, jenkins_instance, jira_project)
        VALUES (?, ?, ?)
        ON CONFLICT(name) DO UPDATE SET
            jenkins_instance = excluded.jenkins_instance,
            jira_project     = excluded.jira_project
    """, (name, jenkins_instance, jira_project))


def get_active(conn: sqlite3.Connection) -> sqlite3.Row | None:
    return conn.execute("""
        SELECT p.* FROM active_profile ap
        JOIN profiles p ON p.name = ap.profile_name
        WHERE ap.id = 1
    """).fetchone()


def set_active(conn: sqlite3.Connection, name: str) -> None:
    conn.execute("UPDATE active_profile SET profile_name = ? WHERE id = 1", (name,))


def list_all(conn: sqlite3.Connection) -> list[sqlite3.Row]:
    return conn.execute("SELECT * FROM profiles ORDER BY name").fetchall()


def delete(conn: sqlite3.Connection, name: str) -> None:
    conn.execute("DELETE FROM profiles WHERE name = ?", (name,))
