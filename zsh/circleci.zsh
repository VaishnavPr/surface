#!/usr/bin/env zsh
# circleci — fzf-powered wrappers for CircleCI
# Commands: ci-pipelines, ci-pr, ci-workflows, ci-jobs, ci-logs, ci-diagnose, ci-open

_CI_BASE="https://circleci.com/api/v2"
_CI_V1="https://circleci.com/api/v1.1"
_CI_PROJECT="github/guardicore/guardicore"
_CI_WEB="https://app.circleci.com/pipelines/github/guardicore/guardicore"

# ── internal: load token ──────────────────────────────────────────────────────
_ci_load_env() {
  [[ -n "$CIRCLECI_TOKEN" ]] && return
  local env_file="$HOME/.config/gc-circleci.env"
  if [[ -f "$env_file" ]]; then
    source "$env_file"
  else
    echo "No token found. Set CIRCLECI_TOKEN or create $env_file" >&2
    return 1
  fi
}

# ── internal: authenticated curl ─────────────────────────────────────────────
_ci() {
  _ci_load_env || return 1
  curl -sf -H "Circle-Token: $CIRCLECI_TOKEN" "$@"
}

# ── internal: status icon ────────────────────────────────────────────────────
_ci_icon() {
  case "$1" in
    success)                    echo "✓" ;;
    failed|failing|error)       echo "✗" ;;
    running)                    echo "●" ;;
    on_hold|blocked)            echo "⏸" ;;
    canceled|cancelled)         echo "○" ;;
    *)                          echo "?" ;;
  esac
}

# ── internal: my pipeline lines for fzf ──────────────────────────────────────
# Output: pid|pipeline_num|pr_num|display_line
_ci_pipeline_lines() {
  local limit="${1:-30}"
  _ci "$_CI_BASE/project/$_CI_PROJECT/pipeline/mine?limit=$limit" | python3 -c "
import json, sys

data = json.load(sys.stdin)
icons = {'success':'✓','failed':'✗','failing':'✗','running':'●','on_hold':'⏸','canceled':'○','errored':'✗','setup-pending':'…','created':'…'}

for p in data.get('items', []):
    num    = p.get('number', '?')
    pid    = p.get('id', '')
    state  = p.get('state', '?')
    vcs    = p.get('vcs') or {}
    branch = (vcs.get('branch') or '')[:40]
    pr     = vcs.get('review_id') or ''
    subj   = (vcs.get('commit') or {}).get('subject') or ''
    subj   = subj[:45]
    icon   = icons.get(state, '?')
    pr_str = f'PR#{pr:<6}' if pr else '       '
    print(f'{pid}|{num}|{pr}|{icon} {pr_str} [{state:<10}] {branch:<41} {subj}')
"
}

# ── internal: fzf picker → returns "pipeline_id pipeline_num pr_num" ──────────
_ci_pick_pipeline() {
  local header="${1:-Select pipeline}"
  local limit="${2:-30}"
  local line
  line=$(_ci_pipeline_lines "$limit" | fzf \
    --delimiter='|' \
    --with-nth=4 \
    --header="$header" \
    --preview='ci-workflows --pipeline-id $(echo {} | cut -d"|" -f1) 2>/dev/null' \
    --preview-window=right:55%:wrap:border-left \
    --ansi) || return 1
  local pid num pr
  pid=$(echo "$line" | cut -d'|' -f1)
  num=$(echo "$line" | cut -d'|' -f2)
  pr=$(echo "$line"  | cut -d'|' -f3)
  echo "$pid $num $pr"
}

# ── ci-pipelines — browse my recent pipelines ────────────────────────────────
ci-pipelines() {
  if [[ "$1" == "--help" ]]; then
    echo "  ci-pipelines          Browse your recent CircleCI pipelines"
    echo "  ci-pipelines --limit N  Show N pipelines (default 30)"
    return
  fi

  local limit=30
  [[ "$1" == "--limit" ]] && limit="$2"

  local line
  line=$(_ci_pipeline_lines "$limit" | fzf \
    --delimiter='|' \
    --with-nth=4 \
    --header="CircleCI pipelines — PR# | status | branch  (Enter → workflows)" \
    --preview='ci-workflows --pipeline-id {1} 2>/dev/null' \
    --preview-window=right:55%:wrap:border-left \
    --ansi) || return 0

  local pid num pr
  pid=$(echo "$line" | cut -d'|' -f1)
  num=$(echo "$line" | cut -d'|' -f2)
  pr=$(echo "$line"  | cut -d'|' -f3)
  [[ -n "$pr" ]] && echo "PR #$pr  →  Pipeline #$num" || echo "Pipeline #$num"
  ci-workflows --pipeline-id "$pid" --pipeline-num "$num"
}

