#!/bin/bash
# Package Categorization and Installation Functions
# Used by setup.sh to optimize package installation

# Note: Do NOT set options here as they affect the calling script

# Guard against multiple sourcing
if [ -n "${PACKAGE_GROUPS_LOADED:-}" ]; then
    return 0
fi
PACKAGE_GROUPS_LOADED=1

# =============================================================================
# Package Categories
# =============================================================================

# Bootstrap packages - minimal set installed by pacstrap during base system setup
# These are the core packages needed to get the system bootable
BOOTSTRAP_PACKAGES="base linux linux-firmware networkmanager git sudo base-devel"
BOOTSTRAP_PACKAGE_COUNT=7

# Essential packages - installation failure stops the process
# These are required for a functional desktop environment
# Note: Some bootstrap packages (git, base-devel, sudo, networkmanager) are also here for completeness
ESSENTIAL_PACKAGES="
    xlibre-xserver xlibre-input-libinput \
    xorg-xinit xorg-xrandr xorg-xrdb xorg-xset xorg-xsetroot \
    i3-wm i3lock polybar rofi \
    alacritty firefox \
    neovim git base-devel sudo \
    zsh starship \
    grub efibootmgr \
    picom feh tmux \
    networkmanager network-manager-applet \
    dex btop \
    lightdm lightdm-gtk-greeter lightdm-gtk-greeter-settings \
    systemd
    "

# System packages - functional tools for desktop operation
# Failure is logged but installation continues
SYSTEM_PACKAGES="
    thunar flameshot \
    pipewire pipewire-alsa pipewire-pulse pipewire-jack \
    wireplumber pulsemixer pavucontrol playerctl \
    bluez blueman \
    dunst gvfs xclip \
    ripgrep fd fzf \
    jq rsync tree ncdu \
    iotop lsof strace sysstat psmisc \
    xdotool \
    less which unzip zip man-db usbutils pciutils \
    xsettingsd inotify-tools \
    power-profiles-daemon \
    ffmpeg \
    ufw \
    gpick \
    lazygit qalculate-gtk
    "

# Shell enhancement tools - modern replacements for standard commands
# These affect .zshrc configuration - aliases only added if installed
# Conservative selection for legacy hardware (2010+ CPUs)
SHELL_TOOLS="zoxide"

# Cosmetic packages - visual enhancements (fonts, themes, wallpapers)
# Installed last as they don't affect functionality
# Default fonts: UI coverage + one mono + nerd symbols.
# Extra coding/UI families are available later via up-font-chooser.
COSMETIC_PACKAGES="
    noto-fonts noto-fonts-emoji ttf-dejavu \
    ttf-nerd-fonts-symbols ttf-jetbrains-mono \
    lxappearance papirus-icon-theme materia-gtk-theme \
    archlinux-wallpaper fastfetch
    "

# AUR-only leftovers. Official apps belong in SYSTEM_PACKAGES.
# Theme wallpapers ship in configs/backgrounds/; do not pull unused AUR sets.
AUR_PACKAGES="
    xautolock
"

# Application packages that are AUR-only (installed via yay).
# Prefer -bin packages so chroot install does not compile toolchains.
# localsend-bin: prebuilt AUR package (provides localsend); source "localsend"
# requires fvm/flutter/rustup and routinely fails during setup.
APPLICATION_PACKAGES="
    localsend-bin
    cliamp-bin
"

# =============================================================================
# Global Tracking Variables
# =============================================================================

FAILED_ESSENTIAL=()
FAILED_SYSTEM=()
FAILED_SHELL_TOOLS=()
FAILED_COSMETIC=()
FAILED_AUR=()
FAILED_APPLICATION=()
FAILED_SERVICES=()
SUCCESS_COUNT=0

# Track which shell tools were successfully installed
INSTALLED_SHELL_TOOLS=()

# =============================================================================
# Safe Output Capture Functions
# =============================================================================

# Strip ANSI escape sequences and control characters from a string
#
# CRITICAL WORKAROUND: ANSI Codes in Tmux Output
# Problem: Commands often output ANSI escape sequences for colors, cursor
# positioning, and other terminal controls. When this output is captured
# and displayed in tmux panes, these sequences appear as garbage characters
# (like ^[[0m, ^[[32m, etc.) instead of formatting the text.
# Solution: Strip all ANSI escape sequences before displaying output in
# the TUI progress tracker. This ensures clean, readable progress messages.
# The regex matches ESC[ followed by optional numbers/semicolons and a letter.
# We also remove carriage returns, tabs, and other control characters.
strip_ansi() {
    printf '%s' "$1" | sed 's/\x1b\[[0-9;]*[a-zA-Z]//g' | tr -d '\r\n\t' | sed 's/[\x00-\x1F\x7F]//g'
}

