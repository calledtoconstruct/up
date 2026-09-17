#!/bin/bash
# Migration: apply boot/runtime tunables (GRUB timeout, wait-online, journald, TRIM)
# Existing installs pick this up via up-update. New installs run tune-system.sh
# from setup.sh; this migration is then a no-op (same files rewritten).

set -euo pipefail

echo "=== Migration 006: boot and runtime tuning ==="

UP_ROOT="${UP_ROOT:-/usr/local/share/up}"
TUNE="$UP_ROOT/configs/scripts/tune-system.sh"

if [ ! -x "$TUNE" ]; then
    if [ -f "$TUNE" ]; then
        chmod +x "$TUNE"
    else
        echo "⚠ $TUNE missing; skip"
        exit 1
    fi
fi

"$TUNE"

echo "=== Migration 006 complete ==="
echo "Next reboot uses a 2s GRUB menu and does not wait for a network before LightDM."
