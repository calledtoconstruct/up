#!/bin/bash
# Up Linux One-Command Installer
# Installs tmux and launches the parallel tmux-based installation process
# Run this from Arch ISO after network setup

set -euo pipefail

echo "Up Linux Installer"
echo "Installing tmux for parallel progress and input..."

pacman -Sy --noconfirm --needed tmux

# Set UP_ROOT for installation scripts (runs from /root/up on Arch ISO)
export UP_ROOT="${UP_ROOT:-/root/up}"
SCRIPT_DIR="$UP_ROOT"
cd "$SCRIPT_DIR"

# Tmux session configuration (host-side state directory)
STATE_DIR="/tmp/up-state"
LOG_FILE="/var/log/up/install.log"
TMUX_SESSION="up-install"

# Source colors
source "$SCRIPT_DIR/configs/scripts/colors.sh"

# Minimum terminal size check
MIN_COLS=80
MIN_ROWS=30

check_terminal_size() {
    local current_cols=$(tput cols 2>/dev/null || echo 80)
    local current_rows=$(tput lines 2>/dev/null || echo 50)
    
    if [ "$current_cols" -lt "$MIN_COLS" ] || [ "$current_rows" -lt "$MIN_ROWS" ]; then
        echo -e "${YELLOW}Warning: Terminal too small. Minimum size: ${MIN_COLS}x${MIN_ROWS}${NC}"
        echo -e "${YELLOW}Current size: ${current_cols}x${current_rows}${NC}"
        echo -e "${YELLOW}Press Enter to continue or Ctrl+C to cancel...${NC}"
        read -r
    fi
}

# Cleanup function for cancelled installations
# Never sources bootstrap.sh (that would re-run the install).
cleanup_and_exit() {
    echo ""
    echo "Installation cancelled by user."
    
    # Kill tmux session
    tmux kill-session -t "$TMUX_SESSION" 2>/dev/null || true
    
    # Read disk from durable answer, legacy input, or boot-config if already written
    local disk=""
    if [ -f "$STATE_DIR/disk.answer" ]; then
        disk=$(cat "$STATE_DIR/disk.answer" 2>/dev/null || true)
        disk="${disk//$'\n'/}"
    elif [ -f "$STATE_DIR/disk.input" ]; then
        disk=$(cat "$STATE_DIR/disk.input" 2>/dev/null || true)
        disk="${disk//$'\n'/}"
    fi
    # bootstrap may have progressed past input; check boot-config under /mnt if present
    if [ -z "$disk" ] && [ -f /mnt/root/up/.boot-config ]; then
        # shellcheck disable=SC1091
        disk=$(grep '^DISK=' /mnt/root/up/.boot-config 2>/dev/null | cut -d= -f2- || true)
    fi

    # Source only the cleanup helper library
    if [ -f "$UP_ROOT/configs/scripts/partition-utils.sh" ]; then
        # shellcheck disable=SC1091
        source "$UP_ROOT/configs/scripts/partition-utils.sh"
        cleanup_partitions "${disk:-}"
    else
        umount --recursive /mnt 2>/dev/null || true
        swapoff -a 2>/dev/null || true
    fi
    
    # Signal cancellation for any waiting processes
    mkdir -p "$STATE_DIR" 2>/dev/null || true
    echo "cancelled" > "$STATE_DIR/install_cancelled.txt" 2>/dev/null || true
    
    echo "Cleanup complete. You can restart the installation with: ./install.sh"
    exit 1
}

# Set trap for Ctrl+C
trap cleanup_and_exit SIGINT SIGTERM

# Calculate total installation steps dynamically
calculate_total_steps() {
    # Source package groups to get package counts
    source "$SCRIPT_DIR/configs/scripts/package-groups.sh"
    
    # Base installation steps (disk, format, mount, pacstrap, etc.)
    local base_steps=11  # Steps 1-11 in bootstrap.sh
    
    # Count package batches (not individual packages, since they install in batches)
    local essential_batches=1    # All essential in one batch
    local system_batches=1       # All system in one batch
    local shell_batches=1        # Shell tools in one batch
    local cosmetic_batches=1     # Cosmetic in one batch
    local application_batches=1  # Application packages in one batch
    local aur_batches=$(echo "$AUR_PACKAGES" | wc -w)  # AUR packages individually
    
    # Config deployment steps
    local config_steps=3  # Deploy configs, GRUB, services
    
    # Total
    local total=$((base_steps + essential_batches + system_batches + shell_batches + cosmetic_batches + application_batches + aur_batches + config_steps))
    
    echo "$total"
}

