#!/bin/bash
# Migration: Switch LightDM to native i3 session (no xinit-xsession AUR dependency)
# This fixes the login loop caused by missing xinit-xsession package

set -euo pipefail

echo "=== Migration 002: Native i3 Session ==="

# Get UP_ROOT
UP_ROOT="${UP_ROOT:-/usr/local/share/up}"

# 1. Deploy start-session.sh script
echo "→ Deploying start-session.sh..."
DEST_SCRIPT="/usr/local/share/up/configs/scripts/start-session.sh"
SRC_SCRIPT="$UP_ROOT/configs/scripts/start-session.sh"
mkdir -p "$(dirname "$DEST_SCRIPT")"

# Skip copy if source and destination are the same file
if [ "$(readlink -f "$SRC_SCRIPT")" = "$(readlink -f "$DEST_SCRIPT")" ]; then
    chmod +x "$DEST_SCRIPT"
    echo "✓ start-session.sh already in place at $DEST_SCRIPT"
elif [ -f "$SRC_SCRIPT" ]; then
    cp "$SRC_SCRIPT" "$DEST_SCRIPT"
    chmod +x "$DEST_SCRIPT"
    echo "✓ Deployed start-session.sh to $DEST_SCRIPT"
else
    echo "⚠ start-session.sh not found in $UP_ROOT/configs/scripts/"
    echo "  Creating it directly..."
    cat > "$DEST_SCRIPT" << 'SCRIPT'
#!/bin/sh
# Up Linux i3 Session Starter
# Replaces .xinitrc for LightDM native session (no xinit-xsession AUR dependency needed)

export UP_ROOT="${UP_ROOT:-/usr/local/share/up}"

if [ -x "$UP_ROOT/configs/scripts/apply-compositor-profile.sh" ]; then
    "$UP_ROOT/configs/scripts/apply-compositor-profile.sh" --no-theme || true
fi

# Early config sync to ensure services start with correct settings
"$UP_ROOT/configs/scripts/config-sync.sh" || true

# Start picom compositor (daemon mode)
picom --daemon --config "$HOME/.config/picom/config" &

# Start i3 window manager
exec i3
SCRIPT
    chmod +x "$DEST_SCRIPT"
    echo "✓ Created start-session.sh at $DEST_SCRIPT"
fi

# 2. Deploy i3-up.desktop session file
echo "→ Deploying i3-up.desktop session file..."
mkdir -p /usr/share/xsessions
cat > /usr/share/xsessions/i3-up.desktop << 'EOF'
[Desktop Entry]
Name=i3 (Up)
Comment=Up Linux i3 session with picom compositor
Exec=/usr/local/share/up/configs/scripts/start-session.sh
Type=XSession
DesktopNames=i3
EOF
echo "✓ Deployed /usr/share/xsessions/i3-up.desktop"

# 3. Update lightdm.conf to use new session
echo "→ Updating LightDM configuration..."
LIGHTDM_CONF="/etc/lightdm/lightdm.conf"

if [ -f "$LIGHTDM_CONF" ]; then
    # Check if it's a symlink to the up config
    if [ -L "$LIGHTDM_CONF" ]; then
        target=$(readlink "$LIGHTDM_CONF")
        echo "  lightdm.conf is a symlink to: $target"
        # The source config in UP_ROOT should already be updated
        # Just verify the setting is correct
        if grep -q "user-session=i3-up" "$target" 2>/dev/null; then
            echo "✓ LightDM config already set to i3-up"
        else
            echo "  Updating symlinked config..."
            sed -i 's/user-session=.*/user-session=i3-up/' "$target"
            echo "✓ Updated LightDM config to use i3-up"
        fi
    else
        # Direct file - update it
        if grep -q "user-session=" "$LIGHTDM_CONF"; then
            sed -i 's/user-session=.*/user-session=i3-up/' "$LIGHTDM_CONF"
            echo "✓ Updated LightDM config to use i3-up"
        else
            # Add the setting under [Seat:*]
            if grep -q "\[Seat:\*\]" "$LIGHTDM_CONF"; then
                sed -i '/\[Seat:\*\]/a user-session=i3-up' "$LIGHTDM_CONF"
                echo "✓ Added user-session=i3-up to LightDM config"
            else
                echo "⚠ Could not find [Seat:*] section in lightdm.conf"
                echo "  Please manually set: user-session=i3-up"
            fi
        fi
    fi
else
    echo "⚠ lightdm.conf not found at $LIGHTDM_CONF"
    echo "  Creating default config..."
    mkdir -p /etc/lightdm
    cat > "$LIGHTDM_CONF" << 'EOF'
# LightDM Configuration for Up Linux
# Display manager configuration

[Seat:*]
# Session to use by default
# Native i3 session (no AUR dependency required)
user-session=i3-up

# Greeter to use
greeter-session=lightdm-gtk-greeter

# Allow manual login
allow-guest=false

[Greeter]
# Theme configuration is in lightdm-gtk-greeter.conf
EOF
    echo "✓ Created lightdm.conf with i3-up session"
fi

# 4. Verify xinit-xsession is no longer needed (optional cleanup note)
echo "→ Checking for xinit-xsession package..."
if pacman -Qi xinit-xsession &>/dev/null; then
    echo "  xinit-xsession is installed (no longer needed)"
    echo "  You can optionally remove it: yay -R xinit-xsession"
else
    echo "✓ xinit-xsession not installed (as expected)"
fi

# 5. Restart LightDM to apply changes (if running)
echo "→ Checking LightDM service..."
if systemctl is-active lightdm &>/dev/null; then
    echo "  LightDM is running. Changes will apply on next login."
    echo "  To apply now: sudo systemctl restart lightdm"
else
    echo "✓ LightDM not currently running"
fi

echo ""
echo "=== Migration 002 Complete ==="
echo "The following changes were made:"
echo "  - Deployed start-session.sh (picom + i3 launcher)"
echo "  - Created /usr/share/xsessions/i3-up.desktop"
echo "  - Updated LightDM config to use 'i3-up' session"
echo ""
echo "This eliminates the xinit-xsession AUR dependency for login."
echo "If you're currently stuck at a login loop, reboot or run:"
echo "  sudo systemctl restart lightdm"
echo ""