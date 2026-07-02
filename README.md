# Surface

Developer CLI and shell integration for Guardicore work — Jenkins, Jira, dev portal, and profile switching.

## What's in here

```
surface/          Python CLI package (click + rich + httpx + SQLite)
zsh/              Zsh function files — source these from your shell
  jira.zsh        jira-tickets, jira-view, jira-start (AI branch suggestions)
  jenkins.zsh     jenkins-jobs, jenkins-trigger, jenkins-watch (fzf-powered)
  devportal.zsh   dp-realms, dp-connect, dp-deploy, dp-info, dp-extend ...
  thin.zsh        thin-ssh, thin-ff, thin-logs, thin-log-search
  circleci.zsh    ci-pipelines, ci-pr, ci-diagnose, ci-logs, ci-open
```

## Python CLI — surface

SQLite-backed cache and profile manager. Lives at `~/.local/share/surface/surface.db`.

```bash
# Install
cd surface && python3 -m venv .venv && .venv/bin/pip install -e .

# Profiles
surface profile create work --jenkins prod --jira-project GC
surface profile create personal
surface profile set work

# Daemon (writes ~/.local/share/surface/shell.zsh, auto-restarts on profile change)
surface daemon start
surface daemon status

# Jenkins cache
surface jenkins jobs
surface jenkins jobs --refresh

# Jira cache
surface jira tickets --project GC

# Servers
surface servers list
surface servers add my-server 1.2.3.4 --user root --port 222 --profile work
```

## Shell integration

Add to `~/.zshrc`:

```zsh
# Surface daemon + precmd hook
_SURFACE_BIN="$HOME/Documents/surface/.venv/bin/surface"
if [[ -x "$_SURFACE_BIN" ]]; then
  "$_SURFACE_BIN" daemon status 2>/dev/null | grep -q Running || "$_SURFACE_BIN" daemon start &>/dev/null
  _SURFACE_SHELL="$HOME/.local/share/surface/shell.zsh"
  [[ -f "$_SURFACE_SHELL" ]] && source "$_SURFACE_SHELL"
  _surface_shell_mtime=0
  _surface_precmd() {
    local mtime=$(stat -f %m "$_SURFACE_SHELL" 2>/dev/null || echo 0)
    if [[ $mtime != $_surface_shell_mtime ]]; then
      _surface_shell_mtime=$mtime
      [[ -f "$_SURFACE_SHELL" ]] && source "$_SURFACE_SHELL"
    fi
  }
  autoload -Uz add-zsh-hook && add-zsh-hook precmd _surface_precmd
fi

# Zsh functions
source ~/Documents/surface/zsh/jira.zsh
source ~/Documents/surface/zsh/jenkins.zsh
source ~/Documents/surface/zsh/devportal.zsh
source ~/Documents/surface/zsh/thin.zsh
source ~/Documents/surface/zsh/circleci.zsh
```

Once the daemon is running, profile commands are available directly:

```
work-profile       → switches to work (opens Slack, Webex, switches git identity)
personal-profile   → switches to personal
profile-info       → shows active profile

thin-ssh 160                         → SSH into thin-160 management
thin-ff 71                           → browse & toggle feature flags on thin-71
thin-ff 71 set access enabled true   → enable access flag directly
thin-logs 160                        → tail logs (fzf log file picker)

dp-realms          → browse all dev portal realms (version, branch, expiry inline)
dp-info            → full info card (credentials, cluster, deploy history)
dp-connect         → pick realm → tsh login → kubectl namespace set
dp-deploy --new    → create realm + deploy SaaS Centra
dp-extend          → extend lease
dp-dev             → devspace dev with fzf service picker
dp-mgmtctl         → gc-mgmtctl inside script-server pod

ci-pipelines       → browse your recent pipelines (fzf → workflows → jobs → logs)
ci-pr <pr>         → find pipeline for a PR, drill into workflows
ci-diagnose <pr>   → automated: PR → failed jobs → print failure logs
ci-logs <job>      → fetch and print failed step output
ci-open [pr]       → open pipeline in browser
```

## Requirements

- `sshpass` — for thin env SSH (`brew install hudochenkov/sshpass/sshpass`)
- `fzf` — for all interactive pickers (`brew install fzf`)
- `devportal-cli` — dev portal access
- `tsh` + `kubectl` — for SaaS realm connection
- `devspace` — for code sync to SaaS pods
