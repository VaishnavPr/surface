import click
from rich.table import Table
from rich.console import Console
from surface.db.core import get_connection
from surface.profile import models

console = Console()


@click.group("profile")
def cli():
    """Manage work/personal profiles."""


@cli.command("create")
@click.argument("name")
@click.option("--jenkins", default="prod", show_default=True, help="Jenkins instance: prod or test")
@click.option("--jira-project", default=None, help="Default Jira project key")
def profile_create(name: str, jenkins: str, jira_project: str | None):
    """Create or update a profile."""
    with get_connection() as conn:
        models.create(conn, name, jenkins_instance=jenkins, jira_project=jira_project)
    console.print(f"[green]✓[/green] Profile [bold]{name}[/bold] saved")


@cli.command("set")
@click.argument("name")
def profile_set(name: str):
    """Set the active profile."""
    with get_connection() as conn:
        row = conn.execute("SELECT name FROM profiles WHERE name = ?", (name,)).fetchone()
        if not row:
            console.print(f"[red]Profile '{name}' not found[/red]")
            raise SystemExit(1)
        models.set_active(conn, name)
    console.print(f"[green]✓[/green] Active profile → [bold]{name}[/bold]")


@cli.command("active")
def profile_active():
    """Show the active profile."""
    with get_connection() as conn:
        row = models.get_active(conn)
    if not row:
        console.print("[dim]No active profile[/dim]")
    else:
        console.print(f"[bold cyan]{row['name']}[/bold cyan]  jenkins={row['jenkins_instance']}  jira={row['jira_project'] or '-'}")


@cli.command("list")
@click.option("--plain", is_flag=True, help="Output names only (for shell completion)")
def profile_list(plain: bool):
    """List all profiles."""
    with get_connection() as conn:
        rows = models.list_all(conn)
        active = models.get_active(conn)

    if plain:
        for row in rows:
            click.echo(row["name"])
        return

    if not rows:
        console.print("[dim]No profiles. Create one with: surface profile create <name>[/dim]")
        return

    active_name = active["name"] if active else None
    table = Table(show_header=True, header_style="bold cyan")
    table.add_column("")
    table.add_column("Name")
    table.add_column("Jenkins")
    table.add_column("Jira project")
    for row in rows:
        marker = "[green]●[/green]" if row["name"] == active_name else " "
        table.add_row(marker, row["name"], row["jenkins_instance"], row["jira_project"] or "-")
    console.print(table)


@cli.command("delete")
@click.argument("name")
def profile_delete(name: str):
    """Delete a profile."""
    with get_connection() as conn:
        models.delete(conn, name)
    console.print(f"[yellow]deleted[/yellow] {name}")
