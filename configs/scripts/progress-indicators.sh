#!/bin/bash
# Progress Indicators Functions
# Used by setup.sh for real-time installation progress
# Uses unified TUI system from tui-dialogs.sh

set -euo pipefail

PROGRESS_UPDATE_INTERVAL=2
LAST_PROGRESS_UPDATE=0

initialize_progress() {
    mkdir -p /var/log/up 2>/dev/null || mkdir -p "$HOME/.var/log/up"
    
    TOTAL_PACKAGES=0
    INSTALLED_PACKAGES=0
    LAST_PROGRESS_UPDATE=0
    
    # Set log file path for installation logging
    export INSTALL_LOG_FILE="/var/log/up/install.log"
    
    calculate_total_packages
    
    log_progress "Progress tracking initialized - Total packages: $TOTAL_PACKAGES"
}

calculate_total_packages() {
    ESSENTIAL_COUNT=$(echo "$ESSENTIAL_PACKAGES" | wc -w)
    SYSTEM_COUNT=$(echo "$SYSTEM_PACKAGES" | wc -w)
    SHELL_TOOLS_COUNT=$(echo "$SHELL_TOOLS" | wc -w)
    COSMETIC_COUNT=$(echo "$COSMETIC_PACKAGES" | wc -w)
    AUR_COUNT=$(echo "$AUR_PACKAGES" | wc -w)
    
    TOTAL_PACKAGES=$((ESSENTIAL_COUNT + SYSTEM_COUNT + SHELL_TOOLS_COUNT + COSMETIC_COUNT + AUR_COUNT))
    
    log_progress "Total packages to install: $TOTAL_PACKAGES (Essential: $ESSENTIAL_COUNT, System: $SYSTEM_COUNT, Shell Tools: $SHELL_TOOLS_COUNT, Cosmetic: $COSMETIC_COUNT, AUR: $AUR_COUNT)"
}

update_progress() {
    local package_type="$1"
    local package_name="$2"
    local success="$3"
    
    if [ "$success" = "true" ]; then
        INSTALLED_PACKAGES=$((INSTALLED_PACKAGES + 1))
    fi
    
    CURRENT_STATUS="$package_type: $package_name"
    
    local current_time
    current_time=$(date +%s)
    local time_since_last_update=$((current_time - LAST_PROGRESS_UPDATE))
    
    if [ "$time_since_last_update" -ge "$PROGRESS_UPDATE_INTERVAL" ] || [ "$success" = "false" ]; then
        show_progress_bar
        LAST_PROGRESS_UPDATE=$current_time
    fi
    
    log_progress "$package_type package $package_name $([ "$success" = "true" ] && echo "installed" || echo "failed")"
}

show_progress_bar() {
    # Progress is now handled by state files and watchers
    # This function is kept for compatibility but does nothing
    return 0
}

log_progress() {
    local message="$1"
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    local log_file="${ERROR_LOG_FILE:-$(get_log_file 2>/dev/null || echo '/tmp/up-install.log')}"
    
    echo "[$timestamp] [PROGRESS] $message" >> "$log_file"
}

progress_callback() {
    local package_type="$1"
    local package_name="$2"
    local success="$3"
    
    update_progress "$package_type" "$package_name" "$success"
}

aur_progress_callback() {
    local package_name="$1"
    local success="$2"
    
    update_progress "AUR" "$package_name" "$success"
}

show_final_summary() {
    local percentage=0
    if [ "$TOTAL_PACKAGES" -gt 0 ]; then
        percentage=$((INSTALLED_PACKAGES * 100 / TOTAL_PACKAGES))
    fi

    # Build progress bar string with Unicode block characters
    local filled=$((percentage * 30 / 100))
    local empty=$((30 - filled))
    local bar=""
    for ((i=0; i<filled; i++)); do bar+="█"; done
    for ((i=0; i<empty; i++)); do bar+="░"; done

    # Log completion summary (watchers will display this)
    log_progress "Installation completed successfully!"
    log_progress "Total packages: $TOTAL_PACKAGES, Successfully installed: $INSTALLED_PACKAGES ($percentage%)"
    log_progress "Progress: [$bar] $percentage%"
}

export -f initialize_progress
export -f calculate_total_packages
export -f update_progress
export -f show_progress_bar
export -f log_progress
export -f progress_callback
export -f aur_progress_callback
export -f show_final_summary

export TOTAL_PACKAGES INSTALLED_PACKAGES CURRENT_STATUS
