import click
from rich.table import Table
from rich.console import Console
from surface.db.core import get_connection
from surface.config import models

console = Console()


@click.group("config")
def cli():
    """Get and set Surface configuration values."""


@cli.command("set")
@click.argument("key")
@click.argument("value")
def config_set(key: str, value: str):
    """Set a config value."""
    with get_connection() as conn:
        models.set(conn, key, value)
    console.print(f"[green]✓[/green] {key} = {value}")


@cli.command("get")
@click.argument("key")
def config_get(key: str):
    """Get a config value."""
    with get_connection() as conn:
        value = models.get(conn, key)
    if value is None:
        console.print(f"[dim]No value for '{key}'[/dim]")
    else:
        console.print(value)


@cli.command("list")
def config_list():
    """List all config entries."""
    with get_connection() as conn:
        rows = models.all_entries(conn)

    if not rows:
        console.print("[dim]No config entries[/dim]")
        return

    table = Table(show_header=True, header_style="bold cyan")
    table.add_column("Key")
    table.add_column("Value")
    for row in rows:
        table.add_row(row["key"], row["value"])
    console.print(table)


@cli.command("delete")
@click.argument("key")
def config_delete(key: str):
    """Delete a config entry."""
    with get_connection() as conn:
        models.delete(conn, key)
    console.print(f"[yellow]deleted[/yellow] {key}")
