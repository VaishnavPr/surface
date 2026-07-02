#!/usr/bin/env zsh
# agg — helpers for Guardicore aggregator access (SaaS/tsh + thin envs)
# Commands: agg-ssh, agg-logs, agg-grep, agg-check-upgrade, agg-j, agg-dev

_AGG_LOGS_DIR="/var/log/guardicore"
_AGG_CONTROLLER_LOG="aggregator.controllerserver.log"
_AGG_INSTALLER_LOG="aggregator.guestinstaller.log"
_AGG_PROXY_LOG="aggregator.upper_sslproxy.log"

_AGG_NOISE='machine-details-update|nop|agent-status-update|fast-label|buffer_available|agent-status'

# ── internal: run a command on an aggregator ──────────────────────────────────
# Usage: _agg_run <type> <id> [cmd...]
#   type: tsh   → tsh ssh root@<realm>-aggregator-1
#   type: thin  → sshpass via _thin_run <num> agg
_agg_run() {
  local type="$1" id="$2"; shift 2
  case "$type" in
    tsh)
      if [[ $# -eq 0 ]]; then
        tsh ssh "root@${id}-aggregator-1"
      else
        tsh ssh "root@${id}-aggregator-1" -- "$@"
      fi
      ;;
    thin)
      _thin_run "$id" agg "$@"
      ;;
    *)
      echo "Unknown type: $type (expected tsh or thin)" >&2
      return 1
      ;;
  esac
}

# ── internal: interactively pick env type + identifier ────────────────────────
# Sets _AGG_TYPE and _AGG_ID in caller scope
_agg_pick_env() {
  local header="${1:-Select aggregator env}"

  local type
  type=$(printf 'tsh  (SaaS / customer realm)\nthin (legacy thin env)' | fzf \
    --header="$header" --height=5 --no-info \
    | awk '{print $1}') || return 1

  if [[ "$type" == "tsh" ]]; then
    local realm
    realm=$(_dp_pick_realm "Pick realm — aggregator-1 will be used") || return 1
    _AGG_TYPE="tsh"
    _AGG_ID="$realm"
  else
    local num
    num=$(_thin_pick_num "Pick thin env — aggregator") || return 1
    _AGG_TYPE="thin"
    _AGG_ID="$num"
  fi
}

# ── internal: describe current env for display ────────────────────────────────
_agg_label() {
  local type="$1" id="$2"
  if [[ "$type" == "tsh" ]]; then
    echo "${id}-aggregator-1"
  else
    echo "thin-${id} aggregator"
  fi
}

# ── agg-ssh — SSH into an aggregator ─────────────────────────────────────────
agg-ssh() {
  if [[ "$1" == "--help" ]]; then
    echo "  agg-ssh                  SSH into an aggregator (fzf pick env type + realm/thin)"
    echo "  agg-ssh tsh <realm>      SSH into SaaS aggregator for realm"
    echo "  agg-ssh thin <num>       SSH into thin env aggregator"
    return
  fi

  local type="${1:-}" id="${2:-}"

  if [[ -n "$type" && -n "$id" ]]; then
    _AGG_TYPE="$type"; _AGG_ID="$id"
  else
    local _AGG_TYPE _AGG_ID
    _agg_pick_env "SSH into aggregator" || return 1
  fi

  echo "Connecting to $(_agg_label $_AGG_TYPE $_AGG_ID)..."
  _agg_run "$_AGG_TYPE" "$_AGG_ID"
}

# ── agg-logs — tail aggregator log with noise filtered ───────────────────────
agg-logs() {
  if [[ "$1" == "--help" ]]; then
    echo "  agg-logs                        Pick env + log, tail with noise filtered"
    echo "  agg-logs tsh <realm> [logfile]  Tail specific log on SaaS aggregator"
    echo "  agg-logs thin <num>  [logfile]  Tail specific log on thin aggregator"
    echo ""
    echo "  Key logs:"
    echo "    controllerserver  — agent connections, upgrades, main activity"
    echo "    guestinstaller    — package/script serving"
    echo "    upper_sslproxy    — HTTP callbacks from agents (report_upgrade etc.)"
    return
  fi

  local type="${1:-}" id="${2:-}" logfile="${3:-}"

  if [[ -n "$type" && -n "$id" ]]; then
    _AGG_TYPE="$type"; _AGG_ID="$id"
  else
    local _AGG_TYPE _AGG_ID
    _agg_pick_env "Tail logs — pick aggregator env" || return 1
  fi

  if [[ -z "$logfile" ]]; then
    logfile=$(printf "${_AGG_CONTROLLER_LOG}\n${_AGG_INSTALLER_LOG}\n${_AGG_PROXY_LOG}\nother (pick from ls)" | fzf \
      --header="$(_agg_label $_AGG_TYPE $_AGG_ID) — pick log" \
      --height=8 --no-info) || return 1

    if [[ "$logfile" == "other (pick from ls)" ]]; then
      logfile=$(_agg_run "$_AGG_TYPE" "$_AGG_ID" "ls $_AGG_LOGS_DIR/" 2>/dev/null \
        | fzf --header="Pick log file" --height=15) || return 1
    fi
  fi

  echo "Tailing $_AGG_LOGS_DIR/$logfile on $(_agg_label $_AGG_TYPE $_AGG_ID)..."
  echo "(noise filtered: nop, machine-details-update, agent-status-update, fast-label)"
  echo ""
  _agg_run "$_AGG_TYPE" "$_AGG_ID" "tail -f $_AGG_LOGS_DIR/$logfile" \
    | grep -vE "$_AGG_NOISE"
}

