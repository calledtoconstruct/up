#!/bin/bash
# bluez is installed, but Arch does not start bluetoothd unless the unit
# is enabled. blueman then reports "Bluez daemon is not running", and
# bluetoothctl exits immediately so the terminal window just flashes.
set -euo pipefail

echo "=== Migration 003: enable bluetoothd ==="

if ! systemctl cat bluetooth.service >/dev/null 2>&1; then
    echo "bluetooth.service is not installed; skipping"
    exit 0
fi

systemctl unmask bluetooth.service >/dev/null 2>&1 || true
systemctl enable bluetooth.service
systemctl start bluetooth.service
echo "bluetooth.service enabled and started"
