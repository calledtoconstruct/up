# Up Linux: Improvement Ideas & Recommendations

This document contains comprehensive recommendations for improving Up Linux across installation, usability, code quality, and post-installation experience. Each suggestion includes a **Notes** section for feedback and clarification.

---

## Table of Contents

1. [Installation UX Improvements](#1-installation-ux-improvements)
2. [System Menu Improvements](#2-system-menu-improvements)
3. [Code Quality Improvements](#3-code-quality-improvements)
4. [Post-Installation Usability](#4-post-installation-usability)
5. [Architectural Improvements](#5-architectural-improvements)
6. [Creative Improvements](#6-creative-improvements)
7. [Documentation Improvements](#7-documentation-improvements)
8. [Priority Matrix](#8-priority-matrix)

---

## 1. Installation UX Improvements

### 1.1 Tmux Pane Sizing & Layout

**Current State:** The tmux layout in `install.sh` uses hardcoded pixel values that don't adapt to terminal size.

**Problems:**
- Title pane (5 rows) is too small — gets cut off on smaller terminals
- Input pane (20 rows) wastes space after input collection completes
- Progress pane doesn't expand to fill available space when input is done
- No adaptation to terminal size

**Recommendations:**
- Use percentage-based sizing instead of fixed rows: `-l 33%` for equal thirds
- Add a terminal size check at startup with a minimum size warning
- After input collection completes, resize the input pane to 3-5 lines (just showing completion status) and expand the progress pane
- Consider a dynamic layout that switches from 4-pane to 3-pane after input collection

> **YOUR NOTES:**
> *I agree that our tmux setup should adapt to the screen size, but some panes are intended to be specific sizes*
> *For example, the title section just needs to show a static title with a fixed height.*

---

### 1.2 Input Prompt Ordering & Messaging

**Current Order in `input-watcher.sh`:**
1. Disk selection
2. Partition choice
3. Partition confirmation
4. Hostname
5. Timezone
6. Username
7. Full name
8. User password
9. Root password
10. NVIDIA detection

**Problems:**
- Disk selection comes first, which is the scariest prompt (data destruction warning) — users may panic
- Timezone requires knowing the exact format (e.g., `America/New_York`) — no picker
- Full name after username feels disconnected
- NVIDIA prompt appears at the end, after passwords — feels tacked on

**Recommended Reorder:**
1. **Hostname** — friendly, low-stakes first question
2. **Username** — natural follow-up
3. **Full name** — connected to username
4. **Timezone** — with a simplified picker (region → city) or common defaults
5. **User password**
6. **Root password**
7. **NVIDIA detection** — hardware question, logically grouped
8. **Disk selection** — now user is invested and committed
9. **Partition choice**
10. **Partition confirmation** — final "are you sure" before destruction

> **YOUR NOTES:**
> *We want an efficient installer. The prompts are in the order that the script consumes them.*
> *However, we do have some flexibility with timezone, user name, proper name, etc...*
> *The key is that we need the target disk configured early, so we ask for it first.*
> *The installation process runs in parallel / asynchronously, so the user is not waiting on the next prompt.*
> *Similarly, the installation can run some steps while the user is still answering prompts.*

---

### 1.3 Timezone Picker Improvement

**Current State:** Users must know the exact timezone format (e.g., `America/New_York`).

**Recommendation:**
- Provide a numbered list of common timezones grouped by region
- Implement a two-step picker: Region → City
- Detect timezone from system clock if available
- Offer fuzzy matching (e.g., "new york" → "America/New_York")

```bash
# Example implementation:
echo "Select your region:"
echo "1) Americas"
echo "2) Europe"
echo "3) Asia"
echo "4) Pacific"
# Then show cities for selected region
```

> **YOUR NOTES:**
> *I like this idea, generally, but it sounds technically complicated and brittle.*

---

### 1.4 Disk Selection UX

**Current State:** Raw `lsblk` output shown to users.

**Recommendations:**
- Show a formatted table with disk type (SSD/HDD), size, and model
- Highlight recommended disk (largest, SSD preferred)
- Show warning color for small disks (< 20GB)
- Display existing partitions and their contents
- Add a "preview" of what will happen to each disk

> **YOUR NOTES:**
> *Yes! We used to have a formatted table, but it was lost in the transition to tmux.*
> *I do not know what you mean by "preview" of what will happen to each disk; I'd like to see an example.*

---

### 1.5 Hostname Suggestions

**Current State:** Default hostname is `dev-laptop`.

**Recommendation:**
- Detect hardware type (laptop vs desktop) from DMI data
- Suggest hostname based on hardware model (e.g., `thinkpad-t480`, `dell-inspiron`)
- Allow custom hostname with validation
- Show a few examples: `my-laptop`, `workstation`, `dev-machine`

> **YOUR NOTES:**
> *Yes! Other ideas are `up-laptop` and `up-desktop`.*

---

### 1.6 Progress Bar Accuracy

**Current State:** Progress total is hardcoded to 30 in `install.sh`, but actual steps vary.

**Problems:**
- Progress bar may reach 100% before installation is complete
- May stall at 95% for a long time during package installation
- No sub-progress for long-running steps

**Recommendations:**
- Calculate total steps dynamically based on actual package counts
- Add sub-progress for long-running steps (e.g., "Installing system packages: 15/32")
- Use weighted progress (package installation is ~60% of total time, not 30%)
- Show estimated time remaining based on download speeds

> **YOUR NOTES:**
> *Yes! Need to find a simple, yet effective way to calculate total steps / duration.*

---

### 1.7 Installation Cancellation

**Current State:** Cancellation requires typing "no/abort" in the input pane.

**Recommendations:**
- Add Ctrl+C handler that shows a confirmation dialog
- Add a "Cancel Installation" option in the system menu
- Show a warning before cancellation with data loss implications
- Allow resuming from last checkpoint after accidental cancellation

> **YOUR NOTES:**
> *I like the idea of the Ctrl+c handler that shows a confirmation prompt.*
> *If the user confirms the cancellation, it should trigger a clean-up so that mounted drives are unmounted, etc...*

---

## 2. System Menu Improvements

### 2.1 Logical Reorganization

**Current Structure:**
```
System Menu
├── Appearance (Theme, Desktop Image, Font)
├── Tools (Packages, Workflows, PMs, Screenshot, Screen Record, Color Picker, Keybindings)
├── Hardware (Power Profile, Night Light, Layout Toggle, Display Scale, Idle Lock)
├── System (Reload i3, Restart i3, Lock, Logout, Suspend, Reboot, Shutdown)
└── Settings (System Monitor, Audio, WiFi, Bluetooth, Login Screen)
```

**Problems:**
- "Settings" and "Hardware" overlap conceptually (WiFi/Bluetooth are hardware)
- "Tools" mixes very different things (Packages, Workflows, Screenshot)
- "System" contains both i3 management and power actions — different concerns
- No search/filter capability for deep menus

**Recommended Structure:**
```
System Menu
├── 🎨 Appearance
│   ├── Switch Theme
│   ├── Desktop Image → (Select / Random)
│   └── Choose Font
├── 🔧 Tools & Apps
│   ├── Install Packages
│   ├── Workflows
│   ├── Project Managers
│   ├── Screenshot
│   ├── Screen Record
│   ├── Color Picker
│   └── Show Keybindings
├── ⚙️ Settings
│   ├── Display Scale
│   ├── Night Light
│   ├── Power Profile
│   ├── Idle Lock
│   ├── Audio Controls
│   ├── WiFi Settings
│   ├── Bluetooth
│   └── Login Screen
├── 🖥️ Window Manager
│   ├── Reload i3
│   ├── Restart i3
│   ├── Layout Toggle
│   └── Lock Screen
└── 🔌 Power
    ├── Logout
    ├── Suspend
    ├── Reboot
    └── Shutdown
```

> **YOUR NOTES:**
> *Good. Remember to add Window Manager Settings for LightDM Settings app.*

---

### 2.2 Menu Navigation Improvements

**Recommendations:**
- Show keyboard shortcuts next to menu items (e.g., "Lock Screen [Super+Ctrl+L]")
- Add a "Back" option consistently styled across all menus
- Enable search/filter: when typing, filter menu items (rofi supports `-filter`)
- Show current state for toggleable items (e.g., "Night Light: ON" vs "Night Light: OFF")
- Add breadcrumb trail showing current menu path

> **YOUR NOTES:**
> *Yes.*

---

### 2.3 Quick Actions Submenu

**Recommendation:** Add a "Quick Actions" submenu at the top level for common tasks:

```
Quick Actions
├── 🔒 Lock Screen
├── 💤 Suspend
├── 🔄 Reboot
├── ⏻ Shutdown
└── 📸 Screenshot
```

These are the most common actions and should be accessible with minimal navigation.

> **YOUR NOTES:**
> *Yes.*

---

### 2.4 System Menu Keyboard Shortcut

**Current State:** System menu is bound to `Super+Space` (same as Omarchy).

**Recommendations:**
- Add `Super+?` or `Super+/` as alternative binding (more discoverable)
- Add a polybar module that shows the system menu icon and is clickable
- Document the shortcut in the polybar tooltip
- Show the shortcut in the first-boot welcome wizard

> **YOUR NOTES:**
> *The system menu is on Super+Space.*
> *Polybar already has an icon for the system menu.*

---

### 2.5 Package Installation Feedback

**Current State:** `up-install-packages` runs in a terminal with raw output.

**Recommendations:**
- Show a progress indicator during installation
- Summarize what was installed at the end
- Offer to launch the installed tool immediately
- Show any post-install instructions
- Add a "Recently Installed" section to the menu

> **YOUR NOTES:**
> *Skip these suggestions for now.*

---

## 3. Code Quality Improvements

### 3.1 Duplicated Code

**Problem:** Several functions are duplicated across scripts:
- `update_phase()`, `update_progress()`, `read_input()` appear in both `bootstrap.sh` and `setup.sh`
- `strip_ansi()` is defined in `package-groups.sh` but could be in `colors.sh`
- `run_and_log` vs `_run_command_to_tui` vs `_yay_run` — three different command runners

**Recommendation:** Create a shared `state-utils.sh` that both `bootstrap.sh` and `setup.sh` source, containing:
- `update_phase()`
- `update_progress()`
- `read_input()`
- `strip_ansi()`

> **YOUR NOTES:**
> *We desire to adhere to the SOLID, DRY, and GRASP principles and patterns.*
> *Need a reliable way or ways to share code and information between scripts.*

---

### 3.2 Error Handling Inconsistencies

**Problems:**
- `bootstrap.sh` uses `set -euo pipefail` but some commands use `|| true` liberally
- `setup.sh` has a trap that echoes "cancelled" but the trap in `bootstrap.sh` calls `cleanup_partitions`
- Some functions return silently on error, others exit the script

**Recommendations:**
- Standardize error handling with a common pattern: `run_with_category()` that handles logging, retries, and failure categorization
- Remove `|| true` from commands where failure should be handled (currently hides real errors)
- Add a consistent "fail fast" vs "continue with warning" decision tree
- Document the error handling strategy in `DEVELOPMENT.md`

> **YOUR NOTES:**
> *High quality analisys here. Well done.*
> *Our goals and constraints are as follows:*
> *The bootstrap.sh and setup.sh scripts run in the background; the user only sees what is written to the log.*
> *The installation should try to succeed as much as possible, only failing when an essential step or package fails.*
> *The code should execute commands in a way that captures the output and the result (success or error code).*
> *The code should not allow a command failure to crash the whole process, except essential step or package failures.*

---

### 3.3 Variable Scope Issues

**Problems:**
- `YAY_AVAILABLE` is exported in `install-yay.sh` but checked in `setup.sh` — relies on subshell inheritance
- `FAILED_*` arrays are populated in `package-groups.sh` but read in `setup.sh` — fragile cross-file state
- `STATE_DIR` is defined differently in different scripts (`/tmp/up-state` vs `/up-state`)

**Recommendations:**
- Use file-based state for cross-script communication (already partially done)
- Document the state file protocol clearly
- Consider a state management library that all scripts source
- Standardize `STATE_DIR` path across all scripts

> **YOUR NOTES:**
> *Yes! Not sure if a library is needed, but I'm open to the idea.*

---

### 3.4 Shell Script Safety

**Problems:**
- Several scripts use `eval "$cmd" &` in `system-menu.sh` — potential command injection
- `run_command()` in `system-menu.sh` doesn't validate input
- Some scripts don't quote variables properly

**Recommendations:**
- Replace `eval` with direct command execution where possible
- Add input validation for menu selections
- Use `shellcheck` in CI/development workflow
- Add a pre-commit hook for shellcheck

> **YOUR NOTES:**
> *Not needed at this time or handled elsewhere.*

---

### 3.5 Code Documentation

**Current State:** Many scripts lack function-level documentation.

**Recommendations:**
- Add header comments to all scripts explaining purpose and usage
- Document all exported functions with examples
- Add a `--help` flag to all user-facing scripts
- Create a `docs/API.md` documenting all shared functions

> **YOUR NOTES:**
> *Sounds good.*

---

## 4. Post-Installation Usability

### 4.1 First-Boot Experience

**Current State:** After reboot, user lands in i3 with no guidance.

**Recommendations:**
- Show keybindings overlay (Super+? or Super+H)
- Prompt to run `up-quickstart` if not already done
- Show system menu shortcut (Super+Space)
- Offer to connect to WiFi if not connected
- Show a floating welcome panel with essential shortcuts

> **YOUR NOTES:**
> *Show keybindings overlay: Not at this time.*
> *Prompt to run quickstart if not already done: Yes.*
> *Show system menu shortcut: Yes. "notification"?*
> *Offer to connect to wifi: Yes.*
> *Floating welcome panel: Yes. How?*

---

### 4.2 Keybinding Discoverability

**Current State:** Keybindings are defined in `configs/i3/config` but not easily discoverable.

**Recommendations:**
- Create a keybinding cheat sheet accessible via `up-show-keybindings`
- Add a "Keybindings" entry to the System Menu
- Show a floating overlay on first boot with essential shortcuts
- Consider a rofi-based keybinding browser with search
- Add tooltips to polybar modules showing their keybindings

> **YOUR NOTES:**
> *I had thought this was already implemented (the up-show-keybindings bin using rofi).*
> *Let's implement these suggestions. What application can be used to display the floating overlay?*

---

### 4.3 Configuration Validation

**Problem:** No validation of `~/.config/up/config` values.

**Recommendations:**
- Add a config validator that runs on startup
- Show a notification if config values are invalid
- Provide sensible defaults for missing values
- Add a `up-validate-config` command
- Show a warning in the system menu if config is invalid

> **YOUR NOTES:**
> *This sounds complex and brittle. Skip these suggestions for now.*

---

### 4.4 Theme System Robustness

**Problem:** Theme application can partially fail (some apps themed, others not).

**Recommendations:**
- Add rollback capability: save current theme state before applying new theme
- Validate theme TOML files before applying
- Add a `up-theme-doctor` command that checks all theme application points
- Show a summary of what was themed successfully
- Add a "Theme Health" indicator in the system menu

> **YOUR NOTES:**
> *This is not necessary at this time.*

---

### 4.5 Update System

**Problem:** `update.sh` overwrites user configs with backups, but users may not notice.

**Recommendations:**
- Show a diff of changes before overwriting
- Add a `--dry-run` flag to `update.sh`
- Create a `up-changelog` command that shows recent changes
- Add a notification when updates are available
- Show a summary of what changed after each update

> **YOUR NOTES:**
> *These suggestions are not needed at this time.*

---

### 4.6 Migration System

**Problem:** Migrations can fail silently or block updates.

**Recommendations:**
- Add a `up-migration-status` command
- Show migration progress in the update output
- Add rollback capability for failed migrations
- Test migrations in a sandbox before applying
- Add a "Migration Failed" notification with troubleshooting steps

> **YOUR NOTES:**
> *These suggestions are not needed at this time.*

---

### 4.7 Help System

**Recommendation:** Create a comprehensive help system:

```bash
up-help                    # Show general help
up-help [topic]            # Show help for specific topic
up-help --search [query]   # Search help topics
```

Topics could include:
- `keybindings` — Show all keyboard shortcuts
- `themes` — How to change themes
- `packages` — How to install packages
- `config` — Configuration options
- `troubleshooting` — Common issues and solutions

> **YOUR NOTES:**
> *Yes.*

---

## 5. Architectural Improvements

### 5.1 State Management Library

**Recommendation:** Create a shared state management library:

```bash
# state-lib.sh
state_set() {
    local key="$1"
    local value="$2"
    echo "$value" > "$STATE_DIR/$key"
}

state_get() {
    local key="$1"
    cat "$STATE_DIR/$key" 2>/dev/null || echo ""
}

state_wait() {
    local key="$1"
    while [ ! -f "$STATE_DIR/$key" ]; do
        sleep 1
    done
    cat "$STATE_DIR/$key"
}
```

> **YOUR NOTES:**
> *Ok.*

---

### 5.2 Configuration Schema

**Recommendation:** Define a configuration schema with validation:

```toml
# config-schema.toml
[schema]
version = "1.0"

[fields.theme]
type = "string"
required = true
default = "aetherweft"
validator = "theme_exists"

[fields.font]
type = "string"
required = false
default = "DejaVu Sans Mono"
validator = "font_installed"

[fields.fade]
type = "boolean"
required = false
default = true
```

> **YOUR NOTES:**
> *This suggestion is not needed at this time.*

---

### 5.3 Plugin System

**Recommendation:** Consider a plugin system for extending functionality:

```
~/.config/up/plugins/
├── my-plugin/
│   ├── plugin.toml          # Plugin metadata
│   ├── install.sh           # Installation script
│   ├── uninstall.sh         # Uninstallation script
│   └── menu.toml            # Menu entries to add
```

This would allow users to add custom tools and menu entries without modifying core files.

> **YOUR NOTES:**
> *This suggestion is not needed at this time.*

---

### 5.4 Testing Framework

**Recommendation:** Create a testing framework for installer components:

```bash
# tests/test-partition.sh
test_standard_partition() {
    # Mock disk
    DISK="/dev/test"
    # Run partition script
    # Verify results
}

test_swap_calculation() {
    # Test swap size calculation for various RAM sizes
}
```

> **YOUR NOTES:**
> *This suggestion is not needed at this time.*

---

## 6. Creative Improvements

### 6.1 Installation Art & Branding

**Current State:** Basic tmux layout with colored text.

**Recommendations:**
- Add ASCII art logo to the title pane
- Use Unicode box-drawing characters for cleaner pane borders
- Add a subtle animation (rotating spinner) during long operations
- Show estimated time remaining based on package download sizes
- Add a progress bar with gradient colors

> **YOUR NOTES:**
> *These suggestions are not needed at this time.*

---

### 6.2 Sound Design

**Recommendations:**
- Add a subtle "ding" sound on installation completion
- Add a "click" sound on menu selections (optional, configurable)
- Add an "error" sound on failures
- Add ambient background music during installation (optional, configurable)

> **YOUR NOTES:**
> *How can this be accomplished? Does the Arch Linux ISO provide the necessary application(s)?*

---

### 6.3 Theming the Installer

**Recommendations:**
- Allow theme selection during installation (not just post-install)
- Apply the selected theme to the installer UI itself
- Show a preview of the theme before applying
- Add a "Theme Gallery" showing all available themes with screenshots

> **YOUR NOTES:**
> *These suggestions are not needed at this time.*

---

### 6.4 Smart Defaults

**Recommendations:**
- Detect hardware capabilities and suggest optimal settings
- Auto-detect timezone from system clock
- Suggest hostname based on hardware model
- Detect existing WiFi networks and offer to connect
- Detect monitor configuration and suggest display scale
- Detect audio devices and configure appropriately

> **YOUR NOTES:**
> *These suggestions are not needed at this time.*

---

### 6.5 Installation Analytics

**Recommendations:**
- Track installation time per phase (opt-in)
- Show installation statistics at completion
- Compare with average installation times
- Offer to share anonymized stats for improvement
- Show a "Installation Report" with timing breakdown

> **YOUR NOTES:**
> *These suggestions are not needed at this time.*

---

### 6.6 Easter Eggs

**Recommendations:**
- Add a "surprise me" theme option that picks a random theme
- Add a "fortune" command that shows random quotes on terminal startup
- Add hidden shortcuts that do fun things (e.g., `Super+Shift+Z` for a matrix effect)
- Add a "Konami code" sequence that unlocks a secret feature

> **YOUR NOTES:**
> *These suggestions are not needed at this time.*

---

## 7. Documentation Improvements

### 7.1 Architecture Diagrams

**Recommendation:** Create visual diagrams for:
- Installation flow (bootstrap → setup → first boot)
- State communication (host ↔ chroot)
- Theme system (TOML → applications)
- Package categories and failure handling
- Configuration system hierarchy

> **YOUR NOTES:**
> *These suggestions are not needed at this time.*

---

### 7.2 Troubleshooting Guide

**Recommendation:** Create `docs/TROUBLESHOOTING.md` with:
- Common installation failures and solutions
- Theme not applying correctly
- WiFi connection issues
- Audio not working
- Display scaling problems
- Boot failures

Add a `up-doctor` command that runs diagnostic checks and suggests solutions.

> **YOUR NOTES:**
> *These suggestions are not needed at this time.*

---

### 7.3 Video Tutorials

**Recommendations:**
- Create a video walkthrough of the installation process
- Create a video tour of the desktop environment
- Create a video showing how to customize themes
- Create a video showing how to use the system menu

> **YOUR NOTES:**
> *No. Not at this time.*

---

### 7.4 Man Pages

**Recommendation:** Create man pages for all `up-*` commands:

```bash
man up-system-menu      # System menu documentation
man up-switch-theme     # Theme switcher documentation
man up-install-packages # Package installer documentation
```

> **YOUR NOTES:**
> *No. Not at this time.*

---

## 8. Specific Code Fixes

### 8.1 `system-menu.sh` — `eval` Usage

**Current (dangerous):**
```bash
run_command() {
    local cmd="$1"
    eval "$cmd" &
}
```

**Recommended (safe):**
```bash
run_command() {
    "$@" &
}
```

> **YOUR NOTES:**
> *Ok.*

---

### 8.2 `input-watcher.sh` — Timezone Validation

**Current (requires exact format):**
```bash
validate_timezone() {
    local timezone="$1"
    if [[ -f "/usr/share/zoneinfo/$timezone" ]]; then
        return 0
    fi
    return 1
}
```

**Recommended (with fuzzy matching):**
```bash
validate_timezone() {
    local timezone="$1"
    if [[ -f "/usr/share/zoneinfo/$timezone" ]]; then
        return 0
    fi
    # Try fuzzy match
    local match=$(find /usr/share/zoneinfo -name "*${timezone}*" 2>/dev/null | head -1)
    if [ -n "$match" ]; then
        echo "${match#/usr/share/zoneinfo/}"
        return 0
    fi
    return 1
}
```

> **YOUR NOTES:**
> *I like the fuzzy match idea.*

---

### 8.3 `install.sh` — Progress Calculation

**Current (hardcoded):**
```bash
echo "15" > "$STATE_DIR/progress_total.txt"
```

**Recommended (dynamic):**
```bash
TOTAL_STEPS=15  # Base steps
PACKAGE_COUNT=$(echo "$ESSENTIAL_PACKAGES $SYSTEM_PACKAGES $SHELL_TOOLS $COSMETIC_PACKAGES" | wc -w)
TOTAL_STEPS=$((TOTAL_STEPS + PACKAGE_COUNT / 5))  # Add sub-steps for packages
echo "$TOTAL_STEPS" > "$STATE_DIR/progress_total.txt"
```

> **YOUR NOTES:**
> *Packages can be installed in batches; this would need to be accounted for in the solution. Let's explore options.*

---

## 9. Additional Ideas

### 9.1 Accessibility

**Recommendations:**
- Add high-contrast theme option
- Support for screen readers
- Keyboard-only navigation for all menus
- Configurable font sizes
- Color-blind friendly theme options

> **YOUR NOTES:**
> *Implement font size via config file. Other suggestions are not needed at this time.*

---

### 9.2 Internationalization

**Recommendations:**
- Support for multiple languages in the installer
- Localized menu options
- RTL language support
- Locale-aware date/time formatting

> **YOUR NOTES:**
> *Not needed at this time.*

---

### 9.3 Security

**Recommendations:**
- Add password strength indicator
- Add option for full disk encryption
- Add firewall configuration during installation
- Add option to disable root account
- Add SSH key setup during installation

> **YOUR NOTES:**
> *Password strength indicator: not at this time.*
> *Full disk encryption: not at this time.*
> *Firewall configuration during installation: yes.*
> *Disable root account: not at this time.*
> *Set up SSH key during setup: yes. Prompt whether to setup. Prompt for type and size? Prompt for optional password.*

---

### 9.4 Performance

**Recommendations:**
- Add option for minimal installation (fewer packages)
- Add option to skip cosmetic packages
- Add parallel package installation where safe
- Add option for lightweight alternatives (e.g., `dwm` instead of `i3`)

> **YOUR NOTES:**
> *No, not needed at this time.*

---

### 9.5 Backup & Recovery

**Recommendations:**
- Add option to create system snapshot after installation
- Add `up-backup` command for user data backup
- Add `up-restore` command for system restoration
- Add automatic backup before major updates

> **YOUR NOTES:**
> *Yes.*

---

*Document created: 2026-03-28*
*Last updated: 2026-03-29*
