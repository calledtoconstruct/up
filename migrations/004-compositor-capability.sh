#!/bin/bash
# Migration: hardware-aware picom profiles (effects=auto|full|lite|safe)
# Adds effects key to existing user configs and materializes capability.conf

set -euo pipefail

echo "=== Migration 004: Compositor capability detection ==="

UP_ROOT="${UP_ROOT:-/usr/local/share/up}"
DETECT="$UP_ROOT/configs/scripts/detect-compositor-capability.sh"
APPLY="$UP_ROOT/configs/scripts/apply-compositor-profile.sh"
PICOM_SRC="$UP_ROOT/configs/picom/config"

chmod +x "$DETECT" "$APPLY" 2>/dev/null || true

for user_home in /home/*; do
    [ -d "$user_home" ] || continue
    username=$(basename "$user_home")
    config="$user_home/.config/up/config"
    picom_dir="$user_home/.config/picom"

    # Skip accounts without a desktop config tree
    if [ ! -d "$user_home/.config" ]; then
        continue
    fi

    mkdir -p "$user_home/.config/up" "$picom_dir"

    # Refresh stock picom config (includes capability.conf @include)
    if [ -f "$PICOM_SRC" ]; then
        if [ -f "$picom_dir/config" ]; then
            if ! cmp -s "$PICOM_SRC" "$picom_dir/config"; then
                cp -p "$picom_dir/config" "$picom_dir/config.backup-mig004-$(date +%Y%m%d)" 2>/dev/null || true
                cp -p "$PICOM_SRC" "$picom_dir/config"
                echo "→ Updated picom config for $username"
            fi
        else
            cp -p "$PICOM_SRC" "$picom_dir/config"
            echo "→ Installed picom config for $username"
        fi
        # Seed default fragments if missing (apply will overwrite capability.conf)
        if [ ! -f "$picom_dir/capability.conf" ] && [ -f "$UP_ROOT/configs/picom/capability.conf" ]; then
            cp -p "$UP_ROOT/configs/picom/capability.conf" "$picom_dir/capability.conf"
        fi
        if [ ! -f "$picom_dir/theme.conf" ] && [ -f "$UP_ROOT/configs/picom/theme.conf" ]; then
            cp -p "$UP_ROOT/configs/picom/theme.conf" "$picom_dir/theme.conf"
        fi
    fi

    if [ -f "$config" ]; then
        if ! grep -qE '^[[:space:]]*effects[[:space:]]*=' "$config"; then
            # Prepend effects=auto so existing fade/blur/dim become auto-managed
            tmp=$(mktemp)
            {
                echo '# effects: auto | full | lite | safe (auto = hardware detection)'
                echo 'effects = "auto"'
                cat "$config"
            } >"$tmp"
            mv "$tmp" "$config"
            echo "→ Added effects = \"auto\" for $username"
        else
            echo "→ effects already set for $username"
        fi
    else
        cat >"$config" <<'EOF'
effects = "auto"
fade = true
blur = true
dim = true
font = "DejaVu Sans Mono"
theme = "aetherweft"
EOF
        echo "→ Created default up config for $username"
    fi

    chown -R "$username:$username" "$user_home/.config/up" "$picom_dir" 2>/dev/null || true

    if [ -x "$APPLY" ]; then
        if HOME="$user_home" "$APPLY" --force --no-theme --home "$user_home"; then
            echo "→ Applied compositor profile for $username"
            # Refresh theme fragment if a theme is configured (files only; no agent)
            if [ -x "$UP_ROOT/configs/scripts/switch-theme.sh" ]; then
                HOME="$user_home" UP_DESKTOP_INLINE=1 \
                  "$UP_ROOT/configs/scripts/switch-theme.sh" \
                    --reapply --home "$user_home" --no-reload >/dev/null 2>&1 || true
            fi
        else
            echo "⚠ Profile apply failed for $username (non-fatal)"
        fi
        chown -R "$username:$username" "$user_home/.config/up" "$picom_dir" 2>/dev/null || true
    fi
done

echo "=== Migration 004 complete ==="
echo "Users can pin a profile with: effects = \"full\" | \"lite\" | \"safe\" in ~/.config/up/config"
echo "Re-detect anytime: $APPLY --force"
