import click
from rich.console import Console
from rich.table import Table
from surface.db.core import get_connection
from surface.servers import models

console = Console()


@click.group("servers")
def cli():
    """Manage SSH server shortcuts per profile."""


@cli.command("list")
@click.option("--profile", default=None, help="Filter by profile")
def servers_list(profile: str | None):
    """List all saved servers."""
    with get_connection() as conn:
        rows = models.list_all(conn) if not profile else models.list_for_profile(conn, profile)

    if not rows:
        console.print("[dim]No servers. Add one with: surface servers add[/dim]")
        return

    table = Table(show_header=True, header_style="bold cyan")
    table.add_column("Name", style="bold")
    table.add_column("Host")
    table.add_column("User")
    table.add_column("Port")
    table.add_column("SSH Key")
    table.add_column("Profile")
    for row in rows:
        table.add_row(
            row["name"],
            row["host"],
            row["user"],
            str(row["port"]),
            row["ssh_key"] or "-",
            row["profile"],
        )
    console.print(table)


@cli.command("add")
@click.argument("name")
@click.argument("host")
@click.option("--user", "-u", default="root", show_default=True)
@click.option("--port", "-p", default=22, show_default=True, type=int)
@click.option("--key", "-k", default=None, help="Path to SSH private key")
@click.option("--profile", default="work", show_default=True, type=click.Choice(["work", "personal"]))
@click.option("--notes", default=None)
def servers_add(name, host, user, port, key, profile, notes):
    """Add or update a server."""
    with get_connection() as conn:
        models.add(conn, name, host, user, port, key, profile, notes)
    console.print(f"[green]✓[/green] Saved server [bold]{name}[/bold] ({user}@{host}:{port})")


@cli.command("remove")
@click.argument("name")
def servers_remove(name: str):
    """Remove a server."""
    with get_connection() as conn:
        models.remove(conn, name)
    console.print(f"[yellow]removed[/yellow] {name}")


@cli.command("seed")
def servers_seed():
    """Seed the database with default known servers."""
    with get_connection() as conn:
        models.seed_defaults(conn)
    console.print("[green]✓[/green] Default servers seeded (thin-160, thin-179, thin-71, ecom, ra)")