# ── agg-grep — grep log files (including rotated .gz) ────────────────────────
agg-grep() {
  if [[ "$1" == "--help" ]]; then
    echo "  agg-grep [pattern]               Pick env + log, grep (incl. rotated .gz)"
    echo "  agg-grep tsh <realm> [pattern]   Grep on SaaS aggregator"
    echo "  agg-grep thin <num>  [pattern]   Grep on thin aggregator"
    return
  fi

  local type="${1:-}" id="${2:-}" pattern="${3:-}"

  if [[ "$type" == "tsh" || "$type" == "thin" ]] && [[ -n "$id" ]]; then
    _AGG_TYPE="$type"; _AGG_ID="$id"
    shift 2; pattern="${1:-}"
  else
    local _AGG_TYPE _AGG_ID
    _agg_pick_env "Grep logs — pick aggregator env" || return 1
    pattern="$type"  # first arg was actually the pattern if no type given
    [[ "$pattern" == "tsh" || "$pattern" == "thin" ]] && pattern=""
  fi

  local logfile
  logfile=$(printf "${_AGG_CONTROLLER_LOG}\n${_AGG_INSTALLER_LOG}\n${_AGG_PROXY_LOG}\nother (pick from ls)" | fzf \
    --header="$(_agg_label $_AGG_TYPE $_AGG_ID) — pick log to search" \
    --height=8 --no-info) || return 1

  if [[ "$logfile" == "other (pick from ls)" ]]; then
    logfile=$(_agg_run "$_AGG_TYPE" "$_AGG_ID" "ls $_AGG_LOGS_DIR/" 2>/dev/null \
      | fzf --header="Pick log file") || return 1
  fi

  if [[ -z "$pattern" ]]; then
    echo -n "Search pattern: " && read -r pattern </dev/tty
    [[ -z "$pattern" ]] && return 1
  fi

  echo "Searching '$pattern' in $logfile (+ rotations) on $(_agg_label $_AGG_TYPE $_AGG_ID)..."
  _agg_run "$_AGG_TYPE" "$_AGG_ID" \
    "zgrep -h '$pattern' $_AGG_LOGS_DIR/${logfile}.*.gz 2>/dev/null; grep '$pattern' $_AGG_LOGS_DIR/$logfile 2>/dev/null" \
    | tail -100
}

