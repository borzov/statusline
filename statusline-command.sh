#!/bin/bash
set -f

input=$(cat)

if [ -z "$input" ]; then
    printf "Claude"
    exit 0
fi

CACHE_DIR="/tmp/claude"
mkdir -p "$CACHE_DIR"

# ── Colors ──────────────────────────────────────────────
blue='\033[38;2;0;153;255m'
orange='\033[38;2;255;176;85m'
green='\033[38;2;0;175;80m'
cyan='\033[38;2;86;182;194m'
red='\033[38;2;255;85;85m'
yellow='\033[38;2;230;200;0m'
white='\033[38;2;220;220;220m'
magenta='\033[38;2;180;140;255m'
dim='\033[2m'
reset='\033[0m'

sep=" ${dim}│${reset} "

# ── Helpers ─────────────────────────────────────────────
format_tokens() {
    local num=$1
    if [ "$num" -ge 1000000 ]; then
        awk "BEGIN {printf \"%.1fm\", $num / 1000000}"
    elif [ "$num" -ge 1000 ]; then
        awk "BEGIN {printf \"%.0fk\", $num / 1000}"
    else
        printf "%d" "$num"
    fi
}

color_for_pct() {
    local pct=$1
    if [ "$pct" -ge 90 ]; then printf "%s" "$red"
    elif [ "$pct" -ge 70 ]; then printf "%s" "$yellow"
    elif [ "$pct" -ge 50 ]; then printf "%s" "$orange"
    else printf "%s" "$green"
    fi
}

build_bar() {
    local pct=$1
    local width=$2
    [[ "$pct" =~ ^-?[0-9]+$ ]] || pct=0
    (( pct < 0 )) && pct=0
    (( pct > 100 )) && pct=100

    local filled=$(( pct * width / 100 ))
    local empty=$(( width - filled ))
    local bar_color
    bar_color=$(color_for_pct "$pct")

    local filled_str="" empty_str=""
    for ((i=0; i<filled; i++)); do filled_str+="●"; done
    for ((i=0; i<empty; i++)); do empty_str+="○"; done

    printf "${bar_color}${filled_str}${dim}${empty_str}${reset}"
}

iso_to_epoch() {
    local iso_str="$1"

    local epoch
    epoch=$(date -d "${iso_str}" +%s 2>/dev/null)
    if [ -n "$epoch" ]; then
        echo "$epoch"
        return 0
    fi

    local stripped="${iso_str%%.*}"
    stripped="${stripped%%Z}"
    stripped="${stripped%%+*}"
    stripped="${stripped%%-[0-9][0-9]:[0-9][0-9]}"

    if [[ "$iso_str" == *"Z"* ]] || [[ "$iso_str" == *"+00:00"* ]] || [[ "$iso_str" == *"-00:00"* ]]; then
        epoch=$(env TZ=UTC date -j -f "%Y-%m-%dT%H:%M:%S" "$stripped" +%s 2>/dev/null)
    else
        epoch=$(date -j -f "%Y-%m-%dT%H:%M:%S" "$stripped" +%s 2>/dev/null)
    fi

    if [ -n "$epoch" ]; then
        echo "$epoch"
        return 0
    fi

    return 1
}

format_reset_compact() {
    local iso_str="$1"
    local window="$2"
    [ -z "$iso_str" ] || [ "$iso_str" = "null" ] && return

    local epoch
    epoch=$(iso_to_epoch "$iso_str")
    [ -z "$epoch" ] && return

    local result=""
    case "$window" in
        five_hour)
            result=$(date -j -r "$epoch" +"%H:%M" 2>/dev/null)
            [ -z "$result" ] && result=$(date -d "@$epoch" +"%H:%M" 2>/dev/null)
            ;;
        seven_day)
            result=$(date -j -r "$epoch" +"%a %H:%M" 2>/dev/null | tr '[:upper:]' '[:lower:]')
            [ -z "$result" ] && result=$(date -d "@$epoch" +"%a %H:%M" 2>/dev/null | tr '[:upper:]' '[:lower:]')
            ;;
    esac
    printf "%s" "$result"
}

# ── OAuth credentials blob (read once per render) ──────
_oauth_blob_cache=""
_oauth_blob_loaded=0

read_oauth_blob() {
    if [ "$_oauth_blob_loaded" = "1" ]; then
        printf "%s" "$_oauth_blob_cache"
        return 0
    fi
    _oauth_blob_loaded=1

    if command -v security >/dev/null 2>&1; then
        _oauth_blob_cache=$(security find-generic-password -s "Claude Code-credentials" -w 2>/dev/null)
    fi

    if [ -z "$_oauth_blob_cache" ] && [ -f "${HOME}/.claude/.credentials.json" ]; then
        _oauth_blob_cache=$(cat "${HOME}/.claude/.credentials.json" 2>/dev/null)
    fi

    printf "%s" "$_oauth_blob_cache"
}

