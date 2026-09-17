#!/bin/bash
# Shared Logging Functions
# Provides centralized log file management for all Up scripts
#
# This file provides the core logging infrastructure used by:
# - bootstrap.sh (initial installation from ISO)
# - setup.sh (chroot configuration)
# - update.sh (system updates)
# - Various utility scripts

# Note: Do NOT set options here as they affect the calling script

# Guard against multiple sourcing
if [ -n "${LOGGING_LOADED:-}" ]; then
    return 0
fi
LOGGING_LOADED=1

# UP_ROOT environment variable must be set by calling script
if [ -z "${UP_ROOT:-}" ]; then
    echo "ERROR: UP_ROOT environment variable not set"
    exit 1
fi

# Source colors.sh from configs/scripts
source "$UP_ROOT/configs/scripts/colors.sh"

# Determine the best log file location
get_log_file() {
    local log_file=""

    if [ -n "${UP_LOG_FILE:-}" ]; then
        echo "$UP_LOG_FILE"
        return
    fi

    # Prefer /var/log/up only when we can actually write there.
    # mkdir -p succeeds on an existing root-owned dir; still check -w.
    if mkdir -p "/var/log/up" 2>/dev/null && [ -w "/var/log/up" ]; then
        log_file="/var/log/up/install.log"
    elif mkdir -p "$HOME/.var/log/up" 2>/dev/null && [ -w "$HOME/.var/log/up" ]; then
        log_file="$HOME/.var/log/up/install.log"
    else
        log_file="/tmp/up-install.log"
    fi
    
    echo "$log_file"
}

# Initialize log file with header
init_log_file() {
    local log_file
    log_file=$(get_log_file)
    
    # Ensure directory exists
    local log_dir
    log_dir=$(dirname "$log_file")
    mkdir -p "$log_dir" 2>/dev/null || true
    
    # Initialize log file
    echo "=== Up Installation Log ===" > "$log_file"
    echo "Timestamp: $(date)" >> "$log_file"
    echo "" >> "$log_file"
    
    echo "$log_file"
}

# Get or create log file (lazy initialization)
get_or_init_log_file() {
    local log_file
    log_file=$(get_log_file)
    
    # If log file doesn't exist, initialize it
    if [ ! -f "$log_file" ]; then
        init_log_file
    fi
    
    echo "$log_file"
}

# =============================================================================
# Two-Tier Logging Architecture
# =============================================================================
#
# This file provides two levels of logging:
#
# 1. CORE LOGGING (Tier 1):
#    - log_to_file()   - File-only logging (for debugging/troubleshooting)
#    - log_for_user()  - Console + file logging (for user-visible messages)
#
# 2. CONVENIENCE ALIASES (Tier 2):
#    - log_info()      - User-visible info message
#    - log_success()   - User-visible success message
#    - log_warning()   - User-visible warning message
#    - log_error()     - User-visible error message
#    - log_fatal()     - User-visible fatal error + exit
#
# USE CASES:
# - Installation scripts: Use log_to_file() for TUI updates, log_for_user() for user messages
# - Post-installation scripts: Use log_for_user() for direct user feedback
# =============================================================================

# Log to file only - for debugging and troubleshooting
# Usage: log_to_file "INFO" "Message to log"
log_to_file() {
    local level="${1:-INFO}"
    local message="$2"
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    local log_file
    log_file=$(get_or_init_log_file)
    
    mkdir -p "$(dirname "$log_file")" 2>/dev/null || true
    echo "[$timestamp] [$level] $message" >> "$log_file" 2>/dev/null || \
        echo "[$timestamp] [$level] $message" >> /tmp/up-install.log 2>/dev/null || true
}

# Log for user visibility - shows to user AND logs to file
# Usage: log_for_user "INFO" "Message user should see"
log_for_user() {
    local level="${1:-INFO}"
    local message="$2"
    
    # Log to file
    log_to_file "$level" "$message"
    
    # Show to user with appropriate color
    case "$level" in
        "INFO")    echo -e "${BLUE}[INFO]${NC} $message" ;;
        "SUCCESS") echo -e "${GREEN}[SUCCESS]${NC} $message" ;;
        "WARNING") echo -e "${YELLOW}[WARNING]${NC} $message" ;;
        "ERROR")   echo -e "${RED}[ERROR]${NC} $message" ;;
        "FATAL")   echo -e "${RED}[FATAL]${NC} $message" ;;
        *)         echo "$message" ;;
    esac
}

# =============================================================================
# Convenience Aliases
# =============================================================================

# Log an info message (console + file)
# Usage: log_info "message"
log_info() {
    log_for_user "INFO" "$1"
}

# Log a success message (console + file)
# Usage: log_success "message"
log_success() {
    log_for_user "SUCCESS" "$1"
}

# Log a warning message (console + file)
# Usage: log_warning "message"
log_warning() {
    log_for_user "WARNING" "$1"
}

# Log an error message (console + file)
# Usage: log_error "message"
log_error() {
    log_for_user "ERROR" "$1"
}

# Log a fatal error message (console + file, exits script)
# Usage: log_fatal "message"
log_fatal() {
    log_for_user "FATAL" "$1"
    exit 1
}

# Alias for compatibility (some scripts use log_warn)
log_warn() {
    log_warning "$@"
}

# Export functions
export -f get_log_file
export -f init_log_file
export -f get_or_init_log_file
export -f log_to_file
export -f log_for_user
export -f log_warning
export -f log_error
export -f log_fatal
export -f log_warn
export -f log_info
export -f log_success
