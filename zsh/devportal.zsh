#!/usr/bin/env zsh
# devportal — fzf-powered wrappers around devportal-cli + devspace
# Commands: dp-realms, dp-envs, dp-extend, dp-terminate, dp-deploy, dp-claim, dp-open, dp-transfer
#           dp-connect, dp-dev, dp-logs, dp-mgmtctl, dp-config-gen

_DP="devportal-cli"
_GC_DIR="$HOME/Documents/guardicore"
_TELEPORT_PROXY="teleport.saas.guardicore.com:443"

# ── internal: strip devportal-cli preamble lines, return only JSON ───────────
_dp_json() {
  python3 -c "
import sys
raw = sys.stdin.read()
for i, c in enumerate(raw):
    if c in '[{':
        print(raw[i:])
        break
"
}

# ── internal: format realms for fzf ─────────────────────────────────────────
_dp_realm_lines() {
  "$_DP" realms list --json 2>/dev/null | _dp_json | python3 -c "
import json, sys, datetime

def expiry(s):
    if not s: return 'no-expiry'
    d = datetime.datetime.fromisoformat(s.replace('Z', '+00:00'))
    now = datetime.datetime.now(datetime.timezone.utc)
    delta = d - now
    days = delta.days
    if days < 0:   return 'EXPIRED'
    if days == 0:  return 'today'
    if days == 1:  return '1d'
    return f'{days}d'

def realm_info(r):
    qd, version, git_ref, commit, ui_dns = {}, '', '', '', ''
    for res in r.get('resources', []):
        d = res.get('details') or {}
        if res.get('type') == 'kube-deployment':
            try:
                qd = json.loads(d.get('queryDetails') or '{}')
            except Exception:
                qd = {}
            v = qd.get('versioning') or {}
            if v.get('major'):
                version = f\"v{v['major']}.{v['minor']}\"
            ui_dns = qd.get('ui_dns_record', '')
    # most recent deploy request
    for req in r.get('requests', []):
        data = req.get('data') or {}
        if data.get('git_ref'):
            git_ref = data['git_ref']
            commit  = (data.get('commit_hash') or '')[:7]
            break
    return version, git_ref, commit, ui_dns

data = json.load(sys.stdin)
data.sort(key=lambda r: r.get('updated_at') or '', reverse=True)
for r in data:
    exp              = expiry(r.get('expired_at'))
    name             = r.get('name') or r['id'][:8]
    version, git_ref, commit, ui_dns = realm_info(r)
    ver_str  = version if version else '?'
    ref_str  = git_ref if git_ref else '?'
    print(f\"{r['id']}|{name:<38} {ver_str:<8} [{ref_str}@{commit}]  exp:{exp:<6}  {ui_dns}\")
"
}

# ── internal: format legacy envs for fzf ────────────────────────────────────
_dp_env_lines() {
  "$_DP" legacy-envs list --json 2>/dev/null | _dp_json | python3 -c "
import json, sys, datetime

def expiry(s):
    if not s: return 'no-expiry'
    d = datetime.datetime.fromisoformat(s.replace('Z', '+00:00'))
    now = datetime.datetime.now(datetime.timezone.utc)
    delta = d - now
    days = delta.days
    if days < 0:   return 'EXPIRED'
    if days == 0:  return 'today'
    if days == 1:  return '1d'
    return f'{days}d'

data = json.load(sys.stdin)
for e in data:
    types = '+'.join(sorted(set(x.get('type','?') for x in e.get('resources', []))))
    exp   = expiry(e.get('expired_at'))
    name  = e.get('name') or e['id'][:8]
    print(f\"{e['id']}|{name:<40} exp:{exp:<8} [{types}]\")
"
}

# ── internal: fzf picker returning ID ────────────────────────────────────────
_dp_pick_realm() {
  local header="${1:-Select realm}"
  local line
  line=$(_dp_realm_lines | fzf \
    --delimiter='|' \
    --with-nth=2 \
    --header="$header" \
    --preview="dp-preview realm \$(echo {} | cut -d'|' -f1)" \
    --preview-window=right:55%:wrap:border-left \
    --ansi)
  [[ -z "$line" ]] && return 1
  echo "$line" | cut -d'|' -f1
}

_dp_pick_env() {
  local header="${1:-Select environment}"
  local line
  line=$(_dp_env_lines | fzf \
    --delimiter='|' \
    --with-nth=2 \
    --header="$header" \
    --preview="dp-preview env \$(echo {} | cut -d'|' -f1)" \
    --preview-window=right:55%:wrap:border-left \
    --ansi)
  [[ -z "$line" ]] && return 1
  echo "$line" | cut -d'|' -f1
}

# ── dp-realms — list / browse realms ─────────────────────────────────────────
dp-realms() {
  if [[ "$1" == "--help" ]]; then
    echo "  dp-realms          List all your realms (fzf browser)"
    echo "  dp-realms --raw    Print raw table from devportal-cli"
    return
  fi
  if [[ "$1" == "--raw" ]]; then
    "$_DP" realms list
    return
  fi
  _dp_realm_lines | fzf \
    --delimiter='|' \
    --with-nth=2 \
    --header="Realms (Enter to view details, Ctrl-C to exit)" \
    --preview="dp-preview realm \$(echo {} | cut -d'|' -f1)" \
    --preview-window=right:55%:wrap:border-left \
    --bind="enter:execute(dp-preview realm \$(echo {} | cut -d'|' -f1) | less)" \
    --ansi
}

# ── dp-envs — list / browse legacy envs ──────────────────────────────────────
dp-envs() {
  if [[ "$1" == "--help" ]]; then
    echo "  dp-envs          List legacy environments (fzf browser)"
    echo "  dp-envs --raw    Print raw table from devportal-cli"
    return
  fi
  if [[ "$1" == "--raw" ]]; then
    "$_DP" legacy-envs list
    return
  fi
  _dp_env_lines | fzf \
    --delimiter='|' \
    --with-nth=2 \
    --header="Legacy envs (Enter to view details, Ctrl-C to exit)" \
    --preview="dp-preview env \$(echo {} | cut -d'|' -f1)" \
    --preview-window=right:55%:wrap:border-left \
    --bind="enter:execute(dp-preview env \$(echo {} | cut -d'|' -f1) | less)" \
    --ansi
}

# ── dp-extend — extend realm or env lease ─────────────────────────────────────
dp-extend() {
  if [[ "$1" == "--help" ]]; then
    echo "  dp-extend              Extend lease on a realm or legacy env (fzf pick)"
    echo "  dp-extend --realm      Force realm picker"
    echo "  dp-extend --env        Force legacy env picker"
    return
  fi

  local type="${1:-}"
  local id duration_flag

  if [[ "$type" == "--realm" ]]; then
    id=$(_dp_pick_realm "Extend lease — pick realm") || return 1
    echo -n "Extend by [1w/2w/3d/...days]: " && read -r dur </dev/tty
    case "$dur" in
      1w) duration_flag="--weeks 1" ;;
      2w) duration_flag="--weeks 2" ;;
      *d) duration_flag="--days ${dur%d}" ;;
      *)  echo "Invalid. Use 1w, 2w, or Nd (e.g. 3d)"; return 1 ;;
    esac
    "$_DP" realms manage extend-lease "$id" ${=duration_flag}

  elif [[ "$type" == "--env" ]]; then
    id=$(_dp_pick_env "Extend lease — pick legacy env") || return 1
    echo -n "Extend by [1w/2w/3d/...days]: " && read -r dur </dev/tty
    case "$dur" in
      1w) duration_flag="--weeks 1" ;;
      2w) duration_flag="--weeks 2" ;;
      *d) duration_flag="--days ${dur%d}" ;;
      *)  echo "Invalid. Use 1w, 2w, or Nd (e.g. 3d)"; return 1 ;;
    esac
    "$_DP" legacy-envs extend-lease "$id" ${=duration_flag}

  else
    # Let user pick type first
    local choice
    choice=$(printf 'realm\nlegacy-env' | fzf --header="What do you want to extend?")
    [[ -z "$choice" ]] && return 1
    if [[ "$choice" == "realm" ]]; then
      dp-extend --realm
    else
      dp-extend --env
    fi
  fi
}

