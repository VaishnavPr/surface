"""
surface daemon — watches the SQLite DB for profile changes,
regenerates shell.zsh whenever the active profile changes.
"""
import os
import signal
import sqlite3
import sys
import time
from pathlib import Path

from surface.db.core import get_connection
from surface.shell import generator

PID_FILE = Path.home() / ".local" / "share" / "surface" / "daemon.pid"


def _current_profile_key(conn: sqlite3.Connection) -> str:
    row = conn.execute("""
        SELECT ap.profile_name, p.jenkins_instance, p.jira_project
        FROM active_profile ap
        LEFT JOIN profiles p ON p.name = ap.profile_name
        WHERE ap.id = 1
    """).fetchone()
    if not row or not row[0]:
        return "__none__"
    return f"{row[0]}|{row[1]}|{row[2]}"


def _write_pid():
    PID_FILE.parent.mkdir(parents=True, exist_ok=True)
    PID_FILE.write_text(str(os.getpid()))


def _clear_pid():
    PID_FILE.unlink(missing_ok=True)


def run(poll_interval: float = 2.0):
    """Main daemon loop. Polls DB every poll_interval seconds."""
    _write_pid()

    def _shutdown(sig, frame):
        _clear_pid()
        sys.exit(0)

    signal.signal(signal.SIGTERM, _shutdown)
    signal.signal(signal.SIGINT, _shutdown)

    last_key = None

    try:
        while True:
            try:
                with get_connection() as conn:
                    key = _current_profile_key(conn)
                    if key != last_key:
                        generator.write(conn)
                        last_key = key
            except Exception:
                pass  # DB may be locked briefly; retry next cycle
            time.sleep(poll_interval)
    finally:
        _clear_pid()


# ── one-shot regenerate (called by surface-profile() shell function) ──────────

def regenerate():
    with get_connection() as conn:
        path = generator.write(conn)
    print(f"[surface] regenerated {path}")
