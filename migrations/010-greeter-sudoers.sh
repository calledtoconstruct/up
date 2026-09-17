#!/bin/bash
# Allow group up to set the LightDM wallpaper without a password.

set -euo pipefail

echo "=== Migration 010: greeter background sudoers ==="

UP_ROOT="${UP_ROOT:-/usr/local/share/up}"
SRC="$UP_ROOT/configs/sudoers/up-greeter"
HELPER="$UP_ROOT/bin/up-set-greeter-background"

if [ -f "$SRC" ]; then
    install -m 440 "$SRC" /etc/sudoers.d/up-greeter
    echo "→ /etc/sudoers.d/up-greeter"
fi

if [ -x "$HELPER" ]; then
    ln -sfn "$HELPER" /usr/local/bin/up-set-greeter-background
    chmod +x "$HELPER"
fi

groupadd -f up 2>/dev/null || true
install -d -m 775 -o root -g up /usr/share/backgrounds/up
if [ -f /etc/lightdm/lightdm-gtk-greeter.conf ]; then
    chown root:up /etc/lightdm/lightdm-gtk-greeter.conf
    chmod 664 /etc/lightdm/lightdm-gtk-greeter.conf
fi

# Apply the current wallpaper now (root) so the next greeter is correct
if [ -x "$HELPER" ]; then
    for user_home in /home/*; do
        [ -s "$user_home/.config/up-background" ] || continue
        bg=$(tr -d '\n' <"$user_home/.config/up-background")
        if [ -f "$bg" ]; then
            "$HELPER" "$bg" || true
            echo "→ Installed greeter wallpaper from $user_home"
            break
        fi
    done
fi

echo "=== Migration 010 complete ==="
