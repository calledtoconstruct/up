# Up Linux Architecture

This document describes the technical implementation of Up Linux, including installation flow, state management, theming system, and key design patterns.

## Installation Architecture

### Overview

Up Linux uses a two-phase installation process that transitions from the Arch ISO environment to the installed system:

1. **Host Phase** (`bootstrap.sh`): Runs from Arch ISO, handles disk operations
2. **Chroot Phase** (`setup.sh`): Runs inside installed system, handles configuration

### Essential post-conditions

These steps must succeed (no silent `|| true`):

- Partition creation with checked exit codes + `wait_for_partitions` device asserts
- Mount of root (and EFI/boot as applicable)
- GRUB install + `grub-mkconfig` producing `/boot/grub/grub.cfg`
- Generation of `~/.config/i3/keybindings.conf` (via `write_i3_keybindings_file`)
- Polybar launched through `~/.config/polybar/launch.sh`

### Partition device naming

`partition_device disk N` in `configs/scripts/partition-utils.sh`:

- `nvme*`, `mmcblk*`, `loop*`, `nbd*`, `md*` → `${disk}p${N}`
- otherwise → `${disk}${N}`

Cleanup uses the same library (`cleanup_partitions`) and must never `source bootstrap.sh`.

### Display stack

Preferred: XLibre from external repo. On failure after retries: fallback to `xorg-server` + `xf86-input-libinput`. Recorded as `DISPLAY_STACK` in install report.

### Progress protocol

`install.sh` owns `progress_total.txt`. Phase scripts read it into `PROGRESS_TOTAL` and pass it to `update_progress`.

### State Communication Between Phases

The installation uses bind mounts to share state between the host (Arch ISO) and chroot (new system) environments:

```
Host: /tmp/up-state/ ──bind mount──┬─ Chroot: /up-state/
Host: /var/log/up/ ──bind mount───┴─ Chroot: /var/log/up/
```

**Implementation Details:**
- Bind mounts created in `bootstrap.sh` before `arch-chroot`
- Enables real-time progress updates during pacstrap
- State files coordinate between tmux watcher panes
- Cleanup handled in both error handlers and normal exit

### Tmux-Based Installer UI

The installer uses tmux with 4 synchronized panes:

- **Title Pane** (top): Branding and status
- **Phases Pane** (middle-left): Installation phases with completion status
- **Progress Pane** (middle-right): Real-time progress, status messages, logs
- **Input Pane** (bottom): User input collection (auto-focus)

**State Coordination:**
- State files in `/up-state/` coordinate between panes
- `update_phase()`, `update_progress()`, `read_input()` functions
- Background installation runs silently in separate tmux window

### Package Management System

#### Package Categories

Packages are categorized by criticality with different failure handling:

1. **ESSENTIAL**: Must succeed - installation aborts on failure
2. **SYSTEM**: Logged failures, installation continues
3. **SHELL TOOLS**: Affects `.zshrc` generation
4. **COSMETIC**: Visual enhancements, optional
5. **AUR**: Requires yay, skipped if yay fails

#### Installation Strategy

- **Batch First**: Attempt group installation for speed
- **Fallback to Individual**: If batch fails, install packages one-by-one
- **Retry Logic**: AUR packages use configurable retry attempts
- **Graceful Degradation**: Optional packages don't block installation

#### Key Implementation Patterns

**Exit Code Preservation:**
```bash
_run_command_to_tui() {
    tmp_file=$(mktemp)
    "$@" > "$tmp_file" 2>&1
    local status=$?
    # Process output for logging
    while IFS= read -r line; do
        log_to_console "$line"
    done < "$tmp_file"
    rm -f "$tmp_file"
    return $status
}
```

**ANSI Stripping for Tmux:**
```bash
strip_ansi() {
    printf '%s' "$1" | sed 's/\x1b\[[0-9;]*[a-zA-Z]//g'
}
```

## Configuration System

### Three-layer configuration

Never symlink live configs into the vendor git tree. Layers:

