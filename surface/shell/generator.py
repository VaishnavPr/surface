"""Generates shell.zsh — profile-aware zsh functions, no 'surface' prefix needed."""
import sqlite3
import sys
from pathlib import Path

SHELL_ZSH = Path.home() / ".local" / "share" / "surface" / "shell.zsh"

_SURFACE_BIN = str(Path(sys.executable).parent / "surface")

_ZSH_PROFILE_FN = {
    "work":     "work_profile",
    "personal": "personal_profile",
}


def _get_state(conn: sqlite3.Connection) -> tuple[dict | None, list[str], list[dict]]:
    active = conn.execute("""
        SELECT p.name, p.jenkins_instance, p.jira_project
        FROM active_profile ap
        JOIN profiles p ON p.name = ap.profile_name
        WHERE ap.id = 1
    """).fetchone()

    all_profiles = [r[0] for r in conn.execute(
        "SELECT name FROM profiles ORDER BY name"
    ).fetchall()]

    servers = [dict(r) for r in conn.execute(
        "SELECT * FROM servers ORDER BY name"
    ).fetchall()]

    return (dict(active) if active else None), all_profiles, servers


def _ssh_cmd(s: dict) -> str:
    parts = ["ssh"]
    if s["ssh_key"]:
        parts += ["-i", s["ssh_key"]]
    if s["port"] != 22:
        parts += ["-p", str(s["port"])]
    parts.append(f"{s['user']}@{s['host']}")
    return " ".join(parts)


def generate(conn: sqlite3.Connection) -> str:
    S = _SURFACE_BIN
    active, all_profiles, all_servers = _get_state(conn)

    profile_name = active["name"] if active else None
    jenkins_instance = (active or {}).get("jenkins_instance") or "prod"
    jira_project = (active or {}).get("jira_project") or ""

    lines = [
        "# surface shell.zsh — auto-generated, do not edit",
        "",
        "# ── profile env ─────────────────────────────────────────────────",
        f"export SURFACE_PROFILE={profile_name!r}" if profile_name else "export SURFACE_PROFILE=''",
        f"export SURFACE_JENKINS_INSTANCE={jenkins_instance!r}",
        f"export SURFACE_JIRA_PROJECT={jira_project!r}",
        "",
    ]

    # ── profile switchers ─────────────────────────────────────────────────────
    lines += ["# ── profile switchers ───────────────────────────────────────────"]
    for pname in all_profiles:
        zsh_fn = _ZSH_PROFILE_FN.get(pname)
        if zsh_fn:
            lines += [
                f"{pname}-profile() {{",
                f"  {zsh_fn}",
                f"  {S} profile set {pname!r} && {S} daemon regenerate &>/dev/null &",
                "}",
                "",
            ]
        else:
            lines += [
                f"{pname}-profile() {{",
                f"  {S} profile set {pname!r} && {S} daemon regenerate",
                f"  echo \"[surface] profile → {pname}\"",
                "}",
                "",
            ]

    lines += [
        "profile-info() {",
        f"  {S} profile active",
        "}",
        "",
    ]

    # ── profile-specific tools ────────────────────────────────────────────────
    if profile_name == "work":
        lines += [
            "# ── work tools ──────────────────────────────────────────────────",
            f"jenkins-cache()   {{ {S} jenkins jobs \"$@\"; }}",
            f"jenkins-refresh() {{ {S} jenkins jobs --refresh \"$@\"; }}",
            f"jenkins-params()  {{ {S} jenkins params-get \"$@\"; }}",
            "",
            f"jira-cache()   {{ {S} jira tickets --project {jira_project!r} \"$@\"; }}" if jira_project else f"jira-cache()   {{ {S} jira tickets \"$@\"; }}",
            f"jira-refresh() {{ {S} jira tickets --project {jira_project!r} --refresh \"$@\"; }}" if jira_project else f"jira-refresh() {{ {S} jira tickets --refresh \"$@\"; }}",
            "",
        ]

    # ── server shortcuts (profile-filtered) ───────────────────────────────────
    profile_servers = [s for s in all_servers if s["profile"] == profile_name] if profile_name else []
    all_profile_servers = all_servers  # for 'connect' fallback

    if profile_servers:
        lines += [f"# ── servers ({profile_name}) ──────────────────────────────────────────"]
        for s in profile_servers:
            cmd = _ssh_cmd(s)
            note = f"  # {s['notes']}" if s.get("notes") else ""
            lines += [
                f"{s['name']}() {{ {cmd}; }}{note}",
            ]
        lines.append("")

    # ── surface-help ──────────────────────────────────────────────────────────
    server_names = [s["name"] for s in profile_servers]
    work_tools = ["jenkins-cache", "jenkins-refresh", "jenkins-params", "jira-cache", "jira-refresh"] if profile_name == "work" else []
    profile_cmds = [f"{p}-profile" for p in all_profiles] + ["profile-info"]

    help_sections = []
    if profile_cmds:
        help_sections.append(("Profiles", profile_cmds))
    if work_tools:
        help_sections.append(("Work tools", work_tools))
    if server_names:
        help_sections.append(("Servers", server_names))

    lines += [
        "# ── surface-help ────────────────────────────────────────────────",
        "sf-help() {",
        f"  echo \"Surface commands  [profile: ${{SURFACE_PROFILE:-none}}]\"",
        "  echo ''",
    ]
    for section, cmds in help_sections:
        lines.append(f"  echo '  {section}:'")
        for cmd in cmds:
            lines.append(f"  echo '    {cmd}'")
        lines.append("  echo ''")
    lines += [
        "}",
        "",
        "# Register surface commands with zsh-help if it's loaded",
        "_surface_zsh_help_hook() {",
        "  if (( $+functions[zsh-help] )); then",
        "    zsh-help surface 2>/dev/null || true",
        "  fi",
        "}",
        "",
    ]

    return "\n".join(lines) + "\n"


def write(conn: sqlite3.Connection) -> Path:
    SHELL_ZSH.parent.mkdir(parents=True, exist_ok=True)
    SHELL_ZSH.write_text(generate(conn))
    return SHELL_ZSH
