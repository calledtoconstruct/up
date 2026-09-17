#!/bin/bash
# Load background on i3 startup
# Uses shared theme-utils.sh for background discovery

set -euo pipefail

export UP_ROOT="${UP_ROOT:-/usr/local/share/up}"

# Get script directory and source utilities
SCRIPT_DIR="$UP_ROOT/configs/scripts"
source "$SCRIPT_DIR/theme-utils.sh"

STATE_FILE="$HOME/.config/up-theme"
BG_STATE_FILE="$HOME/.config/up-background"

# Session curtain owns the root pixmap until i3/keybindings are ready
if [ -f "${XDG_STATE_HOME:-$HOME/.local/state}/up/session-curtain/active" ]; then
    exit 0
fi

# Check if we have a saved background from a theme switch
if [ -f "$BG_STATE_FILE" ]; then
    bg_path=$(cat "$BG_STATE_FILE")
    if [ -n "$bg_path" ] && [ -f "$bg_path" ]; then
        feh --bg-fill --no-fehbg "$bg_path" 2>/dev/null || true
        exit 0
    fi
fi

# Fallback: try to load based on current theme
if [ -f "$STATE_FILE" ]; then
    theme=$(cat "$STATE_FILE")
    bg_path=$(find_background "$theme")
    if [ -n "$bg_path" ] && [ -f "$bg_path" ]; then
        feh --bg-fill --no-fehbg "$bg_path" 2>/dev/null || true
        exit 0
    fi
fi

# Final fallback: use find_background with no theme (returns archlinux default)
bg_path=$(find_background "")
if [ -n "$bg_path" ] && [ -f "$bg_path" ]; then
    feh --bg-fill --no-fehbg "$bg_path" 2>/dev/null || true
fi