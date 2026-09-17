# Up Linux

**Opinionated Arch Linux OS for 2010+ hardware.** From Arch ISO to a working X11 + i3 + themed desktop in about 15 minutes.

## What is Up Linux?

Up Linux is an opinionated Arch Linux distribution for older hardware and a small, reliable desktop. Sensible defaults over cutting-edge features.

### Key features

- **Legacy hardware.** 2010+, X11 only (no Wayland), conservative tool selection
- **One-command install.** Automated installer with a tmux progress UI
- **Theming.** 12 original theme families (dark + light) applied across the desktop
- **Live configuration.** User preferences applied without a full session restart
- **Migrations.** Updates with rollback-friendly numbered scripts
- **Desktop tools.** Application launcher and a system menu for install, style, session, power

### System menu (Super + Alt + Space)

```
Go
├── Apps          Super+Space launcher
├── Learn         Keybindings, quick start, help
├── Capture       Screenshot, record, color picker
├── Style         Theme, background, font
├── Setup         Audio, WiFi, Bluetooth, display, …
├── Install       Official packages, AUR, extra tools
├── Update
├── Session       Reload / restart i3
└── System        Lock, logout, suspend, reboot, shutdown
```

```bash
up-pkg-install              # official Arch packages
up-pkg-aur-install          # AUR via yay
up-install-tools            # VS Code, GHCup, …
sudo up-update
```

## Documentation

📖 **[Installation Guide](docs/INSTALL.md)** — Step-by-step installation and setup for users

🏗️ **[Architecture](docs/ARCHITECTURE.md)** — Technical implementation details for developers

🤖 **[Development](docs/DEVELOPMENT.md)** — Guidelines for contributors and AI assistants

🔧 **[Troubleshooting](docs/TROUBLESHOOTING.md)** — Install and runtime failure recovery

📦 **[Dependencies](docs/DEPENDENCIES.md)** — External repos (XLibre), AUR helper, risk notes

🧪 **[VM Testing](docs/VM-TESTING.md)** — Test Up install/desktop in a VM from Omarchy (or Arch)

## Quick Start

### For Users
```bash
# Boot Arch ISO, then run:
pacman -Sy --needed --noconfirm git
git clone https://github.com/calledtoconstruct/up.git /root/up
cd /root/up
./install.sh
```

After reboot, log in via **LightDM** (i3-up session). Then:

```bash
up-quickstart              # first-run tips
up-update                  # supported updates (not raw pacman -Syu alone)
```

Personal tweaks go in `~/.config/up/` (never overwritten). Stock copies under `~/.config/i3/` and friends are backed up and replaced on update. Do not edit `/usr/local/share/up`.

See [INSTALL.md](docs/INSTALL.md) and [TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md).

### For Developers
```bash
# Clone and explore
git clone https://github.com/calledtoconstruct/up.git
cd up

# Key directories:
# - configs/     # Application configurations and themes
# - migrations/  # Update migration scripts
# - version      # Distro version string
```

## Project Structure

```
up/
├── bootstrap.sh          # ISO installer (disk partitioning, base system)
├── setup.sh             # Chroot setup (packages, configs, user creation)
├── update.sh            # Wrapper → bin/up-update
├── version              # Distro version
├── configs/             # Configuration files and themes
│   ├── scripts/         # Utility scripts
│   ├── themes/          # Theme definitions (TOML)
│   └── [app]/           # Application-specific configs
├── docs/                # Documentation
│   ├── INSTALL.md
│   ├── ARCHITECTURE.md
│   ├── DEVELOPMENT.md
│   ├── TROUBLESHOOTING.md
│   └── DEPENDENCIES.md
├── migrations/          # Update migration scripts
└── bin/                 # up-* executables (up-update, up-refresh-config, ...)
```

## Contributing

Up Linux welcomes contributions! See [Development Guidelines](docs/DEVELOPMENT.md) for coding standards and processes.

## License

MIT License — Use freely, modify as needed.
