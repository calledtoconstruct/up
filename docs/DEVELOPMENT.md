# Up Linux Development Guidelines

This document provides guidelines for developers and AI assistants working on Up Linux. It covers coding standards, common pitfalls, development patterns, and testing strategies.

Repo-level agent routing: see `AGENTS.md`. End-user customization of an installed desktop is `default/agents/skills/up/`, not this file.

## Development Environment

### Host vs Target System Distinction

**CRITICAL WARNING**: Up Linux development involves two distinct environments:

- **Development Machine**: Used ONLY for code editing and analysis
- **Target System**: The actual system where scripts execute (installed Up Linux)

**🚨 NEVER EXECUTE UP SCRIPTS ON YOUR DEVELOPMENT MACHINE** 🚨
- Scripts are designed for the target system and may corrupt your development environment
- They could brick your system or cause irreparable damage
- Always analyze code by inspection, never by execution on development machine

### Context Awareness: Installation vs Post-Installation

**Always consider the time period context of your work:**

1. **Installation Phase** (bootstrap.sh, setup.sh):
   - Host environment (Arch ISO) transitioning to target system
   - Limited tools available, careful with dependencies
   - State communication between host/chroot environments
   - Focus on reliability over features

2. **Post-Installation Usage**:
   - Full target system with all packages installed
   - User interaction and customization
   - Live configuration and theme switching
   - Performance and user experience focus

### Testing Strategy

- **Test by Inspection**: Analyze code paths, verify logic works on target system
- **Target System Testing**: Test modifications on actual Up installations or VMs
- **Path Verification**: Ensure all paths resolve correctly on target system
- **Assumption Validation**: Check that environmental assumptions hold
- **Phase-Appropriate Testing**: Test in correct context (installation vs usage)

**VM walkthrough:** See [VM-TESTING.md](VM-TESTING.md) for a step-by-step guide to install QEMU/KVM on Omarchy (or Arch), create a guest, run `./install.sh` from an Arch ISO, and verify the desktop and `up-update`.

## Path Handling

### UP_ROOT Environment Variable

All scripts derive paths from the `UP_ROOT` environment variable for consistent path resolution:

```bash
# ✅ Good - uses UP_ROOT for all path derivations
export UP_ROOT="${UP_ROOT:-/usr/local/share/up}"
CONFIGS_DIR="$UP_ROOT/configs"
SCRIPT_DIR="$UP_ROOT/configs/scripts"
source "$SCRIPT_DIR/logging.sh"

# ❌ Avoid - hardcoded paths
source "/usr/local/share/up/configs/scripts/logging.sh"
```

### Environment Variable Setup

- **Installation Phase**: `UP_ROOT=/root/up` (during Arch ISO installation)
- **Post-Installation**: `UP_ROOT=/usr/local/share/up` (set via `/etc/profile.d/up-path.sh`)
- **Fallback Logic**: Scripts include `export UP_ROOT="${UP_ROOT:-/usr/local/share/up}"` for safety

### Dynamic Paths When Necessary

Use `${BASH_SOURCE[0]}` when script location varies relative to UP_ROOT:

```bash
# ✅ Correct - works regardless of how script is invoked
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ❌ Avoid - fails if script called via different paths
SCRIPT_DIR="$(pwd)"
```

### Path Derivation Best Practices

Scripts should derive all paths from UP_ROOT rather than hardcoding:

```bash
# ✅ Good - all paths derived from UP_ROOT
THEMES_DIR="$UP_ROOT/configs/themes"
BACKGROUNDS_DIR="$UP_ROOT/configs/backgrounds"
WORKFLOWS_DIR="$UP_ROOT/configs/workflows"

# ❌ Avoid - hardcoded paths that may not be portable
THEMES_DIR="/usr/local/share/up/configs/themes"
```

## Coding Standards

### UP_ROOT Path Derivation

All scripts must derive paths from the UP_ROOT environment variable:

```bash
# ✅ Good - paths derived from UP_ROOT
export UP_ROOT="${UP_ROOT:-/usr/local/share/up}"
CONFIG_DIR="$UP_ROOT/configs"
deploy "$CONFIG_DIR/i3" "/home/$USERNAME/.config/i3"

# ❌ Avoid - hardcoded paths
CONFIG_DIR="/usr/local/share/up/configs"
deploy "$CONFIG_DIR/i3" "/home/$USERNAME/.config/i3"
```

### Logging System

Up Linux uses a two-tier logging architecture:

**Tier 1: Core Logging Functions (logging.sh)**
- `log_to_file()` - File-only logging (for debugging/troubleshooting)
- `log_for_user()` - Console + file logging (for user-visible messages)

**Tier 2: Convenience Aliases**
- `log_info()`, `log_success()`, `log_warning()`, `log_error()`, `log_fatal()`
- `log_message()` - File-only logging (backward compatibility)