# Run command and capture output to temp file, then stream to TUI
#
# CRITICAL WORKAROUND: Exit Code Preservation in Pipelines
# Problem: When you pipe a command's output (e.g., `cmd | process`), the exit
# code of the first command is lost - you only get the exit code of the last
# command in the pipeline. This breaks error handling because we can't detect
# if the original command failed.
# Solution: Use a temporary file to capture all output, then process it
# separately. This preserves the original command's exit code ($?) while
# still allowing us to log and display the output.
# The trade-off is slightly more complex code and temp file management,
# but reliable error detection is essential for installation robustness.
# Usage: _run_command_to_tui <command> [args...]
_run_command_to_tui() {
    local tmp_file
    tmp_file=$(mktemp)

    # Use exec to redirect ALL output including from subshells and background processes
    # Save original file descriptors
    exec 3>&1 4>&2

    # Redirect stdout and stderr to temp file for this command
    {
        "$@" 2>&1
    } > "$tmp_file" 2>&1
    local cmd_status=$?

    # Restore original file descriptors
    exec 1>&3 2>&4 3>&- 4>&-

    # Write raw command output directly to log file (full output, no filtering)
    local log_file="${INSTALL_LOG_FILE:-/var/log/up/install.log}"
    local log_dir
    log_dir=$(dirname "$log_file")
    mkdir -p "$log_dir" 2>/dev/null || true

    # Log command being executed
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    {
        echo "[$timestamp] [CMD] Running: $*"
        cat "$tmp_file"
        echo "[$timestamp] [CMD] Exit code: $cmd_status"
        echo ""
    } >> "$log_file" 2>/dev/null || true

    # Command output is already logged above, no need for additional console logging

    rm -f "$tmp_file"
    return $cmd_status
}

# Run pacman and log output through TUI safely
# Uses --noprogressbar to avoid disruptive progress bars
# Uses --quiet to suppress package list output (still shows errors)
# Usage: run_pacman <args...>
run_pacman() {
    # Detect if this is a sync operation and add --noprogressbar --quiet
    local has_sync=false
    for arg in "$@"; do
        if [[ "$arg" == "-S" || "$arg" == "-Sy" || "$arg" == "-Su" || "$arg" == "-Syu" ]]; then
            has_sync=true
            break
        fi
    done
    
    if $has_sync; then
        _run_command_to_tui pacman --noprogressbar --quiet "$@"
    else
        _run_command_to_tui pacman "$@"
    fi
}

# Run yay and log output through TUI safely
# Uses --noprogressbar and --quiet to suppress noisy output
# Runs as root during installation (chroot environment)
# Usage: run_yay <args...>
run_yay() {
    # Run as root during installation (chroot environment)
    # After installation, users run yay normally with their own credentials
    _run_command_to_tui yay --noprogressbar --quiet "$@"
}

# Generic run_and_log for any command
# Usage: run_and_log <command> [args...]
run_and_log() {
    _run_command_to_tui "$@"
}



