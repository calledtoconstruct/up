#!/bin/bash
# Install VS Code with Cline extension pre-configured
# Usage: ./install-vscode.sh [--with-cline]

set -euo pipefail

# Get script directory and source utilities
SCRIPT_DIR="$UP_ROOT/configs/scripts/install"
source "$SCRIPT_DIR/install-utils.sh"

# Parse arguments
WITH_CLINE=false
while [[ $# -gt 0 ]]; do
    case $1 in
        --with-cline)
            WITH_CLINE=true
            shift
            ;;
        *)
            shift
            ;;
    esac
done

echo ""
echo "═══════════════════════════════════════════════════════════════"
echo "  VS Code Installation"
echo "═══════════════════════════════════════════════════════════════"
echo ""

# Check if already installed
if cmd_exists code; then
    success "VS Code is already installed"
    code --version
else
    info "Installing VS Code from AUR..."
    
    # Check for yay
    if ! cmd_exists yay; then
        error "yay is required to install VS Code from AUR"
        info "Please install yay first: sudo pacman -S yay"
        exit 1
    fi

    # Helper function to run yay as non-root user (exit sudo state)
    _run_yay_as_user() {
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

    # Install VS Code
    _run_yay_as_user yay -S --noconfirm --needed visual-studio-code-bin
    
    if cmd_exists code; then
        success "VS Code installed successfully"
    else
        error "VS Code installation failed"
        exit 1
    fi
fi

echo ""
info "Configuring VS Code..."

# Create config directories
mkdir -p ~/.vscode
mkdir -p ~/.config/Code/User

# Configure password store for VS Code (using gnome-libsecret)
VSCODE_ARGV="$HOME/.vscode/argv.json"
if [ ! -f "$VSCODE_ARGV" ]; then
    cat > "$VSCODE_ARGV" << 'EOF'
// This configuration file allows you to pass permanent command line arguments to VS Code.
// Only a subset of arguments is currently supported to reduce the likelihood of breaking
// the installation.
//
// PLEASE DO NOT CHANGE WITHOUT UNDERSTANDING THE IMPACT
//
// NOTE: Changing this file requires a restart of VS Code.
{
  "password-store": "gnome-libsecret"
}
EOF
    success "Configured password store for VS Code"
else
    info "argv.json already exists, skipping"
fi

# Configure VS Code settings
VSCODE_SETTINGS="$HOME/.config/Code/User/settings.json"
if [ ! -f "$VSCODE_SETTINGS" ]; then
    cat > "$VSCODE_SETTINGS" << 'EOF'
{
  "update.mode": "none",
  "telemetry.telemetryLevel": "off",
  "workbench.startupEditor": "none",
  "editor.minimap.enabled": false,
  "editor.formatOnSave": true,
  "editor.tabSize": 2,
  "files.autoSave": "afterDelay",
  "files.autoSaveDelay": 1000
}
EOF
    success "Created VS Code settings.json"
else
    info "settings.json already exists, skipping"
fi

# Install Cline extension if requested
if [ "$WITH_CLINE" = true ]; then
    echo ""
    info "Installing Cline extension..."
    
    CLINE_EXTENSION="saoudrizwan.claude-dev"
    
    if vscode_extension_installed "$CLINE_EXTENSION"; then
        success "Cline extension already installed"
    else
        vscode_install_extension "$CLINE_EXTENSION"
        
        if vscode_extension_installed "$CLINE_EXTENSION"; then
            success "Cline extension installed successfully"
            echo ""
            echo "  ┌─────────────────────────────────────────────────────────────┐"
            echo "  │  Cline is installed! To configure:                          │"
            echo "  │  1. Open VS Code                                            │"
            echo "  │  2. Press Ctrl+Shift+P and search 'Cline'                   │"
            echo "  │  3. Configure your API provider and key                     │"
            echo "  └─────────────────────────────────────────────────────────────┘"
        else
            warn "Cline extension installation may have failed"
        fi
    fi
fi

echo ""
echo "═══════════════════════════════════════════════════════════════"
echo "  VS Code Installation Complete!"
echo "═══════════════════════════════════════════════════════════════"
echo ""

# Offer to launch VS Code
if [ -t 0 ]; then
    read -p "Launch VS Code now? [y/N] " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        setsid gtk-launch code 2>/dev/null || code &
    fi
fi