#!/bin/bash
# Function to install yay AUR helper
# Usage: source this file and call install_yay
# Sets: YAY_AVAILABLE=true if successful, false otherwise

set -euo pipefail

# Global state variable - can be checked after install_yay completes
YAY_AVAILABLE=false
export YAY_AVAILABLE

# Helper to log to file only
_yay_log() {
    local message="$1"
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    local log_file="${INSTALL_LOG_FILE:-/var/log/up/install.log}"
    mkdir -p "$(dirname "$log_file")" 2>/dev/null || true
    echo "[$timestamp] [YAY] $message" >> "$log_file"
}

# Run command and log output safely (isolates TUI operations from command status)
_yay_run() {
    local tmp_file
    tmp_file=$(mktemp)
    
    # Run command, capture all output to temp file
    # Use "$@" to pass arguments properly without eval
    "$@" > "$tmp_file" 2>&1
    local cmd_status=$?
    
    # Log output through TUI (non-fatally)
    while IFS= read -r line; do
        _yay_log "  $line" || true
    done < "$tmp_file" 2>/dev/null || true
    
    rm -f "$tmp_file"
    return $cmd_status
}

install_yay() {
    # Check if yay is already available
    if command -v yay &> /dev/null; then
        _yay_log "→ yay already installed"
        YAY_AVAILABLE=true
        return 0
    fi
    
    _yay_log "→ Installing yay for AUR support..."
    
    # Install build dependencies (use --quiet to suppress package list)
    _yay_run pacman -Syu --noconfirm --quiet || true
    _yay_run pacman -S --needed --noconfirm --quiet git base-devel || true
    
    # Prepare build directory owned by user (makepkg refuses to run as root)
    mkdir -p /tmp/yaybuild
    chown nobody:nobody /tmp/yaybuild 2>/dev/null || true

    local build_success=false

    cd /tmp/yaybuild
    if _yay_run runuser -u nobody -- git clone --depth 1 https://aur.archlinux.org/yay-bin.git; then
        cd yay-bin
        if _yay_run runuser -u nobody -- makepkg -s --noconfirm; then
            build_success=true
        fi
    fi

    # Check if package was built
    if [ "$build_success" = true ] && ls yay-bin-*.pkg.tar.zst 1>/dev/null 2>&1; then
        # Install the built package (cannot use --quiet to suppress output)
        _yay_run pacman -U --noconfirm yay-bin-*.pkg.tar.zst || true
    fi

    # Clean up build directory
    cd /
    rm -rf /tmp/yaybuild

    # Verify yay is installed
    if command -v yay &> /dev/null; then
        _yay_log "→ yay installed successfully"
        _yay_log "→ Refreshing yay catalog"
        # Run as root during installation (chroot environment)
        _yay_run yay -Sy --noconfirm --quiet || true

        YAY_AVAILABLE=true
        return 0
    else
        _yay_log "→ Warning: yay installation failed"
        _yay_log "→ You can install it manually after reboot:"
        _yay_log "→   git clone https://aur.archlinux.org/yay-bin.git"
        _yay_log "→   cd yay-bin && makepkg -si"
        YAY_AVAILABLE=false
        return 1
    fi
}