# ── dp-terminate — terminate realm or env ────────────────────────────────────
dp-terminate() {
  if [[ "$1" == "--help" ]]; then
    echo "  dp-terminate           Terminate a realm or legacy env (fzf pick + confirm)"
    echo "  dp-terminate --realm   Force realm picker"
    echo "  dp-terminate --env     Force legacy env picker"
    return
  fi

  local type="${1:-}"
  local id name

  if [[ "$type" == "--realm" ]]; then
    local line
    line=$(_dp_realm_lines | fzf --delimiter='|' --with-nth=2 \
      --header="TERMINATE realm — pick one" \
      --color=prompt:red \
      --preview="dp-preview realm \$(echo {} | cut -d'|' -f1)" \
      --preview-window=right:55%:wrap:border-left) || return 1
    id=$(echo "$line" | cut -d'|' -f1)
    name=$(echo "$line" | cut -d'|' -f2 | xargs)
    echo "Terminate realm: $name ($id)?"
    echo -n "[yes/no]: " && read -r confirm </dev/tty
    [[ "$confirm" != "yes" ]] && echo "Aborted." && return 1
    "$_DP" realms manage terminate "$id" --yes

  elif [[ "$type" == "--env" ]]; then
    local line
    line=$(_dp_env_lines | fzf --delimiter='|' --with-nth=2 \
      --header="TERMINATE legacy env — pick one" \
      --color=prompt:red \
      --preview="dp-preview env \$(echo {} | cut -d'|' -f1)" \
      --preview-window=right:55%:wrap:border-left) || return 1
    id=$(echo "$line" | cut -d'|' -f1)
    name=$(echo "$line" | cut -d'|' -f2 | xargs)
    echo "Terminate env: $name ($id)?"
    echo -n "[yes/no]: " && read -r confirm </dev/tty
    [[ "$confirm" != "yes" ]] && echo "Aborted." && return 1
    "$_DP" legacy-envs terminate "$id" --yes

  else
    local choice
    choice=$(printf 'realm\nlegacy-env' | fzf --header="What do you want to terminate?")
    [[ -z "$choice" ]] && return 1
    [[ "$choice" == "realm" ]] && dp-terminate --realm || dp-terminate --env
  fi
}

