# Post-Installation Improvements

## Overview
Improve the post-installation experience through first-boot welcome, keybinding discoverability, help system, and configurable font size.

---

## 1. First-Boot Experience

### Prerequisites
- None

### Implementation Details

**New File:** `configs/scripts/first-boot.sh`

**Purpose:** Run once on first login to guide the user through initial setup.

**Trigger:** Added to `~/.xinitrc` or i3 config, checks for `~/.config/up/first-boot-done` flag.

```bash
#!/bin/bash
# First Boot Experience
# Runs once on first login to guide user through initial setup

set -euo pipefail

FLAG_FILE="$HOME/.config/up/first-boot-done"
UP_ROOT="${UP_ROOT:-/usr/local/share/up}"

# Skip if already completed
if [ -f "$FLAG_FILE" ]; then
    exit 0
fi

# Show welcome notification
notify-send "Welcome to Up Linux!" "Run 'up-quickstart' to set up your system, or press Super+Alt+Space for the system menu." -t 10000

# Check WiFi connection
if ! nmcli -t -f WIFI general | grep -q "enabled"; then
    sleep 2
    notify-send "WiFi Not Connected" "Click here to connect to WiFi" -t 0 --action="connect=Connect" 2>/dev/null || true
fi

# Mark first boot as done
mkdir -p "$(dirname "$FLAG_FILE")"
touch "$FLAG_FILE"
```

**Integration in i3 config:**
```bash
# First boot check (runs once)
exec --no-startup-id [ -f ~/.config/up/first-boot-done ] || /usr/local/share/up/configs/scripts/first-boot.sh
```

**Alternative: Floating Welcome Panel**

Use `yad` or `zenity` for a graphical welcome panel:

```bash
#!/bin/bash
# Show floating welcome panel
show_welcome_panel() {
    if command -v yad >/dev/null 2>&1; then
        yad --title="Welcome to Up Linux" \
            --text="<b>Welcome to Up Linux!</b>\n\nHere are some quick tips:\n\n• Press <b>Super+Space</b> to open the application menu\n• Press <b>Super+Alt+Space</b> to open the system menu\n• Run <b>up-quickstart</b> to set up your system\n• Run <b>up-show-keybindings</b> to see all shortcuts\n\nEnjoy your new desktop!" \
            --button="Got it!":0 \
            --center \
            --width=400 \
            --height=300 \
            --no-escape \
            --undecorated
    elif command -v zenity >/dev/null 2>&1; then
        zenity --info \
            --title="Welcome to Up Linux" \
            --text="<b>Welcome to Up Linux!</b>\n\nHere are some quick tips:\n\n• Press <b>Super+Space</b> to open the application menu\n• Press <b>Super+Alt+Space</b> to open the system menu\n• Run <b>up-quickstart</b> to set up your system\n• Run <b>up-show-keybindings</b> to see all shortcuts\n\nEnjoy your new desktop!" \
            --width=400
    else
        # Fallback to notification
        notify-send "Welcome to Up Linux!" "Press Super+Alt+Space for system menu. Run up-quickstart to get started." -t 10000
    fi
}
```

**Required Packages:**
- `yad` (for floating dialog) — OR —
- `zenity` (GTK dialog) — OR —
- `libnotify` (notification only, already installed via `dunst`)

**Decision:** Use `libnotify` (notification) since it's already installed and lightweight. `yad`/`zenity` are optional enhancements.

---

## 2. Keybinding Discoverability

### Prerequisites
- None

### Implementation Details

**New File:** `bin/up-show-keybindings` (if not already implemented)

**Purpose:** Display all keybindings in a searchable rofi menu.

