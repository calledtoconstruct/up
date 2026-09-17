#!/bin/bash
# Error Handling Functions
# Used by setup.sh for error management

# Note: Do NOT set options here as they affect the calling script

# Guard against multiple sourcing
if [ -n "${ERROR_HANDLING_LOADED:-}" ]; then
    return 0
fi
ERROR_HANDLING_LOADED=1

# State directory for tmux integration (set by sourcing script: setup.sh uses /up-state, watchers use /tmp/up-state)
# Note: This is overridden by the sourcing script, but provide a default for direct execution
STATE_DIR="${STATE_DIR:-/up-state}"

# Initialize error tracking and logging
initialize_error_handling() {
    # Use shared logging functions
    ERROR_LOG_FILE=$(init_log_file)

    # Initialize tracking arrays
    FAILED_ESSENTIAL=()
    FAILED_OPTIONAL=()
    FAILED_AUR=()
    SUCCESS_COUNT=0

    log_info "Error handling initialized"
}

# Update status in state file for tmux display
update_error_status() {
    local message="$1"
    if [ -d "$STATE_DIR" ]; then
        echo "ERROR: $message" > "$STATE_DIR/status.txt"
    fi
}

# Package failure tracking
log_package_failure() {
    local type="$1"
    local package="$2"
    local reason="$3"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')

    case $type in
        "essential") FAILED_ESSENTIAL+=("$package") ;;
        "optional") FAILED_OPTIONAL+=("$package") ;;
        "aur") FAILED_AUR+=("$package") ;;
    esac

    # Log to file with detailed information
    echo "[$timestamp] [FAILURE] $type package $package failed: $reason" >> "$ERROR_LOG_FILE"

    # Update status for tmux display
    update_error_status "Package $package failed: $reason"

    # Print to console with appropriate color
    case $type in
        "essential") echo -e "\033[0;31m❌ Essential package $package failed: $reason\033[0m" ;;
        "optional") echo -e "\033[1;33m⚠️  Optional package $package failed: $reason\033[0m" ;;
        "aur") echo -e "\033[1;33m⚠️  AUR package $package failed: $reason\033[0m" ;;
    esac
}

# Export functions for use in setup.sh
export -f initialize_error_handling
export -f log_package_failure