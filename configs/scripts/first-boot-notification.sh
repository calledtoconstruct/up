#!/bin/bash
# First Boot Experience
# Shows welcome info once; offers quickstart and surfaces install report issues

set -euo pipefail

FLAG_FILE="$HOME/.config/up/first-boot-shown"
UP_ROOT="${UP_ROOT:-/usr/local/share/up}"

if [ -f "$FLAG_FILE" ]; then
    exit 0
fi

# Wait briefly for dunst / desktop to settle (flag already checked above)
sleep 0.4

# Surface install report failures if present
if [ -f /var/log/up/install-report.txt ]; then
    if grep -qE 'FAILED_|failed' /var/log/up/install-report.txt 2>/dev/null; then
        notify-send -u normal -t 15000 \
            "Install completed with warnings" \
            "See /var/log/up/install-report.txt for packages/services that need attention." 2>/dev/null || true
    fi
fi

# WiFi hint if disconnected
if command -v nmcli >/dev/null 2>&1; then
    if ! nmcli -t -f STATE g 2>/dev/null | grep -qi connected; then
        notify-send -u normal -t 12000 \
            "Network" \
            "Not connected. Press Super+Ctrl+W for WiFi, or run nmtui." 2>/dev/null || true
    fi
fi

# Welcome notification
if command -v dunstify >/dev/null 2>&1; then
    action=$(dunstify -u critical -t 0 \
        -A "dismiss=Dismiss" \
        -A "quickstart=Quick Start" \
        -A "keybindings=Keybindings" \
        "Welcome to Up Linux!" \
        "Essential shortcuts:
📋 System Menu: Super+Alt+Space
💻 Terminal: Super+Return
🌐 Browser: Super+Shift+B
⌨️ Keybindings: Super+Shift+K

Run up-quickstart or open the system menu to explore." 2>/dev/null || echo "dismiss")

    case "$action" in
        quickstart)
            if command -v up-quickstart >/dev/null 2>&1; then
                up-quickstart &
            fi
            ;;
        keybindings)
            if command -v up-show-keybindings >/dev/null 2>&1; then
                up-show-keybindings &
            fi
            ;;
    esac
else
    notify-send -u critical -t 30000 \
        "Welcome to Up Linux!" \
        "System Menu: Super+Alt+Space
Terminal: Super+Return
Run: up-quickstart" 2>/dev/null || true
fi

mkdir -p "$(dirname "$FLAG_FILE")"
touch "$FLAG_FILE"
