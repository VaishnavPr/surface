#!/usr/bin/env zsh
# Jira CLI functions — requires ~/.config/gc-jira.env

# ─── internal helpers ────────────────────────────────────────────────────────

_jira_load_env() {
    local env_file="$HOME/.config/gc-jira.env"
    if [[ ! -f "$env_file" ]]; then
        printf "${COLOR_RED}Error: $env_file not found${COLOR_RESET}\n"
        return 1
    fi
    source "$env_file"
}

_jira_search() {
    local jql="$1"
    local max="${2:-30}"
    _jira_load_env || return 1
    local auth=$(echo -n "$JIRA_EMAIL:$JIRA_TOKEN" | base64 | tr -d '\n')
    curl -s --compressed -G \
        -H "Authorization: Basic $auth" \
        -H "Accept: application/json" \
        --data-urlencode "jql=$jql" \
        --data-urlencode "fields=summary,status,priority,issuetype,updated" \
        --data-urlencode "maxResults=$max" \
        "$JIRA_BASE_URL/rest/api/3/search/jql" \
    | tr -d '\000-\010\013-\037'
}

_jira_get() {
    local key="$1"
    _jira_load_env || return 1
    local auth=$(echo -n "$JIRA_EMAIL:$JIRA_TOKEN" | base64 | tr -d '\n')
    curl -s --compressed \
        -H "Authorization: Basic $auth" \
        -H "Accept: application/json" \
        "$JIRA_BASE_URL/rest/api/3/issue/$key" \
    | tr -d '\000-\010\013-\037'
}

_jira_status_color() {
    local jstatus="$1"
    case "${jstatus:l}" in
        "in progress"|"in review") printf "${COLOR_CYAN}" ;;
        "done"|"closed"|"resolved") printf "${COLOR_GREEN}" ;;
        "blocked") printf "${COLOR_RED}" ;;
        *) printf "${COLOR_YELLOW}" ;;
    esac
}

_jira_print_header() {
    local title="$1"
    local count="$2"
    printf "${COLOR_BOLD_CYAN}╔══════════════════════════════════════════════════╗${COLOR_RESET}\n"
    printf "${COLOR_BOLD_CYAN}║${COLOR_RESET}  ${COLOR_BOLD_WHITE}%-44s${COLOR_RESET}  ${COLOR_BOLD_CYAN}║${COLOR_RESET}\n" "$title"
    printf "${COLOR_BOLD_CYAN}╚══════════════════════════════════════════════════╝${COLOR_RESET}\n"
    printf "  ${COLOR_DIM}%s tickets${COLOR_RESET}\n\n" "$count"
}

