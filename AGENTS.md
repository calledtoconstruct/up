# Task guides

This file is for people (and coding agents) working in the Up git tree.

Installed desktops have a different skill: `default/agents/skills/up/`. That skill is for customizing `~/.config/up/` on a live Up machine. Do not follow it when you are editing this repository.

## Development host vs target

Do not run `bootstrap.sh`, `install.sh`, or `install-unattended.sh` on the machine you use to edit this repo. Those scripts install and partition. Use a VM (`tests/vm/README.md`) or a dedicated Up box.

## Layout

- `bin/up-*` — user-facing commands, copied to `/usr/local/share/up` and linked in `/usr/local/bin`
- `configs/` — vendor configs and scripts (`UP_ROOT` at runtime)
- `migrations/` — numbered, idempotent; run by `up-update`
- `default/agents/skills/` — end-user skills, symlinked into harness dirs on install
- `docs/` — INSTALL, TROUBLESHOOTING, ARCHITECTURE
- `tests/vm/` — QEMU installer and desktop suites

## Conventions

- Derive paths from `UP_ROOT` (`export UP_ROOT="${UP_ROOT:-/usr/local/share/up}"`)
- Persistent user tweaks go in `~/.config/up/`, never in the vendor git tree
- `up-update` does `git reset --hard` + `git clean -fd` on `/usr/local/share/up`
- Shebang: `#!/bin/bash` with `set -euo pipefail` unless the file is meant to be sourced
- Host-safe checks live in `tests/host/`; guest suites in `tests/vm/`

## Migrations

Add the next numbered script under `migrations/`. It must be safe to re-run. Mark completion with `/var/lib/up/migrations/<id>.done` (the updater does this on success).
