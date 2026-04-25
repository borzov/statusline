#!/usr/bin/env bash
# Statusline installer for Claude Code.
# Usage:
#   ./install.sh            # symlink (recommended for dev) + patch settings.json
#   ./install.sh --copy     # copy file instead of symlink
#   ./install.sh --no-config  # don't touch settings.json
#   ./install.sh --uninstall  # remove file and revert settings.json
set -euo pipefail

MODE="link"
PATCH_CONFIG=1
ACTION="install"

for arg in "$@"; do
    case "$arg" in
        --copy) MODE="copy" ;;
        --link) MODE="link" ;;
        --no-config) PATCH_CONFIG=0 ;;
        --uninstall) ACTION="uninstall" ;;
        --help|-h)
            sed -n '2,8p' "$0" | sed 's/^# \{0,1\}//'
            exit 0 ;;
        *)
            echo "Unknown argument: $arg" >&2
            exit 1 ;;
    esac
done

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$REPO_DIR/statusline-command.sh"
DEST_DIR="$HOME/.claude"
DEST="$DEST_DIR/statusline-command.sh"
SETTINGS="$DEST_DIR/settings.json"

backup_existing() {
    local target="$1"
    if [ -e "$target" ] || [ -L "$target" ]; then
        local backup="${target}.bak.$(date +%s)"
        mv "$target" "$backup"
        echo "  backed up → $backup"
    fi
}

check_dependencies() {
    local missing=()
    for dep in jq curl bash; do
        if ! command -v "$dep" >/dev/null 2>&1; then
            missing+=("$dep")
        fi
    done
    if [ ${#missing[@]} -gt 0 ]; then
        echo "WARNING: missing dependencies: ${missing[*]}" >&2
        echo "  install with: brew install ${missing[*]}" >&2
    fi
}

if [ "$ACTION" = "uninstall" ]; then
    if [ -e "$DEST" ] || [ -L "$DEST" ]; then
        rm "$DEST"
        echo "Removed $DEST"
    fi
    if [ -f "$SETTINGS" ] && command -v jq >/dev/null 2>&1; then
        installed_cmd=$(jq -r '.statusLine.command // empty' "$SETTINGS" 2>/dev/null)
        if [[ "$installed_cmd" == *"statusline-command.sh"* ]]; then
            backup="${SETTINGS}.bak.$(date +%s)"
            cp "$SETTINGS" "$backup"
            jq 'del(.statusLine)' "$SETTINGS" > "${SETTINGS}.tmp" && mv "${SETTINGS}.tmp" "$SETTINGS"
            echo "Removed statusLine from $SETTINGS (backup: $backup)"
        fi
    fi
    echo "Uninstalled. Restart Claude Code."
    exit 0
fi

if [ ! -f "$SRC" ]; then
    echo "ERROR: $SRC not found" >&2
    exit 1
fi

mkdir -p "$DEST_DIR"

echo "Installing statusline → $DEST"
backup_existing "$DEST"

if [ "$MODE" = "link" ]; then
    ln -s "$SRC" "$DEST"
    echo "  symlinked → $SRC"
else
    cp "$SRC" "$DEST"
    chmod +x "$DEST"
    echo "  copied"
fi

check_dependencies

if [ "$PATCH_CONFIG" = "1" ]; then
    if ! command -v jq >/dev/null 2>&1; then
        echo "Skipping settings.json patch (jq not installed)."
        echo "Add this to $SETTINGS manually:"
        echo '  "statusLine": { "type": "command", "command": "bash '"$DEST"'" }'
    else
        target_cmd="bash $DEST"
        if [ -f "$SETTINGS" ]; then
            current=$(jq -r '.statusLine.command // empty' "$SETTINGS" 2>/dev/null)
            if [ "$current" = "$target_cmd" ]; then
                echo "settings.json already configured."
            else
                backup="${SETTINGS}.bak.$(date +%s)"
                cp "$SETTINGS" "$backup"
                jq --arg cmd "$target_cmd" '.statusLine = {type: "command", command: $cmd}' "$SETTINGS" > "${SETTINGS}.tmp" \
                    && mv "${SETTINGS}.tmp" "$SETTINGS"
                echo "Updated $SETTINGS (backup: $backup)"
            fi
        else
            cat > "$SETTINGS" <<EOF
{
  "statusLine": {
    "type": "command",
    "command": "$target_cmd"
  }
}
EOF
            echo "Created $SETTINGS"
        fi
    fi
fi

echo
echo "Done. Restart Claude Code to see the new statusline."