```bash
#!/bin/bash
# Show Keybindings - Display all i3 keybindings in rofi
# Usage: up-show-keybindings

set -euo pipefail

I3_CONFIG="$HOME/.config/i3/config"

if [ ! -f "$I3_CONFIG" ]; then
    notify-send "Error" "i3 config not found" || true
    exit 1
fi

# Parse keybindings from i3 config
# Format: bindsym $mod+key action  # Description
KEYBINDINGS=$(grep -E "^\s*bindsym" "$I3_CONFIG" | \
    sed 's/bindsym //' | \
    sed 's/exec --no-startup-id //' | \
    sed 's/exec //' | \
    awk '{
        key=$1
        $1=""
        action=$0
        # Try to extract description from comment
        if (match(action, /# (.+)/, desc)) {
            action=desc[1]
        }
        printf "%-25s → %s\n", key, action
    }' | sort)

if [ -z "$KEYBINDINGS" ]; then
    echo "No keybindings found" | rofi -dmenu -p "Keybindings" -lines 5
    exit 0
fi

# Show in rofi with search
echo "$KEYBINDINGS" | rofi -dmenu -i -p "Keybindings" -lines 20 -width 800 -kb-cancel Escape
```

**Add to System Menu:**
```bash
# In system-menu.sh - Tools submenu
show_tools_menu() {
    local options="📦  Install Packages\n🔄  Workflows\n👥  Project Managers\n📸  Screenshot\n📹  Screen Record\n🎨  Color Picker\n⌨️  Show Keybindings\n←  Back"

    local choice=$(show_menu "Tools" "$options" 8)

    case "$choice" in
        # ... existing cases ...
        *Show*Keybindings*) run_command "up-show-keybindings" ;;
        # ...
    esac
}
```

**Floating Overlay for First Boot:**

Use `yad` or `zenity` to show a floating keybinding overlay:

```bash
show_keybinding_overlay() {
    local bindings="
<b>Essential Keybindings</b>

<b>Super+Space</b>        Open application menu
<b>Super+Alt+Space</b>    Open system menu
<b>Super+Return</b>       Open terminal
<b>Super+W</b>            Close window
<b>Super+1-0</b>          Switch workspace
<b>Super+Shift+1-0</b>    Move window to workspace
<b>Super+H/J/K/L</b>      Focus window
<b>Super+Shift+H/J/K/L</b> Move window
<b>Super+F</b>            Fullscreen
<b>Super+R</b>            Resize mode
<b>Ctrl+Alt+Del</b>       Exit i3
    "

    if command -v yad >/dev/null 2>&1; then
        yad --title="Keybindings" \
            --text="$bindings" \
            --button="Close":0 \
            --center \
            --width=500 \
            --height=400 \
            --no-escape
    elif command -v zenity >/dev/null 2>&1; then
        zenity --info \
            --title="Keybindings" \
            --text="$bindings" \
            --width=500
    fi
}
```

**Required Packages:**
- `yad` (for floating overlay) — OR —
- `zenity` (GTK dialog) — OR —
- `rofi` (already installed, used for searchable list)

**Decision:** Primary implementation uses `rofi` (already installed). Floating overlay is optional enhancement using `yad` or `zenity`.

---

## 3. Help System

### Prerequisites
- None

### Implementation Details

**New File:** `bin/up-help`

**Purpose:** Provide command-line help for all up-* commands and common topics.