# ── dp-deploy — deploy SaaS Centra to a realm ────────────────────────────────
dp-deploy() {
  if [[ "$1" == "--help" ]]; then
    echo "  dp-deploy              Deploy SaaS Centra to a realm (fzf pick)"
    echo "  dp-deploy --new        Create a new realm then deploy"
    return
  fi

  local id git_ref agg_cluster

  if [[ "$1" == "--new" ]]; then
    echo "Creating new realm..."
    id=$("$_DP" realms create --id-only 2>/dev/null)
    [[ -z "$id" ]] && echo "Failed to create realm" && return 1
    echo "Created realm: $id"
  else
    id=$(_dp_pick_realm "Deploy SaaS Centra — pick realm") || return 1
  fi

  echo -n "Git ref [master]: " && read -r git_ref </dev/tty
  git_ref="${git_ref:-master}"

  echo -n "Aggregator cluster [cloud:1]: " && read -r agg_cluster </dev/tty
  agg_cluster="${agg_cluster:-cloud:1}"

  echo ""
  echo "Deploying to realm $id"
  echo "  git-ref:            $git_ref"
  echo "  aggregator-cluster: $agg_cluster"
  echo ""

  "$_DP" realms request deploy-saas-centra "$id" \
    --git-ref "$git_ref" \
    --aggregator-cluster "$agg_cluster" \
    --watch
}

# ── dp-claim — claim an instant realm ────────────────────────────────────────
dp-claim() {
  if [[ "$1" == "--help" ]]; then
    echo "  dp-claim    Claim a pre-provisioned instant realm"
    return
  fi
  echo "Claiming instant realm..."
  "$_DP" realms claim-instant
}

