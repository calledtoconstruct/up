# Testing Up Linux in a Virtual Machine

This guide is for developers who already run **Omarchy Linux** (or another Arch-based host) and want to test the **Up Linux installer** and **post-install desktop** safely in a VM—without wiping a real disk.

You will:

1. Install a hypervisor on your Omarchy host  
2. Download an official Arch Linux ISO  
3. Create a virtual machine with a blank virtual disk  
4. Boot the ISO and run the Up installer  
5. Reboot into the installed Up system and verify it works  

---

## Why use a VM?

| Goal | Why a VM helps |
|------|----------------|
| Test the **installer** | Partitioning, pacstrap, GRUB, XLibre/xorg, LightDM |
| Test the **desktop** | i3, polybar, keybindings, themes, system menu |
| Test **updates** | `up-update` without risking your Omarchy install |
| Reproduce bugs | Snapshot / clone VMs; try UEFI vs BIOS, small disks, etc. |

**Important:** The virtual disk is separate from your Omarchy system. You can delete the VM when finished.

---

## What you need on the host (Omarchy)

### Hardware / resources

- **CPU:** hardware virtualization enabled (Intel VT-x or AMD-V) in BIOS/UEFI  
- **RAM:** at least **8 GB** on the host so you can give the VM 2–4 GB  
- **Disk:** about **30–40 GB** free for the virtual disk + ISO  
- **Network:** working internet on Omarchy (the guest will use NAT or bridged networking)

### Check that KVM is available

```bash
# Lists CPU virtualization flags (look for vmx = Intel, or svm = AMD)
lscpu | grep -E 'Virtualization|vmx|svm'

# Kernel KVM modules should load on most Arch systems
lsmod | grep kvm
```

**What these do:**

- `lscpu` — shows CPU features; if neither `vmx` nor `svm` appears, enable virtualization in firmware.  
- `lsmod | grep kvm` — confirms the kernel can run VMs with hardware acceleration.

If KVM is missing, reboot into firmware settings and enable **Intel VT-x** / **AMD-V** / **SVM**.

---

## Step 1 — Install QEMU/KVM tools on Omarchy

Omarchy is Arch-based, so use `pacman` (or Omarchy’s install menu if you prefer).

```bash
# Hypervisor + virtual networking
sudo pacman -S --needed qemu-full libvirt virt-manager dnsmasq iptables-nft edk2-ovmf

# Optional but handy: SPICE display client (better guest display in virt-manager)
sudo pacman -S --needed spice-gtk
```

**What these packages are:**

| Package | Role |
|---------|------|
| `qemu-full` | Emulates a PC and runs the guest OS |
| `libvirt` | Manages VMs (networks, storage, permissions) |
| `virt-manager` | Graphical UI to create and control VMs |
| `dnsmasq` | DHCP/DNS for the default virtual network |
| `iptables-nft` | Firewall rules for NAT (guest internet) |
| `edk2-ovmf` | UEFI firmware for the guest (recommended) |

### Enable and start libvirt

```bash
# Start libvirtd now and on every boot
sudo systemctl enable --now libvirtd

# Let your user manage VMs without typing sudo every time
sudo usermod -aG libvirt "$USER"
```

**What these do:**

- `systemctl enable --now libvirtd` — starts the libvirt daemon and makes it start at boot.  
- `usermod -aG libvirt` — adds you to the `libvirt` group so `virt-manager` can talk to the daemon.

**Log out and back in** (or reboot) so the new group membership applies. Then confirm:

```bash
# Should print: active
systemctl is-active libvirtd

# Default virtual network should be running (provides guest DHCP/NAT)
sudo virsh net-list --all
sudo virsh net-start default 2>/dev/null || true
sudo virsh net-autostart default
```

**What these do:**

- `virsh net-list` — lists libvirt networks.  
- `net-start default` — turns on the usual NAT network so the guest can reach the internet.  
- `net-autostart default` — starts that network automatically after host reboot.

---

## Step 2 — Download the Arch Linux ISO

Up’s installer runs **from a booted Arch ISO** (not from Omarchy’s own root).

```bash
# Create a place to store ISOs and VM disks
mkdir -p ~/VMs/iso ~/VMs/disks

# Download the latest official Arch ISO (example; check archlinux.org for the current filename)
cd ~/VMs/iso
curl -LO https://geo.mirror.pkgbuild.com/iso/latest/archlinux-x86_64.iso

# Optional: verify checksums from the same release page on archlinux.org
```

**What this does:**

- Saves the install media your VM will boot from.  
- The ISO is read-only; the install still targets a **separate virtual hard disk**.