**Installation Context (package-groups.sh)**
- `log_install_progress()` - Updates TUI AND logs to file (no console output)
- `set_status()` - Updates TUI progress bar only

**Usage Guidelines:**
- Installation scripts: Use `log_install_progress()` for progress updates
- Post-installation scripts: Use `log_for_user()` for direct user feedback
- File logging: Use `log_to_file()` for debugging information

```bash
# ✅ Good - installation progress
log_install_progress "📦 Installing packages..."

# ✅ Good - user-visible message
log_info "Theme switched to dark"

# ✅ Good - file-only logging
log_to_file "INFO" "Debug information"

# ❌ Avoid - redundant logging
log_message "Installing packages..."
log_to_console "Installing packages..."
```

### Fail Fast Philosophy

Let errors surface rather than hiding with fallbacks **for essential steps**:

```bash
# ✅ Fail fast - error is immediately visible
run_and_log pacman -S --noconfirm essential-package

# ❌ Hidden failures - delays problem discovery
run_and_log pacman -S --noconfirm essential-package || true
```

**Essential post-conditions (must not use `|| true`):** partitioning success, partition devices exist, mounts, GRUB install/mkconfig, i3 `keybindings.conf` generation.

**Optional failures:** cosmetic/AUR packages, non-critical services — log and continue; record in install report.

### Verify After Mutate

After creating partitions, installing packages, or writing configs, **assert** the result:

```bash
# Partition nodes
wait_for_partitions "$DISK" "$EFI_PART" "$ROOT_PART"

# Package actually installed
pacman -Q "$package" >/dev/null

# Keybindings generated
grep -q '^bindsym ' "$HOME/.config/i3/keybindings.conf"
```

### Never Source Full Phase Scripts for Cleanup

```bash
# ✅ Extract helpers to partition-utils.sh / state-utils.sh
source "$UP_ROOT/configs/scripts/partition-utils.sh"
cleanup_partitions "$DISK"

# ❌ Sources bootstrap.sh and re-runs the install
source "$UP_ROOT/bootstrap.sh"
```

### Progress Protocol

- `install.sh` writes `progress_total.txt` once (dynamic step count).
- `bootstrap.sh` / `setup.sh` read `PROGRESS_TOTAL=$(state_get progress_total.txt)` and pass it to every `update_progress`.
- Do not hardcode `30` in phase scripts.

### Updates and Migrations

- User-facing update path: **`up-update`** (not raw pacman alone).
- Migrations live in `migrations/*.sh`, tracked under `/var/lib/up/migrations/`.
- Prefer skip-and-continue on migration failure during updates (user can re-run later).
- Config refresh helper: `up-refresh-config <relative-path>`.
- Version string: repo root `version` file.

### Single Source of Truth

Each resource has one canonical location:

```bash
# ✅ Theme colors defined once in TOML
# Applied consistently across all applications

# ❌ Colors hardcoded in multiple places
# Leads to inconsistency and maintenance issues
```

## Common Pitfalls

### Bind Mount Communication

**Problem**: Host/chroot environments have isolated filesystems.

**Solution**: Use bind mounts for state sharing:

```bash
# ✅ Correct - bind mounts enable communication
mount --bind "$HOST_STATE_DIR" "$CHROOT_STATE_DIR"
mount --bind "$HOST_LOG_DIR" "$CHROOT_LOG_DIR"

# ❌ Wrong - direct file access doesn't work
# Host /tmp/up-state ≠ Chroot /tmp/up-state
```

### ANSI Escape Sequence Handling

**Problem**: ANSI codes break tmux output formatting.

**Solution**: Strip ANSI sequences for clean display:

```bash
strip_ansi() {
    printf '%s' "$1" | sed 's/\x1b\[[0-9;]*[a-zA-Z]//g'
}
```

### Exit Code Preservation

**Problem**: Piping loses exit codes, breaking error handling.

**Solution**: Use temp files to capture output while preserving codes:

```bash
_run_command_to_tui() {
    tmp_file=$(mktemp)
    "$@" > "$tmp_file" 2>&1
    local status=$?

    # Process output
    while IFS= read -r line; do
        log_install_progress "$line"
    done < "$tmp_file"

    rm -f "$tmp_file"
    return $status
}
```

## Installation UX Improvements

The installer includes several UX enhancements for better user experience:

### Responsive Tmux Layout

- Terminal dimensions are detected at launch
- Pane sizes are calculated dynamically based on available space
- Input pane automatically resizes from 20 lines to 3 lines after input collection completes
- Minimum terminal size check (80x30) with user warning

### Disk Selection UX

- Formatted table showing device, type (SSD/HDD), size, model, and recommendation
- Automatic recommendation of largest disk
- Visual partition preview with ASCII box diagrams
- Color-coded disk types (SSD in green, HDD in yellow, small disks in red)
- Three-option confirmation: yes/proceed, disk/back, no/abort