# Create state directory
setup_state() {
    # Clean up any previous state files from failed installs
    rm -rf "$STATE_DIR"/*
    mkdir -p "$STATE_DIR"
    mkdir -p "$(dirname "$LOG_FILE")"
    echo "=== Up Install Started at $(date) ===" > "$LOG_FILE"

    # Calculate dynamic total steps
    local total_steps=$(calculate_total_steps)

    # Initial state
    echo "Up Linux Installer" > "$STATE_DIR/title.txt"
    echo "From Arch ISO to Full Tiling Desktop with Theme Support" > "$STATE_DIR/subtitle.txt"
    echo "0" > "$STATE_DIR/progress_current.txt"
    echo "$total_steps" > "$STATE_DIR/progress_total.txt"
    echo "Initializing..." > "$STATE_DIR/status.txt"
    echo "1|Welcome & Repo" > "$STATE_DIR/current_phase.txt"

    # Phases list (derived from bootstrap/setup steps)
    cat > "$STATE_DIR/phases.txt" << EOF
1. Welcome & Repo
2. Disk Selection
3. Partitioning
4. Formatting & Mounting
5. Pacstrapping Base
6. Base Config (Hostname/Time/Locale)
7. User Account & Passwords
8. XLibre Repo Setup
9. Essential Packages
10. System Packages
11. Shell & Cosmetic Packages
12. AUR Packages
13. Config Deployment
14. GRUB & Services
15. Welcome to Up Linux
EOF

    echo "State initialized in $STATE_DIR (total steps: $total_steps)"
}

# Launch tmux with responsive layout
launch_tmux() {
    # Kill existing session if any
    tmux kill-session -t "$TMUX_SESSION" 2>/dev/null || true

    # Get terminal dimensions
    local TERM_COLS=$(tput cols 2>/dev/null || echo 120)
    local TERM_ROWS=$(tput lines 2>/dev/null || echo 50)

    # Calculate pane sizes
    local TITLE_HEIGHT=4
    local PROGRESS_BAR_HEIGHT=3  # Fixed height for progress bar pane
    local INPUT_HEIGHT=22  # During input collection
    # Remaining height for log and phase panes
    local MAIN_HEIGHT=$((TERM_ROWS - TITLE_HEIGHT - PROGRESS_BAR_HEIGHT - INPUT_HEIGHT))
    
    # Ensure minimum heights
    [ "$MAIN_HEIGHT" -lt 5 ] && MAIN_HEIGHT=5
    [ "$INPUT_HEIGHT" -lt 10 ] && INPUT_HEIGHT=10

    # Launch tmux session with calculated dimensions
    tmux new-session -d -s "$TMUX_SESSION" -x "$TERM_COLS" -y "$TERM_ROWS" -n "install" "bash $SCRIPT_DIR/configs/scripts/title-watcher.sh"
    
    # Split for progress bar pane (3 lines, full width)
    tmux split-window -t "$TMUX_SESSION:0" -v "bash $SCRIPT_DIR/configs/scripts/progress-bar-watcher.sh"

    # Split for main content area (log + phase panes)
    tmux split-window -t "$TMUX_SESSION:0" -v "bash $SCRIPT_DIR/configs/scripts/phase-watcher.sh"
    
    # Split for input pane (fixed height during input)
    tmux split-window -t "$TMUX_SESSION:0" -v "bash $SCRIPT_DIR/configs/scripts/input-watcher.sh"

    # Set title pane height
    tmux resize-pane -t "$TMUX_SESSION:0.0" -y "$TITLE_HEIGHT"
    tmux resize-pane -t "$TMUX_SESSION:0.1" -y "$PROGRESS_BAR_HEIGHT"
    tmux resize-pane -t "$TMUX_SESSION:0.2" -y "$MAIN_HEIGHT"
    tmux resize-pane -t "$TMUX_SESSION:0.3" -y "$INPUT_HEIGHT"
    
    # Split main content area horizontally for log watcher (right) and phase watcher (left)
    # Phase watcher gets 40% of the width
    tmux split-window -t "$TMUX_SESSION:0.2" -h -p 60 "bash $SCRIPT_DIR/configs/scripts/log-watcher.sh"

    # Launch bootstrap process in separate window
    tmux new-window -t "$TMUX_SESSION" -n "process" "cd /root/up && UP_ROOT=/root/up ./bootstrap.sh 2>&1 | tee -a /var/log/up/install.log"
    tmux select-window -t "$TMUX_SESSION:1"
    tmux select-pane -t "$TMUX_SESSION:1"

    tmux select-window -t "$TMUX_SESSION:0"
    tmux select-pane -t "$TMUX_SESSION:0.4"

    echo "Tmux session launched (${TERM_COLS}x${TERM_ROWS}). Attaching to session..."
    echo "Focus is on input pane - start typing your responses."
    
    # Initialize pane state
    echo "input_pending" > "$STATE_DIR/pane_state.txt"
    
    # Start background monitor to manage input pane sizing using state machine
    (
        while true; do
            local current_state=$(cat "$STATE_DIR/pane_state.txt" 2>/dev/null || echo "input_pending")
            
            case "$current_state" in
                input_pending)
                    tmux resize-pane -t "$TMUX_SESSION:0.4" -y 22 2>/dev/null || true
                    ;;
                input_complete)
                    tmux resize-pane -t "$TMUX_SESSION:0.4" -y 3 2>/dev/null || true
                    ;;
                error_pending)
                    tmux resize-pane -t "$TMUX_SESSION:0.4" -y 15 2>/dev/null || true
                    ;;
                install_complete)
                    tmux resize-pane -t "$TMUX_SESSION:0.4" -y 8 2>/dev/null || true
                    break
                    ;;
            esac
            
            sleep 1
        done
    ) &
}

# Setup and launch
setup_state
launch_tmux

# Attach to the tmux session
echo "Attaching to tmux session..."
TMUX="" tmux attach -t "$TMUX_SESSION"

# Wait for installation to complete or be cancelled
echo "Waiting for installation to finish..."
while true; do
    if [ -f "$STATE_DIR/install_complete.txt" ]; then
        echo "Installation completed successfully!"
        break
    elif [ -f "$STATE_DIR/install_cancelled.txt" ]; then
        echo "Installation was cancelled."
        break
    fi
    sleep 2
done

# Clean up tmux session
echo "Cleaning up tmux session..."
tmux kill-session -t "$TMUX_SESSION" 2>/dev/null || true

echo "Installation process finished."
