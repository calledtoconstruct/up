#!/bin/bash
# Install Menu - Rofi-based menu for installing developer tools
# Triggered from system-menu or directly

set -euo pipefail

# Function to check if a tool is installed
check_installed() {
    local tool="$1"
    case "$tool" in
        vscode)
            command -v code &> /dev/null
            ;;
        cline)
            command -v code &> /dev/null && code --list-extensions 2>/dev/null | grep -Fxq "saoudrizwan.claude-dev"
            ;;
        ghcup)
            command -v ghcup &> /dev/null
            ;;
        haskell-hls)
            command -v haskell-language-server-wrapper &> /dev/null || command -v hls &> /dev/null
            ;;
        *)
            command -v "$tool" &> /dev/null
            ;;
    esac
}

# Get status indicator
get_status() {
    if check_installed "$1"; then
        echo "✓"
    else
        echo "✗"
    fi
}

# Menu options with icons (format: "icon|label|status_check|install_command")
# Uses up-* commands from /usr/local/share/up/bin (in PATH)
MENU_OPTIONS=(
    "📝|VS Code|vscode|up-install-vscode"
    "🤖|Cline Extension|cline|up-install-vscode --with-cline"
    "─|──────────────────|:|:"
    "λ|GHCup (Haskell)|ghcup|up-install-ghcup"
    "🔧|Haskell LS|haskell-hls|up-install-ghcup --with-hls"
)

# Build the menu string with status indicators
MENU_STRING=""
for option in "${MENU_OPTIONS[@]}"; do
    icon=$(echo "$option" | cut -d'|' -f1)
    label=$(echo "$option" | cut -d'|' -f2)
    status_check=$(echo "$option" | cut -d'|' -f3)
    
    # Skip separator lines for status check
    if [ "$status_check" = ":" ]; then
        MENU_STRING="${MENU_STRING}${icon}  ${label}\n"
    else
        status=$(get_status "$status_check")
        MENU_STRING="${MENU_STRING}${icon}  ${label} [${status}]\n"
    fi
done

# Remove trailing newline
MENU_STRING=$(echo -e "$MENU_STRING" | head -c -2)

# Show rofi menu
SELECTED=$(echo -e "$MENU_STRING" | rofi -dmenu -i -p "Install Tools" -lines 10 -width 350 -kb-cancel Escape)

# Exit if nothing selected
if [ -z "$SELECTED" ]; then
    exit 0
fi

# Extract label from selected line (remove icon prefix and status)
LABEL=$(echo "$SELECTED" | sed 's/^[^ ]*  //' | sed 's/ \[.\]$//')

# Find and execute the corresponding command
for option in "${MENU_OPTIONS[@]}"; do
    opt_label=$(echo "$option" | cut -d'|' -f2)
    status_check=$(echo "$option" | cut -d'|' -f3)
    cmd=$(echo "$option" | cut -d'|' -f4)
    
    # Handle both with and without status indicator
    if [ "$LABEL" = "$opt_label" ] || [ "$SELECTED" = *"$opt_label"* ]; then
        # Skip separator lines
        if [ "$status_check" = ":" ]; then
            exit 0
        fi
        
        # Check if already installed and ask for confirmation
        if check_installed "$status_check"; then
            confirm=$(echo -e "Reinstall\nCancel" | rofi -dmenu -i -p "$opt_label already installed" -lines 2 -kb-cancel Escape)
            if [ "$confirm" != "Reinstall" ]; then
                exit 0
            fi
        fi
        
        # Run install in terminal for visibility
        alacritty --class install-terminal -e bash -c "echo 'Installing $opt_label...'; echo; $cmd; echo; read -p 'Press Enter to close...'"
        exit 0
    fi
done

echo "Unknown selection: $SELECTED"