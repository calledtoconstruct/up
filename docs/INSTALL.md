# Installation

Boot an official Arch ISO, clone this repo, run `./install.sh`. About 15 minutes later you have X11 + i3 + a themed desktop.

## Hardware

Up targets **2010 and newer** machines. X11 only (no Wayland). No SSE4.2 requirement.

- **CPU:** Core 2 Duo and newer
- **GPU:** Intel HD, older NVIDIA/AMD with X11
- **RAM:** 2 GB minimum, 4 GB comfortable
- **Disk:** 20 GB+

Skip software that needs AVX/SSE4.2 or a modern GPU (some Electron apps with hardware acceleration). Tested on Core 2 Duo through 8th-gen Intel and Ryzen 1000.

## Installation Flow

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                         UP INSTALLATION FLOW                                 │
└─────────────────────────────────────────────────────────────────────────────┘

     ┌──────────────┐
     │  Arch ISO    │
     │  (booted)    │
     └──────┬───────┘
            │
            ▼
     ┌──────────────┐     ┌──────────────────────────────────────┐
     │  install.sh  │────▶│ Install tmux, create tmux session    │
     │  (entry      │     │ with 4 panes:                        │
     │   point)     │     │ • Title pane (top)                   │
     │              │     │ • Phases pane (middle-left)          │
     │              │     │ • Progress pane (middle-right)       │
     │              │     │ • Input pane (bottom, auto-focus)    │
     └──────┬───────┘     └──────────────────────────────────────┘
            │
            ▼
     ┌──────────────┐     ┌──────────────────────────────────────┐
     │ input-watcher│────▶│ Collect all user input upfront:      │
     │    .sh       │     │ • Disk selection                     │
     │              │     │ • Partitioning choice                │
     │              │     │ • Hostname, timezone, username      │
     │              │     │ • Passwords                          │
     │              │     │ • NVIDIA drivers (if detected)       │
     └──────┬───────┘     └──────────────────────────────────────┘
            │
            ▼
     ┌──────────────┐     ┌──────────────────────────────────────┐
     │ bootstrap.sh │────▶│ 1. Disk partitioning                 │
     │ (background  │     │ 2. Format & mount partitions         │
     │  process)    │     │ 3. Pacstrap base system              │
     │              │     │ 4. Copy repo to /mnt/root/up         │
     └──────┬───────┘     └──────────────────────────────────────┘
            │
            ▼
     ┌──────────────┐
     │ arch-chroot  │
     │ /mnt         │
     └──────┬───────┘
            │
            ▼
     ┌──────────────┐     ┌──────────────────────────────────────┐
     │   setup.sh   │────▶│ 1. Hostname, timezone, locale        │
     │              │     │ 2. User account creation             │
     │ (runs inside │     │ 3. XLibre repository setup           │
     │  chroot)     │     │ 4. Package installation (categorized)│
     └──────┬───────┘     │ 5. yay + AUR packages (if available) │
            │             │ 6. Configuration deployment          │
            │             │ 7. GRUB bootloader installation      │
            ▼             │ 8. Service enabling                  │
     ┌──────────────┐     │ 9. Welcome wizard                    │
     │   Reboot     │     └──────────────────────────────────────┘
     └──────┬───────┘
            │
            ▼
     ┌──────────────┐
     │  LightDM     │
     │  i3-up       │
     └──────────────┘
```

## Quick Start

### From Arch ISO

```bash
# Connect to network (if needed)
iwctl station wlan0 connect YOUR_NETWORK

