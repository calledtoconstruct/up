#!/bin/bash
# Migration: Fix LightDM greeter not starting i3 session
# Addresses home directory permissions and adds proper session configuration

set -euo pipefail

echo "=== Migration 003: LightDM Fixes ==="

# Get UP_ROOT
UP_ROOT="${UP_ROOT:-/usr/local/share/up}"

# Get the primary user (first non-root user with UID >= 1000)
USERNAME=$(getent passwd | awk -F: '$3 >= 1000 && $3 < 65534 {print $1; exit}')

if [ -z "$USERNAME" ]; then
    echo "⚠ Could not determine username. Please set manually."
    echo "  Skipping lightdm fixes."
    exit 0
fi

echo "Detected user: $USERNAME"

# 1. Fix home directory permissions for lightdm access
echo "→ Fixing home directory permissions..."
if [ -d "/home/$USERNAME" ]; then
    chmod 755 "/home/$USERNAME"
    echo "✓ Set /home/$USERNAME permissions to 755"
else
    echo "⚠ Home directory /home/$USERNAME not found"
fi

# 2. Create lightdm drop-in config directory
echo "→ Creating lightdm.conf.d directory..."
mkdir -p /etc/lightdm/lightdm.conf.d
echo "✓ Created /etc/lightdm/lightdm.conf.d"

# 3. Create default i3 session configuration
echo "→ Creating lightdm session configuration..."
cat > /etc/lightdm/lightdm.conf.d/50-default-i3-session.conf << 'EOF'
[Seat:*]
greeter-session=lightdm-gtk-greeter
user-session=i3-up
session-wrapper=/etc/lightdm/Xsession
EOF
echo "✓ Created /etc/lightdm/lightdm.conf.d/50-default-i3-session.conf"

# 4. Create Xsession wrapper script
echo "→ Creating Xsession wrapper..."
cat > /etc/lightdm/Xsession << 'EOF'
#!/bin/sh
. /etc/profile
[ -f "$HOME/.profile" ] && . "$HOME/.profile"
[ -f "$HOME/.xprofile" ] && . "$HOME/.xprofile"

if [ -z "$XAUTHORITY" ]; then
    XAUTHORITY="$HOME/.Xauthority"
    export XAUTHORITY
fi

sleep 1

if [ -x "$HOME/.xsession" ]; then
    exec "$HOME/.xsession"
else
    exec /usr/local/share/up/configs/scripts/start-session.sh
fi
EOF
chmod 755 /etc/lightdm/Xsession
echo "✓ Created /etc/lightdm/Xsession"

# 4b. Remove default i3 session files (we use i3-up.desktop instead)
echo "→ Removing default i3 session files..."
rm -f /usr/share/xsessions/i3.desktop 2>/dev/null && echo "✓ Removed i3.desktop" || true
rm -f /usr/share/xsessions/i3-with-shmconfig.desktop 2>/dev/null && echo "✓ Removed i3-with-shmconfig.desktop" || true

# 5. Create .xprofile with environment exports
echo "→ Creating .xprofile for user $USERNAME..."
cat > "/home/$USERNAME/.xprofile" << 'EOF'
#!/bin/sh
# Up Linux X11 Profile
# Sourced by LightDM Xsession wrapper before starting the session

# X11 Display Settings
export DISPLAY="${DISPLAY:-:0}"

# XDG Session Variables
export XDG_SESSION_TYPE="x11"
export XDG_CURRENT_DESKTOP="i3"
export XDG_SESSION_DESKTOP="i3-up"

# Ensure XAUTHORITY is set
if [ -z "$XAUTHORITY" ]; then
    export XAUTHORITY="$HOME/.Xauthority"
fi

# Add Up tools to PATH
if [ -d "/usr/local/share/up/bin" ]; then
    export PATH="/usr/local/share/up/bin:$PATH"
fi

# Up Root
export UP_ROOT="/usr/local/share/up"

# Source system profile for any additional environment setup
[ -f /etc/profile ] && . /etc/profile

# Source user profile if it exists
[ -f "$HOME/.profile" ] && . "$HOME/.profile"
EOF
chmod 644 "/home/$USERNAME/.xprofile"
chown "$USERNAME:$USERNAME" "/home/$USERNAME/.xprofile"
echo "✓ Created .xprofile with environment exports"

# 6. Create .xsession that calls start-session.sh
echo "→ Creating .xsession for user $USERNAME..."
cat > "/home/$USERNAME/.xsession" << 'EOF'
#!/bin/sh
# Up Linux X11 Session
# Executed by LightDM Xsession wrapper after sourcing .xprofile
# Delegates to start-session.sh for actual session startup

exec /usr/local/share/up/configs/scripts/start-session.sh
EOF
chmod 755 "/home/$USERNAME/.xsession"
chown "$USERNAME:$USERNAME" "/home/$USERNAME/.xsession"
echo "✓ Created .xsession wrapper"

# 7. Verify the configuration
echo ""
echo "=== Migration 003 Complete ==="
echo "The following changes were made:"
echo "  - Fixed /home/$USERNAME permissions to 755"
echo "  - Created /etc/lightdm/lightdm.conf.d/"
echo "  - Created 50-default-i3-session.conf with session-wrapper"
echo "  - Created /etc/lightdm/Xsession wrapper script"
echo "  - Created ~/.xprofile with environment exports"
echo "  - Created ~/.xsession calling start-session.sh"
echo ""
echo "This should fix the lightdm greeter not starting i3."
echo "If you're currently stuck at a login loop, reboot or run:"
echo "  sudo systemctl restart lightdm"
echo ""
