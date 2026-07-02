import sqlite3
from pathlib import Path

_DB_PATH = Path.home() / ".local" / "share" / "surface" / "surface.db"


def get_connection() -> sqlite3.Connection:
    _DB_PATH.parent.mkdir(parents=True, exist_ok=True)
    conn = sqlite3.connect(_DB_PATH)
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA journal_mode=WAL")
    conn.execute("PRAGMA foreign_keys=ON")
    return conn


def init_db() -> None:
    """Run all domain migrations. Import order here controls creation order."""
    from surface.config.models import create_tables as config_tables
    from surface.profile.models import create_tables as profile_tables
    from surface.jenkins.models import create_tables as jenkins_tables
    from surface.jira.models import create_tables as jira_tables
    from surface.servers.models import create_tables as servers_tables, seed_defaults

    with get_connection() as conn:
        config_tables(conn)
        profile_tables(conn)
        jenkins_tables(conn)
        jira_tables(conn)
        servers_tables(conn)
        seed_defaults(conn)  # no-op if rows already exist