# Run installer
pacman -Sy --needed --noconfirm git
git clone https://github.com/calledtoconstruct/up.git /root/up
cd /root/up
./install.sh
```

### After Installation

1. Reboot when prompted (or `reboot` from the ISO).
2. Log in at the **LightDM** greeter with the user account created during install.
3. The **i3-up** session starts automatically (picom + i3 via `start-session.sh`).
4. On first login you should see a welcome notification; run `up-quickstart` if you want guided next steps.

```bash
up-quickstart              # tips, WiFi, keybindings
up-show-keybindings        # searchable shortcuts
sudo up-update             # supported system/config update path
```

**Success checklist after first login:**

| Check | How |
|-------|-----|
| Terminal opens | `Super + Return` |
| App launcher | `Super + Alt + Space` |
| System menu | `Super + Space` |
| Polybar visible | Top of screen |
| Network | Polybar / Super+Ctrl+W |

If any of these fail, see [TROUBLESHOOTING.md](TROUBLESHOOTING.md).

## Package Categories

Packages are installed in order of importance, with different failure handling:

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                      PACKAGE INSTALLATION ORDER                              │
└─────────────────────────────────────────────────────────────────────────────┘

  1. ESSENTIAL          Must succeed - aborts installation if failed
     ├── xlibre-xserver + X11 libraries
     ├── i3-wm + polybar + rofi
     ├── alacritty + firefox + neovim
     ├── btop + git + base-devel
     ├── zsh + starship + picom
     ├── tmux + feh + networkmanager
     └── grub + efibootmgr

  2. SYSTEM             Logged failures, installation continues
     ├── thunar + flameshot + gvfs
     ├── pipewire + pulsemixer + pavucontrol
     ├── bluez + blueman + dunst
     ├── rofi + xclip + xdotool
     └── various system utilities

  3. SHELL TOOLS        Affects .zshrc generation
     └── zoxide         (smart cd)

  4. COSMETIC           Visual enhancements
     ├── noto + dejavu + nerd fonts
     ├── papirus icons + materia gtk theme
     └── lxappearance + fastfetch

  5. AUR / apps         Requires yay (skipped if yay fails)
     ├── qalculate-gtk + imv + lazygit
     ├── localsend-bin (prebuilt AUR; provides `localsend`)
     ├── cliamp-bin (prebuilt AUR; provides `cliamp`, Music Player)
     └── extras that are AUR-only
```


## Post-Install Usage

### Keybindings

| Keybinding | Action |
|------------|--------|
| `Super + Space` | System menu (Go). **Install → Package** adds any Arch app; **Install → AUR** uses yay |
| `Super + Alt + Space` | Application launcher (rofi) |
| `Super + Shift + G` | Theme switcher |
| `Super + Ctrl + R` | Restart i3 |
| `Super + Enter` | Terminal (Alacritty) |
| `Super + Shift + T` | System monitor (btop) |
| `Super + Shift + A` | Grok AI assistant |
| `Super + Shift + B` | Web browser |
| `Super + Shift + C` | Calculator |
| `Super + Shift + D` | Docker manager |
| `Super + Shift + F` | File manager |
| `Super + Shift + H` | Quickstart guide |
| `Super + Shift + K` | Show keybindings |
| `Super + Shift + O` | Obsidian notes |
| `Super + Ctrl + A` | Audio controls |
| `Super + Ctrl + B` | Bluetooth controls |
| `Super + Ctrl + C` | Screenshot tool |
| `Super + Ctrl + I` | System information |
| `Super + Ctrl + Q` | Quit i3 |
| `Super + Ctrl + S` | File sharing |
| `Super + Ctrl + W` | WiFi controls |
| `Super + Space` | System menu |

## Configuration

Up uses a single configuration file at `~/.config/up/config` that serves as the source of truth for user preferences. Changes to this file are automatically applied.

### Config File Format

```toml
# Up Configuration File
# This file contains user preferences for the Up desktop environment
# Changes are automatically applied when the file is saved

# Compositor profile (picom)
# auto = detect GPU / virtualization / RAM and set fade/blur/dim
# full | lite | safe = pin a fixed profile
effects = "auto"
fade = true        # Materialized by effects= (fade transitions)
blur = true        # Materialized by effects= (background blur)
dim = true         # Materialized by effects= (inactive dim)

# Font for terminals and UI elements
font = "DejaVu Sans Mono"

# Current theme (auto-detected from applied theme)
theme = "aetherweft"
ready_sound = false
```

### Configuration Options

| Setting | Type | Description |
|---------|------|-------------|
| `effects` | string | `auto`, `full`, `lite`, or `safe` — hardware-aware compositor profile |
| `fade` | boolean | Window fade transitions in picom (written by profile when using `effects`) |
| `blur` | boolean | Background blur in picom (expensive; off on weak/VM/`safe`) |
| `dim` | boolean | Dim inactive windows in picom |
| `font` | string | Font family for terminals and UI elements |
| `theme` | string | Current theme name (automatically updated) |
| `ready_sound` | boolean | Optional chime when i3 and keybindings are ready (off by default; **Setup → Ready Sound**) |

### Compositor profiles (`effects`)

| Profile | Backend | Blur | Fade | Dim | Typical hardware |
|---------|---------|------|------|-----|------------------|
| `full` | glx | on | on | on | Discrete GPU or strong iGPU, bare metal, ≥4 GiB RAM |
| `lite` | glx | off | on | on | Borderline GPU, many VMs with some acceleration |
| `safe` | xrender | off | off | off | Software GL, low RAM, constrained VMs |
| `auto` | *(detected)* | *(detected)* | *(detected)* | *(detected)* | Default — re-probes when hardware fingerprint changes |