# Run pacstrap with real-time progress updates
# Parses output to show current package being installed
# Uses temp file approach to properly capture exit code (pipe loses exit codes)
# Usage: run_pacstrap_with_progress <pacstrap_args...>
run_pacstrap_with_progress() {
    local tmp_file
    tmp_file=$(mktemp)
    local log_file="${INSTALL_LOG_FILE:-/var/log/up/install.log}"
    local log_dir
    log_dir=$(dirname "$log_file")
    mkdir -p "$log_dir" 2>/dev/null || true

    # Bootstrap packages in installation order (from centralized definition)
    local bootstrap_packages=($BOOTSTRAP_PACKAGES)
    local total_packages=$BOOTSTRAP_PACKAGE_COUNT

    # Log command being executed
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$timestamp] [CMD] Running: pacstrap $*" >> "$log_file"

    # Run pacstrap and capture output to temp file to preserve exit code
    pacstrap "$@" > "$tmp_file" 2>&1
    local cmd_status=$?

    # Process output for logging and progress updates
    local current_package_index=0
    while IFS= read -r line || [ -n "$line" ]; do
        # Write raw output to log file
        echo "$line" >> "$log_file"

        # Parse output for progress updates
        local clean_line
        clean_line=$(strip_ansi "$line")

        # Look for package installation indicators
        if [[ "$clean_line" =~ installing[[:space:]]+([^[:space:]]+) ]]; then
            local package_name="${BASH_REMATCH[1]}"
            # Find which bootstrap package this is
            for i in "${!bootstrap_packages[@]}"; do
                if [[ "$package_name" == "${bootstrap_packages[$i]}"* ]]; then
                    current_package_index=$((i + 1))
                    local progress_status="Installing $package_name... ($current_package_index/$total_packages)"
                    local pt
                    pt=$(cat "${STATE_DIR:-/up-state}/progress_total.txt" 2>/dev/null || echo 30)
                    update_progress 6 "$pt" "$progress_status"
                    break
                fi
            done
        fi
    done < "$tmp_file"

    # Log exit code
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$timestamp] [CMD] Exit code: $cmd_status" >> "$log_file"
    echo "" >> "$log_file"

    rm -f "$tmp_file"
    return $cmd_status
}

# =============================================================================
# Initialization and Logging Functions
# =============================================================================

# Initialize tracking and logging
initialize_tracking() {
    FAILED_ESSENTIAL=()
    FAILED_SYSTEM=()
    FAILED_SHELL_TOOLS=()
    FAILED_COSMETIC=()
    FAILED_AUR=()
    FAILED_APPLICATION=()
    FAILED_SERVICES=()
    SUCCESS_COUNT=0
    INSTALLED_SHELL_TOOLS=()

    # Create log directory
    mkdir -p /var/log/up
    echo "=== Up Installation Log ===" > /var/log/up/install.log
    echo "Timestamp: $(date)" >> /var/log/up/install.log
    echo "" >> /var/log/up/install.log
}

# Safely enable a systemd service (won't fail the script if service not found)
# Usage: enable_service_safe <service_name> [--user]
enable_service_safe() {
    local service="$1"
    local user_flag="${2:-}"
    
    local cmd=""
    local unit_path=""
    
    # Normalize service name - add .service suffix if not present
    local service_name="$service"
    local service_suffix="${service_name##*.}"
    if [ "$service_suffix" != "service" ]; then
        service_name="${service}.service"
    fi
    
    if [ "$user_flag" = "--user" ]; then
        cmd="systemctl --user"
        for path in "/usr/lib/systemd/user/$service_name" "/lib/systemd/user/$service_name"; do
            if [ -f "$path" ]; then
                unit_path="$path"
                break
            fi
        done
    else
        cmd="systemctl"
        for path in "/etc/systemd/system/$service_name" "/usr/lib/systemd/system/$service_name" "/lib/systemd/system/$service_name"; do
            if [ -f "$path" ]; then
                unit_path="$path"
                break
            fi
        done
    fi
    
    # Check if service unit file exists (works in chroot where systemd isn't running)
    if [ -n "$unit_path" ]; then
        if [ "$user_flag" = "--user" ]; then
            # Prefer the install-created user (USERNAME) over SUDO_USER/root
            local user_home=""
            if [ -n "${USERNAME:-}" ] && [ -d "/home/$USERNAME" ]; then
                user_home="/home/$USERNAME"
            else
                user_home=$(getent passwd "${SUDO_USER:-root}" | cut -d: -f6)
            fi
            # Correct path for user units: ~/.config/systemd/user/
            local user_systemd_dir="$user_home/.config/systemd/user"
            local user_wants_dir="$user_systemd_dir/default.target.wants"
            mkdir -p "$user_wants_dir" 2>/dev/null || true
            if ln -sf "$unit_path" "$user_wants_dir/$service_name" 2>/dev/null; then
                log_install_progress "✅ User service enabled: $service"
                return 0
            fi
        else
            mkdir -p /etc/systemd/system/multi-user.target.wants 2>/dev/null || true
            if ln -sf "$unit_path" "/etc/systemd/system/multi-user.target.wants/$service_name" 2>/dev/null; then
                log_install_progress "✅ Service enabled: $service"
                return 0
            fi
        fi
        
        # If direct symlink failed, try systemctl (for non-chroot environments)
        if $cmd enable --now "$service" 2>/dev/null; then
            log_install_progress "✅ Service enabled: $service"
            return 0
        else
            log_warning "Failed to enable service: $service"
            FAILED_SERVICES+=("$service")
            echo "[SERVICE] Failed to enable: $service" >> /var/log/up/install.log
            return 1
        fi
    else
        log_warning "Service not found: $service"
        FAILED_SERVICES+=("$service")
        echo "[SERVICE] Not found: $service" >> /var/log/up/install.log
        return 1
    fi
}

