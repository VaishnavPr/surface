#!/usr/bin/env python3
"""fzf preview script for devportal realms and legacy-envs.
Usage: dp-preview realm <id>
       dp-preview env <id>
"""
import json, os, sqlite3, subprocess, sys, datetime, time

DP     = os.popen("which devportal-cli").read().strip() or os.path.expanduser("~/.local/bin/devportal-cli")
DB     = os.path.expanduser("~/.local/share/surface/dp-realms.db")

BOLD   = "\033[1m";  DIM   = "\033[2m";  RESET = "\033[0m"
RED    = "\033[31m"; GRN   = "\033[32m"; YLW   = "\033[33m"
CYAN   = "\033[36m"; BRED  = "\033[91m"; BYLW  = "\033[93m"
BLUE   = "\033[34m"; MGNT  = "\033[35m"

def section(title):
    return f"  {CYAN}{BOLD}── {title} {DIM}{'─' * (38 - len(title))}{RESET}"

def expiry(s):
    if not s: return DIM + "no expiry" + RESET
    d = datetime.datetime.fromisoformat(s.replace("Z", "+00:00"))
    now = datetime.datetime.now(datetime.timezone.utc)
    days = (d - now).days
    label = f"expires in {days}d  ({d.strftime('%Y-%m-%d')})"
    if days < 0:   return BRED + BOLD + "EXPIRED" + RESET
    if days == 0:  return BRED + "expires today" + RESET
    if days <= 4:  return YLW  + label + RESET
    if days <= 7:  return BYLW + label + RESET
    return GRN + label + RESET

def run(args):
    r = subprocess.run([DP] + args, capture_output=True, text=True)
    raw = r.stdout
    for i, c in enumerate(raw):
        if c in "[{":
            return raw[i:]
    return raw

def db_get_realm(rid):
    try:
        with sqlite3.connect(DB) as conn:
            row = conn.execute("SELECT data FROM realm_data WHERE id=?", (rid,)).fetchone()
            if row:
                return row[0]
    except Exception:
        pass
    return None

def db_save_realm(rid, data_str):
    try:
        with sqlite3.connect(DB) as conn:
            conn.execute(
                "CREATE TABLE IF NOT EXISTS realm_data (id TEXT PRIMARY KEY, data TEXT, saved_at INTEGER)"
            )
            conn.execute(
                "INSERT OR REPLACE INTO realm_data (id, data, saved_at) VALUES (?,?,?)",
                (rid, data_str, int(time.time()))
            )
    except Exception:
        pass

def get_realm(rid):
    cached = db_get_realm(rid)
    if cached:
        return json.loads(cached, strict=False), True
    raw = run(["realms", "get", rid, "--json"])
    if not raw.strip():
        return None, False
    db_save_realm(rid, raw.strip())
    return json.loads(raw, strict=False), False

def fmt_realm(data, from_cache):
    lines = []
    name = data.get("name", "?")
    cache_tag = DIM + "  (cached)" + RESET if from_cache else DIM + "  (live)" + RESET
    lines += [f"  {BOLD}{name}{RESET}{cache_tag}", f"  {expiry(data.get('expired_at'))}", ""]

    for res in data.get("resources", []):
        rtype = res.get("type", "")
        d = res.get("details") or {}

        if rtype == "kube-deployment":
            try:   qd = json.loads(d.get("queryDetails") or "{}", strict=False)
            except: qd = {}
            v   = qd.get("versioning") or {}
            ver = f"v{v['major']}.{v['minor']}" if v.get("major") else "?"
            gc_img = (v.get("versions") or {}).get("gc_service", "")
            tag = gc_img.split(":")[-1] if ":" in gc_img else ""
            cluster  = qd.get("cluster", "?")
            ns       = qd.get("name", "?")
            ui_dns   = qd.get("ui_dns_record", "")
            ui_users = qd.get("ui_users") or {}

            lines += [
                section("Management"),
                f"  Version   {CYAN}{ver}{RESET}  {DIM}({tag}){RESET}",
                f"  Cluster   {BYLW}{cluster}{RESET}",
                f"  NS        {BYLW}{ns}{RESET}",
            ]
            if ui_dns:
                lines.append(f"  UI        {BLUE}https://{ui_dns}{RESET}")
            lines.append("")

            if ui_users:
                lines.append(section("Credentials"))
                for user, pwd in ui_users.items():
                    lines.append(f"  {DIM}{user:<14}{RESET}{YLW}{pwd}{RESET}")
                lines.append("")

        elif rtype == "vm":
            ip  = d.get("ip", "?")
            img = d.get("image", "?")
            lines += [
                section("Aggregator"),
                f"  Image     {DIM}{img}{RESET}",
                f"  IP        {BYLW}{ip}{RESET}",
                "",
            ]

    deploys = [
        req for req in data.get("requests", [])
        if (req.get("data") or {}).get("git_ref")
    ]
    if deploys:
        lines.append(section("Deploy History"))
        for req in deploys[:4]:
            d2  = req.get("data", {})
            tr  = req.get("task_run") or {}
            st  = tr.get("status", "?")
            ts  = (tr.get("created_at") or "")[:16].replace("T", " ")
            ref = d2.get("git_ref", "?")
            sha = (d2.get("commit_hash") or "")[:7]
            if st == "success":
                mark = GRN + "✓" + RESET
            elif st == "failure":
                mark = RED + "✗" + RESET
            else:
                mark = YLW + "●" + RESET
            lines.append(f"  {mark}  {DIM}{ts}{RESET}  {YLW}{ref}{RESET}{DIM}@{sha}{RESET}  {DIM}[{st}]{RESET}")
        lines.append("")

    return "\n".join(lines)

def fmt_env(data):
    lines = []
    name = data.get("name", "?")
    lines += [f"  {name}", f"  {expiry(data.get('expired_at'))}", ""]
    for res in data.get("resources", []):
        lines.append(f"  Type: {res.get('type','?')}  — {res.get('name','')}")
    lines.append("")
    req = data.get("request") or {}
    tr  = req.get("task_run") or {}
    if tr.get("status"):
        ts = (tr.get("created_at") or "")[:16].replace("T", " ")
        lines.append(f"  Last action: {tr['status']} at {ts}")
    return "\n".join(lines)

def main():
    if len(sys.argv) < 3:
        print("Usage: dp-preview realm|env <id>")
        sys.exit(1)
    kind, rid = sys.argv[1], sys.argv[2]
    rid = rid.strip()
    if not rid:
        sys.exit(0)

    if kind == "realm":
        data, from_cache = get_realm(rid)
        if not data:
            print(f"Could not load realm {rid}")
            sys.exit(1)
        print(fmt_realm(data, from_cache))
    elif kind == "env":
        raw = run(["legacy-envs", "get", rid, "--json"])
        try:    data = json.loads(raw, strict=False)
        except: print(f"Could not load env {rid}"); sys.exit(1)
        print(fmt_env(data))

if __name__ == "__main__":
    main()
