#!/bin/bash
# Super+Shift+K must generate an i3 bindsym for the keybindings list.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

export UP_ROOT="$ROOT"
export HOME="$tmp"
mkdir -p "$tmp/.config/up"

# shellcheck source=../../configs/scripts/keybinding-utils.sh
source "$ROOT/configs/scripts/keybinding-utils.sh"

fail=0
ok() { printf 'OK  %s\n' "$1"; }
bad() { printf 'FAIL %s\n' "$1"; fail=1; }

toml="$ROOT/configs/keybindings.toml"
if grep -qE '^"Super\+Shift\+K"[[:space:]]*=' "$toml"; then
    ok "Super+Shift+K present in keybindings.toml"
else
    bad "Super+Shift+K missing from keybindings.toml"
fi

if grep -E '^"Super\+Shift\+K"[[:space:]]*=' "$toml" | grep -q 'up-show-keybindings'; then
    ok "Super+Shift+K command is up-show-keybindings"
else
    bad "Super+Shift+K does not invoke up-show-keybindings"
fi

out="$tmp/keybindings.conf"
if write_i3_keybindings_file "$out"; then
    ok "generated i3 keybindings.conf"
else
    bad "write_i3_keybindings_file failed"
fi

if grep -Eq '^bindsym Mod4\+Shift\+k exec --no-startup-id .*\bup-show-keybindings\b' "$out"; then
    ok "i3 bindsym Mod4+Shift+k -> up-show-keybindings"
else
    bad "generated conf missing Mod4+Shift+k up-show-keybindings"
    if [ -f "$out" ]; then
        grep -E 'Shift\+k|show-keybindings' "$out" || true
    fi
fi

if [ "$fail" -ne 0 ]; then
    echo "keybindings: FAIL"
    exit 1
fi
echo "keybindings: OK"
