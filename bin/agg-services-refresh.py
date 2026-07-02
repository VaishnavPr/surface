#!/usr/bin/env python3
"""
Fetch monicore-ctrl service list from a SaaS aggregator via tsh, cache in SQLite, print for fzf.
Usage: agg-services-refresh.py <realm_id>
Looks up the tsh node name from the realm cache (agg-vm-info.py data).
"""
import json, os, sqlite3, subprocess, sys, time

DB     = os.path.expanduser("~/.local/share/surface/aggr-dev/services.db")
RM_DB  = os.path.expanduser("~/.local/share/surface/dp-realms.db")


def get_tsh_node(realm_id):
    try:
        row = sqlite3.connect(RM_DB).execute(
            "SELECT data FROM realm_data WHERE id=?", (realm_id,)
        ).fetchone()
        if not row:
            return None
        data = json.loads(row[0], strict=False)
        for res in data.get("resources", []):
            if res.get("type") == "vm":
                return res.get("details", {}).get("name")
    except Exception:
        pass
    return None


def main():
    if len(sys.argv) < 2:
        print("Usage: agg-services-refresh.py <realm_id>", file=sys.stderr)
        sys.exit(1)

    realm_id = sys.argv[1]
    tsh_node = get_tsh_node(realm_id)

    if not tsh_node:
        print(f"Could not find tsh node name for realm {realm_id}", file=sys.stderr)
        sys.exit(1)

    r = subprocess.run(
        ["tsh", "ssh", f"root@{tsh_node}", "--", "monicore-ctrl status all"],
        capture_output=True, text=True,
    )

    # output: "{'svc-name': STATUS,\n ...}"  — extract name + status
    import re
    pairs = re.findall(r"'([^']+)':\s*(\w+)", r.stdout)
    # format: "gc-controller-server  RUNNING"
    services = [f"{name:<38} {status}" for name, status in pairs]
    if not services:
        print(f"No services returned from {tsh_node} (tsh: {r.stderr.strip()[:120]})", file=sys.stderr)
        sys.exit(1)

    os.makedirs(os.path.dirname(DB), exist_ok=True)
    with sqlite3.connect(DB) as conn:
        conn.execute(
            "CREATE TABLE IF NOT EXISTS services_cache "
            "(realm_id TEXT PRIMARY KEY, services TEXT, saved_at INTEGER)"
        )
        conn.execute(
            "INSERT OR REPLACE INTO services_cache VALUES (?,?,?)",
            (realm_id, "\n".join(services), int(time.time())),
        )

    print("\n".join(services))


if __name__ == "__main__":
    main()