# Save failed services to a file for the welcome wizard
save_failed_services() {
    mkdir -p /var/log/up
    
    if [ ${#FAILED_SERVICES[@]} -gt 0 ]; then
        echo "FAILED_SERVICES=(" > /var/log/up/failed-services.sh
        for service in "${FAILED_SERVICES[@]}"; do
            echo "    \"$service\"" >> /var/log/up/failed-services.sh
        done
        echo ")" >> /var/log/up/failed-services.sh
    else
        echo "FAILED_SERVICES=()" > /var/log/up/failed-services.sh
    fi
}

# Save all installation state to files for welcome wizard
save_installation_state() {
    mkdir -p /var/log/up
    
    # Load bootstrap package count if available
    local bootstrap_count=0
    if [ -f "/root/up/.bootstrap-state" ]; then
        source /root/up/.bootstrap-state
        bootstrap_count=${BOOTSTRAP_PACKAGE_COUNT:-0}
    fi
    
    # Save success count (include bootstrap packages)
    local total_success=$((SUCCESS_COUNT + bootstrap_count))
    echo "SUCCESS_COUNT=$total_success" > /var/log/up/install-state.sh
    
    # Save failed package arrays
    echo "FAILED_ESSENTIAL=(" >> /var/log/up/install-state.sh
    for pkg in "${FAILED_ESSENTIAL[@]}"; do
        echo "    \"$pkg\"" >> /var/log/up/install-state.sh
    done
    echo ")" >> /var/log/up/install-state.sh
    
    echo "FAILED_SYSTEM=(" >> /var/log/up/install-state.sh
    for pkg in "${FAILED_SYSTEM[@]}"; do
        echo "    \"$pkg\"" >> /var/log/up/install-state.sh
    done
    echo ")" >> /var/log/up/install-state.sh
    
    echo "FAILED_SHELL_TOOLS=(" >> /var/log/up/install-state.sh
    for pkg in "${FAILED_SHELL_TOOLS[@]}"; do
        echo "    \"$pkg\"" >> /var/log/up/install-state.sh
    done
    echo ")" >> /var/log/up/install-state.sh
    
    echo "FAILED_COSMETIC=(" >> /var/log/up/install-state.sh
    for pkg in "${FAILED_COSMETIC[@]}"; do
        echo "    \"$pkg\"" >> /var/log/up/install-state.sh
    done
    echo ")" >> /var/log/up/install-state.sh
    
    echo "FAILED_AUR=(" >> /var/log/up/install-state.sh
    for pkg in "${FAILED_AUR[@]}"; do
        echo "    \"$pkg\"" >> /var/log/up/install-state.sh
    done
    echo ")" >> /var/log/up/install-state.sh

    echo "FAILED_APPLICATION=(" >> /var/log/up/install-state.sh
    for pkg in "${FAILED_APPLICATION[@]}"; do
        echo "    \"$pkg\"" >> /var/log/up/install-state.sh
    done
    echo ")" >> /var/log/up/install-state.sh
    
    # Save package counts for total calculation (include bootstrap packages)
    local essential_count=$(echo "$ESSENTIAL_PACKAGES" | wc -w)
    local system_count=$(echo "$SYSTEM_PACKAGES" | wc -w)
    local shell_count=$(echo "$SHELL_TOOLS" | wc -w)
    local cosmetic_count=$(echo "$COSMETIC_PACKAGES" | wc -w)
    local aur_count=$(echo "$AUR_PACKAGES" | wc -w)
    
    echo "TOTAL_PACKAGES=$((essential_count + system_count + shell_count + cosmetic_count + aur_count + bootstrap_count))" >> /var/log/up/install-state.sh
    
    log_info "Installation state saved to /var/log/up/install-state.sh"
}

# Set status message (for TUI progress)
set_status() {
    local message="$1"
    if declare -f tui_progress_status > /dev/null 2>&1; then
        tui_progress_status "$message" || true
    fi
}

# Log installation progress - updates TUI AND logs to file AND shows on console
# Usage: log_install_progress "Installing packages..."
log_install_progress() {
    local message="$1"
    log_info "$message"
    set_status "$message"
}

# Log package failure
log_failure() {
    local type="$1"
    local package="$2"
    case $type in
        "essential") FAILED_ESSENTIAL+=("$package") ;;
        "system") FAILED_SYSTEM+=("$package") ;;
        "shell-tools") FAILED_SHELL_TOOLS+=("$package") ;;
        "cosmetic") FAILED_COSMETIC+=("$package") ;;
        "aur") FAILED_AUR+=("$package") ;;
        "application") FAILED_APPLICATION+=("$package") ;;
    esac

    echo "[FAILURE] $type package $package" >> /var/log/up/install.log
}

