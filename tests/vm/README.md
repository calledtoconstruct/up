# Automated VM case: `uefi-virtio`

Installs Up into a QEMU guest, reboots from the virtual disk, then runs
one or more **desktop suites**. Each suite boots the installed disk,
exercises the session, and shuts the guest down.

**Never run `install-unattended.sh` or `guest-iso.sh` on your Omarchy host.**
They wipe the selected disk.

## Host packages

```bash
sudo pacman -S --needed qemu-full edk2-ovmf python curl libarchive openssh
```

KVM must be available (`/dev/kvm`).

## Run the case

From the Up repo:

```bash
# Host checks only (no guest)
python3 tests/vm/run.py --dry-run

# Full install + all desktop suites (15–60+ minutes; ISO cached after first run)
python3 tests/vm/run.py

# Install + Super+Return smoke only
python3 tests/vm/run.py --suites smoke

# Reuse a previous disk (skip pacstrap). Current bin/ + configs/ are
# copied into the guest so --invoke / --font / --image match this tree.
python3 tests/vm/run.py --skip-install --suites appearance,apps

# Confirm the installed desktop comes up, then power off
python3 tests/vm/run.py --skip-install --boot-only

# Snapshot whatever is on the disk now as the post-OS base
python3 tests/vm/run.py --skip-install --save-base --boot-only

# Reset to that base, then run appearance (or any suite) on a clean OS
python3 tests/vm/run.py --skip-install --restore-base --suites appearance
```

Useful flags:

| Flag | Meaning |
|---|---|
| `--iso PATH` | Use an existing Arch ISO |
| `--work DIR` | Disk, serial logs, SSH key (default `tests/vm/work`) |
| `--ram-mb 4096` | Guest RAM |
| `--ssh-port 0` | 0 = pick a free localhost port |
| `--suites LIST` | `smoke`, `appearance`, `apps` (default: all three) |
| `--skip-install` | Reuse `tests/vm/work/uefi-virtio.qcow2` (or recreate it from the base) |
| `--boot-only` | Wait for i3 and power off; do not run suites |
| `--save-base` | Freeze the current disk as `uefi-virtio.base.qcow2` (automatic after install) |
| `--restore-base` | Reset the overlay from the base before every suite |
| `--no-restore-base` | Keep a dirty overlay |

## What it does

1. Creates `tests/vm/work/uefi-virtio.qcow2` (VirtIO → `/dev/vda`).
   After a successful OS install that file is promoted to
   `uefi-virtio.base.qcow2` and a thin overlay is used for suites.
2. Boots the Arch ISO kernel with a serial console (no GUI window).
   The kernel cmdline must **not** include `ip=dhcp` — that turns on the
   PXE hook and the live image never starts.
3. Mounts this git tree into the guest (9p) and runs `install-unattended.sh`.
4. Enables SSH + LightDM autologin for user `tester` (password `testervm1`).
5. Reboots **without** the ISO (once per suite).
6. SSHes in, waits for **i3**, then runs the requested suites:
   - **smoke** — Super+Enter via QEMU `sendkey super_l-ret` (xdotool often
     cannot hit i3's grab), confirm Alacritty, type `systemctl poweroff`.
   - **appearance** — `up-switch-theme`, `up-font-chooser`, wallpaper
     select/random from the CLI **and** via `up-system-menu --invoke`,
     then **System → Shutdown** through the menu handler.
   - **apps** — open Alacritty, Firefox, Thunar, nvim, btop; move windows
     between workspaces; toggle split / layout orientation; fullscreen
     on and off; then power off.
   Alacritty needs GL; the guest session sets `LIBGL_ALWAYS_SOFTWARE=1`
   and installed boots use `virtio-vga-gl` + `egl-headless`.
7. Writes `tests/vm/reports/uefi-virtio.json` and `latest.txt`.

## Answers

`tests/vm/fixtures/uefi-virtio.conf` is the unattended answer file
(`disk=auto` becomes `/dev/vda`).