# ── ci-pr — browse pipeline for a PR (fzf picker if no arg) ──────────────────
ci-pr() {
  if [[ "$1" == "--help" ]]; then
    echo "  ci-pr [pr-number]    Pick (or specify) a PR and browse its workflows"
    return
  fi

  local pipeline_id pipeline_num pr_num

  if [[ -n "$1" ]]; then
    # PR number supplied — look it up directly
    pr_num="$1"
    echo "Finding pipeline for PR #$pr_num..."
    local result
    result=$(_ci "$_CI_BASE/project/$_CI_PROJECT/pipeline/mine?limit=30" | python3 -c "
import json, sys
data = json.load(sys.stdin)
for p in data.get('items', []):
    if str((p.get('vcs') or {}).get('review_id', '')) == '$pr_num':
        print(p['id'], p['number'])
        break
")
    [[ -z "$result" ]] && echo "No pipeline found for PR #$pr_num in your last 30 pipelines." && return 1
    pipeline_id=$(echo "$result" | awk '{print $1}')
    pipeline_num=$(echo "$result" | awk '{print $2}')
  else
    # No arg — fzf picker
    local picked
    picked=$(_ci_pick_pipeline "Pick a PR / pipeline to view workflows") || return 1
    pipeline_id=$(echo "$picked" | awk '{print $1}')
    pipeline_num=$(echo "$picked" | awk '{print $2}')
    pr_num=$(echo "$picked" | awk '{print $3}')
  fi

  [[ -n "$pr_num" ]] && echo "PR #$pr_num  →  Pipeline #$pipeline_num" || echo "Pipeline #$pipeline_num"
  ci-workflows --pipeline-id "$pipeline_id" --pipeline-num "$pipeline_num"
}

# ── ci-workflows — list workflows for a pipeline ─────────────────────────────
ci-workflows() {
  if [[ "$1" == "--help" ]]; then
    echo "  ci-workflows                  Pick a pipeline then browse its workflows"
    echo "  ci-workflows --pipeline-id ID  Show workflows for a specific pipeline"
    return
  fi

  local pipeline_id="" pipeline_num=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --pipeline-id) pipeline_id="$2"; shift 2 ;;
      --pipeline-num) pipeline_num="$2"; shift 2 ;;
      *) shift ;;
    esac
  done

  if [[ -z "$pipeline_id" ]]; then
    local picked
    picked=$(_ci_pick_pipeline "Pick a pipeline to view workflows") || return 1
    pipeline_id=$(echo "$picked" | awk '{print $1}')
    pipeline_num=$(echo "$picked" | awk '{print $2}')
  fi

  local label="${pipeline_num:+Pipeline #$pipeline_num}"

  local selected
  selected=$(_ci "$_CI_BASE/pipeline/$pipeline_id/workflow" | python3 -c "
import json, sys
data = json.load(sys.stdin)
icons = {'success':'✓','failed':'✗','failing':'✗','running':'●','on_hold':'⏸','canceled':'○'}
items = sorted(data.get('items',[]), key=lambda w: w.get('created_at',''))
for w in items:
    icon = icons.get(w['status'], '?')
    print(f\"{w['id']}|{icon} [{w['status']:<10}] {w['name']}\")
" | fzf \
    --delimiter='|' \
    --with-nth=2 \
    --header="$label workflows  (Enter → jobs)" \
    --preview='ci-jobs --workflow-id {1} 2>/dev/null' \
    --preview-window=right:55%:wrap:border-left \
    --ansi) || return 0

  local wf_id
  wf_id=$(echo "$selected" | cut -d'|' -f1)
  ci-jobs --workflow-id "$wf_id"
}

# ── ci-jobs — list jobs in a workflow ────────────────────────────────────────
ci-jobs() {
  if [[ "$1" == "--help" ]]; then
    echo "  ci-jobs                     Pick a workflow then browse its jobs"
    echo "  ci-jobs --workflow-id ID    Show jobs for a specific workflow"
    return
  fi

  local workflow_id=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --workflow-id) workflow_id="$2"; shift 2 ;;
      *) shift ;;
    esac
  done

  if [[ -z "$workflow_id" ]]; then
    echo "Usage: ci-jobs --workflow-id <id>  (or use ci-workflows to drill in)" >&2
    return 1
  fi

  local selected
  selected=$(_ci "$_CI_BASE/workflow/$workflow_id/job" | python3 -c "
import json, sys
data = json.load(sys.stdin)
icons = {'success':'✓','failed':'✗','infrastructure_fail':'✗','running':'●','on_hold':'⏸','canceled':'○','blocked':'⏸'}
for j in data.get('items', []):
    icon = icons.get(j['status'], '?')
    num  = j.get('job_number') or 'N/A'
    print(f\"{num}|{icon} [{j['status']:<22}] #{num:<6} {j['name']}\")
" | fzf \
    --delimiter='|' \
    --with-nth=2 \
    --header="Jobs (Enter → view logs)" \
    --preview='ci-logs --job-number {1} 2>/dev/null' \
    --preview-window=right:60%:wrap:border-left \
    --ansi) || return 0

  local job_num
  job_num=$(echo "$selected" | cut -d'|' -f1)
  ci-logs --job-number "$job_num"
}

# ── ci-logs — fetch failed step logs for a job ───────────────────────────────
ci-logs() {
  if [[ "$1" == "--help" ]]; then
    echo "  ci-logs <job-number>          Print failed step logs for a job"
    echo "  ci-logs --job-number <num>    Same, for piping from fzf"
    return
  fi

  local job_num=""
  if [[ "$1" == "--job-number" ]]; then
    job_num="$2"
  else
    job_num="$1"
  fi

  if [[ -z "$job_num" || "$job_num" == "N/A" ]]; then
    echo "No job number. Select a started/failed job." >&2
    return 1
  fi

  _ci_load_env || return 1

  # v1.1 API — use -s only (not -f) so we see the actual error response
  local v1_url="$_CI_V1/project/$_CI_PROJECT/$job_num"
  local http_code job_data
  job_data=$(curl -s -w "\n__HTTP_CODE__:%{http_code}" \
    -H "Circle-Token: $CIRCLECI_TOKEN" "$v1_url")
  http_code=$(echo "$job_data" | grep -o '__HTTP_CODE__:[0-9]*' | cut -d: -f2)
  job_data=$(echo "$job_data" | sed '/__HTTP_CODE__:/d')

  if [[ "$http_code" != "200" ]]; then
    echo "ci-logs: HTTP $http_code fetching job $job_num"
    echo "  URL: $v1_url"
    # Try to print any error message from the response
    echo "$job_data" | python3 -c "
import json, sys
try:
    d = json.load(sys.stdin)
    print(' ', d.get('message', d))
except:
    pass
" 2>/dev/null
    return 1
  fi

  # show job header
  echo "$job_data" | python3 -c "
import json, sys
d = json.load(sys.stdin)
print(f\"Job #{d.get('build_num')}  [{d.get('status')}]  {d.get('subject','')}\")
print(f\"Branch: {d.get('branch','?')}  Started: {(d.get('start_time') or '')[:16]}\")
print()
steps = d.get('steps', [])
failed = [(s,a) for s in steps for a in s.get('actions',[]) if a.get('failed')]
if not failed:
    print('No failed steps found.')
    sys.exit(0)
for s, a in failed:
    print(f\"FAILED STEP: {s['name']}\")
    print(f\"  exit_code:  {a.get('exit_code')}\")
    print(f\"  output_url: {a.get('output_url','')}\")
    print()
" 2>/dev/null

  # fetch and print output for each failed step
  echo "$job_data" | python3 -c "
import json, sys
d = json.load(sys.stdin)
for s in d.get('steps', []):
    for a in s.get('actions', []):
        if a.get('failed') and a.get('output_url'):
            print(a['output_url'])
" 2>/dev/null | while read -r url; do
    echo "──────────────────────────────────────────"
    curl -s "$url" | python3 -c "
import json, sys
try:
    msgs = json.load(sys.stdin)
    for m in msgs:
        print(m.get('message',''), end='')
except:
    sys.stdin.seek(0)
    print(sys.stdin.read())
" 2>/dev/null | tail -100
  done
}

# ── ci-diagnose — full failure diagnosis with fzf picker ─────────────────────
ci-diagnose() {
  if [[ "$1" == "--help" ]]; then
    echo "  ci-diagnose [pr-number]    Pick a PR (or supply number) → print all failure logs"
    return
  fi

  local pipeline_id pipeline_num pr_num

  if [[ -n "$1" ]]; then
    # PR number supplied — resolve to pipeline
    pr_num="$1"
    echo "Finding pipeline for PR #$pr_num..."
    local found
    found=$(_ci "$_CI_BASE/project/$_CI_PROJECT/pipeline/mine?limit=30" | python3 -c "
import json, sys
data = json.load(sys.stdin)
for p in data.get('items', []):
    if str((p.get('vcs') or {}).get('review_id', '')) == '$pr_num':
        print(p['id'], p['number'])
        break
")
    [[ -z "$found" ]] && echo "No pipeline found for PR #$pr_num." && return 1
    pipeline_id=$(echo "$found" | awk '{print $1}')
    pipeline_num=$(echo "$found" | awk '{print $2}')
  else
    # No arg — fzf picker
    local picked
    picked=$(_ci_pick_pipeline "Pick a PR / pipeline to diagnose") || return 1
    pipeline_id=$(echo "$picked" | awk '{print $1}')
    pipeline_num=$(echo "$picked" | awk '{print $2}')
    pr_num=$(echo "$picked" | awk '{print $3}')
  fi

  [[ -n "$pr_num" ]] && echo "PR #$pr_num  →  Pipeline #$pipeline_num" || echo "Pipeline #$pipeline_num"
  echo "URL: $_CI_WEB/$pipeline_num"
  echo ""

  local wf_data
  wf_data=$(_ci "$_CI_BASE/pipeline/$pipeline_id/workflow")

  echo "$wf_data" | python3 -c "
import json, sys
data = json.load(sys.stdin)
icons = {'success':'✓','failed':'✗','failing':'✗','running':'●','on_hold':'⏸','canceled':'○'}
for w in data.get('items', []):
    icon = icons.get(w['status'], '?')
    print(f'  {icon} [{w[\"status\"]:<10}] {w[\"name\"]}')
"
  echo ""

  local failed_wf_ids
  failed_wf_ids=$(echo "$wf_data" | python3 -c "
import json, sys
data = json.load(sys.stdin)
for w in data.get('items', []):
    if w['status'] in ('failed','failing','error'):
        print(w['id'], w['name'])
")
  [[ -z "$failed_wf_ids" ]] && echo "No failed workflows." && return 0

  echo "$failed_wf_ids" | while read -r wf_id wf_name; do
    echo "══ Failed workflow: $wf_name ══"
    local failed_jobs
    failed_jobs=$(_ci "$_CI_BASE/workflow/$wf_id/job" | python3 -c "
import json, sys
data = json.load(sys.stdin)
for j in data.get('items', []):
    if j['status'] in ('failed','infrastructure_fail'):
        print(j.get('job_number',''), j.get('name',''))
")
    [[ -z "$failed_jobs" ]] && echo "  (no failed jobs yet)" && continue

    echo "$failed_jobs" | while read -r job_num job_name; do
      echo ""
      echo "  ✗ Job: $job_name (#$job_num)"
      echo "  URL: $_CI_WEB/$pipeline_num/workflows/$wf_id/jobs/$job_num"
      echo ""
      ci-logs --job-number "$job_num" | sed 's/^/  /'
    done
  done
}

# ── ci-open — open pipeline/PR in browser ────────────────────────────────────
ci-open() {
  if [[ "$1" == "--help" ]]; then
    echo "  ci-open              Pick a pipeline and open it in the browser"
    echo "  ci-open <pr-number>  Open the pipeline for a specific PR"
    return
  fi

  local pipeline_num=""

  if [[ -n "$1" && "$1" =~ ^[0-9]+$ && "$1" -lt 100000 ]]; then
    # looks like a PR number — resolve first
    local found
    found=$(_ci "$_CI_BASE/project/$_CI_PROJECT/pipeline/mine?limit=30" | python3 -c "
import json, sys
data = json.load(sys.stdin)
for p in data.get('items', []):
    if str((p.get('vcs') or {}).get('review_id', '')) == '$1':
        print(p['number'])
        break
")
    pipeline_num="$found"
  fi

  if [[ -z "$pipeline_num" ]]; then
    local picked
    picked=$(_ci_pick_pipeline "Open in browser — pick pipeline") || return 1
    pipeline_num=$(echo "$picked" | awk '{print $2}')
  fi

  local url="$_CI_WEB/$pipeline_num"
  echo "Opening $url"
  open "$url"
}
