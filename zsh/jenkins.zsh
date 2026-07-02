#!/usr/bin/env zsh
# Jenkins CLI functions — requires ~/.config/gc-jenkins.env

# ─── internal helpers ────────────────────────────────────────────────────────

_jenkins_load_env() {
    local env_file="$HOME/.config/gc-jenkins.env"
    if [[ ! -f "$env_file" ]]; then
        printf "${COLOR_RED}Error: $env_file not found${COLOR_RESET}\n"
        return 1
    fi
    source "$env_file"
}

_jk() {
    # usage: _jk [--test] <curl args...>
    _jenkins_load_env || return 1
    local url="$JENKINS_URL"
    if [[ "$1" == "--test" ]]; then
        url="$JENKINS_TESTING_URL"
        shift
    fi
    curl -sk -g -u "$JENKINS_USER:$JENKINS_TOKEN" "$@"
}

_jenkins_url() {
    # usage: _jenkins_url [--test]
    _jenkins_load_env || return 1
    if [[ "$1" == "--test" ]]; then
        printf '%s' "$JENKINS_TESTING_URL"
    else
        printf '%s' "$JENKINS_URL"
    fi
}

_jenkins_to_path() {
    # convert "Folder/SubFolder/Job" → "job/Folder/job/SubFolder/job/Job"
    local job="$1"
    printf 'job/%s' "${job//\//\/job\/}"
}

_jenkins_crumb() {
    local base=$(_jenkins_url "$1")
    _jenkins_load_env || return 1
    curl -sk -g -u "$JENKINS_USER:$JENKINS_TOKEN" \
        "$base/crumbIssuer/api/json" \
    | python3 -c "import json,sys; d=json.load(sys.stdin); print(d['crumbRequestField']+':'+d['crumb'])" 2>/dev/null
}

_jenkins_fill_params() {
    local base="$1"
    local job_path="$2"
    _jenkins_load_env || return 1

    # one Python call: outputs one JSON line per param, HTML stripped, no newlines in values
    local param_lines=$(curl -sk -g -u "$JENKINS_USER:$JENKINS_TOKEN" \
        "$base/$job_path/api/json?tree=property[parameterDefinitions[name,type,defaultParameterValue[value],description,choices]]" \
    | python3 -c "
import json, sys, re

data = json.load(sys.stdin)
params = []
for prop in data.get('property', []):
    for p in prop.get('parameterDefinitions', []):
        params.append(p)

for p in params:
    default_obj = p.get('defaultParameterValue') or {}
    default = str(default_obj.get('value') or '')
    desc = re.sub(r'<[^>]+>', '', p.get('description', '') or '').strip().replace('\n', ' ')
    choices = p.get('choices', []) or []
    print(json.dumps({
        'name':    p.get('name', ''),
        'type':    p.get('type', ''),
        'default': default,
        'desc':    desc,
        'choices': choices,
    }))
" 2>/dev/null)

    [[ -z "$param_lines" ]] && return 0

    local count=$(printf '%s\n' "$param_lines" | python3 -c "import sys; print(sum(1 for l in sys.stdin if l.strip()))")
    printf "\n  ${COLOR_BOLD_WHITE}Parameters (%s):${COLOR_RESET}\n\n" "$count" >&2

    local filled_params=()

    while IFS= read -r line; do
        [[ -z "$line" ]] && continue

        local name=$(printf '%s' "$line"    | python3 -c "import json,sys; print(json.load(sys.stdin)['name'])")
        local ptype=$(printf '%s' "$line"   | python3 -c "import json,sys; print(json.load(sys.stdin)['type'])")
        local default=$(printf '%s' "$line" | python3 -c "import json,sys; print(json.load(sys.stdin)['default'])")
        local desc=$(printf '%s' "$line"    | python3 -c "import json,sys; print(json.load(sys.stdin)['desc'])")
        local choices_str=$(printf '%s' "$line" | python3 -c "import json,sys; print('|'.join(json.load(sys.stdin)['choices']))")

        [[ -n "$desc" ]] && printf "  ${COLOR_DIM}%s${COLOR_RESET}\n" "$desc" >&2
        printf "  ${COLOR_CYAN}%s${COLOR_RESET}  ${COLOR_DIM}[%s]${COLOR_RESET}" "$name" "$ptype" >&2
        [[ -n "$default" ]] && printf "  ${COLOR_DIM}(default: %s)${COLOR_RESET}" "$default" >&2
        printf "\n" >&2

        local value=""

        if [[ -n "$choices_str" ]]; then
            # put default first so it's pre-highlighted, then remaining choices
            local rest=$(printf '%s\n' "${choices_str//|/$'\n'}" | grep -vxF "$default")
            value=$(  { [[ -n "$default" ]] && printf '%s\n' "$default"; printf '%s\n' "$rest"; } | \
                fzf --prompt="  $name > " \
                    --height=30% \
                    --layout=reverse \
                    --border)
        else
            case "$ptype" in
                BooleanParameterDefinition)
                    value=$({ [[ -n "$default" ]] && printf '%s\n' "$default"; printf 'true\nfalse\n' | grep -vxF "$default"; } | \
                        fzf --prompt="  $name > " \
                            --height=5 \
                            --layout=reverse \
                            --border)
                    ;;
                PasswordParameterDefinition)
                    printf "  ${COLOR_DIM}value (hidden):${COLOR_RESET} " >&2
                    read -rs value < /dev/tty
                    printf "\n" >&2
                    ;;
                *)
                    printf "  ${COLOR_DIM}value [Enter for: %s]:${COLOR_RESET} " "$default" >&2
                    read -r value < /dev/tty
                    [[ -z "$value" ]] && value="$default"
                    ;;
            esac
        fi

        if [[ -n "$value" ]]; then
            filled_params+=("$name=$value")
            printf "  ${COLOR_GREEN}✓${COLOR_RESET} %s = ${COLOR_CYAN}%s${COLOR_RESET}\n\n" "$name" "$value" >&2
        else
            printf "  ${COLOR_YELLOW}⚠ %s skipped${COLOR_RESET}\n\n" "$name" >&2
        fi

    done <<< "$param_lines"

    printf '%s\n' "${filled_params[@]}"
}

