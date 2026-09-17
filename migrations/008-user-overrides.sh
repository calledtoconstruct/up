#!/bin/bash
# Seed ~/.config/up/overrides (never overwritten) for existing users.

set -euo pipefail

echo "=== Migration 008: seed user override files ==="

UP_ROOT="${UP_ROOT:-/usr/local/share/up}"
SEED="$UP_ROOT/configs/scripts/seed-user-overrides.sh"

if [ ! -x "$SEED" ] && [ -f "$SEED" ]; then
    chmod +x "$SEED"
fi

if [ ! -x "$SEED" ]; then
    echo "⚠ $SEED missing; skip"
    exit 1
fi

for user_home in /home/*; do
    [ -d "$user_home" ] || continue
    username=$(basename "$user_home")
    case "$username" in
        lost+found) continue ;;
    esac
    id "$username" >/dev/null 2>&1 || continue
    "$SEED" --home "$user_home" || true
    chown -R "$username:$username" "$user_home/.config/up/overrides" \
        "$user_home/.config/up/keybindings-overrides.toml" 2>/dev/null || true
    echo "→ Seeded overrides for $username"
done

echo "=== Migration 008 complete ==="
