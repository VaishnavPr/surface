#!/usr/bin/env zsh
# devportal — fzf-powered wrappers around devportal-cli + devspace
# Commands: dp-realms, dp-envs, dp-extend, dp-terminate, dp-deploy, dp-claim, dp-open, dp-transfer
#           dp-connect, dp-dev, dp-logs, dp-mgmtctl, dp-config-gen

_DP="devportal-cli"
_GC_DIR="$HOME/Documents/guardicore"
_TELEPORT_PROXY="teleport.saas.guardicore.com:443"

# ── internal: format realms for fzf ─────────────────────────────────────────
_dp_realm_lines() {
  "$_DP" realms list --json 2>/dev/null | python3 -c "
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
  "$_DP" legacy-envs list --json 2>/dev/null | python3 -c "
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

  ui_url=$("$_DP" realms get "$id" --json 2>/dev/null | python3 -c "
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
  "$_DP" requests list --json 2>/dev/null | python3 -c "
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

  "$_DP" realms get "$realm_id" --json 2>/dev/null | python3 -c "
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
  "$_DP" realms get "$realm_id" --json 2>/dev/null | python3 -c "
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
