# Code Quality Improvements

## Overview
Improve code quality through shared state management, standardized error handling, and better documentation. Adhere to SOLID, DRY, and GRASP principles.

---

## 1. Shared State Management Library ✅ COMPLETED

### Prerequisites
- None

### Implementation Details

**Status:** Implemented in `configs/scripts/state-utils.sh`

**Changes Made:**
- Created `configs/scripts/state-utils.sh` with consolidated functions
- Updated `bootstrap.sh` to source the shared library
- Updated `setup.sh` to source the shared library
- Removed duplicated `update_phase()`, `update_progress()`, and `read_input()` from both scripts
- Added `sensitive` parameter to `read_input()` to prevent logging passwords

**New File:** `configs/scripts/state-utils.sh`

**Purpose:** Provide consistent state file operations across all scripts (bootstrap.sh, setup.sh, watchers).

```bash
#!/bin/bash
# State Management Library
# Provides consistent state file operations for cross-script communication
# Source this file: source /path/to/state-utils.sh

# Note: Do NOT set options here as they affect the calling script

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
    echo "$value" > "$STATE_DIR/$key"
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

# Update installation phase
# Usage: update_phase "1" "Welcome & Repo"
update_phase() {
    local phase_num="$1"
    local phase_name="$2"
    state_set "current_phase.txt" "$phase_num|$phase_name"
    log_message "Phase updated: $phase_num - $phase_name" 2>/dev/null || true
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
    log_message "Progress: $current/$total - $status" 2>/dev/null || true
}

# Read user input (waits for file, returns value, cleans up)
# Usage: value=$(read_input "disk" "/dev/sda")
# For sensitive data (passwords): value=$(read_input "password_user" "" "true")
read_input() {
    local input_type="$1"
    local default="${2:-}"
    local sensitive="${3:-false}"
    local input_file="$STATE_DIR/${input_type}.input"
    
    # Wait for input file to exist
    while [ ! -f "$input_file" ]; do
        # Check for cancellation
        if [ -f "$STATE_DIR/install_cancelled.txt" ]; then
            log_message "Installation cancelled while waiting for $input_type" 2>/dev/null || true
            exit 1
        fi
        sleep 1
    done
    
    local value
    value=$(cat "$input_file")
    [ -z "$value" ] && value="$default"
    
    # Clean up the input file after reading
    rm -f "$input_file"
    
    # Don't log sensitive values to the log file
    if [ "$sensitive" = "true" ]; then
        log_message "Read $input_type: [REDACTED]" 2>/dev/null || true
    else
        log_message "Read $input_type: $value" 2>/dev/null || true
    fi
    
    echo "$value"
}

# Export functions
export -f state_set state_get state_wait state_exists state_delete
export -f update_phase update_progress read_input
```

**Integration:**
- Source in `bootstrap.sh`: `source "$UP_ROOT/configs/scripts/state-utils.sh"`
- Source in `setup.sh`: `source "$UP_ROOT/configs/scripts/state-utils.sh"`
- Source in watcher scripts: `source "$(dirname "$0")/state-utils.sh"`
- Remove duplicated `update_phase()`, `update_progress()`, `read_input()` from bootstrap.sh and setup.sh

---

## 2. Standardized Error Handling

### Prerequisites
- Shared state management library (above)

### Implementation Details

**File:** `configs/scripts/error-handling.sh` (enhance existing)

**Goals:**
- Background scripts should try to succeed as much as possible
- Only fail on essential step/package failures
- Capture command output AND exit code reliably
- Never crash the whole process except for essential failures

**Implementation:**