Detection runs at install, at session start, and when `~/.config/up/config` changes. Inspect or force re-apply:

```bash
up-compositor-profile              # show detection + applied settings
up-compositor-profile apply --force
```

Pin a profile (disables auto retuning until set back to `auto`):

```toml
effects = "lite"
```

### Automatic Application

The config file is monitored for changes and settings are applied automatically:

- **During i3 startup**: Config is checked and applied if different from current state
- **File watcher**: Live monitoring detects file changes and applies them immediately
- **Manual sync**: `switch-theme.sh --reapply` re-applies the configured theme; `switch-theme.sh --interactive` (or `up-switch-theme`) opens the picker. Bare `switch-theme.sh` re-applies a known theme and only opens the picker when none is set.

### Manual Editing

You can edit the config file directly:

```bash
# Edit the config file
nvim ~/.config/up/config

# Changes are applied automatically, or run:
switch-theme.sh --reapply  # Re-apply configured theme (no picker)
```

**Note**: The theme field is automatically updated when you change themes through the UI. Manual editing of the theme field will apply that theme on next sync.

## Themes

36 themes available, each updating:
- i3 window colors and bar
- Alacritty terminal colors
- Rofi launcher theme
- GTK application theme (partial support - templates available)
- btop system monitor
- htop system monitor (if installed)
- Starship prompt

Press `Super + Shift + G` to open the theme switcher.

**Note**: GTK theming integration is currently incomplete. Theme templates exist but full application may require manual setup.

## Customization

Configs are **copies**, not symlinks into `/usr/local/share/up`. Do not edit the vendor git tree.

**Tweaks that survive `up-update`:**

| What | Where |
|------|--------|
| Theme, font, compositor, ready sound | `~/.config/up/config` or the Style/Setup menus |
| Extra / replacement keybindings | `~/.config/up/keybindings-overrides.toml` |
| Extra i3 lines (`bindsym`, `for_window`, …) | `~/.config/up/overrides/i3.conf` |

**Stock files** such as `~/.config/i3/config` are replaced on update when they differ from the new default. The previous file is saved as `*.backup-update-YYYYMMDD`. Prefer the override files above instead of patching stock copies.

## File Locations

| Path | Purpose |
|------|---------|
| `/usr/local/share/up/` | Vendor tree (git; reset on update) |
| `~/.config/i3/` etc. | Stock live copies (backup + overwrite on update) |
| `~/.config/up/` | User intent (never overwritten) |
| `/var/log/up/install.log` | Installation log |
| `/var/lib/up/migrations/` | Migration state tracking |

## Updates

Use the **supported** update path so migrations always run with package updates:

```bash
up-update
# or: sudo up-update
# or System Menu → Update System
```

`/usr/local/share/up` is reset to upstream (local edits there are discarded). Stock copies under `~/.config/` are backed up and replaced. `~/.config/up/` is left alone.

Do **not** rely on raw `pacman -Syu` alone — that can skip config migrations required for new package versions.

If `up-update` cannot fetch because the vendor tree is dirty (older builds used stash-pop), as root:

```bash
cd /usr/local/share/up
git fetch origin
git reset --hard origin/main
git clean -fd
git stash clear
up-update -y
```

Refresh a single default config (with backup + diff):

```bash
up-refresh-config i3/config
```

## Display stack (XLibre)

Up prefers **XLibre** (`xlibre-xserver`) from `[xlibre-stable]` (`https://packages.xlibre.net/arch/stable/$arch`). If key/repo setup fails after retries, the installer **falls back to stock `xorg-server`** so the machine still gets a desktop. The chosen stack is logged in `/var/log/up/install-report.txt` and `/root/up/.display-stack` during install.

## Troubleshooting

| Issue | Solution |
|-------|----------|
| Theme not applying | `Super + Ctrl + R` to restart i3 |
| No keybindings | Ensure `~/.config/i3/keybindings.conf` exists; re-run `sudo up-update` or generate via setup |
| No polybar | `~/.config/polybar/launch.sh` |
| No audio | Check `pavucontrol`, ensure PipeWire is running |
| yay installation failed | Install manually: `git clone https://aur.archlinux.org/yay-bin.git && cd yay-bin && makepkg -si` |
| Network issues | `sudo systemctl restart NetworkManager` |
| Installation log | `cat /var/log/up/install.log` |
| Install report | `cat /var/log/up/install-report.txt` |

Full recovery guide: [TROUBLESHOOTING.md](TROUBLESHOOTING.md)

**View installation log:** `cat /var/log/up/install.log`