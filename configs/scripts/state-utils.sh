#!/bin/bash
# State Management Library
# Provides consistent state file operations for cross-script communication
# Source this file: source /path/to/state-utils.sh
#
# Input protocol (input pane ↔ bootstrap/setup):
#   write_answer TYPE VALUE  — producer (input-watcher) commits a durable answer
#   read_input TYPE [DEFAULT] [SENSITIVE]
#       — consumer waits for TYPE.answer (or legacy TYPE.input), publishes waiting_for.txt
#   clear_answer TYPE        — drop answer so a new value can be collected
#   request_reprompt TYPE [MSG] — clear answer and ask input pane to re-collect
#
# Answers are durable (.answer) so a consumer re-wait after a failed validation
# does not deadlock if the producer already moved on — the producer re-emits on
# .reprompt, and pre-confirmed answers remain readable until cleared.
#
# One-shot interactive keys (error_response, pacstrap_retry) must call
# clear_answer before read_input so a previous response is not reused.

# Note: Do NOT set options here as they affect the calling script

# Guard against multiple sourcing
if [ -n "${STATE_UTILS_LOADED:-}" ]; then
    return 0
fi
STATE_UTILS_LOADED=1

# State directory - must be set by sourcing script
# bootstrap.sh: STATE_DIR="/tmp/up-state"
# setup.sh: STATE_DIR="/up-state"
# watchers: STATE_DIR="/tmp/up-state"
STATE_DIR="${STATE_DIR:-/tmp/up-state}"

# Write a value to a state file
# Usage: state_set "key" "value"
state_set() {
    local key="$1"
    local value="$2"
    mkdir -p "$STATE_DIR" 2>/dev/null || true
    # Atomic write
    local dest="$STATE_DIR/$key"
    local tmp="${dest}.tmp.$$"
    printf '%s\n' "$value" > "$tmp"
    mv -f "$tmp" "$dest"
}

# Read a value from a state file
# Usage: value=$(state_get "key")
# Returns empty string if file doesn't exist
state_get() {
    local key="$1"
    cat "$STATE_DIR/$key" 2>/dev/null || echo ""
}

# Wait for a state file to exist and return its value
# Usage: value=$(state_wait "key" [timeout])
# Returns empty string if timeout reached
state_wait() {
    local key="$1"
    local timeout="${2:-300}"  # Default 5 minute timeout
    local elapsed=0
    
    while [ ! -f "$STATE_DIR/$key" ] && [ $elapsed -lt $timeout ]; do
        sleep 1
        elapsed=$((elapsed + 1))
    done
    
    if [ -f "$STATE_DIR/$key" ]; then
        cat "$STATE_DIR/$key"
    else
        echo ""
    fi
}

# Check if a state file exists
# Usage: if state_exists "key"; then ...
state_exists() {
    local key="$1"
    [ -f "$STATE_DIR/$key" ]
}

# Delete a state file
# Usage: state_delete "key"
state_delete() {
    local key="$1"
    rm -f "$STATE_DIR/$key" 2>/dev/null || true
}

