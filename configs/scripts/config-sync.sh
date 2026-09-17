#!/bin/bash
# Lightweight Config Sync - Updates config files without restarting services
# Run early in startup before dependent services start

set -euo pipefail

export UP_ROOT="${UP_ROOT:-/usr/local/share/up}"
SCRIPT_DIR="$UP_ROOT/configs/scripts"
source "$SCRIPT_DIR/theme-utils.sh"

# Config file location
CONFIG_FILE="$HOME/.config/up/config"
STATE_FILE="$HOME/.config/up-theme"

# Function to sync config settings to current state (files only, no service restarts)
sync_config_files() {
    if [ ! -f "$CONFIG_FILE" ]; then
        echo "Config file not found: $CONFIG_FILE"
        return 1
    fi

    echo "Syncing config files..."

    # Honor effects= / re-detect when machine fingerprint changes
    if [ -x "$SCRIPT_DIR/apply-compositor-profile.sh" ]; then
        "$SCRIPT_DIR/apply-compositor-profile.sh" --no-theme || true
    fi

    # Read current config values
    local config_theme
    config_theme=$(read_config "theme" | sed 's/^"//' | sed 's/"$//')

    # Files only — desktop-agent starts with the session and owns polybar/picom.
    # Never open the interactive picker on session start.
    #
    # apply_theme_if_changed returns 0 only when it just wrote a new theme.
    # Re-apply when ~/.config/up/config changed since the last successful
    # apply (logged-out font/fade edits). Skip the 1600-line switcher otherwise.
    local applied_hash_file="${XDG_STATE_HOME:-$HOME/.local/state}/up/desktop/config-applied.sha256"
    local current_hash="" applied_hash=""
    if [ -f "$CONFIG_FILE" ] && command -v sha256sum >/dev/null 2>&1; then
        current_hash=$(sha256sum "$CONFIG_FILE" 2>/dev/null | awk '{print $1}')
    fi
    if [ -f "$applied_hash_file" ]; then
        applied_hash=$(tr -d '[:space:]' <"$applied_hash_file" 2>/dev/null || true)
    fi

    if apply_theme_if_changed "$config_theme" "$STATE_FILE"; then
        echo "Theme files updated: $config_theme"
    elif [ -n "$current_hash" ] && [ "$current_hash" != "$applied_hash" ]; then
        echo "Config changed since last apply; re-writing theme files"
        if [ -x "$UP_ROOT/configs/scripts/switch-theme.sh" ]; then
            UP_DESKTOP_INLINE=1 \
                "$UP_ROOT/configs/scripts/switch-theme.sh" --reapply --no-reload >/dev/null 2>&1 || true
        fi
    else
        echo "Theme/config unchanged; skipping switch-theme"
    fi

    if [ -n "$current_hash" ]; then
        mkdir -p "$(dirname "$applied_hash_file")" 2>/dev/null || true
        # Re-hash: compositor apply may have rewritten fade/blur/dim.
        if command -v sha256sum >/dev/null 2>&1 && [ -f "$CONFIG_FILE" ]; then
            sha256sum "$CONFIG_FILE" 2>/dev/null | awk '{print $1}' >"$applied_hash_file" || true
        fi
    fi

    echo "Config file sync complete"
}

# Main function
main() {
    # Ensure config file exists
    if [ ! -f "$CONFIG_FILE" ]; then
        echo "Config file not found, skipping sync: $CONFIG_FILE"
        exit 0
    fi

    sync_config_files
}

main "$@"