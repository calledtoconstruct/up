#!/bin/bash
# Migration: expose up-* commands on sudo secure_path via /usr/local/bin
# Fixes: `sudo up-update` → command not found (PATH drop under sudo)

set -euo pipefail

echo "=== Migration 005: up-* bin links for sudo secure_path ==="

UP_ROOT="${UP_ROOT:-/usr/local/share/up}"
BIN_DIR="$UP_ROOT/bin"

if [ ! -d "$BIN_DIR" ]; then
    echo "⚠ $BIN_DIR missing; is Up installed?"
    exit 1
fi

mkdir -p /usr/local/bin
linked=0
for f in "$BIN_DIR"/up-*; do
    [ -e "$f" ] || continue
    base=$(basename "$f")
    ln -sfn "$f" "/usr/local/bin/$base"
    chmod +x "$f" 2>/dev/null || true
    linked=$((linked + 1))
    echo "→ /usr/local/bin/$base → $f"
done

# Ensure profile.d PATH helper exists for interactive shells
if [ ! -f /etc/profile.d/up-path.sh ]; then
    cat > /etc/profile.d/up-path.sh << 'EOF'
export UP_ROOT="/usr/local/share/up"
export PATH="$UP_ROOT/bin:$PATH"
EOF
    chmod 644 /etc/profile.d/up-path.sh
    echo "→ Created /etc/profile.d/up-path.sh"
fi

# Refresh system-menu if deployed as a copy
if [ -f "$UP_ROOT/configs/scripts/system-menu.sh" ]; then
    chmod +x "$UP_ROOT/configs/scripts/system-menu.sh" 2>/dev/null || true
fi

echo "=== Linked $linked commands into /usr/local/bin ==="
echo "You can now run:  up-update   (auto-sudo)  or  sudo up-update"