_jenkins_all_jobs() {
    # returns newline-separated list of "path|color" for all jobs up to 3 levels deep
    local base="$1"
    _jenkins_load_env || return 1
    curl -sk -g -u "$JENKINS_USER:$JENKINS_TOKEN" \
        "$base/api/json?tree=jobs[name,color,jobs[name,color,jobs[name,color]]]" \
    | python3 -c "
import json, sys

def walk(jobs, prefix=''):
    for j in jobs:
        path = prefix + j['name'] if prefix else j['name']
        color = j.get('color', '')
        sub = j.get('jobs')
        if sub:
            walk(sub, path + '/')
        else:
            print(path + '|' + color)

data = json.load(sys.stdin)
walk(data.get('jobs', []))
" 2>/dev/null
}

_jenkins_status_icon() {
    local color="$1"
    case "$color" in
        blue)             printf "${COLOR_GREEN}✓${COLOR_RESET}" ;;
        blue_anime)       printf "${COLOR_CYAN}●${COLOR_RESET}" ;;
        red)              printf "${COLOR_RED}✗${COLOR_RESET}" ;;
        red_anime)        printf "${COLOR_RED}●${COLOR_RESET}" ;;
        yellow|aborted)   printf "${COLOR_YELLOW}!${COLOR_RESET}" ;;
        *)                printf "${COLOR_DIM}?${COLOR_RESET}" ;;
    esac
}

_jenkins_fzf_job() {
    local base="$1"
    local prompt="${2:-Select job}"

    printf "${COLOR_DIM}  Fetching job list...${COLOR_RESET}\n" >&2

    local jobs=$(_jenkins_all_jobs "$base")
    if [[ -z "$jobs" ]]; then
        printf "${COLOR_RED}Error: could not fetch job list${COLOR_RESET}\n" >&2
        return 1
    fi

    local selected=$(printf '%s\n' "$jobs" | \
        while IFS='|' read -r path color; do
            local icon=$(_jenkins_status_icon "$color")
            printf "%s  %s\n" "$icon" "$path"
        done | \
        fzf --ansi \
            --prompt="$prompt > " \
            --height=50% \
            --layout=reverse \
            --border \
            --no-sort)

    [[ -z "$selected" ]] && return 1
    # strip icon prefix
    awk '{print $NF}' <<< "$selected"
}

