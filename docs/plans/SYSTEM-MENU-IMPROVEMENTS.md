# System Menu Improvements

## Overview
Reorganize the system menu for better usability, add navigation improvements, create a Quick Actions submenu, and add keyboard shortcut documentation.

---

## 1. Menu Reorganization

### Prerequisites
- None

### Implementation Details

**File:** `configs/scripts/system-menu.sh`

**Current Structure:**
```
Appearance → Tools → Hardware → System → Settings
```

**Target Structure:**
```
Appearance → Tools & Apps → Settings → Window Manager → Power
```

**Implementation:**

```bash
# Main menu - updated structure
show_main_menu() {
    local options="🎨  Appearance\n🔧  Tools & Apps\n⚙️  Settings\n🖥️  Window Manager\n🔌  Power"

    local choice=$(show_menu "System Menu" "$options" 5)

    case "$choice" in
        *Appearance*) show_appearance_menu ;;
        *Tools*) show_tools_menu ;;
        *Settings*) show_settings_menu ;;
        *Window*Manager*) show_window_manager_menu ;;
        *Power*) show_power_menu ;;
        *) exit 0 ;;
    esac
}
```

**Settings Menu (consolidated from Hardware + Settings):**
```bash
show_settings_menu() {
    local options="📊  System Monitor\n🔊  Audio Controls\n📶  WiFi Settings\n📱  Bluetooth\n⚡  Power Profile\n🌙  Night Light\n🔍  Display Scale\n🔒  Idle Lock\n🖥️  Login Screen Settings\n←  Back"

    local choice=$(show_menu "Settings" "$options" 10)

    case "$choice" in
        *System*Monitor*) run_command "dex ~/.local/share/applications/system-monitor.desktop" ;;
        *Audio*Controls*) run_command "dex ~/.local/share/applications/audio-controls.desktop" ;;
        *WiFi*Settings*) run_command "dex ~/.local/share/applications/wifi-controls.desktop" ;;
        *Bluetooth*) run_command "dex ~/.local/share/applications/bluetooth-controls.desktop" ;;
        *Power*Profile*) run_command "up-power-profile" ;;
        *Night*Light*) run_command "up-night-light" ;;
        *Display*Scale*) run_command "up-display-scale" ;;
        *Idle*Lock*) run_command "up-idle-lock" ;;
        *Login*Screen*) run_command "lightdm-gtk-greeter-settings" ;;
        *Back*) show_main_menu ;;
        *) show_settings_menu ;;
    esac
}
```

**Window Manager Menu (renamed from System):**
```bash
show_window_manager_menu() {
    local options="🔄  Reload i3\n🔃  Restart i3\n⬌  Layout Toggle\n🔒  Lock Screen\n←  Back"

    local choice=$(show_menu "Window Manager" "$options" 5)

    case "$choice" in
        *Reload*i3*) run_command "i3-msg reload" ;;
        *Restart*i3*) run_command "i3-msg restart" ;;
        *Layout*Toggle*) run_command "up-layout-toggle" ;;
        *Lock*Screen*) run_command "i3lock -c 000000" ;;
        *Back*) show_main_menu ;;
        *) show_window_manager_menu ;;
    esac
}
```

**Power Menu (separated from System):**
```bash
show_power_menu() {
    local options="🚪  Logout\n💤  Suspend\n🔄  Reboot\n⏻  Shutdown\n←  Back"

    local choice=$(show_menu "Power" "$options" 5)

    case "$choice" in
        *Logout*) run_command "i3-msg exit" ;;
        *Suspend*) run_command "systemctl suspend" ;;
        *Reboot*) run_command "systemctl reboot" ;;
        *Shutdown*) run_command "systemctl poweroff" ;;
        *Back*) show_main_menu ;;
        *) show_power_menu ;;
    esac
}
```

---

## 2. Menu Navigation Improvements

### Prerequisites
- None

### Implementation Details

**File:** `configs/scripts/system-menu.sh`

**Keyboard Shortcuts Display:**
```bash
show_system_menu() {
    local options="🔄  Reload i3 [Ctrl+Alt+R]\n🔃  Restart i3 [Ctrl+R]\n🔒  Lock Screen [Ctrl+Alt+L]\n🚪  Logout [Ctrl+Alt+Del]\n💤  Suspend\n🔄  Reboot\n⏻  Shutdown\n←  Back"

    local choice=$(show_menu "System" "$options" 8)
    # ... rest of function
}
```