| Layer | Path | Who writes | On `up-update` |
|-------|------|------------|----------------|
| Vendor | `/usr/local/share/up` | git only | `fetch` + `reset --hard` + `clean` (local dirt discarded) |
| Stock copies | `~/.config/i3/config`, polybar, picom, rofi, … and `/etc/lightdm/*` | Up / theme apply | Backup if different, then overwrite from vendor; theme re-applied |
| User intent | `~/.config/up/config`, `overrides/`, `keybindings-overrides.toml` | User and menus | **Never overwritten** |

Hand-edits to stock copies are not sacred: they are saved as `*.backup-update-YYYYMMDD` (and under `/var/lib/up/backups/pre-update-*`) then replaced so new product files land. Persistent tweaks belong in the user-intent layer.

### User Configuration File

Preferences that survive updates live at `~/.config/up/config` (TOML):

```toml
effects = "auto"   # auto | full | lite | safe
fade = true        # materialized by compositor profile
blur = true
dim = true
font = "DejaVu Sans Mono"
theme = "aetherweft"
ready_sound = false
```

**Compositor capability (picom):**
- `configs/scripts/detect-compositor-capability.sh` — scores virt/GPU/RAM/CPU (optional `glxinfo` when `DISPLAY` is set)
- `configs/scripts/apply-compositor-profile.sh` — writes `fade`/`blur`/`dim`, `~/.config/picom/capability.conf`, and a cache under `~/.config/up/`
- Session start (`start-session.sh` → `config-sync.sh`) re-applies when `effects=auto` and the machine fingerprint changes; a valid compositor cache skips `glxinfo`
- Picom includes: main config → `theme.conf` → `capability.conf` (capability wins for backend / hard blur caps)

**Live Application:**
- **Preferred:** scripts enqueue directly (`theme` / `reapply` / `refresh`) — no need to wait for a watcher
- **config-watcher** still runs: only bridges *external* edits of `~/.config/up/config` into `sync` (no login-time heal sync)
- `desktop-agent` drains the serial queue (compositor → theme files → i3 → polybar → picom)
- Session start does early file-only sync (theme rewrite only when `~/.config/up/config` changed); i3 `exec_always` starts polybar; the agent starts the bar only if it is missing

**Loop prevention (watcher ↔ agent):**
- Agent sets `watch-suppress` while it may rewrite `~/.config/up/config` (fade/theme materialization)
- After apply: cool-off window + `config-applied.sha256` of the file contents
- Watcher uses `desktop_request_from_watch`: skip if suppressed, cool-off, same hash as applied, or `sync` already queued

### Override System

Files that `up-update` will not replace:

```
~/.config/up/config                      # theme, font, effects, ready_sound
~/.config/up/keybindings-overrides.toml  # merged into keybindings.conf
~/.config/up/overrides/i3.conf           # included last by i3 (extra bindsyms / for_window)
```

## Theme System

### TOML-Based Theme Definitions

Themes are defined in `configs/themes/*.toml` with nested sections:

```toml
[colors]
background = "#1E1E2E"
foreground = "#CDD6F4"
accent = "#89B4FA"

[alacritty.normal]
black = "#45475A"
red = "#F38BA8"
# ... etc

[i3]
bg = "#1E1E2E"
fg = "#CDD6F4"
accent = "#89B4FA"
```

### Dynamic Application System

`switch-theme.sh` applies themes to all applications:

- **i3**: Window colors, bar configuration
- **Polybar**: Colors, fonts, layout
- **Alacritty**: Terminal colors, cursor
- **Rofi**: Launcher theme, colors
- **GTK**: Generated CSS with timestamp rotation for live reload
- **Neovim**: Dynamic colorscheme generation
- **Starship**: Prompt colors
- **btop/htop**: System monitor themes

### Install vs live session

Shared scripts (`switch-theme`, `apply-compositor-profile`, `config-sync`) run in **both** places:

