#!/usr/bin/env bash
# Seed user-intent files that up-update must never overwrite.
# Usage: seed-user-overrides.sh [--home DIR]
set -euo pipefail

export UP_ROOT="${UP_ROOT:-/usr/local/share/up}"
HOME_DIR="${HOME:-}"

while [ $# -gt 0 ]; do
    case "$1" in
        --home)
            HOME_DIR="${2:-}"
            shift 2
            ;;
        *)
            echo "Usage: $0 [--home DIR]" >&2
            exit 2
            ;;
    esac
done

if [ -z "$HOME_DIR" ]; then
    echo "seed-user-overrides: HOME not set" >&2
    exit 1
fi

SRC="$UP_ROOT/configs/user-overrides"
DEST="$HOME_DIR/.config/up/overrides"
mkdir -p "$DEST" "$HOME_DIR/.config/up"

if [ ! -f "$DEST/i3.conf" ]; then
    if [ -f "$SRC/i3.conf" ]; then
        cp "$SRC/i3.conf" "$DEST/i3.conf"
    else
        printf '# Extra i3 configuration (never overwritten by up-update)\n' >"$DEST/i3.conf"
    fi
fi

kb="$HOME_DIR/.config/up/keybindings-overrides.toml"
if [ ! -f "$kb" ]; then
    if [ -f "$SRC/keybindings-overrides.toml" ]; then
        cp "$SRC/keybindings-overrides.toml" "$kb"
    else
        printf '# Extra keybindings (never overwritten by up-update)\n' >"$kb"
    fi
fi
