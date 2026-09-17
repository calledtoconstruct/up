#!/bin/bash
# Greeter reads /etc/lightdm/lightdm-gtk-greeter.conf (not conf.d).
# Make that file and a world-readable wallpaper drop-in writable by group up.

set -euo pipefail

echo "=== Migration 009: LightDM greeter background ==="

groupadd -f up 2>/dev/null || true
install -d -m 775 -o root -g up /usr/share/backgrounds/up

GREETER="/etc/lightdm/lightdm-gtk-greeter.conf"
if [ -f "$GREETER" ]; then
    chown root:up "$GREETER"
    chmod 664 "$GREETER"
    echo "→ $GREETER is root:up 664"
fi

THEME_CONF="/etc/lightdm/lightdm-gtk-greeter.conf.d/theme.conf"
if [ -f "$THEME_CONF" ]; then
    chown root:up "$THEME_CONF"
    chmod 664 "$THEME_CONF"
fi

# Push the current user's chosen wallpaper into the greeter if we can
UP_ROOT="${UP_ROOT:-/usr/local/share/up}"
# shellcheck source=/dev/null
if [ -f "$UP_ROOT/configs/scripts/theme-utils.sh" ]; then
    source "$UP_ROOT/configs/scripts/theme-utils.sh"
    for user_home in /home/*; do
        [ -d "$user_home" ] || continue
        if [ -s "$user_home/.config/up-background" ]; then
            bg=$(tr -d '\n' <"$user_home/.config/up-background")
            if [ -f "$bg" ]; then
                HOME="$user_home" set_lightdm_background "$bg" || true
                echo "→ Greeter background from $user_home: $bg"
                break
            fi
        fi
    done
fi

echo "=== Migration 009 complete ==="
echo "Log out to the greeter to see the theme wallpaper."