### Hostname Suggestions

- Automatic hardware detection via DMI (laptop vs desktop)
- Smart hostname suggestions based on chassis type
- Product name sanitization for hostname compatibility
- Default suggestions: `up-laptop`, `up-desktop`, `up-computer`

### Dynamic Progress Calculation

- Total installation steps calculated based on actual package counts
- Package batch counting for accurate progress tracking
- AUR packages counted individually since they install in series
- Progress updates reflect real installation phases

### Installation Cancellation (Ctrl+C Handler)

- SIGINT/SIGTERM trap for graceful cancellation
- Interactive prompt: continue or cancel
- Automatic cleanup of tmux session on cancellation
- Partition cleanup on cancelled installations
- State directory cleanup

### Timezone Picker

- Common timezones organized by region (Americas, Europe, Asia, Pacific)
- Numbered selection menu (1-16 common timezones + custom entry)
- Fuzzy matching for custom timezone entries
- Validation against `/usr/share/zoneinfo`
- Fallback to UTC on invalid input

### GTK Theme Cache Invalidation

**Problem**: GTK applications cache themes, preventing live reload.

**Solution**: Use timestamp-based theme name rotation:

```bash
theme_name="UpTheme-${theme}-${timestamp}"
# Forces GTK to reload CSS
```

### Neovim Colorscheme Loading

**Problem**: Neovim may not load custom colorschemes reliably.

**Solution**: Use direct `vim.api.nvim_set_hl()` calls in module body:

```lua
-- ✅ Direct highlight setting
vim.api.nvim_set_hl(0, 'Normal', { bg = '#bg', fg = '#fg' })

-- ❌ Function wrapper - Neovim doesn't auto-call
local function setup()
  -- highlights here
end
```

## Package Management Patterns

### Categorization Strategy

- **ESSENTIAL**: Core functionality - failure aborts installation
- **SYSTEM**: Important but not critical - logged failures, continue
- **COSMETIC**: Visual enhancements - optional, graceful failure
- **AUR**: Requires external tools - retry logic, then skip

### Installation Order

1. Essential packages (batch → individual fallback)
2. System packages (batch → individual fallback)
3. Shell tools (affects .zshrc generation)
4. Cosmetic packages (fonts, themes)
5. AUR packages (requires yay, retry logic)

### Error Handling by Category

```bash
# Essential - abort on failure
install_essential_packages "$ESSENTIAL_PACKAGES"

# Optional - log and continue
install_system_packages "$SYSTEM_PACKAGES"

# AUR - retry, then skip
install_aur_packages "$AUR_PACKAGES"
```

### AUR Package Categorization

Packages that are only available in AUR should be placed in the `AUR_PACKAGES` section rather than `SYSTEM_PACKAGES`. This ensures clear categorization and proper installation via yay:

```bash
# In package-groups.sh - AUR packages go in AUR_PACKAGES
AUR_PACKAGES="
    xautolock
"
```

## State Management

### State File Coordination

Multiple processes communicate via filesystem:

```bash
# Progress updates
echo "$current" > "$STATE_DIR/progress_current.txt"
echo "$total" > "$STATE_DIR/progress_total.txt"

# Input collection
echo "$user_input" > "$STATE_DIR/${input_type}.input"

# Phase synchronization
echo "$phase_num|$phase_name" > "$STATE_DIR/current_phase.txt"
```

### Migration System

- **Numbered scripts**: `migrations/*.sh` with sequential execution
- **Idempotent**: Each migration runs only once via `.done` files
- **Non-blocking**: Failed migrations don't stop updates
- **State tracking**: `/var/lib/up/migrations/*.done`

**Example: New Features (e.g., 016-install-packages-integration.sh)**: Copies new binaries to /usr/local/bin/, ensures state dirs (e.g., /var/lib/up/packages-installed), installs dependencies like yay. For existing installs, runs on update.sh to integrate without manual steps.

## Configuration Patterns

### Live Configuration System

- **User intent**: `~/.config/up/config` (TOML), `overrides/i3.conf`, `keybindings-overrides.toml` — never overwritten
- **Stock copies**: `~/.config/i3/config` and peers are copies; `up-update` backs them up and replaces them
- **Vendor tree**: `/usr/local/share/up` is git-reset on update (not a user workspace)
- **File watchers**: `~/.config/up/config` changes enqueue a desktop sync

### Theme System Architecture

- **TOML definitions**: Centralized color schemes
- **Dynamic generation**: GTK themes, Neovim colorschemes created on-demand
- **Live reload**: Mechanisms for updating running applications
- **Fallback hierarchy**: Theme-specific → general → solid color

## Testing Guidelines

### Pre-Commit Checks

