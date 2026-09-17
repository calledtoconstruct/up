#!/bin/bash
# Log watcher for main log pane
# Shows scrolling log messages and pending input notifications

set -euo pipefail

STATE_DIR="/tmp/up-state"
LOG_FILE="/var/log/up/install.log"
HASH_FILE="$STATE_DIR/log-watcher-hash.txt"
source "$(dirname "$0")/colors.sh"

# Get content hash for change detection
get_content_hash() {
    local log_hash=""
    if [ -f "$LOG_FILE" ]; then
        log_hash=$(tail -n 50 "$LOG_FILE" | md5sum | cut -d' ' -f1)
    fi
    echo "$log_hash"
}

while true; do
    # Check for cancellation
    if [ -f "$STATE_DIR/install_cancelled.txt" ]; then
        exit 0
    fi

    # Check if content changed
    new_hash=$(get_content_hash)
    if [ "$new_hash" != "${last_hash:-}" ]; then
        last_hash="$new_hash"
        
        # Get pane height
        pane_height=$(tput lines 2>/dev/null || echo 24)
        
        # Print logs first (they can scroll below header)
        tail -n $((pane_height - 3)) "$LOG_FILE" 2>/dev/null || echo "No logs yet"
        
        # Overlay header at top (clear only header lines, not logs)
        tput cup 0 0
        tput el
        echo -e "${BLUE}========================================${NC}"
        tput cup 1 0
        tput el
        tput cup 2 0
        tput el
        echo -e "${BLUE}Recent Logs:${NC}"
    fi

    sleep 1
done