# Prompt user when package installation fails.
# Prefers state-utils prompt_package_error (writes install_error + waits for
# error_response via the input pane). Falls back to stdin when TUI helpers
# are unavailable. Returns: retry, continue, or exit
# Usage: prompt_package_error <type> <failed_packages...>
prompt_package_error() {
    local type="$1"
    shift
    local failed_packages=("$@")

    if [ "${UP_UNATTENDED:-}" = "1" ]; then
        log_error "Failed $type packages: ${failed_packages[*]}"
        if [ "$type" = "essential" ]; then
            echo "retry"
        else
            echo "continue"
        fi
        return 0
    fi
    
    log_error "Failed $type packages: ${failed_packages[*]}"
    
    # For essential packages, provide interactive options
    if [ "$type" = "essential" ]; then
        # Prefer the shared TUI protocol (install_error.txt / error_response)
        # so we never wait on package_error_choice which the input pane never writes.
        if declare -f read_input > /dev/null 2>&1 && [ -n "${STATE_DIR:-}" ]; then
            # Call the state-utils implementation if this function was overwritten;
            # inline the same protocol for a reliable handoff to input-watcher.
            clear_answer "error_response" 2>/dev/null || true
            local error_msg="Failed to install $type packages: ${failed_packages[*]}"
            echo "$error_msg" > "$STATE_DIR/install_error.txt"
            printf "%s\n" "${failed_packages[@]}" > "$STATE_DIR/failed_packages.txt"
            echo "retry_continue_exit" > "$STATE_DIR/error_options.txt"
            echo "error_pending" > "$STATE_DIR/pane_state.txt" 2>/dev/null || true
            local response
            response=$(read_input "error_response")
            rm -f "$STATE_DIR/install_error.txt" "$STATE_DIR/failed_packages.txt" "$STATE_DIR/error_options.txt"
            clear_answer "error_response" 2>/dev/null || true
            echo "$response"
            return 0
        fi

        echo ""
        echo "=========================================="
        echo "  Essential package installation failed"
        echo "=========================================="
        echo ""
        echo "Failed packages: ${failed_packages[*]}"
        echo ""
        echo "This is a critical error. Please choose an option:"
        echo ""
        echo "  1) Retry - Attempt to install failed packages again"
        echo "  2) Continue - Proceed anyway (system may be unstable)"
        echo "  3) Exit - Cancel installation and cleanup"
        echo ""
        echo -n "Enter choice (1/2/3): "
        local choice
        read -r choice
        choice="${choice:-1}"

        case "$choice" in
            1|retry) echo "retry" ;;
            2|continue) echo "continue" ;;
            3|exit|*) echo "exit" ;;
        esac
    else
        # For non-essential packages, just log and continue
        log_warning "Some $type packages failed to install. Continuing..."
        echo "continue"
    fi
}

# =============================================================================
# Package Installation Functions
# =============================================================================

# Install a single package
# Usage: install_single_package <package_name> <type>
install_single_package() {
    local package="$1"
    local type="$2"
    
    # Skip if already installed
    if pacman -Q "$package" > /dev/null 2>&1; then
        log_install_progress "  ✓ Already installed: $package"
        return 0
    fi

    log_install_progress "  → Installing $package..."
    if run_pacman -S --noconfirm --needed "$package"; then
        log_install_progress "  ✓ Installed: $package"
        SUCCESS_COUNT=$((SUCCESS_COUNT + 1))

        # Track shell tools specifically
        if [ "$type" = "shell-tools" ]; then
            INSTALLED_SHELL_TOOLS+=("$package")
        fi
        return 0
    else
        log_install_progress "  ✗ Failed: $package"
        log_failure "$type" "$package"
        return 1
    fi
}

