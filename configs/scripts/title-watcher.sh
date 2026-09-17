#!/bin/bash
# Title pane watcher for tmux top pane
# Displays title and subtitle from state files, updates dynamically

set -euo pipefail

STATE_DIR="/tmp/up-state"
HASH_FILE="$STATE_DIR/title-watcher-hash.txt"
source "$(dirname "$0")/colors.sh"

# Build content to display
build_content() {
    if [ -f "$STATE_DIR/title.txt" ] && [ -f "$STATE_DIR/subtitle.txt" ]; then
        local title
        local subtitle
        title=$(cat "$STATE_DIR/title.txt")
        subtitle=$(cat "$STATE_DIR/subtitle.txt")
        printf "${BLUE}=================================================================================${NC}\n"
        printf "${CYAN}  %s${NC} :: ${BLUE}%s${NC}\n" "$title" "$subtitle"
        printf "${BLUE}=================================================================================${NC}"
    else
        printf "Title Watcher: Waiting for state files..."
    fi
}

while true; do
    # Check for cancellation
    if [ -f "$STATE_DIR/install_cancelled.txt" ]; then
        exit 0
    fi

    # Build content and check if it changed
    content=$(build_content)

    if content_changed "$HASH_FILE" <<< "$content"; then
        tput cup 0 0
        tput ed
        printf "%s\n" "$content"
    fi

    sleep 1
done
