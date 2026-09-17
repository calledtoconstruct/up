# Up Linux Dependencies

Last reviewed: **2026-08-12**. Re-verify XLibre and AUR packages at least quarterly.

## Critical external: XLibre

| Item | Detail |
|------|--------|
| Packages | `xlibre-xserver`, `xlibre-input-libinput` (essential when XLibre path succeeds) |
| Repo | `[xlibre]` → `https://x11libre.net/repo/arch_based/x86_64` |
| Key | `73580DE2EDDFA6D6` |
| Fallback | Stock `xorg-server` + `xf86-input-libinput` if repo/key fails after retries |
| Risk | Not in official Arch repos; packaging/docs have been contentious in the Arch community; AUR install order is fragile; may conflict with NVIDIA ABI assumptions |
| Install behavior | Retry key/repo (with TUI prompt); then fallback rather than hard-brick |

**Do not** treat XLibre as set-and-forget. After each XLibre release, smoke-test a clean install or chroot package update.

## AUR helper: yay

| Item | Detail |
|------|--------|
| Package | Built from `yay-bin` during install when possible |
| Status | Still listed among maintained AUR helpers (Arch Wiki); not officially supported by Arch |
| Alternative | `paru` (optional future drop-in; not required now) |
| Policy | AUR failures are non-fatal; essential desktop must not depend solely on AUR |

## Core desktop (official Arch)

Keep for X11 + legacy hardware mission:

- i3-wm, polybar, rofi, picom, lightdm + greeter
- alacritty, dunst, pipewire + wireplumber
- networkmanager, starship, zsh, neovim, firefox

**Not** migrating to Hyprland/Wayland (see Omarchy comparison in project plans).

## Optional / hygiene

| Package | Notes |
|---------|--------|
| `dmenu` | **Removed from base.** Dunst actions use `rofi -dmenu`. |
| `cliamp` | Official extra; music.desktop depends on it. Verify availability quarterly. |
| `materia-gtk-theme` | Aging; watch GTK4 apps |
| `ufw` | Installed and configured with default deny-in / allow-out / SSH |
| Default fonts | `noto-fonts`, `noto-fonts-emoji`, `ttf-dejavu`, `ttf-nerd-fonts-symbols`, `ttf-jetbrains-mono` — extras via font chooser |
| Base AUR | `yay-bin` helper, then `localsend-bin` + `xautolock` only. Official apps install via pacman. |

## Update discipline

Supported path: **`up-update`** (auto-sudo) or **`sudo up-update`** (or System Menu → Update System).
Commands are linked into `/usr/local/bin` so sudo’s secure_path can find them.

This always runs: config backup → git pull → migrations → pacman → optional AUR → config refresh → theme re-apply.

Raw `pacman -Syu` / `yay -Syu` can leave configs out of sync with package versions (same lesson as Omarchy’s update model).

## Review checklist (quarterly)

- [ ] XLibre repo URL and key still work from a clean Arch ISO
- [ ] Fallback xorg path still produces a loginable LightDM session
- [ ] yay-bin builds as nobody during chroot install
- [ ] No essential packages silently moved to AUR-only
- [ ] `cliamp` still in extra (or replace music.desktop)
- [ ] Base AUR list is still only `localsend-bin` + `xautolock`