_jira_print_issues() {
    local json="$1"

    local error=$(printf '%s\n' "$json" | jq -r '.errorMessages[0] // empty' 2>/dev/null)
    if [[ -n "$error" ]]; then
        printf "${COLOR_RED}Error: $error${COLOR_RESET}\n"
        return 1
    fi

    local count=$(printf '%s\n' "$json" | jq '.issues | length')

    if [[ "$count" == "0" ]]; then
        printf "${COLOR_DIM}  No tickets found${COLOR_RESET}\n"
        return
    fi

    printf "  ${COLOR_BOLD_WHITE}%-12s %-16s %-10s  %s${COLOR_RESET}\n" "KEY" "STATUS" "PRIORITY" "SUMMARY"
    printf "  ${COLOR_DIM}%s${COLOR_RESET}\n" "────────────────────────────────────────────────────────────────────────────────"

    printf '%s\n' "$json" | jq -r '.issues[] | [.key, .fields.status.name, .fields.priority.name, .fields.summary] | @tsv' | \
    while IFS=$'\t' read -r key jstatus priority summary; do
        local sc=$(_jira_status_color "$jstatus")
        local trunc="${summary:0:70}"
        [[ ${#summary} -gt 70 ]] && trunc="${trunc}…"
        printf "  ${COLOR_BOLD_WHITE}%-12s${COLOR_RESET} ${sc}%-16s${COLOR_RESET} ${COLOR_DIM}%-10s${COLOR_RESET}  %s\n" \
            "$key" "$jstatus" "$priority" "$trunc"
    done
    printf "\n"
}

_jira_fzf_pick() {
    local jql="$1"
    local prompt="${2:-Select ticket}"
    local result=$(_jira_search "$jql" 50)

    local error=$(printf '%s\n' "$result" | jq -r '.errorMessages[0] // empty' 2>/dev/null)
    if [[ -n "$error" ]]; then
        printf "${COLOR_RED}Error: $error${COLOR_RESET}\n"
        return 1
    fi

    local selected=$(printf '%s\n' "$result" | \
        jq -r '.issues[] | [.key, .fields.status.name, .fields.priority.name, .fields.summary] | @tsv' | \
        while IFS=$'\t' read -r k s p sum; do
            printf "%-12s  %-16s  %-10s  %s\n" "$k" "$s" "$p" "$sum"
        done | \
        fzf --ansi \
            --prompt="$prompt > " \
            --height=40% \
            --layout=reverse \
            --border \
            --header="$(printf '%-12s  %-16s  %-10s  %s' KEY STATUS PRIORITY SUMMARY)" \
            --no-sort)

    [[ -z "$selected" ]] && return 1
    awk '{print $1}' <<< "$selected"
}

_jira_slug() {
    printf '%s' "${1:l}" | \
        sed 's/[^a-z0-9 -]//g' | \
        sed 's/  */ /g' | \
        tr ' ' '-' | \
        sed 's/-\+/-/g' | \
        cut -c1-50 | \
        sed 's/-$//'
}

_jira_ai_branch_suggestions() {
    local key="$1"
    local summary="$2"

    [[ -z "$ANTHROPIC_FOUNDRY_API_KEY" || -z "$ANTHROPIC_FOUNDRY_BASE_URL" ]] && return 1

    local prompt="Generate exactly 5 git branch name suggestions for a Jira ticket.
Ticket: $key
Summary: $summary
Format: each must start with vpratap/${key}- followed by a short kebab-case slug.
Rules: lowercase only, hyphens only, max 60 chars total per branch name, no explanation, one branch name per line, nothing else."

    local payload=$(jq -n --arg p "$prompt" '{
        model: "claude-haiku-4-5-20251001",
        max_tokens: 200,
        messages: [{"role": "user", "content": $p}]
    }')

    curl -s \
        -H "Authorization: Bearer $ANTHROPIC_FOUNDRY_API_KEY" \
        -H "anthropic-version: 2023-06-01" \
        -H "Content-Type: application/json" \
        -H "user-id: vpratap_prod" \
        -d "$payload" \
        "$ANTHROPIC_FOUNDRY_BASE_URL/v1/messages" \
    | jq -r '.content[0].text // ""' \
    | grep -o "vpratap/${key}-[a-z0-9-]*"
}

# ─── jira-tickets ────────────────────────────────────────────────────────────

jira-tickets() {
    if [[ "$1" == "--help" ]]; then
        printf "  ${COLOR_CYAN}jira-tickets${COLOR_RESET}\n"
        printf "    Show all open tickets assigned to you\n\n"
        return
    fi

    local jql='assignee = currentUser() AND statusCategory != Done ORDER BY updated DESC'
    local result=$(_jira_search "$jql")
    local total=$(printf '%s\n' "$result" | jq '.total // 0')
    _jira_print_header "My Jira Tickets" "$total"
    _jira_print_issues "$result"
}

# ─── jira-all ────────────────────────────────────────────────────────────────

jira-all() {
    if [[ "$1" == "--help" ]]; then
        printf "  ${COLOR_CYAN}jira-all${COLOR_RESET}\n"
        printf "    Show every ticket ever assigned to you, including closed ones\n\n"
        return
    fi

    local jql='assignee = currentUser() ORDER BY updated DESC'
    local result=$(_jira_search "$jql" 100)
    local total=$(printf '%s\n' "$result" | jq '.total // 0')
    _jira_print_header "All My Tickets" "$total"
    _jira_print_issues "$result"
}

# ─── jira-view ───────────────────────────────────────────────────────────────

jira-view() {
    if [[ "$1" == "--help" ]]; then
        printf "  ${COLOR_CYAN}jira-view${COLOR_RESET} [ticket-key]\n"
        printf "    Show details of a Jira ticket\n"
        printf "    ${COLOR_DIM}Without a key, opens an interactive selector${COLOR_RESET}\n"
        printf "    ${COLOR_DIM}Example: jira-view GC-12345${COLOR_RESET}\n\n"
        return
    fi

    local key="$1"

    if [[ -z "$key" ]]; then
        local jql='assignee = currentUser() AND statusCategory != Done ORDER BY updated DESC'
        key=$(_jira_fzf_pick "$jql" "View ticket") || return 0
    fi

    key="${key:u}"
    local json=$(_jira_get "$key")

    local error=$(printf '%s\n' "$json" | jq -r '.errorMessages[0] // empty' 2>/dev/null)
    if [[ -n "$error" ]]; then
        printf "${COLOR_RED}Error: $error${COLOR_RESET}\n"
        return 1
    fi

    local summary=$(printf '%s\n' "$json"   | jq -r '.fields.summary // "-"')
    local jstatus=$(printf '%s\n' "$json"   | jq -r '.fields.status.name // "-"')
    local priority=$(printf '%s\n' "$json"  | jq -r '.fields.priority.name // "-"')
    local issuetype=$(printf '%s\n' "$json" | jq -r '.fields.issuetype.name // "-"')
    local assignee=$(printf '%s\n' "$json"  | jq -r '.fields.assignee.displayName // "Unassigned"')
    local reporter=$(printf '%s\n' "$json"  | jq -r '.fields.reporter.displayName // "-"')
    local updated=$(printf '%s\n' "$json"   | jq -r '.fields.updated[:10] // "-"')
    local desc=$(printf '%s\n' "$json" | jq -r '
        .fields.description.content[]?
        | select(.type == "paragraph")
        | .content[]?
        | select(.type == "text")
        | .text' 2>/dev/null | head -5)

    local sc=$(_jira_status_color "$jstatus")

    _jira_load_env
    printf "\n  ${COLOR_BOLD_WHITE}%s${COLOR_RESET}  ${COLOR_DIM}[%s]${COLOR_RESET}\n\n" "$key" "$issuetype"
    printf "  ${COLOR_BOLD_WHITE}%s${COLOR_RESET}\n\n" "$summary"
    printf "  ${COLOR_DIM}Status:${COLOR_RESET}   ${sc}%s${COLOR_RESET}\n" "$jstatus"
    printf "  ${COLOR_DIM}Priority:${COLOR_RESET} ${COLOR_YELLOW}%s${COLOR_RESET}\n" "$priority"
    printf "  ${COLOR_DIM}Assignee:${COLOR_RESET} %s\n" "$assignee"
    printf "  ${COLOR_DIM}Reporter:${COLOR_RESET} %s\n" "$reporter"
    printf "  ${COLOR_DIM}Updated:${COLOR_RESET}  %s\n" "$updated"

    if [[ -n "$desc" ]]; then
        printf "\n  ${COLOR_DIM}Description:${COLOR_RESET}\n"
        printf "%s\n" "$desc" | fold -s -w 80 | while IFS= read -r line; do
            printf "    %s\n" "$line"
        done
    fi

    printf "\n  ${COLOR_DIM}%s/browse/%s${COLOR_RESET}\n\n" "$JIRA_BASE_URL" "$key"
}

# ─── jira-open ───────────────────────────────────────────────────────────────

jira-open() {
    if [[ "$1" == "--help" || -z "$1" ]]; then
        printf "  ${COLOR_CYAN}jira-open${COLOR_RESET} <ticket-key>\n"
        printf "    Open a Jira ticket in the browser\n"
        printf "    ${COLOR_DIM}Example: jira-open GC-12345${COLOR_RESET}\n\n"
        return
    fi

    local key="${1:u}"
    _jira_load_env || return 1
    open "$JIRA_BASE_URL/browse/$key"
    printf "${COLOR_DIM}Opening %s/browse/%s...${COLOR_RESET}\n" "$JIRA_BASE_URL" "$key"
}

# ─── jira-start ──────────────────────────────────────────────────────────────

jira-start() {
    if [[ "$1" == "--help" ]]; then
        printf "  ${COLOR_CYAN}jira-start${COLOR_RESET}\n"
        printf "    Pick a ticket and create a git branch for it\n"
        printf "    ${COLOR_DIM}Branch format: vpratap/GC-XXXXX-slug${COLOR_RESET}\n\n"
        return
    fi

    if ! git rev-parse --git-dir &>/dev/null; then
        printf "${COLOR_RED}Error: not inside a git repository${COLOR_RESET}\n"
        return 1
    fi

    # ── pick ticket ──────────────────────────────────────────────────────────
    local jql='assignee = currentUser() AND statusCategory != Done ORDER BY updated DESC'
    local key=$(_jira_fzf_pick "$jql" "Start branch for") || return 0

    # ── pick base branch ─────────────────────────────────────────────────────
    local base=$(git branch | sed 's/^[* ]*//' | \
        fzf --prompt="Base branch > " \
            --height=40% \
            --layout=reverse \
            --border \
            --header="Which branch to checkout from?" \
            --query="master")

    [[ -z "$base" ]] && return 0

    # ── fetch + pull base branch ─────────────────────────────────────────────
    printf "\n  ${COLOR_CYAN}git fetch origin${COLOR_RESET}\n"
    git fetch origin

    printf "  ${COLOR_CYAN}git checkout %s${COLOR_RESET}\n" "$base"
    git checkout "$base"

    printf "  ${COLOR_CYAN}git pull origin %s${COLOR_RESET}\n\n" "$base"
    git pull origin "$base"

    # ── build branch name suggestions ────────────────────────────────────────
    local json=$(_jira_get "$key")
    local summary=$(printf '%s\n' "$json" | jq -r '.fields.summary // ""')

    printf "  ${COLOR_DIM}Asking Claude for branch name suggestions...${COLOR_RESET}\n"
    local ai_suggestions=$(_jira_ai_branch_suggestions "$key" "$summary")

    # always include the local slug as a fallback
    local fallback="vpratap/${key}-$(_jira_slug "$summary")"
    local all_suggestions=$(printf '%s\n%s\n' "$ai_suggestions" "$fallback" | grep -v '^$' | awk '!seen[$0]++')

    # build fzf list: available first, existing last with marker
    local available=() existing_marked=()
    while IFS= read -r candidate; do
        if git branch | grep -q "^[* ]*${candidate}$"; then
            existing_marked+=("${candidate}  (already exists)")
        else
            available+=("$candidate")
        fi
    done <<< "$all_suggestions"

    local branch=$(printf '%s\n' "${available[@]}" "${existing_marked[@]}" | grep -v '^$' | \
        fzf --prompt="Branch name > " \
            --height=40% \
            --layout=reverse \
            --border \
            --header="Select or Esc to type manually" \
            --no-sort)

    if [[ -z "$branch" ]]; then
        printf "  ${COLOR_DIM}Branch name:${COLOR_RESET} "
        read -r branch
        [[ -z "$branch" ]] && return 0
    fi

    # strip the marker if user picked an existing branch
    branch="${branch%%  (already exists)}"

    if git branch | grep -q "^[* ]*${branch}$"; then
        printf "${COLOR_YELLOW}Branch already exists, checking it out instead${COLOR_RESET}\n"
        git checkout "$branch"
        return
    fi

    printf "\n  ${COLOR_CYAN}git checkout -b %s${COLOR_RESET}\n\n" "$branch"
    git checkout -b "$branch"
}

# ─── jira-sprint ─────────────────────────────────────────────────────────────

jira-sprint() {
    if [[ "$1" == "--help" ]]; then
        printf "  ${COLOR_CYAN}jira-sprint${COLOR_RESET}\n"
        printf "    Show all tickets in the current active sprint assigned to you\n\n"
        return
    fi

    local jql='assignee = currentUser() AND sprint in openSprints() ORDER BY status ASC, updated DESC'
    local result=$(_jira_search "$jql" 50)
    local total=$(printf '%s\n' "$result" | jq '.total // 0')
    _jira_print_header "Current Sprint" "$total"
    _jira_print_issues "$result"
}
