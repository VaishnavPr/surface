# Surface

Developer CLI and shell integration for Guardicore work — Jenkins, Jira, dev portal, CircleCI, thin envs, and aggregator access.

## Contents

```
surface/          Python CLI (click + rich + httpx + SQLite) — daemon, profiles, caching
zsh/
  jira.zsh        jira-tickets, jira-view, jira-start
  jenkins.zsh     jenkins-jobs, jenkins-trigger, jenkins-watch
  devportal.zsh   dp-realms, dp-new, dp-deploy, dp-connect, dp-info, dp-extend, dp-ff …
  thin.zsh        thin-ssh, thin-ff, thin-logs, thin-log-search
  circleci.zsh    ci-pipelines, ci-pr, ci-diagnose, ci-logs, ci-open
  agg.zsh         agg-ssh, agg-logs, agg-grep, agg-check-upgrade
```

---

## Prerequisites

### Tools

| Tool | Install | Used by |
|------|---------|---------|
| `fzf` | `brew install fzf` | all interactive pickers |
| `sshpass` | `brew install hudochenkov/sshpass/sshpass` | `thin-ssh`, `agg-ssh` |
| `python3` ≥ 3.11 | ships with macOS / `brew install python` | parsing CLI output |
| `jq` | `brew install jq` | JSON formatting |
| `sqlite3` | ships with macOS | `dp-ff` cache |
| `devportal-cli` | internal install (see below) | all `dp-*` commands |
| `tsh` (Teleport) | `brew install teleport` | `dp-connect`, `agg-ssh` |
| `kubectl` | `brew install kubectl` | `dp-connect`, `dp-dev`, `dp-logs` |
| `devspace` | `brew install devspace` | `dp-dev`, `dp-logs`, `dp-config-gen` |
| `uv` | `brew install uv` | `dp-dev`, `dp-config-gen` |

### devportal-cli

Install from the internal registry, then authenticate:

```bash
# Install (ask your team for the exact install command)
pip install devportal-cli

# Authenticate — stores credentials at ~/.devportal-cli/credentials-prod.json
devportal-cli auth login
```

### macOS: iTerm2 Full Disk Access

The zsh files live under `~/Documents/`. macOS blocks shell sourcing from that path unless your terminal has **Full Disk Access**.

**System Settings → Privacy & Security → Full Disk Access** → enable iTerm (or your terminal app). Open a new window after toggling.

---

## Credentials

Each zsh module reads a credentials file from `~/.config/`. Create these files before using the corresponding commands.

### Jira — `~/.config/gc-jira.env`

Required for all `jira-*` commands:

```bash
JIRA_BASE_URL="https://guardicore.atlassian.net"
JIRA_EMAIL="you@akamai.com"        # also used as git branch prefix (email%%@*)
JIRA_TOKEN="<Atlassian API token>"
```

Get your token: https://id.atlassian.com/manage-profile/security/api-tokens

**Optional — AI branch suggestions in `jira-start`:**

```bash
ANTHROPIC_FOUNDRY_API_KEY="<key>"
ANTHROPIC_FOUNDRY_BASE_URL="<url>"
```

If unset, `jira-start` skips the AI step and uses a local slug as the branch name. Set these in `~/.zshrc` (not in the env file) since they are also used by Claude Code.

**Tools required:** `curl`, `jq`, `fzf`, `git`

### Jenkins — `~/.config/gc-jenkins.env`

```bash
JENKINS_URL="https://jenkins.guardi"
JENKINS_TESTING_URL="https://testingjenkins.guardi"
JENKINS_USER="firstname.lastname"
JENKINS_TOKEN="<Jenkins API token>"
```

Get your token: Jenkins → your user → Configure → API Token.

### CircleCI — `~/.config/gc-circleci.env`

```bash
CIRCLECI_TOKEN="<CircleCI personal API token>"
```

Get your token: `https://app.circleci.com/settings/user/tokens`

### Thin envs — `~/.config/gc-thin.env`

```bash
THIN_PASS="<your thin env root password>"
```

If this file is absent, the default shared password is used. Set this if your thin envs use a different password.

### Dev portal — `~/.config/gc-devportal.env`

```bash
SURFACE_GC_DIR="$HOME/Documents/guardicore"   # path to your local guardicore repo clone
```

Required by `dp-dev`, `dp-logs`, `dp-config-gen` (devspace commands run from this directory).

### GitHub — `~/.config/gc-github.env`

```bash
GITHUB_TOKEN="<GitHub personal access token>"
GITHUB_REPO="guardicore/guardicore"
```

Get your token: GitHub → Settings → Developer settings → Personal access tokens. Needs `repo` scope.

---

## Installation

```bash
cd ~/Documents/surface
python3 -m venv .venv
.venv/bin/pip install -e .
```

Start the daemon (generates `~/.local/share/surface/shell.zsh` which the precmd hook re-sources automatically):

```bash
.venv/bin/surface daemon start
.venv/bin/surface daemon status
```

---

## Shell integration

Add to `~/.zshrc`:

