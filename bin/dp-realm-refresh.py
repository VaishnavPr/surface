#!/usr/bin/env python3
"""
Fetch fresh realm list from devportal-cli, save to SQLite cache, print fzf lines.
Called by dp-realms fzf reload binding — must be standalone (no shell sourcing).
"""
import datetime, json, os, sqlite3, subprocess, sys, time

DP = os.popen("which devportal-cli").read().strip() or os.path.expanduser("~/.local/bin/devportal-cli")
DB = os.path.expanduser("~/.local/share/surface/dp-realms.db")


BOLD = "\033[1m";  DIM  = "\033[2m";  RESET = "\033[0m"
RED  = "\033[31m"; GRN  = "\033[32m"; YLW   = "\033[33m"
CYAN = "\033[36m"; BRED = "\033[91m"; BYLW  = "\033[93m"


def expiry(s):
    if not s:
        return DIM + "no-expiry" + RESET
    d = datetime.datetime.fromisoformat(s.replace("Z", "+00:00"))
    now = datetime.datetime.now(datetime.timezone.utc)
    days = (d - now).days
    if days < 0:   return BRED + BOLD + "EXPIRED" + RESET
    if days == 0:  return BRED + "today"  + RESET
    if days == 1:  return RED  + "1d"     + RESET
    if days <= 4:  return YLW  + f"{days}d" + RESET
    if days <= 7:  return BYLW + f"{days}d" + RESET
    return GRN + f"{days}d" + RESET


def realm_info(r):
    version = git_ref = commit = ui_dns = ""
    for res in r.get("resources", []):
        d = res.get("details") or {}
        if res.get("type") == "kube-deployment":
            try:
                qd = json.loads(d.get("queryDetails") or "{}", strict=False)
            except Exception:
                qd = {}
            v = qd.get("versioning") or {}
            if v.get("major"):
                version = f"v{v['major']}.{v['minor']}"
            ui_dns = qd.get("ui_dns_record", "")
    for req in r.get("requests", []):
        data = req.get("data") or {}
        if data.get("git_ref"):
            git_ref = data["git_ref"]
            commit = (data.get("commit_hash") or "")[:7]
            break
    return version, git_ref, commit, ui_dns


def main():
    r = subprocess.run([DP, "realms", "list", "--json"], capture_output=True, text=True)
    raw = r.stdout
    for i, c in enumerate(raw):
        if c in "[{":
            raw = raw[i:]
            break

    if not raw.strip():
        print("Error: no output from devportal-cli", file=sys.stderr)
        sys.exit(1)

    try:
        data = json.loads(raw, strict=False)
    except Exception as e:
        print(f"Error parsing JSON: {e}", file=sys.stderr)
        sys.exit(1)

    ts = int(time.time())
    try:
        os.makedirs(os.path.dirname(DB), exist_ok=True)
        with sqlite3.connect(DB) as conn:
            conn.execute("CREATE TABLE IF NOT EXISTS cache (data TEXT, saved_at INTEGER)")
            conn.execute("CREATE TABLE IF NOT EXISTS realm_data (id TEXT PRIMARY KEY, data TEXT, saved_at INTEGER)")
            conn.execute("DELETE FROM cache")
            conn.execute("INSERT INTO cache (data, saved_at) VALUES (?,?)", (raw, ts))
            for realm in data:
                conn.execute(
                    "INSERT OR REPLACE INTO realm_data (id, data, saved_at) VALUES (?,?,?)",
                    (realm["id"], json.dumps(realm), ts),
                )
    except Exception as e:
        print(f"Cache write error: {e}", file=sys.stderr)

    data.sort(key=lambda r: r.get("updated_at") or "", reverse=True)
    for r in data:
        exp     = expiry(r.get("expired_at"))
        name    = r.get("name") or r["id"][:8]
        version, git_ref, commit, ui_dns = realm_info(r)
        ver_pad = f"{(version or '?'):<8}"
        ref_str = git_ref or "?"
        print(f"{r['id']}|{BOLD}{name:<38}{RESET} {CYAN}{ver_pad}{RESET} {DIM}[{YLW}{ref_str}{RESET}{DIM}@{commit}]{RESET}  exp:{exp:<6}  {DIM}{ui_dns}{RESET}")


if __name__ == "__main__":
    main()