**Toggle State Display:**
```bash
# Read current night light state
get_night_light_state() {
    if pgrep -x "redshift" > /dev/null 2>&1; then
        echo "ON"
    else
        echo "OFF"
    fi
}

show_hardware_menu() {
    local nl_state=$(get_night_light_state)
    local options="⚡  Power Profile\n🌙  Night Light [$nl_state]\n⬌  Layout Toggle\n🔍  Display Scale\n🔒  Idle Lock\n←  Back"

    local choice=$(show_menu "Hardware" "$options" 6)
    # ... rest of function
}
```

**Consistent Back Styling:**
All submenus should end with `←  Back` option (already implemented).

---

## 3. Quick Actions Submenu

### Prerequisites
- None

### Implementation Details

**File:** `configs/scripts/system-menu.sh`

**Add Quick Actions to main menu:**
```bash
show_main_menu() {
    local options="⚡  Quick Actions\n🎨  Appearance\n🔧  Tools & Apps\n⚙️  Settings\n🖥️  Window Manager\n🔌  Power"

    local choice=$(show_menu "System Menu" "$options" 6)

    case "$choice" in
        *Quick*Actions*) show_quick_actions_menu ;;
        *Appearance*) show_appearance_menu ;;
        *Tools*) show_tools_menu ;;
        *Settings*) show_settings_menu ;;
        *Window*Manager*) show_window_manager_menu ;;
        *Power*) show_power_menu ;;
        *) exit 0 ;;
    esac
}

show_quick_actions_menu() {
    local options="🔒  Lock Screen\n💤  Suspend\n🔄  Reboot\n⏻  Shutdown\n📸  Screenshot\n←  Back"

    local choice=$(show_menu "Quick Actions" "$options" 6)

    case "$choice" in
        *Lock*Screen*) run_command "i3lock -c 000000" ;;
        *Suspend*) run_command "systemctl suspend" ;;
        *Reboot*) run_command "systemctl reboot" ;;
        *Shutdown*) run_command "systemctl poweroff" ;;
        *Screenshot*) run_command "flameshot gui" ;;
        *Back*) show_main_menu ;;
        *) show_quick_actions_menu ;;
    esac
}
```

---

## 4. Dynamic Project Managers Menu

### Prerequisites
- Desktop files must be created for each project manager

### Implementation Details

**File:** `configs/scripts/system-menu.sh`

**Current:** Shows "No project managers installed" message

**Target:** Dynamically discovers installed project managers from desktop files

```bash
show_project_managers_menu() {
    local pm_options=""
    local pm_count=0
    local -a pm_desktop_files=()

    # Search for project manager desktop files
    if [ -d "$HOME/.local/share/applications" ]; then
        for desktop_file in "$HOME/.local/share/applications"/*.desktop; do
            if [ -f "$desktop_file" ]; then
                local name=$(grep '^Name=' "$desktop_file" | cut -d'=' -f2)
                local icon=$(grep '^Icon=' "$desktop_file" | cut -d'=' -f2)
                if [ -n "$name" ]; then
                    pm_options="$pm_options📋  $name\n"
                    pm_desktop_files+=("$desktop_file")
                    ((pm_count++))
                fi
            fi
        done
    fi

    if [ $pm_count -eq 0 ]; then
        notify-send "Project Managers" "No project managers installed." || true
        show_tools_menu
        return
    fi

    pm_options="$pm_options←  Back"

    local choice=$(show_menu "Project Managers" "$pm_options" $((pm_count + 1)))

    if [[ "$choice" == *Back* ]]; then
        show_tools_menu
    elif [ -n "$choice" ]; then
        # Extract name and find corresponding desktop file
        local selected_name="${choice#📋  }"
        for desktop_file in "${pm_desktop_files[@]}"; do
            local name=$(grep '^Name=' "$desktop_file" | cut -d'=' -f2)
            if [ "$name" = "$selected_name" ]; then
                run_command "dex '$desktop_file'"
                break
            fi
        done
        show_project_managers_menu
    else
        show_project_managers_menu
    fi
}
```

---