_jenkins_print_header() {
    local title="$1"
    printf "${COLOR_BOLD_CYAN}╔══════════════════════════════════════════════════╗${COLOR_RESET}\n"
    printf "${COLOR_BOLD_CYAN}║${COLOR_RESET}  ${COLOR_BOLD_WHITE}%-44s${COLOR_RESET}  ${COLOR_BOLD_CYAN}║${COLOR_RESET}\n" "$title"
    printf "${COLOR_BOLD_CYAN}╚══════════════════════════════════════════════════╝${COLOR_RESET}\n\n"
}

# ─── jenkins-jobs ─────────────────────────────────────────────────────────────

jenkins-jobs() {
    if [[ "$1" == "--help" ]]; then
        printf "  ${COLOR_CYAN}jenkins-jobs${COLOR_RESET} [--test]\n"
        printf "    List all Jenkins jobs with pass/fail status\n"
        printf "    ${COLOR_DIM}--test  Use testing Jenkins instance${COLOR_RESET}\n\n"
        return
    fi

    local flag=""
    [[ "$1" == "--test" ]] && flag="--test"
    local base=$(_jenkins_url $flag)

    _jenkins_print_header "Jenkins Jobs"

    _jenkins_all_jobs "$base" | \
    while IFS='|' read -r path color; do
        local icon=$(_jenkins_status_icon "$color")
        printf "  %s  %s\n" "$icon" "$path"
    done
    printf "\n"
}

# ─── jenkins-status ───────────────────────────────────────────────────────────

jenkins-status() {
    if [[ "$1" == "--help" ]]; then
        printf "  ${COLOR_CYAN}jenkins-status${COLOR_RESET} [job-path] [--test]\n"
        printf "    Show last build status for a job\n"
        printf "    ${COLOR_DIM}Example: jenkins-status Folder/MyJob${COLOR_RESET}\n\n"
        return
    fi

    local flag="" job=""
    for arg in "$@"; do
        [[ "$arg" == "--test" ]] && flag="--test" || job="$arg"
    done

    local base=$(_jenkins_url $flag)

    if [[ -z "$job" ]]; then
        job=$(_jenkins_fzf_job "$base" "Status for") || return 0
    fi

    local job_path=$(_jenkins_to_path "$job")

    printf "\n  ${COLOR_BOLD_WHITE}Job:${COLOR_RESET} %s\n" "$job"
    curl -sk -g -u "$JENKINS_USER:$JENKINS_TOKEN" \
        "$base/$job_path/lastBuild/api/json?tree=number,result,timestamp,duration,building,url" \
    | python3 -c "
import json, sys, datetime
d = json.load(sys.stdin)
ts = datetime.datetime.fromtimestamp(d['timestamp']/1000).strftime('%Y-%m-%d %H:%M:%S')
dur = d['duration'] // 1000
result = 'RUNNING' if d['building'] else d.get('result', 'UNKNOWN')
icons = {'SUCCESS': '✓', 'FAILURE': '✗', 'RUNNING': '●', 'ABORTED': '!'}
icon = icons.get(result, '?')
print(f'  {icon}  Build #{d[\"number\"]}  [{result}]')
print(f'     Time:     {ts}')
print(f'     Duration: {dur}s')
print(f'     URL:      {d[\"url\"]}')
" 2>/dev/null || printf "  ${COLOR_RED}Could not fetch build status${COLOR_RESET}\n"
    printf "\n"
}

# ─── jenkins-log ──────────────────────────────────────────────────────────────

