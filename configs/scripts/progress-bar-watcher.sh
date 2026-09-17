#!/bin/bash
# Progress bar watcher for tmux pane
# Shows progress bar and status message only (3 lines, full width)

set -euo pipefail

STATE_DIR="/tmp/up-state"
HASH_FILE="$STATE_DIR/progress-bar-watcher-hash.txt"
source "$(dirname "$0")/colors.sh"

print_progress_bar() {
    local current="$1"
    local total="$2"
    local width=50
    local percentage=$((current * 100 / total))
    local filled=$((percentage * width / 100))
    local empty=$((width - filled))

    printf "${CYAN}[${NC}"
    printf "${GREEN}%0.s█${NC}" $(seq 1 $filled)
    printf "${YELLOW}%0.s░${NC}" $(seq 1 $empty)
    printf "${CYAN}]${NC} ${BLUE}%3d%%${NC} (%d/%d)" "$percentage" "$current" "$total"
}

# Build content to display (exactly 3 lines)
build_content() {
    if [ -f "$STATE_DIR/progress_current.txt" ] && [ -f "$STATE_DIR/progress_total.txt" ]; then
        local current
        local total
        local status
        current=$(cat "$STATE_DIR/progress_current.txt")
        total=$(cat "$STATE_DIR/progress_total.txt")
        status=$(cat "$STATE_DIR/status.txt" 2>/dev/null || echo "Running...")
        
        echo -e "${CYAN}PROGRESS:${NC}"
        print_progress_bar "$current" "$total"
        echo ""
        echo -e "${YELLOW}Status: $status${NC}"
    else
        echo -e "${CYAN}PROGRESS:${NC}"
        echo "Initializing..."
        echo ""
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