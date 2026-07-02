import os
import signal
import subprocess
import sys
from pathlib import Path

import click
from rich.console import Console

from surface.db.core import get_connection
from surface.shell import generator
from surface.shell.daemon import PID_FILE

console = Console()


@click.group("daemon")
def cli():
    """Manage the Surface background daemon."""


# ── helpers ───────────────────────────────────────────────────────────────────

def _read_pid() -> int | None:
    if PID_FILE.exists():
        try:
            return int(PID_FILE.read_text().strip())
        except ValueError:
            return None
    return None


def _pid_alive(pid: int) -> bool:
    try:
        os.kill(pid, 0)
        return True
    except (ProcessLookupError, PermissionError):
        return False


# ── commands ──────────────────────────────────────────────────────────────────

@cli.command("start")
@click.option("--foreground", "-f", is_flag=True, help="Run in foreground (don't daemonize)")
def start(foreground: bool):
    """Start the daemon."""
    pid = _read_pid()
    if pid and _pid_alive(pid):
        console.print(f"[yellow]Daemon already running[/yellow] (pid {pid})")
        return

    if foreground:
        console.print("[dim]Running in foreground — Ctrl-C to stop[/dim]")
        from surface.shell.daemon import run
        run()
    else:
        proc = subprocess.Popen(
            [sys.executable, "-m", "surface.shell._runner"],
            start_new_session=True,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        console.print(f"[green]✓[/green] Daemon started (pid {proc.pid})")


@cli.command("stop")
def stop():
    """Stop the daemon."""
    pid = _read_pid()
    if not pid or not _pid_alive(pid):
        console.print("[dim]Daemon is not running[/dim]")
        PID_FILE.unlink(missing_ok=True)
        return
    os.kill(pid, signal.SIGTERM)
    console.print(f"[yellow]Stopped[/yellow] (pid {pid})")


@cli.command("status")
def status():
    """Show daemon status."""
    pid = _read_pid()
    if pid and _pid_alive(pid):
        console.print(f"[green]●[/green] Running (pid {pid})")
        shell_zsh = generator.SHELL_ZSH
        if shell_zsh.exists():
            import datetime
            mtime = shell_zsh.stat().st_mtime
            ts = datetime.datetime.fromtimestamp(mtime).strftime("%Y-%m-%d %H:%M:%S")
            console.print(f"  [dim]shell.zsh last updated:[/dim] {ts}")
    else:
        console.print("[dim]○ Not running[/dim]")


@cli.command("regenerate")
def regenerate():
    """Force-regenerate shell.zsh from the current active profile."""
    with get_connection() as conn:
        path = generator.write(conn)
    console.print(f"[green]✓[/green] Regenerated {path}")


@cli.command("shell")
def shell():
    """Print the zsh integration snippet (paste into .zshrc)."""
    shell_zsh = generator.SHELL_ZSH
    click.echo(f"""\
# ── surface shell integration ─────────────────────────────────────
# Add this block to your ~/.zshrc

# Start daemon on shell init if not running
if ! surface daemon status 2>/dev/null | grep -q Running; then
  surface daemon start &>/dev/null
fi

# Source generated profile snippet
[[ -f {shell_zsh} ]] && source {shell_zsh}

# Re-source shell.zsh on every prompt if it changed
_surface_shell_mtime=0
_surface_precmd() {{
  local mtime
  mtime=$(stat -f %m {shell_zsh} 2>/dev/null || echo 0)
  if [[ $mtime != $_surface_shell_mtime ]]; then
    _surface_shell_mtime=$mtime
    [[ -f {shell_zsh} ]] && source {shell_zsh}
  fi
}}
autoload -Uz add-zsh-hook
add-zsh-hook precmd _surface_precmd
# ─────────────────────────────────────────────────────────────────
""")
