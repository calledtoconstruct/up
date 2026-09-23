#!/bin/bash
# Flameshot 13+ uses the XDG screenshot portal. i3 on X11 has no portal
# backend, so capture fails until useX11LegacyScreenshot=true is set.
set -euo pipefail

echo "=== Migration 002: flameshot legacy X11 capture ==="

UP_ROOT="${UP_ROOT:-/usr/local/share/up}"
shot="$UP_ROOT/configs/scripts/screenshot.sh"
desktop_src="$UP_ROOT/configs/local/share/applications/capture.desktop"

for user_home in /home/*; do
    [ -d "$user_home" ] || continue
    username=$(basename "$user_home")
    case "$username" in
        lost+found) continue ;;
    esac
    id "$username" >/dev/null 2>&1 || continue

    if [ -x "$shot" ]; then
        HOME="$user_home" "$shot" --ensure-config
        chown -R "$username:$username" "$user_home/.config/flameshot" 2>/dev/null || true
        echo "flameshot.ini updated for $username"
    fi

    if [ -f "$desktop_src" ]; then
        mkdir -p "$user_home/.local/share/applications"
        cp "$desktop_src" "$user_home/.local/share/applications/capture.desktop"
        chown "$username:$username" "$user_home/.local/share/applications/capture.desktop" 2>/dev/null || true
        chmod 644 "$user_home/.local/share/applications/capture.desktop" 2>/dev/null || true
    fi
done
