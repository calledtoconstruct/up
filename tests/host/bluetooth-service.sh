#!/bin/bash
# Bluetooth apps are installed, but the daemon is not started unless we enable it.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

fail=0
ok() { printf 'OK  %s\n' "$1"; }
bad() { printf 'FAIL %s\n' "$1"; fail=1; }

if grep -q 'enable_service_safe bluetooth' "$ROOT/setup.sh"; then
    ok "setup enables bluetooth.service"
else
    bad "setup.sh does not enable bluetooth.service"
fi

mig="$ROOT/migrations/003-enable-bluetooth.sh"
if [ -x "$mig" ] && grep -q 'systemctl enable bluetooth.service' "$mig" \
    && grep -q 'systemctl start bluetooth.service' "$mig"; then
    ok "migration enables and starts bluetooth.service"
else
    bad "migration 003 does not enable and start bluetooth.service"
fi

# shellcheck source=../../configs/scripts/package-groups.sh
source "$ROOT/configs/scripts/package-groups.sh"
if printf '%s\n' $SYSTEM_PACKAGES | grep -qx bluez \
    && printf '%s\n' $SYSTEM_PACKAGES | grep -qx blueman; then
    ok "bluez and blueman are installed packages"
else
    bad "bluez or blueman missing from SYSTEM_PACKAGES"
fi

if [ "$fail" -ne 0 ]; then
    echo "bluetooth-service: FAIL"
    exit 1
fi
echo "bluetooth-service: OK"