- **Syntax validation**: `bash -n script.sh`
- **Path verification**: Ensure all paths exist in target layout
- **Logic review**: Check conditional branches work on target system
- **Assumption validation**: Verify environmental assumptions

### Target System Testing

- **VM testing**: Test in virtualized Up Linux environment
- **Clean installs**: Verify from Arch ISO → working system
- **Update testing**: Test migration system with version changes
- **Error scenarios**: Test failure modes and recovery

### Code Review Checklist

- [ ] UP_ROOT environment variable used for all path derivations
- [ ] Fallback logic `export UP_ROOT="${UP_ROOT:-/usr/local/share/up}"` included
- [ ] No hardcoded `/usr/local/share/up` paths in scripts
- [ ] No development machine execution assumptions
- [ ] Error handling appropriate for package category
- [ ] State files used for inter-process communication
- [ ] ANSI stripping applied to tmux output
- [ ] Exit codes preserved in pipelines
- [ ] Migration scripts are idempotent
- [ ] Theme changes trigger appropriate reloads

## Modification Patterns

### Adding New Themes

1. **Create TOML definition** in `configs/themes/`
2. **Add background images** to `configs/backgrounds/{theme}/`
3. **Test all applications** (i3, alacritty, rofi, etc.)
4. **Verify live reload** works for running applications

### Adding Configuration Options

1. **Add to user config schema** (`~/.config/up/config`)
2. **Implement application logic** in appropriate scripts
3. **Add file watchers** if live application needed
4. **Update documentation** in INSTALL.md

### Modifying Installation Flow

1. **Update state coordination** between phases
2. **Maintain tmux UI synchronization**
3. **Preserve error handling patterns**
4. **Test bind mount communication**

## Troubleshooting Development Issues

### Script Fails on Target System

- Check absolute paths resolve correctly
- Verify file permissions (especially after `git clone`)
- Ensure dependencies are installed in correct order
- Test with `bash -x` for execution tracing

### Theme Not Applying

- Check TOML syntax is valid
- Verify color definitions exist for all required sections
- Test individual application application
- Check live reload mechanisms are working

### Installation Hangs

- Check state file communication between processes
- Verify bind mounts are working
- Test tmux pane synchronization
- Check for infinite loops in input collection

### Updates Not Working

- Verify migration numbering is sequential
- Check `.done` files are created correctly
- Test individual migration scripts
- Ensure backup system works

## AI Development Guidelines

### Think Outside the Box

**Challenge assumptions and consider alternatives:**
- Question whether current approaches are optimal
- Consider if there are simpler solutions without loss of functionality
- Evaluate whether features could be implemented differently
- Think about user experience improvements beyond the immediate request

### Consider Unexplored Options

**Always evaluate potential improvements:**
- **Simplifications**: Can complex processes be made simpler?
- **Consolidations**: Can multiple tools/scripts be combined?
- **Alternative approaches**: Are there better ways to solve problems?
- **User experience**: Does the current approach serve users well?
- **Maintenance burden**: Will this create technical debt?

### Communicate Insights

**When you identify potential improvements:**
- Document them clearly in your response
- Explain the benefits and trade-offs
- Suggest implementation approaches if appropriate
- Note any risks or considerations

## Complex Process Documentation

### Plan Files for Multi-Session Work

**For complex processes spanning multiple AI coding sessions:**

1. **Create temporary plan files** (`plan.md`, `plan-*.md`) to document:
   - Current progress and completed work
   - Next steps and priorities
   - Technical decisions and rationale
   - Open questions or blockers
   - Testing requirements

2. **Structure plan files with:**
   - Clear milestones and checkpoints
   - Dependencies between tasks
   - Risk assessment and mitigation
   - Success criteria

3. **Update plans** after each session to maintain continuity

### Example Plan File Structure

```markdown
# Implementation Plan: [Feature Name]

## Current Status
- [x] Completed task 1
- [x] Completed task 2
- [ ] In progress: task 3
- [ ] Pending: task 4

## Technical Decisions
- Decision 1: Rationale and alternatives considered
- Decision 2: Implementation approach chosen

## Next Steps
1. Complete task 3 by [deadline]
2. Test integration with existing systems
3. Update documentation

## Risks & Mitigations
- Risk: Description and impact
  - Mitigation: Planned approach

## Questions/Blockers
- Question for next session
- Dependency on external factors
```

## Contribution Workflow

This repo's GitHub remote must only receive `main`. Enable the push guard:

```
git config core.hooksPath hooks
```

1. **Fork and branch** for feature development
2. **Test on target system** (VM or physical hardware)
3. **Follow coding standards** and patterns
4. **Update documentation** as needed
5. **Test failure scenarios** and edge cases
6. **Submit pull request** with clear description

Remember: Up Linux targets legacy hardware with robust, simple solutions. Prioritize reliability and maintainability over cutting-edge features.