# ── agg-check-upgrade — trace upgrade activity by job or agent UUID ──────────
agg-check-upgrade() {
  if [[ "$1" == "--help" ]]; then
    echo "  agg-check-upgrade                   Pick env, enter UUID, show upgrade logs"
    echo "  agg-check-upgrade tsh <realm> <id>  Check by job/agent UUID on SaaS"
    echo "  agg-check-upgrade thin <num>  <id>  Check by job/agent UUID on thin"
    echo ""
    echo "  Searches controllerserver.log for the UUID, then upper_sslproxy.log"
    echo "  for report_upgrade / upgrade_status outcomes."
    return
  fi

  local type="${1:-}" id="${2:-}" uuid="${3:-}"

  if [[ "$type" == "tsh" || "$type" == "thin" ]] && [[ -n "$id" ]]; then
    _AGG_TYPE="$type"; _AGG_ID="$id"
    uuid="$3"
  else
    local _AGG_TYPE _AGG_ID
    _agg_pick_env "Check upgrade — pick aggregator env" || return 1
    uuid="$type"
    [[ "$uuid" == "tsh" || "$uuid" == "thin" ]] && uuid=""
  fi

  if [[ -z "$uuid" ]]; then
    echo -n "Job or agent UUID: " && read -r uuid </dev/tty
    [[ -z "$uuid" ]] && return 1
  fi

  local label
  label=$(_agg_label "$_AGG_TYPE" "$_AGG_ID")

  echo ""
  echo "=== controllerserver.log — UUID: $uuid ==="
  _agg_run "$_AGG_TYPE" "$_AGG_ID" \
    "grep '$uuid' $_AGG_LOGS_DIR/$_AGG_CONTROLLER_LOG 2>/dev/null | grep -v 'machine-details\|nop\|buffer_available'" \
    | tail -80

  echo ""
  echo "=== upgrade activity (all) ==="
  _agg_run "$_AGG_TYPE" "$_AGG_ID" \
    "grep -E 'on_upgrade_agent_bundle|Got update|create_upgrader|AlreadyLatest|is upgrading|COMPLETED|FAILED' \
     $_AGG_LOGS_DIR/$_AGG_CONTROLLER_LOG 2>/dev/null | grep '$uuid'" \
    | tail -40

  echo ""
  echo "=== upper_sslproxy.log — report_upgrade outcomes ==="
  _agg_run "$_AGG_TYPE" "$_AGG_ID" \
    "grep -E 'report_upgrade|upgrade_status=COMPLETED|upgrade_status=FAILED' \
     $_AGG_LOGS_DIR/$_AGG_PROXY_LOG 2>/dev/null | grep '$uuid'" \
    | tail -40
}

