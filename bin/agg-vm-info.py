#!/usr/bin/env python3
"""
Print aggregator VM info (ip + ssh_key) for a realm from the list cache.
Usage: agg-vm-info.py <realm-id>
Exits 1 if no VM found.
"""
import json, os, sqlite3, sys

DB  = os.path.expanduser("~/.local/share/surface/dp-realms.db")
rid = sys.argv[1] if len(sys.argv) > 1 else ""

if not rid:
    print("Usage: agg-vm-info.py <realm-id>", file=sys.stderr)
    sys.exit(1)

try:
    row = sqlite3.connect(DB).execute(
        "SELECT data FROM realm_data WHERE id=?", (rid,)
    ).fetchone()
except Exception as e:
    print(f"DB error: {e}", file=sys.stderr)
    sys.exit(1)

if not row:
    print(f"Realm {rid} not in cache", file=sys.stderr)
    sys.exit(2)

data = json.loads(row[0], strict=False)
for res in data.get("resources", []):
    if res.get("type") == "vm":
        d = res.get("details", {})
        if d.get("ssh_key"):
            print(json.dumps({
                "ip":       d.get("ip", ""),
                "ssh_key":  d.get("ssh_key", ""),
                "tsh_node": d.get("name", ""),
            }))
            sys.exit(0)

print("No VM with ssh_key found in realm data", file=sys.stderr)
sys.exit(3)