jenkins-log() {
    if [[ "$1" == "--help" ]]; then
        printf "  ${COLOR_CYAN}jenkins-log${COLOR_RESET} [job-path] [build-number] [--test]\n"
        printf "    Tail console log of a build (default: lastBuild)\n"
        printf "    ${COLOR_DIM}Example: jenkins-log Folder/MyJob 42${COLOR_RESET}\n\n"
        return
    fi

    local flag="" job="" build="lastBuild"
    for arg in "$@"; do
        if [[ "$arg" == "--test" ]]; then
            flag="--test"
        elif [[ "$arg" =~ ^[0-9]+$ ]]; then
            build="$arg"
        else
            job="$arg"
        fi
    done

    local base=$(_jenkins_url $flag)
    _jenkins_load_env || return 1

    if [[ -z "$job" ]]; then
        job=$(_jenkins_fzf_job "$base" "View log for") || return 0
    fi

    local job_path=$(_jenkins_to_path "$job")

    printf "\n  ${COLOR_BOLD_WHITE}Job:${COLOR_RESET} %s  ${COLOR_DIM}build %s${COLOR_RESET}\n" "$job" "$build"
    printf "  ${COLOR_DIM}────────────────────────────────────────${COLOR_RESET}\n\n"

    curl -sk -g -u "$JENKINS_USER:$JENKINS_TOKEN" \
        "$base/$job_path/$build/consoleText" | tail -100
    printf "\n"
}

# ─── jenkins-trigger ──────────────────────────────────────────────────────────