# ── dp-open — open realm UI in browser ───────────────────────────────────────
dp-open() {
  if [[ "$1" == "--help" ]]; then
    echo "  dp-open    Pick a realm and open its UI in the browser"
    return
  fi

  local line id ui_url
  line=$(_dp_realm_lines | fzf \
    --delimiter='|' \
    --with-nth=2 \
    --header="Open in browser — pick realm" \
    --preview="dp-preview realm \$(echo {} | cut -d'|' -f1)" \
    --preview-window=right:55%:wrap:border-left) || return 1

  id=$(echo "$line" | cut -d'|' -f1)

  ui_url=$("$_DP" realms get "$id" --json 2>/dev/null | _dp_json | python3 -c "
import json, sys
data = json.load(sys.stdin)
for r in data.get('resources', []):
    d = r.get('details') or {}
    if isinstance(d, dict) and d.get('ui_dns_record'):
        print('https://' + d['ui_dns_record'])
        break
")

  if [[ -n "$ui_url" ]]; then
    echo "Opening $ui_url"
    open "$ui_url"
  else
    echo "No UI URL found for this realm (may still be deploying)"
  fi
}

# ── dp-transfer — transfer ownership ─────────────────────────────────────────
dp-transfer() {
  if [[ "$1" == "--help" ]]; then
    echo "  dp-transfer           Transfer realm or env ownership (fzf pick)"
    return
  fi

  local choice
  choice=$(printf 'realm\nlegacy-env' | fzf --header="What do you want to transfer?")
  [[ -z "$choice" ]] && return 1

  local id to_email
  if [[ "$choice" == "realm" ]]; then
    id=$(_dp_pick_realm "Transfer — pick realm") || return 1
  else
    id=$(_dp_pick_env "Transfer — pick legacy env") || return 1
  fi

  echo -n "Transfer to (email): " && read -r to_email </dev/tty
  [[ -z "$to_email" ]] && echo "No email provided." && return 1

  if [[ "$choice" == "realm" ]]; then
    "$_DP" realms manage transfer "$id" --to "$to_email"
  else
    "$_DP" legacy-envs transfer "$id" --to "$to_email"
  fi
}

# ── dp-requests — view recent request history ─────────────────────────────────
dp-requests() {
  if [[ "$1" == "--help" ]]; then
    echo "  dp-requests    Browse recent devportal request history"
    return
  fi
  "$_DP" requests list --json 2>/dev/null | _dp_json | python3 -c "
import json, sys
data = json.load(sys.stdin)
for r in data:
    status = r.get('status', '?')
    rtype  = r.get('type') or r.get('trigger_event_type', '?')
    ts     = (r.get('created_at') or '')[:16].replace('T', ' ')
    rid    = r.get('id', '')[:8]
    print(f\"{rid}  {ts}  {status:<10}  {rtype}\")
" | fzf --header="Request history (read-only)" --no-select-1
}

# ── dp-info — rich deployment summary for a realm ────────────────────────────
dp-info() {
  if [[ "$1" == "--help" ]]; then
    echo "  dp-info    Pick a realm and show full deployment info (version, branch, URLs, creds)"
    return
  fi

  local realm_id
  realm_id=$(_dp_pick_realm "Show deployment info") || return 1

  "$_DP" realms get "$realm_id" --json 2>/dev/null | _dp_json | python3 -c "
import json, sys, datetime

def expiry(s):
    if not s: return 'no expiry'
    d = datetime.datetime.fromisoformat(s.replace('Z', '+00:00'))
    now = datetime.datetime.now(datetime.timezone.utc)
    delta = d - now
    days = delta.days
    if days < 0:   return 'EXPIRED'
    if days == 0:  return 'expires today'
    return f'expires in {days}d ({d.strftime(\"%Y-%m-%d\")})'

r = json.load(sys.stdin)
name = r.get('name', '?')
rid  = r.get('id', '?')
exp  = expiry(r.get('expired_at'))

print()
print(f'  Realm    {name}')
print(f'  ID       {rid}')
print(f'  Lease    {exp}')
print()

qd = {}
version = ''
ui_dns = ''
comp_dns = ''
ui_users = {}
ns = ''
cluster = ''

for res in r.get('resources', []):
    rtype = res.get('type', '')
    d = res.get('details') or {}

    if rtype == 'kube-deployment':
        try:
            qd = json.loads(d.get('queryDetails') or '{}')
        except Exception:
            qd = {}
        v = qd.get('versioning') or {}
        if v.get('major'):
            version = f\"v{v['major']}.{v['minor']}\"
        ui_dns   = qd.get('ui_dns_record', '')
        comp_dns = qd.get('components_dns_record', '')
        ns       = qd.get('name', '')
        cluster  = qd.get('cluster', '')
        ui_users = qd.get('ui_users') or {}
        # extract image tag from gc_service image for patch version
        gc_img = (v.get('versions') or {}).get('gc_service', '')
        tag = gc_img.split(':')[-1] if ':' in gc_img else ''

        print(f'  ── Management ─────────────────────────────')
        print(f'  Version  {version}  ({tag})')
        print(f'  Cluster  {cluster}')
        print(f'  NS       {ns}')
        if ui_dns:
            print(f'  UI       https://{ui_dns}')
        if comp_dns:
            print(f'  Comps    https://{comp_dns}')
        print()

    elif rtype == 'vm':
        ip    = d.get('ip', '?')
        img   = d.get('image', '?')
        cloud = d.get('cloud', '')
        print(f'  ── Aggregator ─────────────────────────────')
        print(f'  Image    {img}')
        print(f'  IP       {ip}  ({cloud})')
        print()

if ui_users:
    print(f'  ── UI Credentials ─────────────────────────')
    for user, pwd in ui_users.items():
        print(f'  {user:<12} {pwd}')
    print()

# deployment history
deploys = [
    req for req in r.get('requests', [])
    if (req.get('data') or {}).get('git_ref')
]
if deploys:
    print(f'  ── Deploy History ─────────────────────────')
    for req in deploys[:5]:
        data    = req.get('data', {})
        tr      = req.get('task_run') or {}
        status  = tr.get('status', '?')
        ts      = (tr.get('created_at') or '')[:16].replace('T', ' ')
        git_ref = data.get('git_ref', '?')
        commit  = (data.get('commit_hash') or '')[:7]
        job_url = ((tr.get('last_update') or {}).get('payload') or {}).get('task_url', '')
        mark    = '✓' if status == 'success' else ('✗' if status == 'failure' else '●')
        print(f'  {mark} {ts}  {git_ref}@{commit}  [{status}]')
        if job_url:
            print(f'             {job_url}')
    print()
"
}

# ═══════════════════════════════════════════════════════════════════════════════
# DEVSPACE — realm connection + dev workflow
# ═══════════════════════════════════════════════════════════════════════════════

# ── internal: extract cluster + namespace from a realm ID ─────────────────────
_dp_realm_kube_info() {
  local realm_id="$1"
  "$_DP" realms get "$realm_id" --json 2>/dev/null | _dp_json | python3 -c "
import json, sys

data = json.load(sys.stdin)
for r in data.get('resources', []):
    if r.get('type') != 'kube-deployment':
        continue
    details = r.get('details') or {}
    # queryDetails is a JSON string embedded inside details
    qd_raw = details.get('queryDetails') or '{}'
    try:
        qd = json.loads(qd_raw)
    except Exception:
        qd = {}
    cluster   = qd.get('cluster') or details.get('cluster', '')
    namespace = qd.get('name') or qd.get('namespace') or r.get('name', '')
    ui_dns    = qd.get('ui_dns_record', '')
    print(f'{cluster}|{namespace}|{ui_dns}')
    sys.exit(0)
print('||')
"
}

# ── dp-connect — full cluster connection flow ─────────────────────────────────
dp-connect() {
  if [[ "$1" == "--help" ]]; then
    echo "  dp-connect            Pick a realm and connect to its k8s cluster via Teleport"
    echo "  dp-connect --relogin  Force tsh re-login before connecting"
    return
  fi

  local relogin=0
  [[ "$1" == "--relogin" ]] && relogin=1

  # 1. Pick realm
  local realm_id
  realm_id=$(_dp_pick_realm "Connect — pick realm") || return 1

  # 2. Extract cluster + namespace
  local info cluster namespace ui_dns
  info=$(_dp_realm_kube_info "$realm_id")
  cluster=$(echo "$info"   | cut -d'|' -f1)
  namespace=$(echo "$info" | cut -d'|' -f2)
  ui_dns=$(echo "$info"    | cut -d'|' -f3)

  if [[ -z "$cluster" || -z "$namespace" ]]; then
    echo "Could not find kube-deployment resource on this realm."
    echo "It may still be deploying, or this is a non-SaaS realm."
    return 1
  fi

  echo ""
  echo "  Realm:     $realm_id"
  echo "  Cluster:   $cluster"
  echo "  Namespace: $namespace"
  [[ -n "$ui_dns" ]] && echo "  UI:        https://$ui_dns"
  echo ""

  # 3. Teleport login (skip if already logged in unless --relogin)
  if [[ $relogin -eq 1 ]] || ! tsh status &>/dev/null; then
    echo "Logging in to Teleport..."
    tsh login --proxy="$_TELEPORT_PROXY" "$_TELEPORT_PROXY" || return 1
  else
    echo "Teleport session active."
  fi

  # 4. Connect to cluster
  echo "Connecting to cluster $cluster..."
  tsh kube login "$cluster" || return 1

  # 5. Set namespace
  echo "Setting namespace $namespace..."
  kubectl config set-context --current --namespace="$namespace" || return 1

  # 6. Verify
  echo ""
  echo "Connection ready. Verifying pods..."
  kubectl get pods 2>/dev/null | head -10

  echo ""
  echo "  dp-dev         — start devspace dev (pick services)"
  echo "  dp-logs        — tail pod logs (pick service)"
  echo "  dp-mgmtctl     — run mgmtctl command"
  echo "  dp-ff          — browse & toggle feature flags"
  echo "  dp-config-gen  — generate devspace.yaml for selected services"
  echo ""
}

# ── dp-dev — devspace dev with fzf service picker ────────────────────────────
_DP_SERVICES=(
  active-directory-cache active-directory-rpc-worker agent-configuration-rpc-worker
  agent-event-processor agent-event-rpc-worker agent-installation-profiles-rpc-worker
  agent-operations-rpc-worker agents-sdk alive-agents-processor asset-changes-processor
  celery-beat celery-critical celery-long-run celery-short-run
  cloud-inventory-fetcher connection-aggregation-processor control-rpc-worker
  data-export eaa-sync enrichment-worker gc-spawn graph-worker-go
  label-changes-processor machine-update-processor machine-update-rpc-worker
  orchestration-rpc-worker policy-manager rest-server script-rest-server script-server
  sync-controller system-events-rpc-worker time-server visibility-ingestion-server
)

dp-dev() {
  if [[ "$1" == "--help" ]]; then
    echo "  dp-dev              Pick services to sync with devspace dev"
    echo "  dp-dev rest-server  Start devspace dev for a specific service directly"
    return
  fi

  local services=("$@")

  if [[ ${#services[@]} -eq 0 ]]; then
    local picked
    picked=$(printf '%s\n' "${_DP_SERVICES[@]}" | fzf \
      --multi \
      --header="Select services for devspace dev (Tab to multi-select)") || return 1
    services=(${(f)picked})
  fi

  if [[ ${#services[@]} -eq 0 ]]; then
    echo "No services selected."
    return 1
  fi

  echo "Starting devspace dev for: ${services[*]}"
  echo ""

  # Regenerate devspace.yaml for selected services then start
  (cd "$_GC_DIR" && \
    uv run devspace-config.py create "${services[@]}" --overwrite && \
    devspace dev "${services[@]/#/--var SERVICE=}" 2>/dev/null || \
    devspace dev)
}

# ── dp-logs — tail logs for a service ────────────────────────────────────────
dp-logs() {
  if [[ "$1" == "--help" ]]; then
    echo "  dp-logs              Pick a service and tail its logs"
    echo "  dp-logs rest-server  Tail logs for a specific service directly"
    return
  fi

  local service="$1"

  if [[ -z "$service" ]]; then
    service=$(printf '%s\n' "${_DP_SERVICES[@]}" | fzf \
      --header="Pick service to tail logs") || return 1
  fi

  echo "Tailing logs for $service..."
  (cd "$_GC_DIR" && devspace logs -c "$service" -f)
}

# ── dp-mgmtctl — run mgmtctl inside script-server ────────────────────────────
dp-mgmtctl() {
  if [[ "$1" == "--help" ]]; then
    echo "  dp-mgmtctl <cmd> [args...]    Run mgmtctl command inside script-server pod"
    echo "  dp-mgmtctl get_conf --group ai_labeling --option enabled"
    echo "  dp-mgmtctl set_ff --feature_flag_name <group>.<option> --value true"
    echo "  dp-mgmtctl get_feature_flags"
    return
  fi

  if [[ $# -eq 0 ]]; then
    echo "Usage: dp-mgmtctl <command> [args...]"
    echo "       dp-mgmtctl --help"
    return 1
  fi

  (cd "$_GC_DIR" && devspace run gc-mgmtctl "$@")
}

# ── internal: find script-server pod and run mgmtctl ────────────────────────
_dp_mgmtctl_exec() {
  local pod
  pod=$(kubectl get pods -o name 2>/dev/null \
    | grep '/script-server-' | grep -v 'rest' | head -1 | sed 's|pod/||')
  if [[ -z "$pod" ]]; then
    echo "No script-server pod found in current namespace." >&2
    return 1
  fi
  kubectl exec "$pod" -- bash -c \
    "cd /var/lib/guardicore/management && python scripts/mgmtctl/main.pyc $* 2>&1" \
    | grep -vE 'Initializing STATSD|Using STATSD|Initializing logger|Creating a new Consul|\[.*:INFO\]|\[.*:ERROR\]|\[.*:WARNING\]|^(WARNING|ERROR|INFO|DEBUG):[^:]+:|^\s*$'
}

_DP_FF_DB="$HOME/.local/share/surface/dp-ff.db"

_dp_ff_db_init() {
  sqlite3 "$_DP_FF_DB" "
    CREATE TABLE IF NOT EXISTS cache (
      namespace TEXT PRIMARY KEY,
      conf      TEXT,
      ff        TEXT,
      saved_at  INTEGER
    );"
}

_dp_ff_cache_age() {
  local saved_at now diff
  saved_at=$(sqlite3 "$_DP_FF_DB" "SELECT saved_at FROM cache WHERE namespace='$1';" 2>/dev/null)
  [[ -z "$saved_at" ]] && return 1
  now=$(date +%s)
  diff=$(( now - saved_at ))
  if   (( diff <    60 )); then echo "${diff}s ago"
  elif (( diff <  3600 )); then echo "$((diff/60))m ago"
  elif (( diff < 86400 )); then echo "$((diff/3600))h ago"
  else                          echo "$((diff/86400))d ago"
  fi
}

_dp_ff_cache_save() {
  local ns="$1"
  _dp_ff_db_init
  _DP_FF_CONF="$2" _DP_FF_FF="$3" python3 - "$_DP_FF_DB" "$ns" "$(date +%s)" <<'PYEOF'
import sys, sqlite3, os
db, ns, ts = sys.argv[1], sys.argv[2], int(sys.argv[3])
with sqlite3.connect(db) as conn:
    conn.execute(
        "INSERT OR REPLACE INTO cache (namespace, conf, ff, saved_at) VALUES (?,?,?,?)",
        (ns, os.environ['_DP_FF_CONF'], os.environ['_DP_FF_FF'], ts))
PYEOF
  echo "  [cache] saved to db for $ns"
}

_dp_ff_cache_bust() {
  sqlite3 "$_DP_FF_DB" "DELETE FROM cache WHERE namespace='$1';" 2>/dev/null
}

_dp_ff_fetch() {
  # Populates conf_raw and ff_raw in caller scope; saves cache
  local ns="$1"
  echo "Fetching conf + feature flags from cluster..."
  conf_raw=$(_dp_mgmtctl_exec "dump_conf" 2>/dev/null)
  ff_raw=$(_dp_mgmtctl_exec "get_feature_flags" 2>/dev/null)
  if [[ -z "$conf_raw" && -z "$ff_raw" ]]; then
    echo "No output — is the namespace connected? (run dp-connect first)" >&2
    return 1
  fi
  _dp_ff_cache_save "$ns" "$conf_raw" "$ff_raw"
}

_dp_ff_load() {
  # Populates conf_raw and ff_raw in caller scope; prompts to use cache or fetch fresh
  local ns="$1" age choice row
  _dp_ff_db_init
  age=$(_dp_ff_cache_age "$ns")
  if [[ -n "$age" ]]; then
    choice=$(printf "Use cached  [$age]\nFetch fresh from cluster" | fzf \
      --header="  ns: $ns" \
      --height=6 --no-info) || return 1
    if [[ "$choice" == Use\ cached* ]]; then
      conf_raw=$(python3 -c "import sys,sqlite3; r=sqlite3.connect(sys.argv[1]).execute('SELECT conf FROM cache WHERE namespace=?',(sys.argv[2],)).fetchone(); print(r[0] if r else '',end='')" "$_DP_FF_DB" "$ns")
      ff_raw=$(python3   -c "import sys,sqlite3; r=sqlite3.connect(sys.argv[1]).execute('SELECT ff FROM cache WHERE namespace=?',(sys.argv[2],)).fetchone(); print(r[0] if r else '',end='')" "$_DP_FF_DB" "$ns")
      echo "Using cache ($age)."
      return 0
    fi
  fi
  _dp_ff_fetch "$ns"
}

_dp_ff_pick_env() {
  local current_ns current_ctx
  current_ns=$(kubectl config view --minify -o jsonpath='{..namespace}' 2>/dev/null)
  current_ctx=$(kubectl config current-context 2>/dev/null | sed 's/.*\///')

  echo ""
  if [[ -n "$current_ns" ]]; then
    echo "  Current env:  ctx=${current_ctx}  ns=${current_ns}"
  else
    echo "  Current env:  (not connected)"
  fi
  echo ""

  local choice
  choice=$(printf "Use current env  [${current_ns:-none}]\nPick a different realm" | fzf \
    --header="Which environment?" \
    --height=6 \
    --no-info) || return 1

  if [[ "$choice" == "Pick a different realm" ]]; then
    dp-connect || return 1
  else
    # Verify kubectl is reachable; Teleport tokens expire so refresh if needed
    if ! kubectl get pods --no-headers 2>/dev/null | grep -q .; then
      echo "  kube connection stale — refreshing..."
      local proxy_base="${_TELEPORT_PROXY%%:*}"
      local cluster="${current_ctx#${proxy_base}-}"
      tsh kube login "$cluster" || return 1
    fi
  fi
}

# ── dp-ff — feature flag + conf browser for SaaS devportal realms ───────────
dp-ff() {
  if [[ "$1" == "--help" ]]; then
    echo "  dp-ff                        Browse & toggle flags/conf (interactive, cached)"
    echo "  dp-ff get <group> <option>   Get a specific conf value (live)"
    echo "  dp-ff set <group> <opt> <v>  Set a conf option (live, clears cache)"
    echo "  dp-ff refresh                Force re-fetch and update cache"
    echo "  dp-ff list                   Dump raw conf + feature flags (no fzf)"
    return
  fi

  local subcmd="${1:-}"

  case "$subcmd" in
    get)
      local group="$2" option="$3"
      [[ -z "$group" || -z "$option" ]] && echo "Usage: dp-ff get <group> <option>" && return 1
      _dp_ff_pick_env || return 1
      _dp_mgmtctl_exec "get_conf --group $group --option $option"
      ;;

    set)
      local group="$2" option="$3" value="$4"
      [[ -z "$group" || -z "$option" || -z "$value" ]] \
        && echo "Usage: dp-ff set <group> <option> <value>" && return 1
      _dp_ff_pick_env || return 1
      local ns
      ns=$(kubectl config view --minify -o jsonpath='{..namespace}' 2>/dev/null)
      echo "Setting $group.$option = $value..."
      _dp_mgmtctl_exec "set_conf --group $group --option $option --value $value" \
        && _dp_ff_cache_bust "$ns" && echo "Cache cleared for $ns."
      ;;

    refresh)
      _dp_ff_pick_env || return 1
      local ns conf_raw ff_raw
      ns=$(kubectl config view --minify -o jsonpath='{..namespace}' 2>/dev/null)
      _dp_ff_fetch "$ns"
      ;;

    list)
      _dp_ff_pick_env || return 1
      local ns conf_raw ff_raw
      ns=$(kubectl config view --minify -o jsonpath='{..namespace}' 2>/dev/null)
      _dp_ff_load "$ns" || return 1
      echo "=== conf ===" && echo "$conf_raw"
      echo "" && echo "=== feature flags ===" && echo "$ff_raw"
      ;;

    "")
      _dp_ff_pick_env || return 1

      local ns
      ns=$(kubectl config view --minify -o jsonpath='{..namespace}' 2>/dev/null)

      local conf_raw ff_raw
      _dp_ff_load "$ns" || return 1

      if [[ -z "$conf_raw" && -z "$ff_raw" ]]; then
        echo "No output — is the namespace connected? (run dp-connect first)" >&2
        return 1
      fi

      local lines
      lines=$(python3 -c "
import json, sys, re

RED    = '\033[31m'
GREEN  = '\033[32m'
YELLOW = '\033[33m'
DIM    = '\033[2m'
RESET  = '\033[0m'

conf_raw = sys.argv[1]
ff_raw   = sys.argv[2]

def color_val(v):
    vs = str(v)
    if vs.lower() == 'true':  return GREEN  + vs + RESET
    if vs.lower() == 'false': return RED    + vs + RESET
    return YELLOW + vs + RESET

lines = []

# conf (INI)
current_group = ''
for line in conf_raw.splitlines():
    m = re.match(r'^\[(.+)\]', line)
    if m: current_group = m.group(1); continue
    m = re.match(r'^(\S+)\s*=\s*(.+)', line)
    if m and current_group:
        opt, val = m.group(1), m.group(2).strip()
        disp = f'{DIM}[conf]{RESET}  {current_group:<22} {opt:<42} = {color_val(val)}'
        lines.append(f'conf|{current_group}|{opt}|{val}|{disp}')

# feature flags (JSON)
if ff_raw:
    try:
        start = ff_raw.index('{')
        data = json.loads(ff_raw[start:])
        for group, opts in sorted(data.items()):
            if not isinstance(opts, dict): continue
            for opt, val in sorted(opts.items()):
                disp = f'{DIM}[ff]  {RESET}  {group:<22} {opt:<42} = {color_val(val)}'
                lines.append(f'ff|{group}|{opt}|{val}|{disp}')
    except: pass

print('\n'.join(lines))
" "$conf_raw" "$ff_raw")

      [[ -z "$lines" ]] && echo "Could not parse output." && return 1

      local selected
      selected=$(echo "$lines" | fzf \
        --delimiter='|' \
        --with-nth=5 \
        --ansi \
        --header="$ns — conf + feature flags  (Enter to set, Ctrl-C to exit)" \
        --preview='echo "type:   {1}\ngroup:  {2}\noption: {3}\nvalue:  {4}"' \
        --preview-window=down:6:wrap) || return 0

      local ftype group option current_val
      ftype=$(echo "$selected"      | cut -d'|' -f1)
      group=$(echo "$selected"      | cut -d'|' -f2)
      option=$(echo "$selected"     | cut -d'|' -f3)
      current_val=$(echo "$selected"| cut -d'|' -f4)

      echo ""
      echo "  [$ftype]  $group.$option = $current_val"
      echo ""

      local new_val
      if   [[ "${current_val:l}" == "true"  ]]; then new_val="False"
      elif [[ "${current_val:l}" == "false" ]]; then new_val="True"
      else
        echo -n "  New value [$current_val]: " && read -r new_val </dev/tty
        [[ -z "$new_val" ]] && echo "Aborted." && return 0
      fi

      echo "  $group.$option  →  $new_val"
      echo -n "  Confirm? [y/N]: " && read -r confirm </dev/tty
      [[ "$confirm" != "y" && "$confirm" != "Y" ]] && echo "Aborted." && return 0

      echo "Setting..."
      if [[ "$ftype" == "ff" ]]; then
        _dp_mgmtctl_exec "set_ff --feature_flag_name ${group}.${option} --value ${new_val:l}" || return 1
      else
        _dp_mgmtctl_exec "set_conf --group $group --option $option --value $new_val" || return 1
      fi

      echo "Refreshing cache..."
      _dp_ff_fetch "$ns"
      ;;
  esac
}

# ── dp-config-gen — generate devspace.yaml with fzf service picker ────────────
dp-config-gen() {
  if [[ "$1" == "--help" ]]; then
    echo "  dp-config-gen         Pick services and generate devspace.yaml"
    echo "  dp-config-gen --debug Also configure PyCharm remote debugger"
    return
  fi

  local debug_flag=""
  [[ "$1" == "--debug" ]] && debug_flag="--debugger"

  local picked
  picked=$(printf '%s\n' "${_DP_SERVICES[@]}" | fzf \
    --multi \
    --header="Select services (Tab multi-select) — generates devspace.yaml") || return 1

  local services=(${(f)picked})
  if [[ ${#services[@]} -eq 0 ]]; then
    echo "No services selected."
    return 1
  fi

  echo "Generating devspace.yaml for: ${services[*]}"
  (cd "$_GC_DIR" && uv run devspace-config.py create "${services[@]}" $debug_flag --overwrite)
  echo ""
  echo "Done. Run 'dp-dev' to start devspace, or 'devspace dev' from $GC_DIR"
}