You can also download via a browser from [https://archlinux.org/download/](https://archlinux.org/download/).

---

## Step 3 — Create the virtual machine (virt-manager GUI)

This is the easiest path on a desktop host.

1. Open **Virtual Machine Manager**:
   ```bash
   virt-manager
   ```
2. **File → New Virtual Machine** (or the toolbar “+”).
3. Choose **Local install media (ISO image or CDROM)** → Forward.
4. Browse to `~/VMs/iso/archlinux-x86_64.iso`.
5. When asked for OS type, pick **Arch Linux** (or Generic Linux if needed).
6. **Memory:** **4096 MB** recommended (2048 MB minimum).  
7. **CPUs:** **2** or more.  
8. **Storage:** create a new disk image, **≥ 25 GB** (40 GB is comfortable).  
   - Example path: `~/VMs/disks/up-test.qcow2`  
9. Name the VM something clear, e.g. `up-test`.
10. Before finishing, open **Customize configuration before install** (if shown), then set:

| Setting | Recommended for Up testing | Why |
|---------|----------------------------|-----|
| Firmware | **UEFI** (OVMF) | Matches most modern machines |
| Disk bus | VirtIO | Fast; Up’s partition helper supports `vd*` names |
| NIC | VirtIO, network **default** | Guest internet for pacstrap |
| Video | Virtio or QXL | Fine for X11 inside guest |
| Display | Spice | Comfortable full-screen in virt-manager |

11. Click **Begin Installation** / **Finish**, then **start** the VM if it is not already running.

### Terminal size for the installer UI

Up’s installer uses **tmux** and expects roughly **80×30** or larger. Maximize the virt-manager window (or full-screen) so the TUI panes are readable.

---

## Step 4 — Alternative: create the VM from the command line

If you prefer not to use virt-manager:

```bash
# Create a 40G sparse disk image (grows as data is written)
qemu-img create -f qcow2 ~/VMs/disks/up-test.qcow2 40G

# Boot Arch ISO with UEFI, virtio disk, NAT network, and a graphical window
qemu-system-x86_64 \
  -enable-kvm \
  -machine q35 \
  -cpu host \
  -m 4096 \
  -smp 2 \
  -drive if=pflash,format=raw,readonly=on,file=/usr/share/edk2/x64/OVMF_CODE.4m.fd \
  -drive if=pflash,format=raw,file=/tmp/OVMF_VARS.up-test.fd \
  -drive file=~/VMs/disks/up-test.qcow2,if=virtio,format=qcow2 \
  -cdrom ~/VMs/iso/archlinux-x86_64.iso \
  -boot d \
  -netdev user,id=net0 \
  -device virtio-net-pci,netdev=net0 \
  -device virtio-vga \
  -display gtk
```

**One-time UEFI variables file** (copy before first boot if the path above is empty):

```bash
# Writable UEFI NVRAM for this VM (keeps boot entries after install)
cp /usr/share/edk2/x64/OVMF_VARS.4m.fd /tmp/OVMF_VARS.up-test.fd
```

**What the important flags mean:**

| Flag | Meaning |
|------|---------|
| `-enable-kvm` | Use hardware virtualization (fast) |
| `-m 4096` | Give the guest 4 GB RAM |
| `-drive ... qcow2` | Guest hard disk where Up will be installed |
| `-cdrom ...iso` | Boot media (Arch) |
| `-boot d` | Prefer CD/DVD on first boot |
| `-netdev user` | Simple NAT: guest can reach the internet |
| OVMF files | UEFI firmware so GRUB EFI install is exercised |

> Paths for OVMF may vary slightly (`OVMF_CODE.fd` vs `OVMF_CODE.4m.fd`). Check with:  
> `ls /usr/share/edk2/x64/` or `pacman -Ql edk2-ovmf | grep OVMF`.

After install, reboot the guest **without** the ISO (or change boot order to the hard disk) so you start Up from disk, not the live ISO again.

---

## Step 5 — Inside the Arch ISO: network and time

When the Arch live environment finishes booting, you get a root shell.

### Network

```bash
# See interfaces (often ens3, enp1s0, or eth0 in a VM)
ip link

# Wired (most virt-manager NAT setups): usually already up via DHCP
# If not:
dhcpcd
# or
systemctl start dhcpcd

# Test connectivity
ping -c 3 archlinux.org
```

**What these do:**

- `ip link` — lists network interfaces.  
- `dhcpcd` / NetworkManager — obtains an IP via DHCP from the host’s virtual network.  
- `ping` — confirms DNS and internet work (required for pacstrap and package installs).

Wi‑Fi is rarely needed in a VM; NAT over the host’s connection is enough.

### Clock (optional)

```bash
# Sync time so package signatures validate reliably
timedatectl set-ntp true
```

---

## Step 6 — Run the Up installer

Still as **root** on the Arch ISO:

```bash
# Install git so you can clone the Up repository
pacman -Sy --needed --noconfirm git

# Clone Up (use your fork URL if testing a branch)
git clone https://github.com/calledtoconstruct/up.git /root/up
cd /root/up

# Optional: test a specific branch
# git checkout your-feature-branch

# Launch the tmux-based installer
./install.sh
```

**What these commands do:**

| Command | Purpose |
|---------|---------|
| `pacman -Sy ... git` | Refresh package DBs and install `git` |
| `git clone ... /root/up` | Download Up onto the live ISO (not your Omarchy host disk) |
| `./install.sh` | Installs `tmux`, builds the installer UI, starts `bootstrap.sh` |

### During the installer prompts

Typical order (installer may collect some answers while work runs in parallel):

1. **Disk** — choose the virtual disk (often `/dev/vda` for VirtIO, or `/dev/sda`).  
   - Do **not** pick anything that looks like a USB stick unless you mean to.  
2. **Partition scheme** — Standard, or Standard + Swap.  
3. **Confirm wipe** — this only wipes the **virtual** disk.  
4. **Hostname, timezone, username, passwords.**  
5. **SSH key / NVIDIA** — usually “no” in a plain VM.  
6. Wait for pacstrap, packages, GRUB, services.

**Terminal too small?** The installer may warn; enlarge the virt-manager window.

**Cancel safely:** Ctrl+C in the input pane and confirm cancel so mounts are cleaned up; then you can re-run `./install.sh`.

Install log (live ISO / later on installed system):

```bash
# During/after install (paths may be on the installed root once mounted)
cat /var/log/up/install.log
```

---

## Step 7 — Reboot into installed Up

When the installer reports success:

1. In the installer UI, choose reboot if offered, **or** in a shell: `reboot`.  
2. In **virt-manager**, either:
   - Eject / disconnect the ISO (Boot options → uncheck CD), or  
   - Enter the guest firmware boot menu and select the hard disk.  
3. You should see **GRUB**, then **LightDM**.  
4. Log in with the user you created.  
5. The **i3-up** session should start (tiling desktop + polybar).

If you boot the ISO again by accident, you are still in the live environment—change boot order and reboot.

---

## Step 8 — Verify the installed system (checklist)

Open a terminal (`Super + Return` if keybindings work) and run:

### Session and packages

```bash
# Who am I / shell
whoami
echo "$SHELL"

# Up install location and version
ls /usr/local/share/up
cat /usr/local/share/up/version

# Display stack chosen at install (xlibre or xorg)
cat /var/log/up/install-report.txt 2>/dev/null | head -40
```

### Desktop basics (manual)

| Test | Expected |
|------|----------|
| `Super + Return` | Alacritty terminal |
| `Super + Space` | Application launcher (rofi) |
| `Super + Alt + Space` | System menu |
| Polybar | Bar along the top (or configured edge) |
| Theme | `up-switch-theme` or Super+Shift+G |
| Quick start | `up-quickstart` |

### Keybindings file (common regression)

```bash
# Must exist and contain bindsym lines
test -s ~/.config/i3/keybindings.conf && echo "keybindings OK" || echo "MISSING keybindings"
wc -l ~/.config/i3/keybindings.conf
```

### Network and audio (smoke)

```bash
# Network
ip addr
ping -c 2 archlinux.org

# Audio stack present (may be quiet until something plays)
systemctl --user status pipewire pipewire-pulse wireplumber --no-pager
```

### Updates path (optional second pass)

```bash
# Supported update path (needs network + may ask for password)
sudo up-update -y
```

**What this tests:** git pull of Up configs, migrations, pacman upgrade, config refresh—without using bare `pacman -Syu` alone.

---

## Step 9 — Suggested test matrix

Run separate VMs (or snapshots) when hardening install reliability:

| Scenario | How to configure | What it exercises |
|----------|------------------|-------------------|
| UEFI + VirtIO disk | Default virt-manager UEFI + virtio disk (`/dev/vda`) | Main modern path |
| UEFI + SATA disk | Disk bus **SATA** (`/dev/sda`) | Non-nvme naming |
| BIOS (SeaBIOS) | Firmware: BIOS instead of UEFI | BIOS partition scripts + GRUB i386-pc |
| Small disk | 20 GB disk | Tight space / swap math |
| Low RAM | 2048 MB | Minimum memory path |
| XLibre failure | Block XLibre host in guest `/etc/hosts` mid-retry *or* unplug net during XLibre key step | Fallback to xorg-server |
| Cancel install | Ctrl+C mid-partition | Cleanup / re-run safety |

**Snapshots (virt-manager):** before risky steps, use **Create snapshot**. Roll back instead of reinstalling from scratch.

```bash
# CLI snapshot example (libvirt)
virsh snapshot-create-as up-test clean-before-update "Before up-update"
virsh snapshot-revert up-test clean-before-update
```

---

## Step 10 — Clean up when finished

```bash
# Shut down the guest from inside: Super+Alt+Space → Power → Shutdown
# Or force from host:
virsh destroy up-test          # force power off
virsh undefine up-test --nvram # remove VM definition (keep or delete disk)

# Delete the virtual disk if you no longer need it
rm -f ~/VMs/disks/up-test.qcow2
```

**What these do:**

- `virsh destroy` — hard power-off (like pulling the plug). Prefer a clean shutdown from the guest when possible.  
- `virsh undefine` — removes the VM from libvirt.  
- Deleting the `.qcow2` file frees disk space on Omarchy.

---

## Common problems (host = Omarchy, guest = Up)

| Symptom | Likely cause | Fix |
|---------|--------------|-----|
| Guest has no network | `default` libvirt network stopped | `sudo virsh net-start default` |
| `Permission denied` on virt-manager | Not in `libvirt` group / session not refreshed | Re-login after `usermod -aG libvirt` |
| Installer panes unreadable | Terminal too small | Maximize virt-manager / increase resolution |
| Install hangs on packages | Guest offline or slow mirror | Fix guest network; retry |
| Reboot returns to Arch live ISO | CD still first in boot order | Disconnect ISO; boot hard disk |
| Black screen after LightDM | Display stack / session issue | See [TROUBLESHOOTING.md](TROUBLESHOOTING.md); check `/var/log/up/install-report.txt` |
| No keybindings in i3 | `keybindings.conf` missing | Generate per TROUBLESHOOTING; re-test installer path |

---

## Developing Up on Omarchy, testing in the VM

Typical loop:

1. Edit Up on Omarchy in `~/code/up` (or your clone path).  
2. Push to a branch **or** share the tree with the guest.  
3. On the Arch ISO / in a reinstall, clone that branch and run `./install.sh`.

### Option A — Clone from GitHub (simple)

```bash
# On ISO or inside already-installed Up guest
git clone -b your-branch https://github.com/YOU/up.git /root/up
```

### Option B — Serve local clone over the network

On **Omarchy host** (from your Up repo):

```bash
# Quick read-only HTTP of the repo (only on your LAN/VM network)
cd ~/code/up
python -m http.server 8000
```

On **guest** (find host IP: on Omarchy run `ip -br a`; for NAT, use the gateway or a bridge setup):

For **user NAT**, the host is often reachable as the default gateway from the guest:

```bash
# Inside guest
ip route | awk '/default/ {print $3}'   # often 10.0.2.2 for qemu user NAT
# Then fetch a tarball if you published one, or use git over SSH/HTTPS instead.
```

**Easiest reliable path:** push your branch and `git clone` it from the guest. Avoid fighting NAT port forwards unless you need offline testing.

### Option C — 9p / virtio shared folder (advanced)

Possible with libvirt filesystem mounts so the guest sees `~/code/up` live. Useful for rapid iteration; more setup. Prefer git branches for formal install tests so the guest matches a real user clone.

---

## Quick reference commands

```bash
# Host: start UI
virt-manager

# Host: list VMs
virsh list --all

# Host: start / stop
virsh start up-test
virsh shutdown up-test

# Guest ISO: install Up
pacman -Sy --needed --noconfirm git
git clone https://github.com/calledtoconstruct/up.git /root/up
cd /root/up && ./install.sh

# Guest installed: verify + update
up-quickstart
cat /var/log/up/install-report.txt
sudo up-update -y
```

---

## Automated single case

The same UEFI + VirtIO path can be run without a human at the prompts:

```bash
python3 tests/vm/run.py --dry-run   # host tools + ISO extract
python3 tests/vm/run.py             # install + smoke + appearance + apps
python3 tests/vm/run.py --suites smoke
python3 tests/vm/run.py --skip-install --suites appearance,apps
```

See [tests/vm/README.md](../tests/vm/README.md). That runner uses
`install-unattended.sh` (no tmux) and must only ever run against a **virtual**
disk inside QEMU.

## Related docs

- [INSTALL.md](INSTALL.md) — full install flow and post-install usage  
- [TROUBLESHOOTING.md](TROUBLESHOOTING.md) — install/runtime failures  
- [DEPENDENCIES.md](DEPENDENCIES.md) — XLibre, yay, and risk notes  
- [DEVELOPMENT.md](DEVELOPMENT.md) — coding rules; do **not** run Up install scripts on your Omarchy host root  

**Rule of thumb:** develop on Omarchy; **install and execute** Up only inside the VM (or bare metal dedicated to Up).
