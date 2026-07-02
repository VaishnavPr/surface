import click
from surface.db.core import init_db


@click.group()
@click.pass_context
def cli(ctx: click.Context):
    """Surface — work profile, Jenkins, and Jira from your terminal."""
    ctx.ensure_object(dict)
    init_db()


def _load_groups():
    from surface.config.cli import cli as config_cli
    from surface.profile.cli import cli as profile_cli
    from surface.jenkins.cli import cli as jenkins_cli
    from surface.jira.cli import cli as jira_cli
    from surface.shell.cli import cli as daemon_cli
    from surface.servers.cli import cli as servers_cli
    cli.add_command(config_cli)
    cli.add_command(profile_cli)
    cli.add_command(jenkins_cli)
    cli.add_command(jira_cli)
    cli.add_command(daemon_cli)
    cli.add_command(servers_cli)


_load_groups()