# Install packages with fallback to individual installation
# Usage: install_packages_with_fallback <packages> <type> [critical]
#   packages: space-separated list of packages
#   type: essential, system, shell-tools, cosmetic
#   critical: if set to "true", failure stops the install
install_packages_with_fallback() {
    local packages="$1"
    local type="$2"
    local critical="${3:-false}"
    
    local -a failed=()
    local count=0
    local package_list=($packages)
    local total_count=${#package_list[@]}
    local installed_count=0
    
    log_install_progress "📦 Installing $type packages ($total_count total)..."
    
    # Try batch installation first (faster)
    log_install_progress "  Attempting batch installation..."
    # shellcheck disable=SC2086 - we want word splitting for package list
    if run_pacman -S --noconfirm --needed $packages; then
        # Batch succeeded - verify and count with sub-progress updates
        log_install_progress "  Verifying installed packages..."
        for package in $packages; do
            installed_count=$((installed_count + 1))
            # Update status with sub-progress
            set_status "Installing $type: $installed_count/$total_count - $package"
            
            if pacman -Q "$package" > /dev/null 2>&1; then
                count=$((count + 1))
                SUCCESS_COUNT=$((SUCCESS_COUNT + 1))

                # Track shell tools
                if [ "$type" = "shell-tools" ]; then
                    INSTALLED_SHELL_TOOLS+=("$package")
                fi
            else
                failed+=("$package")
                log_failure "$type" "$package"
            fi
        done
        log_install_progress "✅ $type packages installed: $count/$total_count"
    else
        # Batch failed - fall back to individual installation with sub-progress
        log_warning "Batch $type install failed, falling back to individual packages..."
        log_install_progress "⚠️ Batch install failed, installing individually..."
        
        local current=0
        for package in $packages; do
            current=$((current + 1))
            # Update status with sub-progress
            set_status "Installing $type: $current/$total_count - $package"
            
            if ! install_single_package "$package" "$type"; then
                failed+=("$package")
            fi
        done
    fi
    
    # Report failures
    if [ ${#failed[@]} -gt 0 ]; then
        log_warning "Failed $type packages: ${failed[*]}"
        
        # For essential packages, prompt user with error handling
        if [ "$type" = "essential" ]; then
            log_error "Essential package installation failed"
            log_install_progress "❌ Essential packages failed: ${failed[*]}"
            
            # Prompt user for action
            local response=$(prompt_package_error "essential" "${failed[@]}")
            
            case "$response" in
                retry)
                    log_install_progress "Retrying failed essential packages..."
                    for pkg in "${failed[@]}"; do
                        log_install_progress "  Retrying: $pkg"
                        run_pacman -S --noconfirm --needed "$pkg" || true
                    done
                    ;;
                continue)
                    log_warning "Continuing despite essential package failures: ${failed[*]}"
                    ;;
                exit)
                    log_error "User chose to exit. Exiting..."
                    echo "cancelled" > "${STATE_DIR:-/tmp/up-state}/install_cancelled.txt"
                    exit 1
                    ;;
            esac
        fi
    fi
    
    return 0
}

# Install essential packages (convenience wrapper)
install_essential_packages() {
    install_packages_with_fallback "$1" "essential" "true"
}

# Install system packages (convenience wrapper)
install_system_packages() {
    install_packages_with_fallback "$1" "system" "false"
}

# Install shell tools (convenience wrapper)
install_shell_tools() {
    install_packages_with_fallback "$1" "shell-tools" "false"
}

# Install cosmetic packages (convenience wrapper)
install_cosmetic_packages() {
    install_packages_with_fallback "$1" "cosmetic" "false"
}

# Install application packages (convenience wrapper)
install_application_packages() {
    local packages=($1)
    log_install_progress "🔥 Installing application packages..."

    for package in "${packages[@]}"; do
        set_status "App: $package"
        log_install_progress "  → Installing $package..."
        if ! install_aur_package "$package"; then
            log_failure "application" "$package"
        else
            SUCCESS_COUNT=$((SUCCESS_COUNT + 1))
        fi
    done
}

# Install AUR packages in series
install_aur_packages() {
    local packages=($1)
    log_install_progress "🔥 Installing AUR packages..."
    
    for package in "${packages[@]}"; do
        set_status "AUR: $package"
        log_install_progress "  → Installing $package..."
        if ! install_aur_package "$package"; then
            log_failure "aur" "$package"
        else
            SUCCESS_COUNT=$((SUCCESS_COUNT + 1))
        fi
    done
}

