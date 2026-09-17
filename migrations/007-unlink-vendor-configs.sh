#!/bin/bash
# Replace live symlinks that pointed into the vendor git tree with copies.
# LightDM / greeter / xsession writes were dirtying /usr/local/share/up.

set -euo pipefail

echo "=== Migration 007: stop writing through symlinks into the vendor tree ==="

UP_ROOT="${UP_ROOT:-/usr/local/share/up}"

unlink_to_copy() {
    local dst="$1"
    [ -L "$dst" ] || return 0
    local real
    real=$(readlink -f "$dst" 2>/dev/null || true)
    case "$real" in
        "$UP_ROOT"/*|/usr/local/share/up/*) ;;
        *) return 0 ;;
    esac
    [ -f "$real" ] || return 0
    local tmp
    tmp=$(mktemp)
    cp -a "$real" "$tmp"
    rm -f "$dst"
    mv "$tmp" "$dst"
    echo "→ $dst is now a copy (was symlink → $real)"
}

unlink_to_copy /etc/lightdm/lightdm.conf
unlink_to_copy /etc/lightdm/lightdm-gtk-greeter.conf
unlink_to_copy /usr/share/xsessions/i3-up.desktop

if [ -d "$UP_ROOT/.git" ]; then
    git -C "$UP_ROOT" config core.fileMode false 2>/dev/null || true
fi

echo "=== Migration 007 complete ==="
