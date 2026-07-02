import click
from rich.console import Console
from rich.table import Table
from rich.panel import Panel
from surface.db.core import get_connection
from surface.jira import models, client

console = Console()

STATUS_COLORS = {
    "To Do": "white",
    "In Progress": "cyan",
    "In Review": "yellow",
    "Done": "green",
    "Closed": "dim",
    "Blocked": "red",
}


def _color(status: str) -> str:
    return STATUS_COLORS.get(status, "white")


@click.group("jira")
def cli():
    """Jira ticket cache and lookup."""


@cli.command("tickets")
@click.option("--project", default=None, help="Jira project key (e.g. GC)")
@click.option("--jql", default=None, help="Custom JQL (overrides --project)")
@click.option("--refresh", is_flag=True, help="Force refresh the cache")
@click.option("--json", "as_json", is_flag=True, help="Output as KEY|status|summary lines (for zsh)")
def tickets(project: str | None, jql: str | None, refresh: bool, as_json: bool):
    """List Jira tickets for a project."""
    if not jql and not project:
        console.print("[red]Provide --project or --jql[/red]")
        raise SystemExit(1)

    effective_jql = jql or f"project = {project} ORDER BY updated DESC"
    cache_project = project or "__custom__"

    with get_connection() as conn:
        if refresh or not models.tickets_cache_fresh(conn, cache_project):
            console.print("[dim]Fetching from Jira...[/dim]", highlight=False)
            fetched = client.search(effective_jql)
            models.tickets_cache_set(conn, cache_project, fetched)
        rows = models.tickets_cache_get(conn, cache_project)

    if as_json:
        for row in rows:
            click.echo(f"{row['key']}|{row['status']}|{row['summary']}")
        return

    table = Table(show_header=True, header_style="bold cyan")
    table.add_column("Key", style="bold")
    table.add_column("Status")
    table.add_column("Summary")
    table.add_column("Assignee")
    for row in rows:
        color = _color(row["status"])
        table.add_row(
            row["key"],
            f"[{color}]{row['status']}[/{color}]",
            row["summary"],
            row["assignee"] or "-",
        )
    console.print(table)


@cli.command("view")
@click.argument("key")
def view(key: str):
    """Show full details for a Jira ticket."""
    issue = client.get_issue(key)

    color = _color(issue["status"])
    console.print(f"\n[bold]{issue['key']}[/bold]  [{color}]{issue['status']}[/{color}]  [dim]{issue['type']} · {issue['priority']}[/dim]")
    console.print(f"[bold]{issue['summary']}[/bold]\n")

    if issue["assignee"]:
        console.print(f"  [dim]Assignee:[/dim] {issue['assignee']}")
    if issue["labels"]:
        console.print(f"  [dim]Labels:[/dim]   {', '.join(issue['labels'])}")

    if issue["description"]:
        console.print(Panel(issue["description"], title="Description", border_style="dim"))

    if issue["comments"]:
        console.print("\n[bold dim]Recent comments[/bold dim]")
        for c in issue["comments"]:
            console.print(f"  [cyan]{c['author']}[/cyan]: {c['body'][:200]}")
    console.print()


@cli.command("cache-clear")
@click.option("--project", default=None, help="Clear only one project")
def cache_clear(project: str | None):
    """Clear the Jira tickets cache."""
    with get_connection() as conn:
        models.tickets_cache_clear(conn, project)
    label = project or "all projects"
    console.print(f"[yellow]Cache cleared[/yellow] ({label})")