# Install single AUR package with retry logic
install_aur_package() {
    local package="$1"
    local max_retries=3
    local retry_delay=5
    
    for attempt in $(seq 1 $max_retries); do
        log_install_progress "    Attempt $attempt/$max_retries for $package"
        
        if run_yay -S --noconfirm "$package"; then
            log_install_progress "✅ AUR package $package installed successfully"
            return 0
        fi
        
        if [ $attempt -lt $max_retries ]; then
            log_warning "Retrying $package in $retry_delay seconds..."
            sleep $retry_delay
        fi
    done
    
    log_error "❌ AUR package $package failed after $max_retries attempts"
    return 1
}

# =============================================================================
# Shell Tools Tracking and .zshrc Generation
# =============================================================================

# Check which shell tools are installed and save to file
check_shell_tools() {
    INSTALLED_SHELL_TOOLS=()

    for tool in zoxide; do
        if command -v "$tool" > /dev/null 2>&1; then
            INSTALLED_SHELL_TOOLS+=("$tool")
        fi
    done

    # Save to file for later reference
    mkdir -p /var/log/up
    echo "INSTALLED_SHELL_TOOLS=(" > /var/log/up/shell-tools.sh
    for tool in "${INSTALLED_SHELL_TOOLS[@]}"; do
        echo "    \"$tool\"" >> /var/log/up/shell-tools.sh
    done
    echo ")" >> /var/log/up/shell-tools.sh

    log_info "Shell tools available: ${INSTALLED_SHELL_TOOLS[*]}"
}

# Check if a shell tool is installed
has_shell_tool() {
    local tool="$1"
    for installed in "${INSTALLED_SHELL_TOOLS[@]}"; do
        if [ "$installed" = "$tool" ]; then
            return 0
        fi
    done
    return 1
}

# Generate .zshrc based on installed tools
# Usage: generate_zshrc <username>
generate_zshrc() {
    local username="$1"
    local zshrc="/home/$username/.zshrc"
    
    log_info "📝 Generating .zshrc for $username..."
    
    # Start with base config
    cat > "$zshrc" << 'EOF'
# XLibre i3 Zsh config — clean + Starship + dev tools

# History
HISTSIZE=10000
SAVEHIST=10000
setopt SHARE_HISTORY APPEND_HISTORY

# Completion (reuse dump unless it is a week old — skips the slow security scan)
autoload -Uz compinit
if [[ -f ${ZDOTDIR:-$HOME}/.zcompdump && -z $(find ${ZDOTDIR:-$HOME}/.zcompdump -mtime +7 2>/dev/null) ]]; then
  compinit -C -u
else
  compinit -u
fi

# Editor
alias vim='nvim'
alias update='sudo $UP_ROOT/update.sh'
EOF

    # Add zoxide if installed
    if has_shell_tool "zoxide"; then
        cat >> "$zshrc" << 'EOF'

# zoxide (smart directory jumping) - use 'z <dir>' or 'z -l' to list
eval "$(zoxide init zsh)"
EOF
        log_install_progress "  ✓ Added zoxide initialization"
    fi

    # Add starship and theme (always present)
    cat >> "$zshrc" << 'EOF'

# Starship prompt
eval "$(starship init zsh)"

# Theme colors (auto-generated by switch-theme.sh - do not edit)
[[ -f ~/.config/zsh/theme.zsh ]] && source ~/.config/zsh/theme.zsh
EOF

    # Set ownership
    chown "$username:$username" "$zshrc"
    
    log_info "✅ .zshrc generated"
}


# =============================================================================
# Exports
# =============================================================================
export -f initialize_tracking
export -f run_and_log run_pacman run_yay run_pacstrap_with_progress
export -f set_status
export -f log_install_progress
export -f log_failure
export -f prompt_package_error
export -f install_single_package
export -f install_packages_with_fallback
export -f install_essential_packages
export -f install_system_packages
export -f install_shell_tools
export -f install_cosmetic_packages
export -f install_application_packages
export -f install_aur_packages
export -f install_aur_package
export -f check_shell_tools
export -f has_shell_tool
export -f generate_zshrc
export -f enable_service_safe
export -f save_failed_services
export -f save_installation_state
