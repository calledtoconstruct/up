#!/bin/bash
# Link agent skills into harness dirs and enable crash-watch for each user.

set -euo pipefail

echo "=== Migration 011: agent skills and crash watch ==="

UP_ROOT="${UP_ROOT:-/usr/local/share/up}"
INSTALLER="$UP_ROOT/configs/scripts/install-agent-skills.sh"
UNIT_SRC="$UP_ROOT/configs/systemd/user/up-crash-watch.service"

chmod +x "$INSTALLER" "$UP_ROOT/bin"/up-agent* "$UP_ROOT/bin"/up-crash-* "$UP_ROOT/bin"/up-default-agent* 2>/dev/null || true

for up_bin in "$UP_ROOT"/bin/up-agent "$UP_ROOT"/bin/up-agent-crash "$UP_ROOT"/bin/up-agent-prompt \
    "$UP_ROOT"/bin/up-default-agent "$UP_ROOT"/bin/up-default-agent-pick \
    "$UP_ROOT"/bin/up-crash-mute "$UP_ROOT"/bin/up-crash-watch; do
    [ -f "$up_bin" ] || continue
    ln -sfn "$up_bin" "/usr/local/bin/$(basename "$up_bin")"
done

for user_home in /home/*; do
    [ -d "$user_home" ] || continue
    user=$(basename "$user_home")
    id "$user" >/dev/null 2>&1 || continue

    if [ -x "$INSTALLER" ]; then
        runuser -u "$user" -- env HOME="$user_home" UP_ROOT="$UP_ROOT" bash "$INSTALLER" --home "$user_home" || true
        echo "→ skills linked for $user"
    fi

    unit_dir="$user_home/.config/systemd/user"
    mkdir -p "$unit_dir/default.target.wants"
    if [ -f "$UNIT_SRC" ]; then
        install -m 644 "$UNIT_SRC" "$unit_dir/up-crash-watch.service"
        ln -sfn "$unit_dir/up-crash-watch.service" "$unit_dir/default.target.wants/up-crash-watch.service"
        chown -R "$user:$user" "$user_home/.config/systemd" 2>/dev/null || true
        chown -R "$user:$user" "$user_home/.agents" "$user_home/.claude" "$user_home/.codex" \
            "$user_home/.pi" "$user_home/.gemini" "$user_home/.hermes" 2>/dev/null || true
    fi
done
