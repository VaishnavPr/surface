#!/usr/bin/env zsh
# thin — helpers for Guardicore thin env (v1) SSH-based environments
# Commands: thin-ssh, thin-run, thin-mgmtctl, thin-ff, thin-logs, thin-log-search, thin-status

_THIN_PASS="tisctmt1"
_THIN_SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o IdentitiesOnly=yes"

# ── internal: port for service ────────────────────────────────────────────────
_thin_port() {
  case "$1" in
    mgmt|management|m) echo 222 ;;
    tester|t)          echo 22  ;;
    agg|aggregator|a)  echo 231 ;;
    *)                 echo 222 ;;
  esac
}

# ── internal: run a command on a thin env ─────────────────────────────────────
_thin_run() {
  local num="$1" service="$2"; shift 2
  local port=$(_thin_port "$service")
  sshpass -p "$_THIN_PASS" ssh ${=_THIN_SSH_OPTS} \
    root@${num}.thin.env -p "$port" "$@"
}

# ── internal: fzf pick env number from devportal legacy-envs ─────────────────
_thin_pick_num() {
  local header="${1:-Select thin env}"
  local picked
  picked=$(devportal-cli legacy-envs list --json 2>/dev/null | python3 -c "
import json, sys, re, datetime

def expiry(s):
    if not s: return ''
    d = datetime.datetime.fromisoformat(s.replace('Z', '+00:00'))
    now = datetime.datetime.now(datetime.timezone.utc)
    days = (d - now).days
    if days < 0:  return 'EXPIRED'
    return f'exp:{days}d'

raw = sys.stdin.read()
for i, c in enumerate(raw):
    if c in '[{':
        raw = raw[i:]; break
data = json.loads(raw)
data.sort(key=lambda e: e.get('updated_at') or '', reverse=True)
for e in data:
    name = e.get('name', '')
    nums = re.findall(r'\d+', name)
    num  = nums[0] if nums else ''
    exp  = expiry(e.get('expired_at'))
    print(f'{num}|{name:<36} {exp}')
" | fzf \
    --delimiter='|' \
    --with-nth=2 \
    --header="$header  (or type a number for any env)" \
    --print-query \
    --bind='enter:accept' \
    2>/dev/null)

  # --print-query outputs query on first line, selection on second
  local query=$(echo "$picked" | head -1)
  local selection=$(echo "$picked" | tail -1)

  # if they selected a known env, use its number; if they typed a bare number, use that
  if echo "$selection" | grep -qE '^\d+\|'; then
    echo "$selection" | cut -d'|' -f1
  elif [[ "$query" =~ ^[0-9]+$ ]]; then
    echo "$query"
  else
    return 1
  fi
}

# ── internal: fzf pick service ────────────────────────────────────────────────
_thin_pick_service() {
  printf 'mgmt\ntester\nagg' | fzf --header="Pick service" --height=6
}

# ── thin-ssh — interactive SSH into a thin env ───────────────────────────────
thin-ssh() {
  if [[ "$1" == "--help" ]]; then
    echo "  thin-ssh [num] [mgmt|tester|agg]   SSH into a thin env interactively"
    echo "  thin-ssh 160                        SSH into thin-160 management"
    echo "  thin-ssh 160 agg                    SSH into thin-160 aggregator"
    return
  fi

  local num="$1" service="${2:-mgmt}"

  if [[ -z "$num" ]]; then
    num=$(_thin_pick_num "SSH into thin env") || return 1
  fi
  if [[ "$#" -lt 2 ]]; then
    service=$(_thin_pick_service) || return 1
  fi

  local port=$(_thin_port "$service")
  echo "Connecting to thin-${num} ${service} (port ${port})..."
  sshpass -p "$_THIN_PASS" ssh ${=_THIN_SSH_OPTS} root@${num}.thin.env -p "$port"
}

# ── thin-mgmtctl — run gc-mgmtctl on management ──────────────────────────────
thin-mgmtctl() {
  if [[ "$1" == "--help" ]]; then
    echo "  thin-mgmtctl [num] <cmd> [args...]   Run gc-mgmtctl on thin env management"
    echo "  thin-mgmtctl 160 get_feature_flags"
    echo "  thin-mgmtctl 160 set_conf --group access --option enabled --value true"
    return
  fi

  local num="$1"
  if [[ -z "$num" || ! "$num" =~ ^[0-9]+$ ]]; then
    num=$(_thin_pick_num "Run mgmtctl — pick env") || return 1
  else
    shift
  fi

  if [[ $# -eq 0 ]]; then
    echo "Usage: thin-mgmtctl [num] <command> [args...]"
    return 1
  fi

  _thin_run "$num" mgmt "gc-mgmtctl $*"
}

# ── thin-ff — feature flag & config management ────────────────────────────────
thin-ff() {
  if [[ "$1" == "--help" ]]; then
    echo "  thin-ff [num]                        Browse & set feature flags (interactive)"
    echo "  thin-ff [num] get <group.option>     Get a specific flag/conf value"
    echo "  thin-ff [num] set <group> <opt> <v>  Set a config option"
    echo "  thin-ff [num] set-ff <group.opt> <v> Set a feature flag"
    echo "  thin-ff [num] list                   List all feature flags"
    return
  fi

  local num="$1"
  if [[ -z "$num" || ! "$num" =~ ^[0-9]+$ ]]; then
    num=$(_thin_pick_num "Feature flags — pick env") || return 1
  else
    shift
  fi

  local subcmd="${1:-}"

  case "$subcmd" in
    get)
      local flag="$2"
      if [[ -z "$flag" ]]; then
        echo "Usage: thin-ff $num get <group.option>"
        return 1
      fi
      local group="${flag%%.*}"
      local option="${flag#*.}"
      echo "Getting $flag on thin-$num..."
      _thin_run "$num" mgmt "gc-mgmtctl get_conf --group $group --option $option 2>/dev/null || gc-mgmtctl get_ff --feature_flag_name $flag"
      ;;

    set)
      local group="$2" option="$3" value="$4"
      if [[ -z "$group" || -z "$option" || -z "$value" ]]; then
        echo "Usage: thin-ff $num set <group> <option> <value>"
        return 1
      fi
      echo "Setting $group.$option = $value on thin-$num..."
      _thin_run "$num" mgmt "gc-mgmtctl set_conf --group $group --option $option --value $value"
      ;;

    set-ff)
      local flag="$2" value="$3"
      if [[ -z "$flag" || -z "$value" ]]; then
        echo "Usage: thin-ff $num set-ff <group.option> <true|false>"
        return 1
      fi
      echo "Setting feature flag $flag = $value on thin-$num..."
      _thin_run "$num" mgmt "gc-mgmtctl set_ff --feature_flag_name $flag --value $value"
      ;;

    list|"")
      # Interactive: fetch all feature flags, fzf browse, offer to toggle
      echo "Fetching feature flags from thin-$num..."
      local flags_raw
      flags_raw=$(_thin_run "$num" mgmt "gc-mgmtctl get_feature_flags 2>/dev/null")

      local selected
      selected=$(echo "$flags_raw" | fzf \
        --header="thin-$num feature flags  (Enter to toggle, Ctrl-C to exit)" \
        --preview="echo {}" \
        --preview-window=down:3:wrap)
      [[ -z "$selected" ]] && return 0

      # parse flag name and current value from the line
      local flag_name flag_val
      flag_name=$(echo "$selected" | awk '{print $1}')
      flag_val=$(echo "$selected" | grep -oE 'True|False|true|false' | tail -1 | tr '[:upper:]' '[:lower:]')

      local new_val
      if [[ "$flag_val" == "true" ]]; then
        new_val="false"
      else
        new_val="true"
      fi

      echo "Toggle $flag_name: $flag_val → $new_val on thin-$num?"
      echo -n "[y/N]: " && read -r confirm </dev/tty
      [[ "$confirm" != "y" && "$confirm" != "Y" ]] && echo "Aborted." && return 0

      _thin_run "$num" mgmt "gc-mgmtctl set_ff --feature_flag_name $flag_name --value $new_val"
      ;;
  esac
}

