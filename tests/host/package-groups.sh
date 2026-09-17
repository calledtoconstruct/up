#!/bin/bash
# cliamp is AUR-only; it must not be installed with pacman.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck source=../../configs/scripts/package-groups.sh
source "$ROOT/configs/scripts/package-groups.sh"

fail=0
ok() { printf 'OK  %s\n' "$1"; }
bad() { printf 'FAIL %s\n' "$1"; fail=1; }

in_list() {
    local needle="$1"
    local list="$2"
    # shellcheck disable=SC2086
    for p in $list; do
        [ "$p" = "$needle" ] && return 0
    done
    return 1
}

if in_list cliamp "$SYSTEM_PACKAGES" || in_list cliamp "$ESSENTIAL_PACKAGES"; then
    bad "cliamp is in a pacman package list (AUR-only; install via yay)"
else
    ok "cliamp is not in pacman lists"
fi

if in_list cliamp-bin "$APPLICATION_PACKAGES" || in_list cliamp-bin "$AUR_PACKAGES"; then
    ok "cliamp-bin is in an AUR/application list"
else
    bad "cliamp-bin missing from APPLICATION_PACKAGES / AUR_PACKAGES"
fi

if in_list cliamp "$APPLICATION_PACKAGES" || in_list cliamp "$AUR_PACKAGES"; then
    ok "source cliamp is an allowed AUR fallback"
fi

if [ "$fail" -ne 0 ]; then
    echo "package-groups: FAIL"
    exit 1
fi
echo "package-groups: OK"