# ── OAuth token resolution ─────────────────────────────
get_oauth_token() {
    if [ -n "$CLAUDE_CODE_OAUTH_TOKEN" ]; then
        echo "$CLAUDE_CODE_OAUTH_TOKEN"
        return 0
    fi

    local blob
    blob=$(read_oauth_blob)
    if [ -n "$blob" ]; then
        local token
        token=$(echo "$blob" | jq -r '.claudeAiOauth.accessToken // empty' 2>/dev/null)
        if [ -n "$token" ] && [ "$token" != "null" ]; then
            echo "$token"
            return 0
        fi
    fi

    echo ""
}

# ── Subscription info (cached) ─────────────────────────
get_subscription_info() {
    local auth_cache="${CACHE_DIR}/statusline-auth-cache.json"
    local auth_cache_max_age=60

    if [ -f "$auth_cache" ]; then
        local cache_mtime
        cache_mtime=$(stat -c %Y "$auth_cache" 2>/dev/null || stat -f %m "$auth_cache" 2>/dev/null)
        local now
        now=$(date +%s)
        local cache_age=$(( now - cache_mtime ))
        if [ "$cache_age" -lt "$auth_cache_max_age" ]; then
            cat "$auth_cache"
            return 0
        fi
    fi

    local sub_type="" rate_tier=""
    local blob
    blob=$(read_oauth_blob)
    if [ -n "$blob" ]; then
        IFS=$'\t' read -r sub_type rate_tier < <(echo "$blob" | jq -r '
            [.claudeAiOauth.subscriptionType // "",
             .claudeAiOauth.rateLimitTier // ""] | @tsv' 2>/dev/null)
    fi

    local result
    result=$(jq -n --arg st "${sub_type}" --arg rt "${rate_tier}" '{subscriptionType: $st, rateLimitTier: $rt}')
    echo "$result" > "$auth_cache"
    echo "$result"
}

# ── Extract JSON data (single jq pass) ─────────────────
# Compatible with macOS system bash 3.2 (no mapfile).
fields=()
while IFS= read -r line; do
    fields+=("$line")
done < <(echo "$input" | jq -r '
  [
    (.model.display_name // "Claude"),
    (.context_window.context_window_size | tonumber? // 200000),
    (.context_window.current_usage.input_tokens | tonumber? // 0),
    (.context_window.current_usage.cache_creation_input_tokens | tonumber? // 0),
    (.context_window.current_usage.cache_read_input_tokens | tonumber? // 0),
    (.cost.total_cost_usd // ""),
    (.cwd // ""),
    (.session.start_time // ""),
    (.worktree.name // ""),
    ((.rate_limits != null) | tostring),
    (.rate_limits // {} | tojson)
  ] | .[]
' 2>/dev/null)

model_name="${fields[0]:-Claude}"
size="${fields[1]:-200000}"
input_tokens="${fields[2]:-0}"
cache_create="${fields[3]:-0}"
cache_read="${fields[4]:-0}"
total_cost="${fields[5]:-}"
cwd="${fields[6]:-}"
session_start="${fields[7]:-}"
worktree_name="${fields[8]:-}"
has_native_rl="${fields[9]:-false}"
native_rl_json="${fields[10]:-{}}"

[ "$size" -eq 0 ] && size=200000
current=$(( input_tokens + cache_create + cache_read ))

used_tokens=$(format_tokens "$current")
total_tokens=$(format_tokens "$size")
pct_used=$(( current * 100 / size ))

effort="default"
settings_path="$HOME/.claude/settings.json"
if [ -f "$settings_path" ]; then
    effort=$(jq -r '.effortLevel // "default"' "$settings_path" 2>/dev/null)
fi

# ── Subscription / API mode ────────────────────────────
sub_info=$(get_subscription_info)
IFS=$'\t' read -r sub_type rate_tier < <(echo "$sub_info" | jq -r '
    [.subscriptionType // "", .rateLimitTier // ""] | @tsv')

is_subscription=false
sub_display=""
if [ -n "$sub_type" ] && [ "$sub_type" != "null" ]; then
    is_subscription=true
    # Capitalize first letter (bash 3.2 compatible — uses awk)
    sub_display=$(awk -v s="$sub_type" 'BEGIN {print toupper(substr(s,1,1)) tolower(substr(s,2))}')
    # Extract tier multiplier (e.g., "5x" from "default_claude_max_5x")
    if [ -n "$rate_tier" ] && [ "$rate_tier" != "null" ] && [[ "$rate_tier" =~ ([0-9]+x) ]]; then
        sub_display="${sub_display} ${BASH_REMATCH[1]}"
    fi
fi

# ── LINE 1 ─────────────────────────────────────────────
pct_color=$(color_for_pct "$pct_used")
if [ -z "$cwd" ] || [ "$cwd" = "null" ]; then
    cwd=$(pwd)
fi
dirname=$(basename "$cwd")

git_branch=""
git_staged=0
git_modified=0
if git -C "$cwd" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    git_branch=$(git -C "$cwd" symbolic-ref --short HEAD 2>/dev/null)
    git_staged=$(git -C "$cwd" diff --cached --numstat 2>/dev/null | wc -l | tr -d ' ')
    git_modified=$(git -C "$cwd" diff --numstat 2>/dev/null | wc -l | tr -d ' ')
fi

session_duration=""
if [ -n "$session_start" ] && [ "$session_start" != "null" ]; then
    start_epoch=$(iso_to_epoch "$session_start")
    if [ -n "$start_epoch" ]; then
        now_epoch=$(date +%s)
        elapsed=$(( now_epoch - start_epoch ))
        if [ "$elapsed" -ge 3600 ]; then
            session_duration="$(( elapsed / 3600 ))h$(( (elapsed % 3600) / 60 ))m"
        elif [ "$elapsed" -ge 60 ]; then
            session_duration="$(( elapsed / 60 ))m"
        else
            session_duration="${elapsed}s"
        fi
    fi
fi

# Build line 1
line1="${blue}${model_name}${reset}"
line1+="${sep}"
line1+="✍️ ${pct_color}${used_tokens}/${total_tokens} ${pct_used}%${reset}"
line1+="${sep}"

# Directory or worktree
if [ -n "$worktree_name" ] && [ "$worktree_name" != "null" ]; then
    line1+="${magenta}⎇ ${worktree_name}${reset}"
else
    line1+="${cyan}${dirname}${reset}"
fi

# Git branch + stats
if [ -n "$git_branch" ]; then
    line1+=" ${green}(${git_branch})${reset}"
fi
if [ "$git_staged" -gt 0 ]; then
    line1+=" ${green}+${git_staged}${reset}"
fi
if [ "$git_modified" -gt 0 ]; then
    line1+=" ${yellow}~${git_modified}${reset}"
fi

# Session duration
if [ -n "$session_duration" ]; then
    line1+="${sep}"
    line1+="${dim}⏱ ${reset}${white}${session_duration}${reset}"
fi

# Subscription or cost
line1+="${sep}"
if $is_subscription; then
    line1+="${green}${sub_display}${reset}"
else
    # API mode — show cost
    if [ -n "$total_cost" ] && [ "$total_cost" != "null" ]; then
        cost_display=$(awk "BEGIN { printf \"%.2f\", $total_cost }")
        line1+="${orange}\$${cost_display}${reset}"
    else
        line1+="${dim}API${reset}"
    fi
fi

# Effort
line1+="${sep}"
case "$effort" in
    high)   line1+="${magenta}● ${effort}${reset}" ;;
    medium) line1+="${dim}◑ ${effort}${reset}" ;;
    low)    line1+="${dim}◔ ${effort}${reset}" ;;
    *)      line1+="${dim}◑ ${effort}${reset}" ;;
esac

# ── Rate limits: hybrid data (native % + API resets_at) ─
bar_width=5
rl_sep=" ${dim}│${reset} "
rate_line=""

# Fetch API data for resets_at (cached)
api_cache="/tmp/claude/statusline-usage-cache.json"
api_cache_max_age=60
mkdir -p /tmp/claude

api_data=""
needs_api_refresh=true

if [ -f "$api_cache" ]; then
    cache_mtime=$(stat -c %Y "$api_cache" 2>/dev/null || stat -f %m "$api_cache" 2>/dev/null)
    now=$(date +%s)
    cache_age=$(( now - cache_mtime ))
    if [ "$cache_age" -lt "$api_cache_max_age" ]; then
        needs_api_refresh=false
        api_data=$(cat "$api_cache" 2>/dev/null)
    fi
fi

if $needs_api_refresh; then
    token=$(get_oauth_token)
    if [ -n "$token" ] && [ "$token" != "null" ]; then
        response=$(curl -s --max-time 3 \
            -H "Accept: application/json" \
            -H "Content-Type: application/json" \
            -H "Authorization: Bearer $token" \
            -H "anthropic-beta: oauth-2025-04-20" \
            -H "User-Agent: claude-code/2.1.34" \
            "https://api.anthropic.com/api/oauth/usage" 2>/dev/null)
        if [ -n "$response" ] && echo "$response" | jq -e '.five_hour' >/dev/null 2>&1; then
            api_data="$response"
            echo "$response" > "$api_cache"
        fi
    fi
    if [ -z "$api_data" ] && [ -f "$api_cache" ]; then
        api_data=$(cat "$api_cache" 2>/dev/null)
    fi
fi

# Helper: build a rate limit segment with hybrid data.
# Native % preferred, API resets_at always, API as full fallback if native is null.
# Reads from $native_rl_json (extracted upfront) and $api_data (cached).
build_rl_segment() {
    local label="$1"
    local key="$2"
    local window="$3"

    local native_pct=""
    if [ "$has_native_rl" = "true" ]; then
        native_pct=$(echo "$native_rl_json" | jq -r --arg k "$key" '
            .[$k] // null |
            if . == null then ""
            elif .used_percentage != null then (.used_percentage | floor)
            elif .utilization != null then (.utilization | floor)
            else "" end' 2>/dev/null)
    fi

    local api_pct="" api_reset=""
    if [ -n "$api_data" ]; then
        IFS=$'\t' read -r api_pct api_reset < <(echo "$api_data" | jq -r --arg k "$key" '
            .[$k] // null |
            if . == null then "\t"
            else "\((.utilization // 0) | floor)\t\(.resets_at // "")"
            end' 2>/dev/null)
    fi

    local pct="${native_pct:-$api_pct}"
    [ -z "$pct" ] && return 1

    local bar pct_color pct_fmt reset_str
    bar=$(build_bar "$pct" "$bar_width")
    pct_color=$(color_for_pct "$pct")
    pct_fmt=$(printf "%3d" "$pct")
    reset_str=$(format_reset_compact "$api_reset" "$window")

    local segment="${white}${label}${reset} ${bar} ${pct_color}${pct_fmt}%${reset}"
    if [ -n "$reset_str" ]; then
        segment+=" ${dim}⟳  ${reset}${white}${reset_str}${reset}"
    fi

    printf "%s" "$segment"
    return 0
}

if [ "$has_native_rl" = "true" ] || [ -n "$api_data" ]; then
    for entry in "current:five_hour:five_hour" \
                 "weekly:seven_day:seven_day" \
                 "sonnet:seven_day_sonnet:seven_day"; do
        IFS=':' read -r label key window <<<"$entry"
        seg=$(build_rl_segment "$label" "$key" "$window")
        if [ -n "$seg" ]; then
            [ -n "$rate_line" ] && rate_line+="$rl_sep"
            rate_line+="$seg"
        fi
    done
fi

# ── Extra usage (separate line) ─────────────────────────
extra_line=""
extra_src=""
if [ "$has_native_rl" = "true" ]; then
    extra_src="$native_rl_json"
elif [ -n "$api_data" ]; then
    extra_src="$api_data"
fi

if [ -n "$extra_src" ]; then
    IFS=$'\t' read -r extra_enabled extra_pct extra_used_cents extra_limit_cents \
        < <(echo "$extra_src" | jq -r '
            [(.extra_usage.is_enabled // false | tostring),
             ((.extra_usage.utilization // 0) | floor),
             (.extra_usage.used_credits // 0),
             (.extra_usage.monthly_limit // 0)] | @tsv' 2>/dev/null)
    if [ "$extra_enabled" = "true" ]; then
        extra_used=$(awk "BEGIN {printf \"%.2f\", $extra_used_cents / 100}")
        extra_limit=$(awk "BEGIN {printf \"%.2f\", $extra_limit_cents / 100}")
        extra_bar=$(build_bar "$extra_pct" "$bar_width")
        extra_pct_color=$(color_for_pct "$extra_pct")

        extra_reset=$(date -v+1m -v1d +"%b %-d" 2>/dev/null | tr '[:upper:]' '[:lower:]')
        if [ -z "$extra_reset" ]; then
            extra_reset=$(date -d "$(date +%Y-%m-01) +1 month" +"%b %-d" 2>/dev/null | tr '[:upper:]' '[:lower:]')
        fi

        extra_line="${white}extra${reset}   ${extra_bar} ${extra_pct_color}\$${extra_used}${dim}/${reset}${white}\$${extra_limit}${reset} ${dim}⟳ ${reset} ${white}${extra_reset}${reset}"
    fi
fi

# ── Output ──────────────────────────────────────────────
printf "%b" "$line1"
[ -n "$rate_line" ] && printf "\n%b" "$rate_line"
[ -n "$extra_line" ] && printf "\n%b" "$extra_line"

exit 0
