#!/bin/bash
# Config Watcher — bridge *external* edits of ~/.config/up/config into the queue
#
# Does NOT apply theme/polybar/picom itself. Only enqueues when:
#   - agent is not suppressing watches (not mid-apply)
#   - cool-off after agent apply has elapsed
#   - config content hash differs from last successfully applied hash
#
# Scripts that already know the intent (theme/font chooser) should enqueue
# directly via desktop-request and not depend on this watcher.

set -euo pipefail

export UP_ROOT="${UP_ROOT:-/usr/local/share/up}"
SCRIPT_DIR="$UP_ROOT/configs/scripts"

CONFIG_FILE="$HOME/.config/up/config"
CONFIG_DIR=$(dirname "$CONFIG_FILE")
CONFIG_BASENAME=$(basename "$CONFIG_FILE")

# shellcheck source=desktop-request.sh
source "$SCRIPT_DIR/desktop-request.sh"

main() {
    if [ ! -f "$CONFIG_FILE" ]; then
        echo "Config file not found, exiting: $CONFIG_FILE"
        exit 1
    fi

    echo "Starting config watcher (external edits → queue; loop-safe)..."
    desktop_ensure_agent || true

    # Seed applied hash so agent startup materialization is not treated as "user edit"
    desktop_mark_config_applied "$(desktop_config_hash)" || true

    # Do not enqueue sync on login. start-session.sh already did a file-only
    # sync; a boot-time sync rewrites theme files, reloads i3, and restarts
    # polybar/picom for no user-visible change. External edits while the
    # session is up still go through inotify below.

    if ! command -v inotifywait >/dev/null 2>&1; then
        echo "inotifywait not found; initial sync enqueued, live watch disabled"
        echo "Install inotify-tools for live config updates"
        exit 0
    fi

    echo "Watching $CONFIG_FILE (suppress+hash guarded)..."
    last_run=0
    inotifywait -m -e modify,close_write,moved_to,create --format '%f' "$CONFIG_DIR" \
        | while read -r file; do
            if [ "$file" != "$CONFIG_BASENAME" ]; then
                continue
            fi

            # Hard ignore while agent owns config mutations
            if desktop_watch_suppressed; then
                continue
            fi

            now=$(date +%s)
            if [ $((now - last_run)) -lt 1 ]; then
                continue
            fi

            # Hash/cooloff/duplicate-queue guard
            if desktop_request_from_watch 1; then
                last_run=$now
                echo "External config change → enqueued sync force=1"
                desktop_ensure_agent || true
            fi
        done
}

main "$@"