| Context | Behavior |
|---------|----------|
| `setup.sh` (arch-chroot) | `UP_INSTALL=1`, `--no-reload`, `--home /home/user` — write theme/picom files only; never start desktop-agent |
| `up-update` / migrations / `up-add-user` | `--home` + `--no-reload` + `UP_DESKTOP_INLINE=1` — per-user files only |
| `start-session.sh` (pre-i3) | `UP_DESKTOP_INLINE=1` for config-sync; session curtain fade-in; then i3 starts `desktop-agent` |

**Session curtain:** theme/background apply pre-renders ~10 JPEG frames (ffmpeg `gblur` + dim) under `~/.local/state/up/session-curtain/`. Login fades those frames in, then `session-curtain.sh reveal` fades them out once i3 IPC and `keybindings.conf` are present. Optional `ready_sound` (Kenney CC0) is off by default.
| Graphical session | Theme/font tools enqueue work; agent reloads i3/polybar/picom |

`switch-theme` refuses the desktop queue when: no DISPLAY, chroot, `UP_INSTALL`, `UP_DESKTOP_INLINE`, `--home` override, or missing agent scripts.

### Desktop apply queue

Serial worker so theme, font, compositor, and bar updates never race:

| Piece | Role |
|--------|------|
| `configs/scripts/desktop-agent.sh` | Session daemon; single-instance flock; drains queue |
| `configs/scripts/desktop-request.sh` | Enqueue API (`up-desktop-request`) |
| Queue dir | `~/.local/state/up/desktop/queue/*.req` |
| Log | `~/.local/state/up/desktop/agent.log` |

**Request types:** `theme name=…`, `reapply`, `sync [force=1]`, `compositor [force=1]`, `polybar`, `picom`, `refresh`, `boot`.

**Planning / deduplication:**

| Kind | Types | Rule |
|------|--------|------|
| Config-changing | `theme`, `reapply`, `sync`, `compositor` | Always executed in queue order. Consecutive same type merges params only (theme name last-wins, `force` OR). Non-consecutive ops both run. |
| Idempotent | `polybar`, `picom`, `refresh`, `boot` | Earlier duplicates skipped; only the **last** of each type in the batch runs (after config steps). |

**Batch execution order:**

1. Each config-changing step (compositor / theme files as planned)  
2. i3 reload once (if any step needs it)  
3. polybar restart once  
4. picom restart once (explicit `picom`, or fragments changed)  

**GTK Applications:**
- Theme name rotation with timestamps forces cache invalidation
- `xsettingsd` broadcasts theme changes
- Direct signaling of running GTK processes

**Neovim:**
- Custom colorschemes generated in `~/.local/share/nvim/site/colors/`
- Direct `vim.api.nvim_set_hl()` calls for reliable loading
- File watchers trigger reload without RPC

### Background System

Smart fallback hierarchy:
1. Theme-specific backgrounds (`configs/backgrounds/{theme}/`)
2. General backgrounds
3. Solid color fallback

## Migration System

### Design Principles

- **Numbered Scripts**: `migrations/*.sh` with sequential numbering
- **Idempotent**: Each migration runs only once
- **State Tracking**: `/var/lib/up/migrations/*.done` files
- **Non-Blocking**: Failed migrations don't stop updates

### Example Migration Structure

```bash
MIG_NUM="010"
MIG_NAME="installer-config-fixes"
STATE_DIR="/var/lib/up/migrations"
DONE_FILE="$STATE_DIR/${MIG_NUM}.done"

if [ -f "$DONE_FILE" ]; then
    echo "Migration $MIG_NUM already applied."
    exit 0
fi

# Migration logic here...

# Mark as done
touch "$DONE_FILE"
```

### Update Process

Supported entry point: **`up-update`** (System Menu → Update System). `./update.sh` is a thin wrapper.

Pipeline (Omarchy-inspired, X11-adapted):

1. Confirm + pre-update config backup under `/var/lib/up/backups/`
2. `git fetch` then `reset --hard` to upstream and `git clean -fd` on `/usr/local/share/up` (vendor tree — local edits are discarded, never stash-popped)
3. Migrations with skip-and-continue option
4. `pacman -Syu` (failures reported, not swallowed)
5. Optional AUR update if yay present
6. Diff-aware config refresh + keybindings regenerate if missing
7. Re-apply current theme