```bash
# Run command with output capture and exit code preservation
# Usage: run_with_capture "command" "arg1" "arg2" ...
# Sets: CAPTURE_OUTPUT (stdout), CAPTURE_ERROR (stderr), CAPTURE_EXIT_CODE
run_with_capture() {
    local tmp_stdout=$(mktemp)
    local tmp_stderr=$(mktemp)
    
    "$@" > "$tmp_stdout" 2> "$tmp_stderr"
    CAPTURE_EXIT_CODE=$?
    CAPTURE_OUTPUT=$(cat "$tmp_stdout")
    CAPTURE_ERROR=$(cat "$tmp_stderr")
    
    rm -f "$tmp_stdout" "$tmp_stderr"
    return $CAPTURE_EXIT_CODE
}

# Run command with logging (captures output, logs, returns exit code)
# Usage: run_with_log "package_type" "command" "arg1" "arg2" ...
# Returns: exit code of command
run_with_log() {
    local category="$1"
    shift
    
    local tmp_file=$(mktemp)
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    local log_file="${INSTALL_LOG_FILE:-/var/log/up/install.log}"
    
    # Run command, capture all output
    "$@" > "$tmp_file" 2>&1
    local exit_code=$?
    
    # Log command and output
    mkdir -p "$(dirname "$log_file")" 2>/dev/null || true
    {
        echo "[$timestamp] [$category] Running: $*"
        cat "$tmp_file"
        echo "[$timestamp] [$category] Exit code: $exit_code"
        echo ""
    } >> "$log_file" 2>/dev/null || true
    
    rm -f "$tmp_file"
    return $exit_code
}

# Run command with failure categorization
# Usage: run_categorized "essential|system|cosmetic|aur" "package_name" "command" "args..."
# Returns: 0 on success, 1 on failure (but doesn't exit unless essential)
run_categorized() {
    local category="$1"
    local package="$2"
    shift 2
    
    if run_with_log "$category" "$@"; then
        SUCCESS_COUNT=$((SUCCESS_COUNT + 1))
        return 0
    else
        case "$category" in
            essential)
                log_error "Essential package $package failed - aborting installation"
                log_to_console "❌ FATAL: Essential package $package failed"
                exit 1
                ;;
            system|cosmetic|aur|application)
                log_warning "Package $package failed - continuing"
                log_to_console "⚠️  Failed: $package"
                log_failure "$category" "$package"
                return 1
                ;;
            *)
                log_warning "Unknown category $category for $package"
                return 1
                ;;
        esac
    fi
}

# Safe package installation with category handling
# Usage: install_safe "essential" "package1 package2 package3"
install_safe() {
    local category="$1"
    local packages="$2"
    local package_list=($packages)
    local total=${#package_list[@]}
    local current=0
    
    log_to_console "📦 Installing $category packages ($total total)..."
    
    # Try batch first
    if run_categorized "$category" "batch-$category" pacman -S --noconfirm --needed $packages; then
        log_to_console "✅ Batch install succeeded"
        return 0
    fi
    
    # Batch failed - fall back to individual
    log_to_console "⚠️ Batch failed, installing individually..."
    for package in $packages; do
        current=$((current + 1))
        update_progress "$current_step" "$total_steps" "Installing $category: $current/$total - $package" 2>/dev/null || true
        run_categorized "$category" "$package" pacman -S --noconfirm --needed "$package" || true
    done
}

export -f run_with_capture run_with_log run_categorized install_safe
```

**Error Handling Rules:**
1. **Essential packages**: Failure = abort installation
2. **System packages**: Failure = log and continue
3. **Cosmetic packages**: Failure = log and continue
4. **AUR packages**: Failure = log and continue
5. **Commands**: Always capture output and exit code, never let them crash the script

---

## 3. Remove `|| true` Anti-Pattern

### Prerequisites
- Standardized error handling (above)

### Implementation Details

**Problem:** Commands use `|| true` which hides real errors.

**Solution:** Use `run_categorized()` which handles failures appropriately.

**Example:**
```bash
# Before:
run_and_log grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=GRUB || true

# After:
run_categorized "system" "grub-install" grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=GRUB
```

**Files to update:**
- `bootstrap.sh` — Replace `|| true` with categorized calls
- `setup.sh` — Replace `|| true` with categorized calls
- `configs/scripts/package-groups.sh` — Already uses categorized installation

---

## 4. Code Documentation

### Prerequisites
- None

### Implementation Details

**Standard Header Template:**
```bash
#!/bin/bash
# Script Name: script-name.sh
# Purpose: Brief description of what this script does
# Usage: script-name.sh [options]
# Source: Called by parent-script.sh
# Dependencies: colors.sh, logging.sh, state-utils.sh
#
# This script is part of the Up Linux installation system.
# It runs in [host/chroot/both] environment.
```

**Function Documentation Template:**
```bash
# Function description
# Usage: function_name "arg1" "arg2" [optional_arg]
# Returns: 0 on success, 1 on failure
# Sets: VARIABLE_NAME on success
function_name() {
    local arg1="$1"
    local arg2="$2"
    local optional="${3:-default}"
    # ...
}
```

**Files to document:**
- `install.sh`
- `bootstrap.sh`
- `setup.sh`
- `update.sh`
- `configs/scripts/system-menu.sh`
- `configs/scripts/switch-theme.sh`
- `configs/scripts/package-groups.sh`
- `configs/scripts/input-watcher.sh`
- `configs/scripts/progress-watcher.sh`
- `configs/scripts/phase-watcher.sh`
- `configs/scripts/title-watcher.sh`

---

## 5. Standardize STATE_DIR Path

### Prerequisites
- Shared state management library

### Implementation Details

**Current:** Different scripts use different paths:
- `bootstrap.sh`: `STATE_DIR="/tmp/up-state"`
- `setup.sh`: `STATE_DIR="/up-state"` (bind-mounted)
- Watchers: `STATE_DIR="/tmp/up-state"`

**Solution:** Define in shared library with context-aware default:

```bash
# In state-utils.sh
# Determine STATE_DIR based on environment
if [ -d "/up-state" ]; then
    # Running in chroot (bind-mounted from host)
    STATE_DIR="/up-state"
elif [ -d "/tmp/up-state" ]; then
    # Running on host
    STATE_DIR="/tmp/up-state"
else
    # Default fallback
    STATE_DIR="/tmp/up-state"
    mkdir -p "$STATE_DIR" 2>/dev/null || true
fi
```

**Note:** The bind mount in bootstrap.sh ensures both host and chroot see the same state directory. This is correct and should be maintained.

---