# Trim leading/trailing whitespace without xargs (xargs breaks some values)
# Usage: trimmed=$(trim_value "$raw")
trim_value() {
    local s="${1-}"
    # Leading
    s="${s#"${s%%[![:space:]]*}"}"
    # Trailing
    s="${s%"${s##*[![:space:]]}"}"
    printf '%s' "$s"
}

# Atomically write a durable user answer for the given input type.
# Also writes legacy TYPE.input so older readers keep working until removed.
# Usage: write_answer "disk" "/dev/sda"
write_answer() {
    local input_type="$1"
    local value="${2-}"
    mkdir -p "$STATE_DIR" 2>/dev/null || true

    local answer_file="$STATE_DIR/${input_type}.answer"
    local input_file="$STATE_DIR/${input_type}.input"
    local tmp="${answer_file}.tmp.$$"

    # printf preserves empty values (e.g. optional SSH passphrase)
    printf '%s\n' "$value" > "$tmp"
    mv -f "$tmp" "$answer_file"

    # Legacy one-shot path: keep in sync for any consumer still watching .input
    tmp="${input_file}.tmp.$$"
    printf '%s\n' "$value" > "$tmp"
    mv -f "$tmp" "$input_file"

    # Clear any outstanding reprompt for this type
    rm -f "$STATE_DIR/${input_type}.reprompt" 2>/dev/null || true
}

# Remove a previously written answer so the producer can supply a new one.
# Usage: clear_answer "disk"
clear_answer() {
    local input_type="$1"
    rm -f \
        "$STATE_DIR/${input_type}.answer" \
        "$STATE_DIR/${input_type}.input" \
        2>/dev/null || true
}

# Invalidate an answer and ask the input pane to re-collect it.
# Usage: request_reprompt "disk" "Not a valid block device"
request_reprompt() {
    local input_type="$1"
    local message="${2:-Please re-enter $input_type}"
    clear_answer "$input_type"
    state_set "${input_type}.reprompt" "$message"
    state_set "waiting_for.txt" "$input_type"
}

# Update installation phase
# Usage: update_phase "1" "Welcome & Repo"
update_phase() {
    local phase_num="$1"
    local phase_name="$2"
    state_set "current_phase.txt" "$phase_num|$phase_name"
    # File-only: safe if ever used inside command substitution
    if declare -f log_to_file >/dev/null 2>&1; then
        log_to_file "INFO" "Phase updated: $phase_num - $phase_name" 2>/dev/null || true
    fi
}

# Update progress bar
# Usage: update_progress "5" "30" "Installing packages..."
update_progress() {
    local current="$1"
    local total="$2"
    local status="$3"
    state_set "progress_current.txt" "$current"
    state_set "progress_total.txt" "$total"
    state_set "status.txt" "$status"
    if declare -f log_to_file >/dev/null 2>&1; then
        log_to_file "INFO" "Progress: $current/$total - $status" 2>/dev/null || true
    fi
}

# Read user input (waits for durable answer or legacy one-shot input file).
# Publishes waiting_for.txt so the UI and input pane know what is blocked.
#
# Usage: value=$(read_input "disk" "/dev/sda")
# For sensitive data (passwords): value=$(read_input "password_user" "" "true")
#
# Protocol notes:
# - Prefers TYPE.input (one-shot; deleted after read) over TYPE.answer (durable).
# - Durable answers are NOT deleted, so re-entry after partial failure works when
#   the answer is still valid. Call clear_answer/request_reprompt to force new input.
# - Empty files are NOT treated as "use default" for required fields without a
#   default; intentional empty answers (default "") are accepted once a file exists.
read_input() {
    local input_type="$1"
    local default="${2-}"
    local sensitive="${3:-false}"
    local input_file="$STATE_DIR/${input_type}.input"
    local answer_file="$STATE_DIR/${input_type}.answer"
    local value=""
    local got_file=0

    mkdir -p "$STATE_DIR" 2>/dev/null || true
    state_set "waiting_for.txt" "$input_type"
    # Status hint for progress pane (non-destructive if status already set)
    state_set "waiting_for_status.txt" "Waiting for input: $input_type"

    while true; do
        if [ -f "$STATE_DIR/install_cancelled.txt" ]; then
            log_info "Installation cancelled while waiting for $input_type" 2>/dev/null || true
            rm -f "$STATE_DIR/waiting_for.txt" "$STATE_DIR/waiting_for_status.txt" 2>/dev/null || true
            exit 1
        fi

        got_file=0
        value=""

        # Prefer one-shot .input (fresh response / override), then durable .answer.
        # Note: never use $(< file || true) — bash parses that as empty.
        if [ -f "$input_file" ]; then
            value=$(cat "$input_file" 2>/dev/null) || value=""
            rm -f "$input_file"
            got_file=1
        elif [ -f "$answer_file" ]; then
            value=$(cat "$answer_file" 2>/dev/null) || value=""
            got_file=1
        fi

        if [ "$got_file" -eq 0 ]; then
            sleep 1
            continue
        fi

        # Strip trailing newlines/CR and surrounding whitespace.
        # Answers are single-line; take the last non-empty line defensively.
        value=$(printf '%s' "$value" | tr -d '\r' | sed '/^$/d' | tail -n1)
        value=$(trim_value "$value")

        if [ -z "$value" ] && [ -n "$default" ]; then
            value="$default"
        fi

        # If still empty: accept only when the caller allows empty (default is empty
        # string and a file was present — intentional blank, e.g. SSH passphrase).
        # If default is non-empty we already applied it. If both empty, accept blank.
        break
    done

    rm -f "$STATE_DIR/waiting_for.txt" "$STATE_DIR/waiting_for_status.txt" 2>/dev/null || true

    # CRITICAL: never write to stdout here except the final value.
    # Callers use value=$(read_input ...); log_info/log_for_user echo to stdout
    # and would corrupt DISK/HOSTNAME/etc. (e.g. "[INFO] Read disk: /dev/vda\n/dev/vda")
    # so [ -b "$DISK" ] fails even for a valid device.
    if declare -f log_to_file >/dev/null 2>&1; then
        if [ "$sensitive" = "true" ]; then
            log_to_file "INFO" "Read $input_type: [REDACTED]" 2>/dev/null || true
        else
            log_to_file "INFO" "Read $input_type: $value" 2>/dev/null || true
        fi
    fi

    # Sole stdout: the answer value (with a trailing newline for command substitution)
    printf '%s\n' "$value"
}

# Generic error prompt for installation failures
# Usage: prompt_on_error "error_message" ["options"]
# Returns: "retry", "continue", or "exit"
# Options: "retry_continue_exit" (default), "retry_exit", "continue_exit"
prompt_on_error() {
    local error_msg="$1"
    local options="${2:-retry_continue_exit}"

    if [ "${UP_UNATTENDED:-}" = "1" ]; then
        printf '%s\n' "continue"
        return 0
    fi
    
    # Ensure a fresh response (do not reuse a prior error_response answer)
    clear_answer "error_response"

    # Write error to state file for input watcher
    state_set "install_error.txt" "$error_msg"
    state_set "error_options.txt" "$options"
    state_set "pane_state.txt" "error_pending"
    
    # Wait for user response
    local response
    response=$(read_input "error_response")
    
    # Clean up state files
    rm -f "$STATE_DIR/install_error.txt"
    rm -f "$STATE_DIR/error_options.txt"
    clear_answer "error_response"
    
    printf '%s\n' "$response"
}

# Package-specific error prompt
# Usage: prompt_package_error "package_type" "failed_packages_array"
# Returns: "retry", "continue", or "exit"
prompt_package_error() {
    local pkg_type="$1"
    shift
    local failed_pkgs=("$@")

    if [ "${UP_UNATTENDED:-}" = "1" ]; then
        if [ "$pkg_type" = "essential" ]; then
            printf '%s\n' "retry"
        else
            printf '%s\n' "continue"
        fi
        return 0
    fi
    
    # Build error message with failed packages list
    local error_msg="Failed to install $pkg_type packages"

    clear_answer "error_response"
    
    # Write error to state file (packages list as separate file)
    state_set "install_error.txt" "$error_msg"
    mkdir -p "$STATE_DIR" 2>/dev/null || true
    printf "%s\n" "${failed_pkgs[@]}" > "$STATE_DIR/failed_packages.txt"
    state_set "error_options.txt" "retry_continue_exit"
    state_set "pane_state.txt" "error_pending"
    
    # Wait for user response
    local response
    response=$(read_input "error_response")
    
    # Clean up state files
    rm -f "$STATE_DIR/install_error.txt"
    rm -f "$STATE_DIR/failed_packages.txt"
    rm -f "$STATE_DIR/error_options.txt"
    clear_answer "error_response"
    
    printf '%s\n' "$response"
}

# Export functions
export -f state_set state_get state_wait state_exists state_delete
export -f trim_value write_answer clear_answer request_reprompt
export -f update_phase update_progress read_input
export -f prompt_on_error prompt_package_error
