#!/bin/bash
set -f

input=$(cat)

if [ -z "$input" ]; then
    printf "Claude"
    exit 0
fi

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
    if [ "$pct" -ge 90 ]; then printf "$red"
    elif [ "$pct" -ge 70 ]; then printf "$yellow"
    elif [ "$pct" -ge 50 ]; then printf "$orange"
    else printf "$green"
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
    local auth_cache="/tmp/claude/statusline-auth-cache.json"
    local auth_cache_max_age=60
    mkdir -p /tmp/claude

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
        sub_type=$(echo "$blob" | jq -r '.claudeAiOauth.subscriptionType // empty' 2>/dev/null)
        rate_tier=$(echo "$blob" | jq -r '.claudeAiOauth.rateLimitTier // empty' 2>/dev/null)
    fi

    local result
    result=$(jq -n --arg st "${sub_type}" --arg rt "${rate_tier}" '{subscriptionType: $st, rateLimitTier: $rt}')
    echo "$result" > "$auth_cache"
    echo "$result"
}

# ── Extract JSON data ───────────────────────────────────
model_name=$(echo "$input" | jq -r '.model.display_name // "Claude"')

size=$(echo "$input" | jq -r '.context_window.context_window_size // 200000')
[[ "$size" =~ ^[0-9]+$ ]] || size=200000
[ "$size" -eq 0 ] && size=200000

input_tokens=$(echo "$input" | jq -r '.context_window.current_usage.input_tokens // 0')
cache_create=$(echo "$input" | jq -r '.context_window.current_usage.cache_creation_input_tokens // 0')
cache_read=$(echo "$input" | jq -r '.context_window.current_usage.cache_read_input_tokens // 0')
[[ "$input_tokens" =~ ^[0-9]+$ ]] || input_tokens=0
[[ "$cache_create" =~ ^[0-9]+$ ]] || cache_create=0
[[ "$cache_read" =~ ^[0-9]+$ ]] || cache_read=0
current=$(( input_tokens + cache_create + cache_read ))

used_tokens=$(format_tokens $current)
total_tokens=$(format_tokens $size)

if [ "$size" -gt 0 ]; then
    pct_used=$(( current * 100 / size ))
else
    pct_used=0
fi

effort="default"
settings_path="$HOME/.claude/settings.json"
if [ -f "$settings_path" ]; then
    effort=$(jq -r '.effortLevel // "default"' "$settings_path" 2>/dev/null)
fi

total_cost=$(echo "$input" | jq -r '.cost.total_cost_usd // empty')

# ── Subscription / API mode ────────────────────────────
sub_info=$(get_subscription_info)
sub_type=$(echo "$sub_info" | jq -r '.subscriptionType // empty')
rate_tier=$(echo "$sub_info" | jq -r '.rateLimitTier // empty')

is_subscription=false
sub_display=""
if [ -n "$sub_type" ] && [ "$sub_type" != "null" ] && [ "$sub_type" != "" ]; then
    is_subscription=true
    # Capitalize first letter
    sub_display=$(echo "$sub_type" | awk '{print toupper(substr($0,1,1)) tolower(substr($0,2))}')
    # Extract tier multiplier (e.g., "5x" from "default_claude_max_5x")
    if [ -n "$rate_tier" ] && [ "$rate_tier" != "null" ]; then
        tier_mult=$(echo "$rate_tier" | grep -o '[0-9]\+x' | tail -1)
        if [ -n "$tier_mult" ]; then
            sub_display="${sub_display} ${tier_mult}"
        fi
    fi
fi

# ── Worktree ───────────────────────────────────────────
worktree_name=$(echo "$input" | jq -r '.worktree.name // empty')

# ── LINE 1 ─────────────────────────────────────────────
pct_color=$(color_for_pct "$pct_used")
cwd=$(echo "$input" | jq -r '.cwd // ""')
[ -z "$cwd" ] || [ "$cwd" = "null" ] && cwd=$(pwd)
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
session_start=$(echo "$input" | jq -r '.session.start_time // empty')
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