```zsh
# ── surface shell integration ─────────────────────────────────────────────────
_SURFACE_BIN="$HOME/Documents/surface/.venv/bin/surface"

if [[ -x "$_SURFACE_BIN" ]]; then
  if ! "$_SURFACE_BIN" daemon status 2>/dev/null | grep -q Running; then
    "$_SURFACE_BIN" daemon start &>/dev/null
  fi

  _SURFACE_SHELL="$HOME/.local/share/surface/shell.zsh"
  [[ -f "$_SURFACE_SHELL" ]] && source "$_SURFACE_SHELL"

  # Re-source on every prompt if shell.zsh changed (cheap stat check)
  _surface_shell_mtime=$(stat -f %m "$_SURFACE_SHELL" 2>/dev/null || echo 0)
  _surface_precmd() {
    local mtime
    mtime=$(stat -f %m "$_SURFACE_SHELL" 2>/dev/null || echo 0)
    if [[ $mtime != $_surface_shell_mtime ]]; then
      _surface_shell_mtime=$mtime
      [[ -f "$_SURFACE_SHELL" ]] && source "$_SURFACE_SHELL"
    fi
  }
  autoload -Uz add-zsh-hook
  add-zsh-hook precmd _surface_precmd
fi
# ─────────────────────────────────────────────────────────────────────────────
```

The daemon writes the zsh function sources into `shell.zsh`; the precmd hook picks up changes live. The zsh files themselves are sourced from there — **no need to source them manually in `.zshrc`**.

---

## Commands

### Dev portal (`dp-*`)

Requires: `devportal-cli` authenticated, `fzf`, `python3`, `sqlite3`

```
dp-realms          Browse all your realms (version, branch, expiry inline)
dp-envs            Browse legacy (thin) environments
dp-new             Create a new realm; optionally deploy SaaS Centra to it
dp-deploy          Deploy SaaS Centra to a realm (fzf pick)
dp-claim           Claim a pre-provisioned instant realm
dp-info            Full info card — credentials, cluster, versions, deploy history
dp-connect         Pick realm → tsh login → kubectl namespace set
dp-extend          Extend realm or legacy env lease
dp-terminate       Terminate a realm or legacy env (with confirmation)
dp-transfer        Transfer ownership of a realm or legacy env
dp-open            Open realm UI in browser
dp-requests        Browse recent devportal request history
dp-dev             Pick realm → pick services → start devspace dev
dp-logs            Tail logs for a service (fzf pick)
dp-mgmtctl         Run mgmtctl commands inside script-server pod
dp-ff              Browse & toggle feature flags / conf (cached, interactive)
dp-config-gen      Generate devspace.yaml for selected services
dp-mongo           Interactive MongoDB browser (db → collection → documents)
```

`dp-connect` requires `tsh` and `kubectl`. `dp-dev`, `dp-logs`, `dp-config-gen` additionally require `devspace` and `uv` (run from the path set in `SURFACE_GC_DIR`, defaults to `~/Documents/guardicore`).

### Thin envs (`thin-*`)

Requires: `sshpass`, `devportal-cli` (for env list), `fzf`

```
thin-ssh <num>                     SSH into thin-<num> management node
thin-ff <num>                      Browse & toggle feature flags on thin-<num>
thin-ff <num> set <grp> <opt> <v>  Set a conf option directly
thin-logs <num>                    Tail logs (fzf log file picker)
thin-log-search <num> <pattern>    Search logs for a pattern
thin-mgmtctl <num> <cmd>           Run mgmtctl command on thin-<num>
thin-status <num>                  Quick health check
```

The default shared password is used if `~/.config/gc-thin.env` is absent. Set `THIN_PASS` there if yours differs.

### Aggregator (`agg-*`)

Requires: `sshpass` (thin), or `tsh` (SaaS)

```
agg-ssh              SSH into aggregator (fzf pick: SaaS realm or thin env)
agg-logs             Tail aggregator logs with noise filtered
agg-grep             Grep logs including rotated .gz files
agg-check-upgrade    Trace upgrade activity by job or agent UUID
agg-j                Run a j command on an agent (fzf command picker)
agg-dev              Sync local aggregator code to a SaaS realm (aggr-dev-cli)
```

`agg-dev` requires `aggr-dev-cli` and `rsync >2.6.9`. It fetches the SSH key from realm data automatically and stores it in `~/.local/share/surface/aggr-dev/keys/`. SaaS only.

### Jira (`jira-*`)

Requires: `~/.config/gc-jira.env`, `fzf`

```
jira-tickets           Browse your open tickets (fzf)
jira-view <key>        View a ticket (GC-12345)
jira-start             Pick a ticket and create a git branch for it
```

### Jenkins (`jenkins-*`)

Requires: `~/.config/gc-jenkins.env`, `fzf`

```
jenkins-jobs           Browse jobs (fzf)
jenkins-trigger <job>  Trigger a build
jenkins-watch <job>    Watch a running build's console output
```

### CircleCI (`ci-*`)

Requires: `~/.config/gc-circleci.env`, `fzf`

```
ci-pipelines           Browse your recent pipelines → workflows → jobs → logs
ci-pr <pr-number>      Find pipeline for a PR, drill into workflows
ci-diagnose <pr>       Auto: PR → failed jobs → print failure logs
ci-logs <job-id>       Fetch and print failed step output
ci-open [pr]           Open pipeline in browser
```

### Profiles

After `surface daemon start`, the daemon injects profile-switch commands into the shell:

```
work-profile       Switch to work (git identity, tools)
personal-profile   Switch to personal
profile-info       Show active profile
```

---

## surface CLI reference

```bash
# Profiles
surface profile create work --jenkins prod --jira-project GC
surface profile set work
surface profile list

# Daemon
surface daemon start
surface daemon stop
surface daemon status

# Jenkins job cache
surface jenkins jobs
surface jenkins jobs --refresh

# Jira ticket cache
surface jira tickets --project GC

# Server inventory
surface servers list
surface servers add my-server 1.2.3.4 --user root --port 222 --profile work
```

Data is stored in `~/.local/share/surface/surface.db` (SQLite).
