import sqlite3


def create_tables(conn: sqlite3.Connection) -> None:
    conn.execute("""
        CREATE TABLE IF NOT EXISTS jenkins_jobs_cache (
            id         INTEGER PRIMARY KEY,
            instance   TEXT    NOT NULL DEFAULT 'prod',
            job_path   TEXT    NOT NULL,
            color      TEXT,
            fetched_at REAL    NOT NULL,
            UNIQUE(instance, job_path)
        )
    """)
    conn.execute("""
        CREATE TABLE IF NOT EXISTS jenkins_param_history (
            id         INTEGER PRIMARY KEY,
            instance   TEXT    NOT NULL DEFAULT 'prod',
            job_path   TEXT    NOT NULL,
            param_name TEXT    NOT NULL,
            last_value TEXT    NOT NULL,
            updated_at REAL    NOT NULL DEFAULT (unixepoch()),
            UNIQUE(instance, job_path, param_name)
        )
    """)


# ── jobs cache ────────────────────────────────────────────────────────────────

JOBS_TTL = 300  # 5 minutes


def jobs_cache_fresh(conn: sqlite3.Connection, instance: str) -> bool:
    row = conn.execute("""
        SELECT MIN(fetched_at) as oldest FROM jenkins_jobs_cache WHERE instance = ?
    """, (instance,)).fetchone()
    if not row or not row["oldest"]:
        return False
    import time
    return (time.time() - row["oldest"]) < JOBS_TTL


def jobs_cache_get(conn: sqlite3.Connection, instance: str) -> list[sqlite3.Row]:
    return conn.execute("""
        SELECT job_path, color FROM jenkins_jobs_cache
        WHERE instance = ? ORDER BY job_path
    """, (instance,)).fetchall()


def jobs_cache_set(conn: sqlite3.Connection, instance: str, jobs: list[dict]) -> None:
    import time
    now = time.time()
    conn.execute("DELETE FROM jenkins_jobs_cache WHERE instance = ?", (instance,))
    conn.executemany("""
        INSERT INTO jenkins_jobs_cache (instance, job_path, color, fetched_at)
        VALUES (?, ?, ?, ?)
    """, [(instance, j["path"], j["color"], now) for j in jobs])


def jobs_cache_clear(conn: sqlite3.Connection, instance: str | None = None) -> None:
    if instance:
        conn.execute("DELETE FROM jenkins_jobs_cache WHERE instance = ?", (instance,))
    else:
        conn.execute("DELETE FROM jenkins_jobs_cache")


# ── param history ─────────────────────────────────────────────────────────────

def params_get(conn: sqlite3.Connection, instance: str, job_path: str) -> dict[str, str]:
    rows = conn.execute("""
        SELECT param_name, last_value FROM jenkins_param_history
        WHERE instance = ? AND job_path = ?
    """, (instance, job_path)).fetchall()
    return {row["param_name"]: row["last_value"] for row in rows}


def params_save(conn: sqlite3.Connection, instance: str, job_path: str, params: dict[str, str]) -> None:
    import time
    now = time.time()
    conn.executemany("""
        INSERT INTO jenkins_param_history (instance, job_path, param_name, last_value, updated_at)
        VALUES (?, ?, ?, ?, ?)
        ON CONFLICT(instance, job_path, param_name)
        DO UPDATE SET last_value = excluded.last_value, updated_at = excluded.updated_at
    """, [(instance, job_path, k, v, now) for k, v in params.items()])