```bash
#!/bin/bash
# Up Help System
# Usage: up-help [topic]
# Topics: keybindings, themes, packages, config, troubleshooting

set -euo pipefail

UP_ROOT="${UP_ROOT:-/usr/local/share/up}"

show_general_help() {
    cat << 'EOF'
Up Linux Help System

Usage: up-help [topic]

Available topics:
  keybindings      Show all keyboard shortcuts
  themes           How to change themes
  packages         How to install packages
  config           Configuration options
  troubleshooting  Common issues and solutions

Commands:
  up-system-menu       Open system menu
  up-switch-theme      Change theme
  up-pkg-install       Install official Arch packages
  up-show-keybindings  Show all keybindings
  up-quickstart        Run initial setup

For more help, see: /usr/local/share/up/docs/
EOF
}

show_keybindings_help() {
    cat << 'EOF'
Keybindings

Window Management:
  Super+Return         Open terminal
  Super+W              Close window
  Super+H/J/K/L        Focus left/down/up/right
  Super+Shift+H/J/K/L  Move window left/down/up/right
  Super+F              Toggle fullscreen
  Super+Space          Open application menu
  Super+Alt+Space      Open system menu

Workspaces:
  Super+1-0            Switch to workspace 1-10
  Super+Shift+1-0      Move window to workspace 1-10

Layout:
  Super+J              Toggle split layout
  Super+H              Split horizontal
  Super+V              Split vertical
  Super+Mod1+S         Stack layout
  Super+Mod1+W         Tabbed layout
  Super+Mod1+E         Toggle split

System:
  Ctrl+Alt+Del         Exit i3
  Ctrl+Mod1+R          Reload i3
  Ctrl+R               Restart i3
  Ctrl+Alt+L           Lock screen

Run up-show-keybindings for interactive search.
EOF
}

show_themes_help() {
    cat << 'EOF'
Themes

Change theme:
  up-switch-theme          Interactive theme picker
  up-switch-theme --theme NAME   Apply specific theme

Themes are defined in: /usr/local/share/up/configs/themes/
Custom backgrounds: ~/.config/up/backgrounds/

Current theme: $(cat ~/.config/up-theme 2>/dev/null || echo "unknown")
EOF
}

show_packages_help() {
    cat << 'EOF'
Packages

Install packages:
  up-pkg-install
  up-pkg-aur-install
EOF
}

show_config_help() {
    cat << 'EOF'
Configuration

Config file: ~/.config/up/config

Available options:
  theme = "aetherweft"    # Current theme
  font = "DejaVu Sans Mono"  # Terminal font
  fade = true             # Window fade transitions
  blur = true             # Background blur
  dim = true              # Dim inactive windows

Changes are applied automatically when the file is saved.
EOF
}

show_troubleshooting_help() {
    cat << 'EOF'
Troubleshooting

Theme not applying:
  1. Check theme exists: ls /usr/local/share/up/configs/themes/
  2. Check config: cat ~/.config/up/config
  3. Re-apply: up-switch-theme --theme THEME_NAME

WiFi not working:
  1. Check status: nmcli general status
  2. List networks: nmcli device wifi list
  3. Connect: nmcli device wifi connect SSID password PASSWORD

Audio not working:
  1. Check PipeWire: systemctl --user status pipewire
  2. Restart: systemctl --user restart pipewire pipewire-pulse

Display issues:
  1. Check display: xrandr
  2. Set scale: up-display-scale

Installation log: /var/log/up/install.log
EOF
}

# Main
case "${1:-}" in
    keybindings)  show_keybindings_help ;;
    themes)       show_themes_help ;;
    packages)     show_packages_help ;;
    config)       show_config_help ;;
    troubleshooting) show_troubleshooting_help ;;
    "")           show_general_help ;;
    *)
        echo "Unknown topic: $1"
        echo "Run 'up-help' for available topics."
        exit 1
        ;;
esac
```

---

## 4. Configurable Font Size

### Prerequisites
- None

### Implementation Details

**File:** `configs/scripts/switch-theme.sh` — `apply_alacritty()` function

**Current:** Font family is configurable, but size is hardcoded.

**Target:** Font size configurable via `~/.config/up/config`.

**Config Addition:**
```toml
# ~/.config/up/config
font = "DejaVu Sans Mono"
font_size = 10
```

**Implementation:**
```bash
# In switch-theme.sh - read font size from config
FONT_SIZE=10  # Default
if [ -f "$USER_CONFIG" ]; then
    FONT_SIZE=$(grep "^font_size =" "$USER_CONFIG" | sed 's/.*= *//' | tr -d ' ')
    [ -z "$FONT_SIZE" ] && FONT_SIZE=10
fi

# In apply_alacritty():
# Update font size in alacritty config
sed -i "s/font.size = .*/font.size = $FONT_SIZE/" "$alacritty_config" 2>/dev/null || true
```

**Files to Update:**
- `configs/scripts/switch-theme.sh` — Read and apply font_size
- `configs/scripts/config-sync.sh` — Handle font_size changes
- `configs/scripts/first-boot.sh` — Optionally prompt for font size

---

