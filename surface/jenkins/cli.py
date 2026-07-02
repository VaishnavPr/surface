import click
from rich.console import Console
from rich.table import Table
from surface.db.core import get_connection
from surface.jenkins import models, client

console = Console()


@click.group("jenkins")
def cli():
    """Jenkins job cache, param history, and build info."""


@cli.command("jobs")
@click.option("--instance", default="prod", show_default=True, type=click.Choice(["prod", "test"]))
@click.option("--refresh", is_flag=True, help="Force refresh the cache")
@click.option("--json", "as_json", is_flag=True, help="Output as path|color lines (for zsh)")
def jobs(instance: str, refresh: bool, as_json: bool):
    """List cached Jenkins jobs."""
    with get_connection() as conn:
        if refresh or not models.jobs_cache_fresh(conn, instance):
            console.print("[dim]Fetching jobs from Jenkins...[/dim]", highlight=False)
            fetched = client.fetch_jobs(instance)
            models.jobs_cache_set(conn, instance, fetched)

        rows = models.jobs_cache_get(conn, instance)

    if as_json:
        for row in rows:
            click.echo(f"{row['job_path']}|{row['color'] or ''}")
        return

    table = Table(show_header=True, header_style="bold cyan")
    table.add_column("Status", width=3)
    table.add_column("Job")
    icons = {"blue": "[green]✓[/green]", "red": "[red]✗[/red]", "blue_anime": "[cyan]●[/cyan]", "red_anime": "[red]●[/red]"}
    for row in rows:
        icon = icons.get(row["color"], "[dim]?[/dim]")
        table.add_row(icon, row["job_path"])
    console.print(table)


@cli.command("params-get")
@click.argument("job_path")
@click.option("--instance", default="prod", show_default=True, type=click.Choice(["prod", "test"]))
def params_get(job_path: str, instance: str):
    """Print last-used params for a job as KEY=value lines."""
    with get_connection() as conn:
        history = models.params_get(conn, instance, job_path)
    for k, v in history.items():
        click.echo(f"{k}={v}")


@cli.command("params-save")
@click.argument("job_path")
@click.argument("pairs", nargs=-1)
@click.option("--instance", default="prod", show_default=True, type=click.Choice(["prod", "test"]))
def params_save(job_path: str, pairs: tuple[str, ...], instance: str):
    """Save param values for a job. Format: KEY=value ..."""
    parsed = {}
    for pair in pairs:
        if "=" in pair:
            k, _, v = pair.partition("=")
            parsed[k] = v
    if not parsed:
        console.print("[yellow]No KEY=value pairs provided[/yellow]")
        return
    with get_connection() as conn:
        models.params_save(conn, instance, job_path, parsed)
    console.print(f"[green]✓[/green] Saved {len(parsed)} param(s) for [bold]{job_path}[/bold]")


@cli.command("cache-clear")
@click.option("--instance", default=None, type=click.Choice(["prod", "test"]), help="Clear only one instance")
def cache_clear(instance: str | None):
    """Clear the Jenkins jobs cache."""
    with get_connection() as conn:
        models.jobs_cache_clear(conn, instance)
    label = instance or "all instances"
    console.print(f"[yellow]Cache cleared[/yellow] ({label})")


@cli.command("status")
@click.argument("job_path")
@click.option("--instance", default="prod", show_default=True, type=click.Choice(["prod", "test"]))
def status(job_path: str, instance: str):
    """Show the last build status for a job."""
    import datetime
    build = client.last_build(job_path, instance)
    ts = datetime.datetime.fromtimestamp(build["timestamp"] / 1000).strftime("%Y-%m-%d %H:%M:%S")
    dur = build["duration"] // 1000
    result = "RUNNING" if build["building"] else build.get("result", "UNKNOWN")
    icons = {"SUCCESS": "[green]✓[/green]", "FAILURE": "[red]✗[/red]", "RUNNING": "[cyan]●[/cyan]"}
    icon = icons.get(result, "[dim]?[/dim]")
    console.print(f"\n  {icon}  Build #{build['number']}  [{result}]")
    console.print(f"     [dim]Time:[/dim]     {ts}")
    console.print(f"     [dim]Duration:[/dim] {dur}s")
    console.print(f"     [dim]URL:[/dim]      {build['url']}\n")