# Helper: build a rate limit segment with hybrid data
# Native % preferred, API resets_at always, API as full fallback if native is null
build_rl_segment() {
    local label="$1"
    local native_path="$2"
    local api_field="$3"
    local window="$4"

    local pct="" reset_iso=""

    # Try native data for pct (utilization only — resets_at comes from API)
    local native_exists
    native_exists=$(echo "$input" | jq -r "${native_path} // empty" 2>/dev/null)
    if [ -n "$native_exists" ] && [ "$native_exists" != "null" ]; then
        pct=$(echo "$input" | jq -r "${native_path}.used_percentage // ${native_path}.utilization // empty" 2>/dev/null | awk '{printf "%.0f", $1}')
    fi

    # API: authoritative source for resets_at; fallback for pct if native missing
    if [ -n "$api_data" ]; then
        local api_exists
        api_exists=$(echo "$api_data" | jq -r ".${api_field} // empty" 2>/dev/null)
        if [ -n "$api_exists" ] && [ "$api_exists" != "null" ]; then
            reset_iso=$(echo "$api_data" | jq -r ".${api_field}.resets_at // empty")
            if [ -z "$pct" ] || [ "$pct" = "0" -a -z "$native_exists" ]; then
                pct=$(echo "$api_data" | jq -r ".${api_field}.utilization // 0" | awk '{printf "%.0f", $1}')
            fi
        fi
    fi

    [ -z "$pct" ] && return 1

    local bar pct_color pct_fmt reset_str
    bar=$(build_bar "$pct" "$bar_width")
    pct_color=$(color_for_pct "$pct")
    pct_fmt=$(printf "%3d" "$pct")
    reset_str=$(format_reset_compact "$reset_iso" "$window")

    local segment="${white}${label}${reset} ${bar} ${pct_color}${pct_fmt}%${reset}"
    if [ -n "$reset_str" ]; then
        segment+=" ${dim}⟳  ${reset}${white}${reset_str}${reset}"
    fi

    printf "%s" "$segment"
    return 0
}

# Check if we have any rate limit data at all
has_native_rl=$(echo "$input" | jq -r '.rate_limits // empty')
has_any_rl=false
if [ -n "$has_native_rl" ] && [ "$has_native_rl" != "null" ]; then
    has_any_rl=true
elif [ -n "$api_data" ]; then
    has_any_rl=true
fi

if $has_any_rl; then
    # Build current (five_hour)
    seg=$(build_rl_segment "current" ".rate_limits.five_hour" "five_hour" "five_hour")
    if [ -n "$seg" ]; then
        rate_line+="$seg"
    fi

    # Build weekly (seven_day)
    seg=$(build_rl_segment "weekly" ".rate_limits.seven_day" "seven_day" "seven_day")
    if [ -n "$seg" ]; then
        [ -n "$rate_line" ] && rate_line+="$rl_sep"
        rate_line+="$seg"
    fi

    # Build sonnet (seven_day_sonnet) — only if data exists
    seg=$(build_rl_segment "sonnet" ".rate_limits.seven_day_sonnet" "seven_day_sonnet" "seven_day")
    if [ -n "$seg" ]; then
        [ -n "$rate_line" ] && rate_line+="$rl_sep"
        rate_line+="$seg"
    fi

fi

# ── Extra usage (separate line) ─────────────────────────
extra_line=""
extra_src=""
if [ -n "$has_native_rl" ] && [ "$has_native_rl" != "null" ]; then
    extra_src="$input"
    extra_prefix=".rate_limits"
elif [ -n "$api_data" ]; then
    extra_src="$api_data"
    extra_prefix=""
fi

if [ -n "$extra_src" ]; then
    extra_enabled=$(echo "$extra_src" | jq -r "${extra_prefix}.extra_usage.is_enabled // false" 2>/dev/null)
    if [ "$extra_enabled" = "true" ]; then
        extra_pct=$(echo "$extra_src" | jq -r "${extra_prefix}.extra_usage.utilization // 0" | awk '{printf "%.0f", $1}')
        extra_used=$(echo "$extra_src" | jq -r "${extra_prefix}.extra_usage.used_credits // 0" | awk '{printf "%.2f", $1/100}')
        extra_limit=$(echo "$extra_src" | jq -r "${extra_prefix}.extra_usage.monthly_limit // 0" | awk '{printf "%.2f", $1/100}')
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