jenkins-trigger() {
    if [[ "$1" == "--help" ]]; then
        printf "  ${COLOR_CYAN}jenkins-trigger${COLOR_RESET} [job-path] [--test] [KEY=value ...]\n"
        printf "    Trigger a Jenkins build, with optional parameters\n"
        printf "    ${COLOR_DIM}Example: jenkins-trigger Folder/MyJob BRANCH=main ENV=staging${COLOR_RESET}\n\n"
        return
    fi

    local flag="" job=""
    local -a params=()

    for arg in "$@"; do
        if [[ "$arg" == "--test" ]]; then
            flag="--test"
        elif [[ "$arg" == *=* ]]; then
            params+=("$arg")
        else
            job="$arg"
        fi
    done

    local base=$(_jenkins_url $flag)
    _jenkins_load_env || return 1

    if [[ -z "$job" ]]; then
        job=$(_jenkins_fzf_job "$base" "Trigger job") || return 0
        printf "\n  ${COLOR_BOLD_WHITE}Selected:${COLOR_RESET} %s\n" "$job"
    else
        printf "\n  ${COLOR_BOLD_WHITE}Job:${COLOR_RESET} %s\n" "$job"
    fi

    local job_path=$(_jenkins_to_path "$job")

    # if no params passed via CLI, interactively fill from job definition
    if [[ ${#params[@]} -eq 0 ]]; then
        local filled
        filled=$(_jenkins_fill_params "$base" "$job_path")
        while IFS= read -r line; do
            [[ -n "$line" ]] && params+=("$line")
        done <<< "$filled"
    fi

    # crumb is optional — some Jenkins instances have CSRF disabled
    local -a crumb_header=()
    local crumb=$(_jenkins_crumb $flag)
    [[ -n "$crumb" ]] && crumb_header=(-H "$crumb")

    local endpoint="build"
    local -a curl_params=()
    if [[ ${#params[@]} -gt 0 ]]; then
        endpoint="buildWithParameters"
        for p in "${params[@]}"; do
            curl_params+=(--data-urlencode "$p")
        done
    fi

    [[ ${#params[@]} -gt 0 ]] && printf "  ${COLOR_DIM}Params: %s${COLOR_RESET}\n" "${params[*]}"

    local http_code=$(curl -sk -g -o /dev/null -w "%{http_code}" \
        -X POST \
        -u "$JENKINS_USER:$JENKINS_TOKEN" \
        "${crumb_header[@]}" \
        "${curl_params[@]}" \
        "$base/$job_path/$endpoint")

    if [[ "$http_code" == "201" || "$http_code" == "200" ]]; then
        printf "  ${COLOR_GREEN}✓ Build triggered (HTTP $http_code)${COLOR_RESET}\n\n"
    else
        printf "  ${COLOR_RED}✗ Trigger failed (HTTP $http_code)${COLOR_RESET}\n\n"
        return 1
    fi
}

# ─── jenkins-watch ────────────────────────────────────────────────────────────

jenkins-watch() {
    if [[ "$1" == "--help" ]]; then
        printf "  ${COLOR_CYAN}jenkins-watch${COLOR_RESET} [job-path] [--test]\n"
        printf "    Poll last build until it finishes, then show result + log tail on failure\n"
        printf "    ${COLOR_DIM}Example: jenkins-watch Folder/MyJob${COLOR_RESET}\n\n"
        return
    fi

    local flag="" job=""
    for arg in "$@"; do
        [[ "$arg" == "--test" ]] && flag="--test" || job="$arg"
    done

    local base=$(_jenkins_url $flag)
    _jenkins_load_env || return 1

    if [[ -z "$job" ]]; then
        job=$(_jenkins_fzf_job "$base" "Watch job") || return 0
    fi

    local job_path=$(_jenkins_to_path "$job")

    printf "\n  ${COLOR_BOLD_WHITE}Job:${COLOR_RESET} %s\n  ${COLOR_DIM}Polling every 10s...${COLOR_RESET}\n\n" "$job"

    while true; do
        local data=$(curl -sk -g -u "$JENKINS_USER:$JENKINS_TOKEN" \
            "$base/$job_path/lastBuild/api/json?tree=number,result,building,timestamp,duration")

        local building=$(printf '%s' "$data" | python3 -c "import json,sys; print(json.load(sys.stdin)['building'])" 2>/dev/null)

        if [[ "$building" == "False" ]]; then
            printf '%s' "$data" | python3 -c "
import json, sys, datetime
d = json.load(sys.stdin)
ts = datetime.datetime.fromtimestamp(d['timestamp']/1000).strftime('%Y-%m-%d %H:%M:%S')
dur = d['duration'] // 1000
result = d.get('result', 'UNKNOWN')
icons = {'SUCCESS': '✓', 'FAILURE': '✗', 'ABORTED': '!'}
icon = icons.get(result, '?')
print(f'  {icon}  Build #{d[\"number\"]}  [{result}]  ({dur}s)  {ts}')
"
            local result=$(printf '%s' "$data" | python3 -c "import json,sys; print(json.load(sys.stdin).get('result',''))" 2>/dev/null)
            if [[ "$result" != "SUCCESS" ]]; then
                printf "\n  ${COLOR_DIM}Last 80 lines of console:${COLOR_RESET}\n"
                printf "  ${COLOR_DIM}────────────────────────────────────────${COLOR_RESET}\n\n"
                curl -sk -g -u "$JENKINS_USER:$JENKINS_TOKEN" \
                    "$base/$job_path/lastBuild/consoleText" | tail -80
            fi
            printf "\n"
            break
        fi

        local num=$(printf '%s' "$data" | python3 -c "import json,sys; print(json.load(sys.stdin)['number'])" 2>/dev/null)
        printf "  ${COLOR_DIM}●  Build #%s running...${COLOR_RESET}\r" "$num"
        sleep 10
    done
}

# ─── jenkins-open ─────────────────────────────────────────────────────────────

jenkins-open() {
    if [[ "$1" == "--help" ]]; then
        printf "  ${COLOR_CYAN}jenkins-open${COLOR_RESET} [job-path] [--test]\n"
        printf "    Open a Jenkins job in the browser\n"
        printf "    ${COLOR_DIM}Example: jenkins-open Folder/MyJob${COLOR_RESET}\n\n"
        return
    fi

    local flag="" job=""
    for arg in "$@"; do
        [[ "$arg" == "--test" ]] && flag="--test" || job="$arg"
    done

    local base=$(_jenkins_url $flag)

    if [[ -z "$job" ]]; then
        job=$(_jenkins_fzf_job "$base" "Open job") || return 0
    fi

    local job_path=$(_jenkins_to_path "$job")
    local url="$base/$job_path"
    open "$url"
    printf "${COLOR_DIM}Opening %s...${COLOR_RESET}\n" "$url"
}