Single-file helper: `up-refresh-config <relative-path>`.

Version string: repo root `version` file.

## Error Handling Patterns

### Comprehensive Logging

All output captured to `/var/log/up/install.log`:

```bash
log_message() {
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$timestamp] $*" >> "$ERROR_LOG_FILE"
}
```

### Failure Categorization

Different handling based on package type:
- **Essential**: Abort installation
- **Optional**: Log and continue
- **AUR**: Retry with backoff, then skip

### Recovery Mechanisms

- **Rollback**: Failed transactions can be rolled back
- **State Saving**: Installation state persisted for welcome wizard
- **Service Tracking**: Failed services recorded for post-install fixing

## Path Handling Guidelines

### Absolute Paths Preferred

```bash
# Good - absolute path guaranteed by installation
/usr/local/share/up/configs/scripts/switch-theme.sh

# Avoid - relative paths that may break
~/.config/up/scripts/switch-theme.sh
```

### Dynamic Paths Only When Necessary

```bash
# Use ${BASH_SOURCE[0]} when script location varies
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
```

### Installation-Controlled Paths

Scripts assume correct installation placement - no fallbacks for corrupted systems.

## Development Environment Considerations

### Host vs Target System

- **Development Machine**: Used only for code editing and analysis
- **Target System**: Where scripts actually execute
- **Never execute scripts on development machine** - analyze for target system behavior
- **Test by inspection**: Verify paths, logic work on target system

## File System Layout

```
/usr/local/share/up/          # System installation
├── configs/                  # Application configurations
│   ├── scripts/             # Utility scripts
│   ├── themes/              # Theme definitions
│   └── [app]/               # App-specific configs
├── migrations/              # Update scripts
└── bin/                     # Executables

~/.config/up/                # User intent (never overwritten)
├── config                   # Preferences (TOML)
├── keybindings-overrides.toml
└── overrides/
    └── i3.conf              # Extra i3 lines (included last)

/var/lib/up/                 # System state
└── migrations/             # Migration tracking

/var/log/up/                 # Logs
└── install.log             # Installation log
```

## Key Design Patterns

### State File Coordination

Multiple processes communicate via filesystem:
- Progress updates via status files
- Input collection via dedicated files
- Phase synchronization across host/chroot

### Live Configuration

- File watchers monitor config changes
- Immediate application without restarts
- Fallback to manual sync commands

### Graceful Degradation

- Optional components fail safely
- Installation continues despite non-critical failures
- Clear logging of what succeeded/failed

### Template-Based Generation

- GTK themes generated from color definitions
- Neovim colorschemes created dynamically
- Configuration files templated with user preferences

## Desktop menus

**System menu (`up-system-menu` / Super+Alt+Space):**
- Verb-first top level: Apps, Learn, Capture, Style, Setup, Install, Update, Session, System
- Implementation: `configs/scripts/system-menu.sh` + `rofi-menu.sh` + `menu-addons.sh`
- Install offers official packages (`up-pkg-install`), AUR (`up-pkg-aur-install`), extra tools, and remove
- Stack-based Back / Escape; actions close the tree

Optional fragments may exist at `/usr/local/share/up-addons/*/menu.sh`. The OS sources them if present. `up-update` only `git clean`s `/usr/local/share/up`, never sibling directories.

## Coding agents

End-user skills ship in `default/agents/skills/` (`up`, `diagnose-crash`) and are symlinked into `~/.agents/skills` and the usual harness skill dirs on install and `up-update`. The default agent name lives in `~/.config/up/config` as `agent = "…"`. `up-agent`, `up-agent-prompt`, and `up-agent-crash` launch it. A user unit `up-crash-watch` toasts coredumps when an agent is set. Contributor instructions for this git tree are in `AGENTS.md`, not in the end-user skill.

**Rofi/drun (Super+Space):** desktop files under `~/.local/share/applications` and `/usr/local/share/applications`.