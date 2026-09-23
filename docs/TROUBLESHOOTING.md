# Up Linux Troubleshooting

## Installation

### Find what failed

```bash
cat /var/log/up/install.log
cat /var/log/up/install-report.txt   # human summary if install finished
ls /tmp/up-state/                    # live state during install (ISO host)
```

### Partition / disk errors

- **Wrong partition device (mmcblk, nvme):** Up uses `partition_device()` in `configs/scripts/partition-utils.sh` so `nvme*` / `mmcblk*` / `loop*` / `nbd*` get a `p` suffix. If you still see missing `/dev/...pN`, check `partprobe` and dmesg.
- **Silent wipe failed:** UEFI scripts now check `sgdisk` exit codes. Re-run install; if wipe fails, ensure the disk is not mounted and not in use.
- **Cancel mid-install:** Ctrl+C should unmount `/mnt` and swapoff via `cleanup_partitions` (never re-runs bootstrap). Restart with `./install.sh`.

### Pacstrap / network

- Pacstrap has a retry UI when network fails. Fix connectivity (`iwctl` / cable), then choose retry.
- Mirror issues: try `reflector` on the ISO or edit `/etc/pacman.d/mirrorlist`.

### XLibre / no graphical login

- Install prefers XLibre; on repo/key failure it falls back to `xorg-server`.
- Check: `grep DISPLAY_STACK /var/log/up/install-report.txt` or `/root/up/.display-stack` (pre-reboot on target).
- Manual XLibre key (if retrying by hand). Do **not** `recv-keys 73580DE2EDDFA6D6` — that key and the old x11libre.net mirror were retired 2026-08-12:
  ```bash
  curl -fsSL https://xlibre-arch.github.io/xlibre-archlinux.asc -o /tmp/xlibre.asc
  pacman-key --add /tmp/xlibre.asc
  pacman-key --lsign-key B97F7C613F359424
  # [xlibre-stable] Server = https://packages.xlibre.net/arch/stable/$arch
  pacman -Sy
  ```
- LightDM login loop: confirm `/usr/share/xsessions/i3-up.desktop` exists and the greeter session is `i3-up`.

### GRUB / unbootable system

- GRUB install is **essential** (no longer ignored). If install aborted at GRUB, boot an Arch ISO, mount root, `arch-chroot`, re-run `grub-install` + `grub-mkconfig`.
- BIOS installs need `DISK` from `.boot-config`.
- The menu timeout is **2 seconds** (`GRUB_TIMEOUT=2` in `/etc/default/grub`) so the menu stays interruptible. Hold Shift (BIOS) or tap Esc (UEFI) to keep it.

### Login screen shows the Arch wallpaper instead of the theme

`lightdm-gtk-greeter` reads **`/etc/lightdm/lightdm-gtk-greeter.conf`**, not `conf.d/theme.conf`. Theme switch now writes `background=` there and copies a world-readable file to `/usr/share/backgrounds/up/current.jpg`.

After `up-update`, switch the theme once (or `up-switch-theme --reapply`) and log out. Check:

```bash
grep ^background /etc/lightdm/lightdm-gtk-greeter.conf
ls -l /usr/share/backgrounds/up/current.jpg
sudo -n up-set-greeter-background ~/.config/up-background
```

The session user must be in group `up` (`groups`). `sudo -n` should work without a password for that helper.

### Login screen waits on the network

LightDM must not wait for DHCP. `NetworkManager-wait-online.service` and `systemd-networkd-wait-online.service` are masked. NetworkManager still connects after the greeter appears. To wait for a link before other units, unmask and enable the wait-online unit for that stack.

## First boot / runtime

### Polybar missing entirely after update

**Cause:** Bar was only started by `desktop-agent`. If the agent fails to take its lock (stale peer) or exits early, nothing launched polybar. `exec_always` for the bar was removed during the queue work.

**Fix (in tree):** i3 runs `exec_always …/polybar/launch.sh` again as a safety net; agent + launch.sh share a flock. After `up-update`:

```bash
# Immediate recovery
~/.config/polybar/launch.sh
pgrep -a polybar
tail -30 "${XDG_RUNTIME_DIR:-/tmp}/polybar-$(id -u).log"
tail -30 ~/.local/state/up/desktop/agent.log
```

Also confirm i3 config includes the safety net:

```bash
grep polybar ~/.config/i3/config
# should show: exec_always ... polybar/launch.sh
# If missing: up-refresh-config i3/config && i3-msg reload
```

### Polybar: “failed to open config.ini: Permission denied”

**Cause:** `~/.config/polybar` (or `config.ini`) owned by **root** after `sudo up-update` created dirs as root, or `config.ini` is an unreadable symlink into the package tree.

**Fix now:**

```bash
sudo chown -R "$USER:$USER" ~/.config/polybar
chmod 755 ~/.config/polybar
chmod 644 ~/.config/polybar/config.ini 2>/dev/null || true
chmod 755 ~/.config/polybar/launch.sh
# Replace bad symlink if present:
[ -L ~/.config/polybar/config.ini ] && rm -f ~/.config/polybar/config.ini
[ ! -f ~/.config/polybar/config.ini ] && \
  cp /usr/local/share/up/configs/polybar/config.ini ~/.config/polybar/config.ini
chmod 644 ~/.config/polybar/config.ini

~/.config/polybar/launch.sh
ls -la ~/.config/polybar/
```

