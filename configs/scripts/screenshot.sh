#!/bin/bash
# Screenshot entry point for i3.
# Flameshot 13+ captures through the XDG screenshot portal. i3 on X11 has
# no portal backend, so `flameshot gui` errors with "Unable to capture screen"
# unless the legacy Qt X11 path is enabled.
set -euo pipefail

ensure_flameshot_x11_legacy() {
    local ini="$1"
    local tmp
    mkdir -p "$(dirname "$ini")"
    if [ ! -e "$ini" ]; then
        printf '%s\n' '[General]' 'useX11LegacyScreenshot=true' >"$ini"
        chmod 644 "$ini" 2>/dev/null || true
        return 0
    fi
    tmp=$(mktemp)
    awk '
        BEGIN { in_general = 0; done = 0 }
        /^\[/ {
            if (in_general && !done) {
                print "useX11LegacyScreenshot=true"
                done = 1
            }
            in_general = ($0 ~ /^\[General\][[:space:]]*$/)
            print
            next
        }
        in_general && /^[[:space:]]*useX11LegacyScreenshot[[:space:]]*=/ {
            print "useX11LegacyScreenshot=true"
            done = 1
            next
        }
        { print }
        END {
            if (!done) {
                if (!in_general) print "[General]"
                print "useX11LegacyScreenshot=true"
            }
        }
    ' "$ini" >"$tmp"
    mv "$tmp" "$ini"
    chmod 644 "$ini" 2>/dev/null || true
}

ini="${HOME}/.config/flameshot/flameshot.ini"
before=""
if [ -f "$ini" ]; then
    before=$(cksum "$ini" 2>/dev/null || true)
fi
ensure_flameshot_x11_legacy "$ini"
after=$(cksum "$ini" 2>/dev/null || true)

if [ "${1:-}" = "--ensure-config" ]; then
    exit 0
fi

# A running daemon keeps the old setting until it is restarted.
if [ "$before" != "$after" ]; then
    pkill -u "$(id -u)" -x flameshot 2>/dev/null || true
    sleep 0.2
fi

if ! command -v flameshot >/dev/null 2>&1; then
    if command -v notify-send >/dev/null 2>&1; then
        notify-send -u critical "Screenshot" "flameshot is not installed" 2>/dev/null || true
    fi
    echo "flameshot is not installed" >&2
    exit 1
fi

exec flameshot gui "$@"
