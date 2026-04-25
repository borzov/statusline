#!/usr/bin/env bash
# Regenerate README screenshots using `freeze`.
# Requires: jq, freeze (brew install charmbracelet/tap/freeze).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
OUT="$ROOT/docs/screenshots"
SCRIPT="$ROOT/statusline-command.sh"

mkdir -p "$OUT" /tmp/claude

if ! command -v freeze >/dev/null 2>&1; then
    echo "ERROR: freeze not installed. Run: brew install charmbracelet/tap/freeze" >&2
    exit 1
fi

NOW=$(date +%s)
RESET_5H=$(date -u -r $((NOW + 14400)) +"%Y-%m-%dT%H:%M:%S.000000+00:00")
RESET_7D=$(date -u -r $((NOW + 432000)) +"%Y-%m-%dT%H:%M:%S.000000+00:00")
SESSION_START=$(date -u -r $((NOW - 1500)) +"%Y-%m-%dT%H:%M:%SZ")

cat > /tmp/claude/statusline-auth-cache.json <<EOF
{"subscriptionType":"max","rateLimitTier":"default_claude_max_20x"}
EOF
touch /tmp/claude/statusline-auth-cache.json

render() {
    local input_json="$1"
    local out_png="$2"
    local ansi_file="$OUT/.tmp.ansi"

    echo "$input_json" | bash "$SCRIPT" > "$ansi_file"

    freeze --execute "cat $ansi_file" \
        -o "$out_png" \
        --window \
        --shadow.blur 18 --shadow.x 0 --shadow.y 10 \
        --padding "30,40" --margin 24 \
        --background "#1a1b26" \
        --border.radius 10 \
        --font.family "JetBrains Mono" \
        --font.size 14 \
        --width 1280

    rm -f "$ansi_file"
    echo "  → $out_png"
}

# Scenario 1: hero / typical session
cat > /tmp/claude/statusline-usage-cache.json <<EOF
{
  "five_hour": {"utilization": 23.0, "resets_at": "$RESET_5H"},
  "seven_day": {"utilization": 41.0, "resets_at": "$RESET_7D"},
  "seven_day_sonnet": {"utilization": 28.0, "resets_at": "$RESET_7D"},
  "extra_usage": null
}
EOF
touch /tmp/claude/statusline-usage-cache.json

INPUT_HERO=$(jq -n --arg ts "$SESSION_START" --arg cwd "$HOME/projects/statusline" '{
  model: {display_name: "Sonnet 4.6"},
  context_window: {
    context_window_size: 200000,
    current_usage: {input_tokens: 8000, cache_creation_input_tokens: 12000, cache_read_input_tokens: 35000}
  },
  cwd: $cwd,
  session: {start_time: $ts}
}')

echo "Rendering hero..."
render "$INPUT_HERO" "$OUT/hero.png"

# Scenario 2: with extra_usage
cat > /tmp/claude/statusline-usage-cache.json <<EOF
{
  "five_hour": {"utilization": 67.0, "resets_at": "$RESET_5H"},
  "seven_day": {"utilization": 78.0, "resets_at": "$RESET_7D"},
  "seven_day_sonnet": {"utilization": 71.0, "resets_at": "$RESET_7D"},
  "extra_usage": {"is_enabled": true, "monthly_limit": 10000, "used_credits": 4250, "utilization": 42.5, "currency": "USD"}
}
EOF
touch /tmp/claude/statusline-usage-cache.json

INPUT_EXTRA=$(jq -n --arg ts "$SESSION_START" --arg cwd "$HOME/projects/myproject" '{
  model: {display_name: "Opus 4.7"},
  context_window: {
    context_window_size: 200000,
    current_usage: {input_tokens: 35000, cache_creation_input_tokens: 18000, cache_read_input_tokens: 75000}
  },
  cwd: $cwd,
  session: {start_time: $ts}
}')

echo "Rendering extra-usage..."
render "$INPUT_EXTRA" "$OUT/extra-usage.png"

# Scenario 3: high-pressure / API mode (no subscription, shows cost)
rm -f /tmp/claude/statusline-auth-cache.json
cat > /tmp/claude/statusline-auth-cache.json <<EOF
{"subscriptionType":"","rateLimitTier":""}
EOF
touch /tmp/claude/statusline-auth-cache.json

cat > /tmp/claude/statusline-usage-cache.json <<EOF
{
  "five_hour": {"utilization": 92.0, "resets_at": "$RESET_5H"},
  "seven_day": {"utilization": 88.0, "resets_at": "$RESET_7D"},
  "seven_day_sonnet": {"utilization": 95.0, "resets_at": "$RESET_7D"},
  "extra_usage": null
}
EOF
touch /tmp/claude/statusline-usage-cache.json

INPUT_API=$(jq -n --arg ts "$SESSION_START" --arg cwd "$HOME/projects/myproject" '{
  model: {display_name: "Sonnet 4.6"},
  context_window: {
    context_window_size: 200000,
    current_usage: {input_tokens: 95000, cache_creation_input_tokens: 12000, cache_read_input_tokens: 65000}
  },
  cwd: $cwd,
  session: {start_time: $ts},
  cost: {total_cost_usd: 3.42}
}')

echo "Rendering api-mode..."
render "$INPUT_API" "$OUT/api-mode.png"

echo "Done. Screenshots in $OUT/"
