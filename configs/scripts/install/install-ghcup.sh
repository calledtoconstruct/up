#!/bin/bash
# Install GHCup with Haskell Language Server
# Usage: ./install-ghcup.sh [--with-hls] [--with-stack]

set -euo pipefail

# Get script directory and source utilities
SCRIPT_DIR="$UP_ROOT/configs/scripts/install"
source "$SCRIPT_DIR/install-utils.sh"

# Parse arguments
WITH_HLS=true  # Default to installing HLS
WITH_STACK=false
while [[ $# -gt 0 ]]; do
    case $1 in
        --with-hls)
            WITH_HLS=true
            shift
            ;;
        --no-hls)
            WITH_HLS=false
            shift
            ;;
        --with-stack)
            WITH_STACK=true
            shift
            ;;
        *)
            shift
            ;;
    esac
done

echo ""
echo "═══════════════════════════════════════════════════════════════"
echo "  GHCup Installation (Haskell Toolchain)"
echo "═══════════════════════════════════════════════════════════════"
echo ""

# Check if ghcup is already installed
if cmd_exists ghcup; then
    success "GHCup is already installed"
    ghcup --version
    echo ""
    
    # Show installed tools
    info "Installed Haskell tools:"
    ghcup list 2>/dev/null | head -20 || true
    
    echo ""
    read -p "Reinstall/update GHCup? [y/N] " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        info "Skipping GHCup installation"
        exit 0
    fi
fi

# Install Arch Linux dependencies
echo ""
info "Installing system dependencies..."

DEPENDENCIES=(
    base-devel
    curl
    wget
    git
    gmp
    gmp-devel
    ncurses
    xz
    zlib
    libffi
    pkgconf
)

# Check if we're on Arch
if [ -f /etc/arch-release ]; then
    # Map generic names to Arch package names
    ARCH_DEPS=(
        base-devel
        curl
        wget
        git
        gmp
        gmp-devel
        ncurses
        xz
        zlib
        libffi
        pkgconf
    )
    
    sudo pacman -S --noconfirm --needed "${ARCH_DEPS[@]}" 2>/dev/null || {
        warn "Some dependencies may have failed to install"
    }
    success "System dependencies installed"
else
    warn "Not running on Arch Linux. Please ensure you have the required dependencies:"
    echo "  - build-essential, curl, wget, git"
    echo "  - gmp, gmp-devel, ncurses, xz, zlib, libffi"
    read -p "Continue anyway? [y/N] " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        exit 1
    fi
fi

echo ""
info "Configuring GHCup installation..."

# Build environment variables for non-interactive installation
export BOOTSTRAP_HASKELL_NONINTERACTIVE=1
export BOOTSTRAP_HASKELL_GHC_VERSION="${BOOTSTRAP_HASKELL_GHC_VERSION:-recommended}"
export BOOTSTRAP_HASKELL_CABAL_VERSION="${BOOTSTRAP_HASKELL_CABAL_VERSION:-recommended}"
export BOOTSTRAP_HASKELL_HLS_VERSION="${BOOTSTRAP_HASKELL_HLS_VERSION:-recommended}"

# HLS installation (default: yes)
if [ "$WITH_HLS" = true ]; then
    export BOOTSTRAP_HASKELL_INSTALL_HLS=1
    info "Haskell Language Server will be installed"
else
    export BOOTSTRAP_HASKELL_INSTALL_HLS=0
    info "Haskell Language Server will NOT be installed"
fi

# Stack installation (default: no)
if [ "$WITH_STACK" = true ]; then
    export BOOTSTRAP_HASKELL_INSTALL_NO_STACK=0
    export BOOTSTRAP_HASKELL_STACK_VERSION="${BOOTSTRAP_HASKELL_STACK_VERSION:-recommended}"
    info "Stack will be installed"
else
    export BOOTSTRAP_HASKELL_INSTALL_NO_STACK=1
    info "Stack will NOT be installed"
fi

# Adjust bashrc for PATH
export BOOTSTRAP_HASKELL_ADJUST_BASHRC=1

# Use XDG directories (optional, cleaner)
export GHCUP_USE_XDG_DIRS="${GHCUP_USE_XDG_DIRS:-0}"

echo ""
info "Installing GHCup and Haskell toolchain..."
echo "  - GHC: $BOOTSTRAP_HASKELL_GHC_VERSION"
echo "  - Cabal: $BOOTSTRAP_HASKELL_CABAL_VERSION"
echo "  - HLS: $([ "$WITH_HLS" = true ] && echo "yes" || echo "no")"
echo "  - Stack: $([ "$WITH_STACK" = true ] && echo "yes" || echo "no")"
echo ""

# Download and run the GHCup installer
curl --proto '=https' --tlsv1.2 -sSf https://get-ghcup.haskell.org | sh

# Source the new PATH
if [ -f "$HOME/.ghcup/env" ]; then
    source "$HOME/.ghcup/env"
elif [ -f "$HOME/.local/share/ghcup/env" ]; then
    source "$HOME/.local/share/ghcup/env"
fi

# Verify installation
echo ""
echo "═══════════════════════════════════════════════════════════════"
echo "  Installation Results"
echo "═══════════════════════════════════════════════════════════════"
echo ""

if cmd_exists ghcup; then
    success "GHCup: $(ghcup --version 2>/dev/null || echo 'installed')"
else
    error "GHCup installation failed"
    exit 1
fi

if cmd_exists ghc; then
    success "GHC: $(ghc --version 2>/dev/null || echo 'installed')"
else
    warn "GHC not found in PATH"
fi

if cmd_exists cabal; then
    success "Cabal: $(cabal --version 2>/dev/null | head -1 || echo 'installed')"
else
    warn "Cabal not found in PATH"
fi

if [ "$WITH_HLS" = true ]; then
    if cmd_exists haskell-language-server-wrapper || cmd_exists hls; then
        success "HLS: $(haskell-language-server-wrapper --version 2>/dev/null | head -1 || echo 'installed')"
    else
        warn "HLS not found - may need manual installation"
        info "Run: ghcup install hls"
    fi
fi

if [ "$WITH_STACK" = true ]; then
    if cmd_exists stack; then
        success "Stack: $(stack --version 2>/dev/null | head -1 || echo 'installed')"
    else
        warn "Stack not found in PATH"
    fi
fi

# Update cabal package index
echo ""
info "Updating Cabal package index..."
if cmd_exists cabal; then
    cabal update 2>/dev/null || warn "Cabal update failed (network issue?)"
    success "Cabal package index updated"
fi

echo ""
echo "═══════════════════════════════════════════════════════════════"
echo "  GHCup Installation Complete!"
echo "═══════════════════════════════════════════════════════════════"
echo ""
echo "  PATH has been added to your shell config."
echo "  Restart your terminal or run:"
echo ""
echo "    source ~/.ghcup/env    (if installed to ~/.ghcup)"
echo "    source ~/.local/share/ghcup/env    (if using XDG)"
echo ""
echo "  Useful commands:"
echo "    ghcup list          - List available/installed tools"
echo "    ghcup install hls   - Install Haskell Language Server"
echo "    ghcup upgrade       - Upgrade GHCup itself"
echo ""

# Install Haskell VS Code extension if VS Code is installed
if cmd_exists code; then
    echo ""
    read -p "Install Haskell extension for VS Code? [Y/n] " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Nn]$ ]]; then
        vscode_install_extension "haskell.haskell"
        vscode_install_extension "justusadam.language-haskell"
    fi
fi