Updated `up-update` chowns the polybar tree after refresh so this should not recur.

### Two polybars / double top bar after theme or font change

**Cause:** Concurrent theme apply, config watcher, and i3 startup all restarted polybar.

**Fix:** Desktop apply agent serializes work; `launch.sh` uses flock. After update, log out/in. Emergency:

```bash
pkill -x polybar
~/.config/polybar/launch.sh
pgrep -a polybar   # one process
```

### Desktop agent not applying theme / bar stuck

```bash
pgrep -a desktop-agent || up-desktop-agent &
tail -50 ~/.local/state/up/desktop/agent.log
ls ~/.local/state/up/desktop/queue/
up-desktop-request --wait reapply
```

### Polybar colors do not change when switching themes

**Cause:**
1. `launch.sh` left its lock open inside polybar, so the next theme change could not replace the process.
2. Super+Ctrl+R is i3 `restart`. i3 does not run plain `exec` lines on restart, so the bar only redraws and keeps the colors it parsed at login.

**Fix:** Update Up (`exec_always` re-runs `launch.sh` on reload and restart; the bar does not inherit the lock). Verify colors were written:

```bash
grep -A5 '^\[colors\]' ~/.config/polybar/config.ini
up-switch-theme --reapply
```

### Polybar missing workspace numbers (no 1 / 2 tabs)

**Cause (common after theme/font apply):**
1. Polybar started while i3 was mid-reload — `internal/i3` never got workspaces.
2. `pin-workspaces = true` with a `MONITOR` name that does not match i3’s output (VMs, docking).

**Fix:** Update Up (waits for i3 IPC; `pin-workspaces = false` by default), then:

```bash
up-refresh-config polybar/config.ini   # or copy from /usr/local/share/up/configs/polybar/
up-switch-theme --reapply
# or:
pkill -x polybar; ~/.config/polybar/launch.sh
```

Confirm: `pgrep -a polybar` and that the left side of the bar shows `1` (and other used workspaces).

### Theme picker opens automatically after login (or loops after picking)

**Cause (two related bugs):**

1. Session startup / config watcher re-applies the theme for picom fade/blur/dim. Older builds called `switch-theme.sh` with no arguments; when a theme was already set, that path opened the rofi picker.
2. `config-watcher.sh` watched `~/.config/up/config`, and `apply-compositor-profile.sh` rewrote `fade`/`blur`/`dim` on every sync (even when unchanged). That re-triggered inotify → another sync → picom kill/restart → often another picker. Choosing a theme wrote `theme = ...` and fed the same loop.

**Fix:** Update Up (`up-update`) and log out/in (or restart i3). Current behavior:

- Automation uses `--reapply` / silent re-apply; picker only with `--interactive`
- Config writes no-op when values are unchanged; watcher uses a lock and only restarts picom when compositor fragments actually change

Interactive pick:

- Super+Shift+G
- System menu → Switch Theme
- `up-switch-theme`

Re-apply current theme without picking:

```bash
up-switch-theme --reapply
```

If picom still thrashing after update, check for a stuck lock and remove it:

```bash
rm -rf ~/.config/up/.config-sync.lock.d
```

### Rofi: “Failed to load theme” / error loading theme file

**Cause:** Older Up configs used:

```rasi
@theme ".config/rofi/theme.rasi"
```

That path is resolved from the **process working directory** (often `/` when started by i3), not from `~/.config/rofi/`, so the theme file is not found.

**Fix:**

```bash
# 1) Point config at same-directory theme (or refresh stock config)
sed -i 's|@theme "\.config/rofi/theme.rasi"|@theme "theme.rasi"|' ~/.config/rofi/config.rasi
# or:
up-refresh-config rofi/config.rasi
cp /usr/local/share/up/configs/rofi/theme.rasi ~/.config/rofi/theme.rasi

# 2) Regenerate theme colors
up-switch-theme
# or re-apply current theme via Super+Shift+G
```

Confirm:

```bash
ls -la ~/.config/rofi/config.rasi ~/.config/rofi/theme.rasi
grep '@theme' ~/.config/rofi/config.rasi   # should be: @theme "theme.rasi"
```

### Picom slow, laggy, or blur looks broken

Up auto-tunes picom via `effects` in `~/.config/up/config`:

```bash
up-compositor-profile              # what was detected / applied
cat ~/.config/picom/capability.conf
cat ~/.config/up/compositor-capability
```

- **Force a light profile:** set `effects = "lite"` or `effects = "safe"`, save, wait for config watcher (or re-login).
- **Force full effects:** `effects = "full"` then `up-compositor-profile apply --force`.
- **Return to detection:** `effects = "auto"` then `up-compositor-profile apply --force`.
- NVIDIA + glx may set `xrender-sync-fence = true` in `capability.conf`; if the screen still glitches, try `effects = "safe"` (xrender, no blur).
- `fade` / `blur` / `dim` are **materialized by the profile** when `effects` is `auto`/`full`/`lite`/`safe` — editing them alone while `effects = "auto"` will be overwritten on next apply.