# ── thin-logs — tail or browse logs on a thin env ────────────────────────────
thin-logs() {
  if [[ "$1" == "--help" ]]; then
    echo "  thin-logs [num] [mgmt|agg]   Pick a log file and tail it"
    return
  fi

  local num="$1" service="${2:-}"

  if [[ -z "$num" || ! "$num" =~ ^[0-9]+$ ]]; then
    num=$(_thin_pick_num "Tail logs — pick env") || return 1
  else
    shift; service="${1:-}"
  fi

  if [[ -z "$service" ]]; then
    service=$( printf 'mgmt\nagg' | fzf --header="Pick host" --height=5 ) || return 1
  fi

  local log_file
  log_file=$(_thin_run "$num" "$service" "ls /var/log/guardicore/" 2>/dev/null \
    | fzf --header="thin-$num $service — pick log file") || return 1

  echo "Tailing /var/log/guardicore/$log_file on thin-$num $service..."
  _thin_run "$num" "$service" "tail -f /var/log/guardicore/$log_file"
}

# ── thin-log-search — grep across log files ───────────────────────────────────
thin-log-search() {
  if [[ "$1" == "--help" ]]; then
    echo "  thin-log-search [num] [mgmt|agg] <keyword>   Grep logs including rotated .gz"
    echo "  thin-log-search 160 agg 'upgrade_status=COMPLETED'"
    return
  fi

  local num="$1" service="${2:-}" keyword="${3:-}"

  if [[ -z "$num" || ! "$num" =~ ^[0-9]+$ ]]; then
    num=$(_thin_pick_num "Log search — pick env") || return 1
  else
    shift
    service="${1:-}"
    keyword="${2:-}"
  fi

  if [[ -z "$service" ]]; then
    service=$(printf 'mgmt\nagg' | fzf --header="Pick host" --height=5) || return 1
  fi

  local log_file
  log_file=$(_thin_run "$num" "$service" "ls /var/log/guardicore/" 2>/dev/null \
    | fzf --header="thin-$num $service — pick log to search") || return 1

  if [[ -z "$keyword" ]]; then
    echo -n "Search keyword: " && read -r keyword </dev/tty
  fi
  [[ -z "$keyword" ]] && return 1

  echo "Searching '$keyword' in $log_file (+ rotations) on thin-$num $service..."
  _thin_run "$num" "$service" \
    "zgrep -h '$keyword' /var/log/guardicore/${log_file}.*.gz 2>/dev/null; grep '$keyword' /var/log/guardicore/$log_file 2>/dev/null" \
    | tail -50
}

# ── thin-status — show service status on management ──────────────────────────
thin-status() {
  if [[ "$1" == "--help" ]]; then
    echo "  thin-status [num]   Show monicore service status on thin env"
    return
  fi

  local num="$1"
  if [[ -z "$num" || ! "$num" =~ ^[0-9]+$ ]]; then
    num=$(_thin_pick_num "Service status — pick env") || return 1
  fi

  echo "Service status on thin-$num management..."
  _thin_run "$num" mgmt "monicore-ctrl status 2>/dev/null || supervisorctl status 2>/dev/null"
}
