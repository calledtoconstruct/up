#!/bin/bash
# Quick Start guide for Up Linux
# Usage: up-quickstart  (via bin/up-quickstart)

set -euo pipefail

export UP_ROOT="${UP_ROOT:-/usr/local/share/up}"

show_help() {
    cat << 'EOF'
Up Linux Quick Start
====================

Essential shortcuts
  Super + Space          System menu
  Super + Alt + Space    Application launcher (rofi)
  Super + Return         Terminal (Alacritty)
  Super + Shift + B      Web browser
  Super + Shift + G      Theme switcher
  Super + Shift + K      Show keybindings
  Super + Ctrl + R       Restart i3

First steps
  1. Connect to WiFi (if needed):
       Super + Ctrl + W   or   nmtui
  2. Open the system menu:
       Super + Space
  3. Browse keybindings:
       up-show-keybindings
  4. Change theme:
       up-switch-theme
  5. Install extra software:
       up-pkg-install

Help
  up-help                 General help topics
  up-help keybindings     Keyboard shortcuts
  up-help themes          Theme system
  up-help packages        Package installer
  up-help troubleshooting Common fixes

Updates
  Prefer:  up-update   (or System Menu → Update)
  Avoid:   raw pacman -Syu without migrations

Logs
  Install log:  /var/log/up/install.log
  Install report: /var/log/up/install-report.txt (if present)

EOF
}

# Interactive menu when rofi is available and DISPLAY is set
if [ -n "${DISPLAY:-}" ] && command -v rofi >/dev/null 2>&1; then
    choice=$(printf '%s\n' \
        "📖 Show quick start guide" \
        "⌨️  Show keybindings" \
        "📶 WiFi settings" \
        "🎨 Switch theme" \
        "📦 Install packages" \
        "❓ Help system" \
        "Cancel" | rofi -dmenu -i -p "Quick Start" -lines 7 -kb-cancel Escape || true)

    case "$choice" in
        *guide*)
            show_help | less -R
            ;;
        *keybindings*)
            if command -v up-show-keybindings >/dev/null 2>&1; then
                up-show-keybindings
            else
                show_help
            fi
            ;;
        *WiFi*)
            if command -v nmtui >/dev/null 2>&1; then
                alacritty -e nmtui 2>/dev/null || nmtui
            else
                notify-send "WiFi" "Open Network Manager applet or run: nmtui" 2>/dev/null || true
            fi
            ;;
        *theme*)
            up-switch-theme 2>/dev/null || true
            ;;
        *packages*)
            up-pkg-install 2>/dev/null || true
            ;;
        *Help*)
            up-help 2>/dev/null || show_help | less -R
            ;;
        *)
            exit 0
            ;;
    esac
else
    show_help
fi