### Screenshot fails (“Unable to capture screen” / portal)

**Cause:** Flameshot 13+ takes screenshots through the XDG desktop portal. i3 on X11 has no portal screenshot backend, so `flameshot gui` exits with `Could not locate the org.freedesktop.portal.Desktop service` or `Unable to capture screen`.

**Fix:** Update Up. Capture uses `configs/scripts/screenshot.sh`, which sets `useX11LegacyScreenshot=true` in `~/.config/flameshot/flameshot.ini` and restarts a running flameshot. By hand:

```bash
mkdir -p ~/.config/flameshot
printf '%s\n' '[General]' 'useX11LegacyScreenshot=true' >> ~/.config/flameshot/flameshot.ini
pkill -x flameshot
flameshot gui
```

### No keybindings

```bash
ls -l ~/.config/i3/keybindings.conf
# Regenerate:
export UP_ROOT=/usr/local/share/up
source "$UP_ROOT/configs/scripts/keybinding-utils.sh"
write_i3_keybindings_file ~/.config/i3/keybindings.conf
i3-msg reload
```

### No polybar

```bash
~/.config/polybar/launch.sh
# or
killall polybar; polybar -c ~/.config/polybar/config.ini main &
```

### `up-quickstart` / `up-help` missing

```bash
sudo chmod +x /usr/local/share/up/bin/up-*
echo $PATH   # should include /usr/local/share/up/bin via /etc/profile.d/up-path.sh
```

### Theme not applying

```bash
up-switch-theme
# or
Super + Ctrl + R   # restart i3
```

### Bluetooth: "Bluez daemon is not running", or the controls window flashes closed

**Cause:** `bluez` and `blueman` are installed, but `bluetooth.service` is not enabled. Arch does not start `bluetoothd` on its own. Blueman shows the daemon error. The menu entry runs `bluetoothctl`, which exits at once, so the terminal closes.

**Fix:** Update Up (migration `003-enable-bluetooth` enables and starts the service). By hand:

```bash
sudo systemctl enable --now bluetooth.service
systemctl status bluetooth.service
```

### Audio / network

```bash
systemctl --user status pipewire pipewire-pulse wireplumber
sudo systemctl restart NetworkManager
nmtui
```

## Updates

### `up-update` stuck / vendor tree dirty

`/usr/local/share/up` is a git checkout. Older `up-update` stashed local dirt and **popped it back**, so the pull never stuck. Greeter settings used to follow **symlinks** into that tree and mark it dirty.

As root on the target (does not touch `~/.config`):

```bash
cd /usr/local/share/up
git status
git fetch origin
git reset --hard origin/main
git clean -fd
git stash clear
up-update -y
```

If `reset --hard` fails on permissions: `chown -R root:root /usr/local/share/up` and retry. If `origin/main` is missing, use the upstream `git branch -vv` shows.

After a successful update, `git -C /usr/local/share/up status` should be clean.

### Preferred path

```bash
up-update          # auto-elevates with sudo (absolute path)
# or
sudo up-update     # works when /usr/local/bin/up-update symlink exists
```

System Menu → **Update System** opens a terminal and runs the same command.

Avoid bare `pacman -Syu` without migrations — config fixes may be skipped.

### `up-update must run as root` / `sudo: up-update: command not found`

**Cause:** `up-update` lives in `/usr/local/share/up/bin`, which is on your login `PATH` via `/etc/profile.d/up-path.sh`, but **sudo resets PATH** to `secure_path` (usually `/usr/local/bin:/usr/bin`). So:

| Command | Result (old behavior) |
|---------|------------------------|
| `up-update` | “must be root” |
| `sudo up-update` | “command not found” |

**Fix (pick one):**

```bash
# 1) Call by absolute path (always works)
sudo /usr/local/share/up/bin/up-update

# 2) Install secure_path links (up-update does this)
sudo ln -sfn /usr/local/share/up/bin/up-update /usr/local/bin/up-update

# 3) After links or a new up-update is in place, plain works:
up-update
```

If the install tree is missing entirely:

```bash
ls -la /usr/local/share/up/bin/up-update
# Should exist; if not, Up was not deployed to /usr/local/share/up
```

### Bad update / config overwrite

- Config backups: `~/.config/**/*.backup-*` and `/var/lib/up/backups/pre-update-*`
- Single file restore from defaults: `up-refresh-config i3/config`
- Compare: `diff -u ~/.config/i3/config.backup-... ~/.config/i3/config`

### Migration failed

```bash
ls /var/lib/up/migrations/
ls /var/lib/up/migrations/skipped/
# Re-run a migration manually:
sudo bash /usr/local/share/up/migrations/00N-name.sh
sudo touch /var/lib/up/migrations/00N-name.done
```

## Getting help

- Install log: `/var/log/up/install.log`
- Install report: `/var/log/up/install-report.txt`
- Version: `cat /usr/local/share/up/version`
- Architecture notes: [ARCHITECTURE.md](ARCHITECTURE.md)