# ── agg-j — run a `j` command on an agent from the aggregator ────────────────
agg-j() {
  if [[ "$1" == "--help" ]]; then
    echo "  agg-j <j-cmd> [args]             Run j command on agent (picks env interactively)"
    echo "  agg-j tsh <realm> <j-cmd> [args] Run j command on SaaS aggregator"
    echo "  agg-j thin <num>  <j-cmd> [args] Run j command on thin aggregator"
    echo ""
    echo "  Common j commands:"
    echo "    get-agent-info"
    echo "    get-agent-status"
    echo "    create-processes-info-snapshot '{\"flags\": 40}'"
    echo "    query-processes-info '{\"max-processes\": 100}'"
    return
  fi

  local type="${1:-}" id="${2:-}"

  if [[ "$type" == "tsh" || "$type" == "thin" ]] && [[ -n "$id" ]]; then
    _AGG_TYPE="$type"; _AGG_ID="$id"
    shift 2
  else
    local _AGG_TYPE _AGG_ID
    _agg_pick_env "Run j command — pick aggregator env" || return 1
  fi

  local jcmd
  if [[ $# -eq 0 ]]; then
    jcmd=$(printf \
      'get-agent-info\nget-agent-status\ncreate-processes-info-snapshot {"flags": 40}\nquery-processes-info {"max-processes": 100}\nget-agent-config\nget-network-topology\nother (type manually)' \
      | fzf --header="$(_agg_label $_AGG_TYPE $_AGG_ID) — pick j command" --height=12 --no-info) || return 1
    if [[ "$jcmd" == "other (type manually)" ]]; then
      echo -n "j command: " && read -r jcmd </dev/tty
      [[ -z "$jcmd" ]] && return 1
    fi
  else
    jcmd="$*"
  fi

  echo "Running: j $jcmd on $(_agg_label $_AGG_TYPE $_AGG_ID)..."
  _agg_run "$_AGG_TYPE" "$_AGG_ID" "j $jcmd"
}

# ── agg-dev helpers ───────────────────────────────────────────────────────────
_AGG_DEV_DIR="$HOME/.local/share/surface/aggr-dev"
_AGG_SERVICES_DB="$_AGG_DEV_DIR/services.db"

_agg_services_cache_load() {
  sqlite3 "$_AGG_SERVICES_DB" \
    "SELECT services FROM services_cache WHERE realm_id='$1' LIMIT 1;" 2>/dev/null
}

_agg_services_cache_age() {
  local saved_at now diff
  saved_at=$(sqlite3 "$_AGG_SERVICES_DB" \
    "SELECT saved_at FROM services_cache WHERE realm_id='$1' LIMIT 1;" 2>/dev/null)
  [[ -z "$saved_at" ]] && return 1
  now=$(date +%s); diff=$(( now - saved_at ))
  if   (( diff <    60 )); then echo "${diff}s ago"
  elif (( diff <  3600 )); then echo "$((diff/60))m ago"
  elif (( diff < 86400 )); then echo "$((diff/3600))h ago"
  else                          echo "$((diff/86400))d ago"
  fi
}

# ── agg-dev — sync local aggregator code to a SaaS realm via aggr-dev-cli ────

agg-dev() {
  if [[ "$1" == "--help" ]]; then
    echo "  agg-dev    Sync local aggregator code to a SaaS realm aggregator"
    echo ""
    echo "  Requires: aggr-dev-cli, rsync >2.6.9"
    echo "  SSH key is fetched automatically from realm data."
    echo "  Keys stored in $_AGG_DEV_DIR/keys/  configs in $_AGG_DEV_DIR/configs/"
    echo "  Ctrl+C stops syncing and restores compiled files on the remote."
    return
  fi

  if ! command -v aggr-dev-cli &>/dev/null; then
    echo "aggr-dev-cli not found. Install it with uv (see Confluence: Remote Aggregator code updates)." >&2
    return 1
  fi

  mkdir -p "$_AGG_DEV_DIR/keys" "$_AGG_DEV_DIR/configs"

  # 1. Pick realm
  local realm_id
  realm_id=$(_dp_pick_realm "agg-dev — pick realm") || return 1

  # 2. Extract aggregator IP + SSH key from list cache
  # (ssh_key only present in realms list response, not realms get)
  local vm_json
  vm_json=$(agg-vm-info.py "$realm_id" 2>/dev/null)

  if [[ -z "$vm_json" ]]; then
    echo "Refreshing realm list..."
    dp-realm-refresh.py 2>/dev/null
    vm_json=$(agg-vm-info.py "$realm_id" 2>/dev/null)
  fi

  local agg_ip ssh_key_content
  agg_ip=$(printf '%s' "$vm_json" | python3 -c "import json,sys; print(json.load(sys.stdin)['ip'])" 2>/dev/null)
  ssh_key_content=$(printf '%s' "$vm_json" | python3 -c "import json,sys; print(json.load(sys.stdin)['ssh_key'])" 2>/dev/null)

  if [[ -z "$agg_ip" || -z "$ssh_key_content" ]]; then
    echo "No aggregator VM found on this realm. Deploy one first." >&2
    return 1
  fi

  # Save SSH key (reuse if already exists for this realm)
  local ssh_key="$_AGG_DEV_DIR/keys/${realm_id}.pem"
  echo "$ssh_key_content" > "$ssh_key"
  chmod 600 "$ssh_key"

  echo "  Aggregator:  $agg_ip"
  echo "  SSH key:     $ssh_key"

  # 3. Pick services to restart (cached, Ctrl-R to refresh)
  echo ""
  local services_lines age svc_header
  age=$(_agg_services_cache_age "$realm_id" 2>/dev/null)
  if [[ -n "$age" ]]; then
    services_lines=$(_agg_services_cache_load "$realm_id")
    svc_header="Services  [cached $age · Ctrl-R to refresh]  Tab to multi-select"
  else
    echo "Fetching services from aggregator (via tsh)..."
    services_lines=$(agg-services-refresh.py "$realm_id" 2>/dev/null)
    svc_header="Services  [live · Ctrl-R to refresh]  Tab to multi-select"
  fi

  if [[ -z "$services_lines" ]]; then
    echo -n "Could not fetch services. Enter manually (comma-separated): " && read -r services </dev/tty
  else
    local _svc_refresh="change-header(Services  [⟳ Refreshing…])+reload(agg-services-refresh.py $realm_id)+change-header(Services  [✓ Refreshed · Ctrl-R to refresh again]  Tab to multi-select)"
    services=$(printf '%s' "$services_lines" | fzf \
      --multi \
      --header="$svc_header" \
      --bind="ctrl-r:$_svc_refresh" \
      "${_DP_FZF_COLORS[@]}" \
      | awk '{print $1}' | tr '\n' ',' | sed 's/,$//') || return 1
  fi
  [[ -z "$services" ]] && echo "No services selected." && return 1

  # 4. Generate config
  # services is comma-separated; split to positional args for create-config
  local config_file="$_AGG_DEV_DIR/configs/${realm_id}.yaml"
  local -a svc_args
  svc_args=(${(s:,:)services})
  echo ""
  echo "Generating config..."
  aggr-dev-cli create-config \
    -a "$agg_ip" \
    -i "$ssh_key" \
    -gp "$_GC_DIR" \
    --output "$config_file" \
    --overwrite \
    "${svc_args[@]}" || { echo "Config generation failed." >&2; return 1; }

  # 5. Start syncing
  echo ""
  echo "Starting sync (Ctrl+C to stop and restore compiled files)..."
  echo ""
  aggr-dev-cli dev --config-file-path "$config_file"
}
