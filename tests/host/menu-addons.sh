#!/bin/bash
# Host-safe check that extra menu files load without naming them in the OS.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

fail=0
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

UP_ADDONS_DIR="$tmp"
# shellcheck source=../../configs/scripts/menu-addons.sh
source "$ROOT/configs/scripts/menu-addons.sh"

addon_main_items | grep -q . && fail=1
load_menu_addons
addon_main_items | grep -q . && fail=1

mkdir -p "$tmp/sample"
cat > "$tmp/sample/menu.sh" <<'EOF'
addon_main_items() { printf '%s\n' "EXTRA_ITEM"; }
addon_install_items() { printf '%s\n' "EXTRA_INSTALL"; }
addon_menu_title() {
    if [ "$1" = "extra" ]; then
        echo "Extra"
        return 0
    fi
    return 1
}
addon_menu_options() {
    if [ "$1" = "extra" ]; then
        printf '%s\n' "One"
        return 0
    fi
    return 1
}
addon_handle_choice() {
    if [ "$1" = "main" ] && [ "$2" = "EXTRA_ITEM" ]; then
        return 0
    fi
    return 1
}
EOF

load_menu_addons
out=$(addon_main_items)
[ "$out" = "EXTRA_ITEM" ] || fail=1
out=$(addon_install_items)
[ "$out" = "EXTRA_INSTALL" ] || fail=1
title=$(addon_menu_title extra)
[ "$title" = "Extra" ] || fail=1
opts=$(addon_menu_options extra)
[ "$opts" = "One" ] || fail=1
addon_handle_choice main EXTRA_ITEM || fail=1
addon_handle_choice main nosuch && fail=1

if [ "$fail" -ne 0 ]; then
    echo "menu-addons: FAIL"
    exit 1
fi
echo "menu-addons: OK"
