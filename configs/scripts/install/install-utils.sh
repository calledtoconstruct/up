#!/bin/bash
# Install Utilities - Shared functions for install scripts
# Source this file in other install scripts

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Print colored status messages
info() {
    echo -e "${BLUE}→${NC} $1"
}

success() {
    echo -e "${GREEN}✓${NC} $1"
}

warn() {
    echo -e "${YELLOW}!${NC} $1"
}

error() {
    echo -e "${RED}✗${NC} $1" >&2
}

# Check if a command exists
cmd_exists() {
    command -v "$1" &> /dev/null
}

# Check if a package is installed (pacman)
pkg_installed() {
    pacman -Qi "$1" &> /dev/null
}

# Helper function to run commands as non-root user (exit sudo state)
_run_as_user() {
    local target_user=""

    if [ -n "${SUDO_USER:-}" ]; then
        # Called via sudo - run as the original user
        target_user="$SUDO_USER"
    else
        # Fallback - find first non-root user with UID >= 1000
        target_user=$(getent passwd | awk -F: '$3 >= 1000 && $3 < 65534 {print $1; exit}')
    fi

    if [ -n "$target_user" ] && [ "$target_user" != "root" ] && id "$target_user" &>/dev/null; then
        runuser -u "$target_user" -- "$@"
    else
        "$@"
    fi
}

# Check if a package is installed from AUR (yay)
aur_pkg_installed() {
    _run_as_user yay -Q "$1" &> /dev/null 2>&1
}

# Install packages using pacman
pkg_add() {
    local pkgs=("$@")
    
    # Filter out already installed packages
    local to_install=()
    for pkg in "${pkgs[@]}"; do
        if ! pkg_installed "$pkg"; then
            to_install+=("$pkg")
        fi
    done
    
    if [ ${#to_install[@]} -eq 0 ]; then
        info "All packages already installed"
        return 0
    fi
    
    info "Installing: ${to_install[*]}"
    sudo pacman -S --noconfirm --needed "${to_install[@]}"
    
    # Verify installation
    for pkg in "${to_install[@]}"; do
        if ! pkg_installed "$pkg"; then
            error "Package '$pkg' failed to install"
            return 1
        fi
    done
    
    success "Packages installed successfully"
}

# Install packages using yay (AUR support)
yay_add() {
    local pkgs=("$@")
    
    # Check if yay is installed
    if ! cmd_exists yay; then
        error "yay is not installed. Install it first."
        return 1
    fi
    
    # Filter out already installed packages
    local to_install=()
    for pkg in "${pkgs[@]}"; do
        if ! pkg_installed "$pkg" && ! aur_pkg_installed "$pkg"; then
            to_install+=("$pkg")
        fi
    done
    
    if [ ${#to_install[@]} -eq 0 ]; then
        info "All packages already installed"
        return 0
    fi
    
    info "Installing from AUR: ${to_install[*]}"
    _run_as_user yay -S --noconfirm --needed "${to_install[@]}"

    # Verify installation
    for pkg in "${to_install[@]}"; do
        if ! pkg_installed "$pkg" && ! aur_pkg_installed "$pkg"; then
            error "Package '$pkg' failed to install"
            return 1
        fi
    done
    
    success "AUR packages installed successfully"
}

# Install VS Code extension
vscode_install_extension() {
    local extension="$1"
    local code_cmd=""
    
    # Determine which code command to use
    if cmd_exists code; then
        code_cmd="code"
    elif cmd_exists codium; then
        code_cmd="codium"
    else
        error "Neither 'code' nor 'codium' found"
        return 1
    fi
    
    # Check if extension is already installed
    if $code_cmd --list-extensions | grep -Fxq "$extension" 2>/dev/null; then
        info "Extension '$extension' already installed"
        return 0
    fi
    
    info "Installing VS Code extension: $extension"
    $code_cmd --install-extension "$extension"
    success "Extension '$extension' installed"
}

# Check if VS Code extension is installed
vscode_extension_installed() {
    local extension="$1"
    local code_cmd=""
    
    if cmd_exists code; then
        code_cmd="code"
    elif cmd_exists codium; then
        code_cmd="codium"
    else
        return 1
    fi
    
    $code_cmd --list-extensions 2>/dev/null | grep -Fxq "$extension"
}

# Add line to file if not already present
add_to_file() {
    local file="$1"
    local line="$2"
    
    mkdir -p "$(dirname "$file")"
    
    if [ -f "$file" ]; then
        if ! grep -Fxq "$line" "$file"; then
            echo "$line" >> "$file"
        fi
    else
        echo "$line" > "$file"
    fi
}

# Add PATH to shell config if not present
add_to_path() {
    local path_dir="$1"
    local shell_rc=""
    
    # Detect shell config file
    if [ -n "${ZSH_VERSION:-}" ]; then
        shell_rc="$HOME/.zshrc"
    elif [ -n "${BASH_VERSION:-}" ]; then
        shell_rc="$HOME/.bashrc"
    else
        shell_rc="$HOME/.profile"
    fi
    
    local export_line="export PATH=\"$path_dir:\$PATH\""
    
    if [ -f "$shell_rc" ]; then
        if ! grep -q "$path_dir" "$shell_rc"; then
            echo "" >> "$shell_rc"
            echo "# Added by up install script" >> "$shell_rc"
            echo "$export_line" >> "$shell_rc"
            info "Added $path_dir to PATH in $shell_rc"
        fi
    fi
}

# Get install script directory
get_install_dir() {
    echo "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
}