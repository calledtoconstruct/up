#!/bin/bash
# Install cliamp from the AUR. It was listed as a pacman package, so existing
# installs have a Music Player menu entry and no binary.
set -euo pipefail

echo "=== Migration 001: install cliamp (AUR) ==="

if command -v cliamp >/dev/null 2>&1 \
    || pacman -Q cliamp >/dev/null 2>&1 \
    || pacman -Q cliamp-bin >/dev/null 2>&1; then
    echo "cliamp already installed"
    exit 0
fi

if ! command -v yay >/dev/null 2>&1; then
    echo "yay not available; skip cliamp install"
    exit 0
fi

REAL_USER="${SUDO_USER:-}"
if [ -z "$REAL_USER" ] || [ "$REAL_USER" = "root" ]; then
    REAL_USER=""
    for d in /home/*; do
        [ -d "$d" ] || continue
        u=$(basename "$d")
        case "$u" in
            lost+found) continue ;;
        esac
        if id "$u" >/dev/null 2>&1; then
            REAL_USER="$u"
            break
        fi
    done
fi

if [ -z "$REAL_USER" ] || [ "$REAL_USER" = "root" ]; then
    echo "no non-root user for yay; skip cliamp install"
    exit 0
fi

echo "Installing cliamp-bin as $REAL_USER"
sudo -u "$REAL_USER" -- yay -S --noconfirm --needed cliamp-bin
