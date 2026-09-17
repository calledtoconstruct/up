#!/bin/bash
# Point pacman at the current XLibre Arch repo and import the 2026 signing key.
# The old x11libre.net mirror and key 73580DE2EDDFA6D6 were retired 2026-08-12.

set -euo pipefail

echo "=== Migration 012: XLibre repository URL and signing key ==="

UP_ROOT="${UP_ROOT:-/usr/local/share/up}"
KEY_ID="B97F7C613F359424"
KEY_FILE="$UP_ROOT/configs/keys/xlibre-archlinux.asc"
KEY_URL="https://xlibre-arch.github.io/xlibre-archlinux.asc"

if ! grep -qE '^\[xlibre(-stable)?\]' /etc/pacman.conf 2>/dev/null; then
    echo "→ No [xlibre] repo in pacman.conf (xorg fallback or never added); skip"
    exit 0
fi

if [ -f "$KEY_FILE" ]; then
    pacman-key --add "$KEY_FILE" || true
elif curl -fsSL "$KEY_URL" -o /tmp/xlibre-archlinux.asc; then
    pacman-key --add /tmp/xlibre-archlinux.asc || true
    rm -f /tmp/xlibre-archlinux.asc
fi
pacman-key --lsign-key "$KEY_ID" || true

sed -i '/^\[xlibre\]/,/^Server = /d;/^\[xlibre-stable\]/,/^Server = /d' /etc/pacman.conf 2>/dev/null || true
cat <<EOF >>/etc/pacman.conf

[xlibre-stable]
Server = https://packages.xlibre.net/arch/stable/\$arch
SigLevel = Required DatabaseOptional
EOF

echo "→ pacman.conf now uses [xlibre-stable] at packages.xlibre.net"
pacman -Sy --noconfirm || true
