#!/bin/bash
# Phase pane watcher - shows numbered phases with status

set -euo pipefail

STATE_DIR="/tmp/up-state"
HASH_FILE="$STATE_DIR/phase-watcher-hash.txt"
source "$(dirname "$0")/colors.sh"

# Build content to display
build_content() {
    echo -e "${CYAN}PHASES:${NC}"
    
    if [ -f "$STATE_DIR/phases.txt" ] && [ -f "$STATE_DIR/current_phase.txt" ]; then
        local current
        current=$(cat "$STATE_DIR/current_phase.txt" | cut -d'|' -f1)
        while IFS= read -r phase || [ -n "$phase" ]; do
            local num
            num=$(echo "$phase" | cut -d'.' -f1 | tr -d ' ')
            if [ "$num" = "$current" ]; then
                echo -e "${YELLOW}▶ $phase${NC}"
            elif [ "$num" -lt "$current" ]; then
                echo -e "${GREEN}✓ $phase${NC}"
            else
                echo "  $phase"
            fi
        done < "$STATE_DIR/phases.txt"
    else
        echo "Loading phases..."
    fi
    
    echo -e "\n${BLUE}Use bottom pane for input${NC}"
}

while true; do
    # Check for cancellation
    if [ -f "$STATE_DIR/install_cancelled.txt" ]; then
        exit 0
    fi

    # Build content and check if it changed
    content=$(build_content)

    if content_changed "$HASH_FILE" <<< "$content"; then
        clear
        echo "$content"
    fi

    sleep 3
done
