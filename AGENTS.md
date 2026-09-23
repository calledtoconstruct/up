# Task guides

This file is for people (and coding agents) working in the Up git tree.

Installed desktops have a different skill: `default/agents/skills/up/`. That skill is for customizing `~/.config/up/` on a live Up machine. Do not follow it when you are editing this repository.

## Development host vs target

`/home/joseph/code/up` on this machine is the development checkout. It is not an installed Up desktop. Bug reports from "the other machine" are from a separate Up box. Do not run `bootstrap.sh`, `install.sh`, or `install-unattended.sh` here. Those scripts install and partition. Do not treat this machine's `~/.config` as the product, and do not kill or restart its desktop session to "verify" a change. Check host scripts in `tests/host/` and guest suites in `tests/vm/` (`tests/vm/README.md`).

## Git

Joseph asks the agent to commit. He pushes himself, after unlocking SSH. The key is `/home/joseph/.ssh/id_ed25519`. Do not push, and do not assume SSH works from the agent shell.

Two remotes, two histories. Do not mix them.

- `origin` is GitLab, `git@meriupol:joseph/up.git`. Branch `main` is the real history. Update it with `git push origin main`.
- `github` is `git@github.com:calledtoconstruct/up.git`. Its `main` is a rewritten public history (root `2d8f4fd`). It does not share a merge-base with `origin/main`. Never `git pull github main` onto this `main`. Never merge, rebase, or force-push one history onto the other.

`git push github` does not send the current branch. The remote push refspec is `refs/heads/github-main:refs/heads/main`, so it publishes the local `github-main` branch and nothing else. If `github-main` was not moved, Git says "everything up-to-date" even when `main` has new commits. `git push github main` is the wrong command.

To publish new work, cherry-pick only the new `main` commits onto `github-main`, in order, keeping the original messages. `git log github-main..main` is the entire GitLab history, because the branches are unrelated. Do not replay that list. The last equivalent pair is the commit on each branch whose tree matches. Cherry-pick what landed on `main` after that pair. Then tell Joseph to run `git push github`.

`usecases` is a GitLab-only overlay. Do not publish it to GitHub.

## Layout

- `bin/up-*` — user-facing commands, copied to `/usr/local/share/up` and linked in `/usr/local/bin`
- `configs/` — vendor configs and scripts (`UP_ROOT` at runtime)
- `migrations/` — numbered, idempotent; run by `up-update`
- `default/agents/skills/` — end-user skills, symlinked into harness dirs on install
- `docs/` — INSTALL, TROUBLESHOOTING, ARCHITECTURE
- `tests/vm/` — QEMU installer and desktop suites

## Facts that are easy to get wrong

- Keybindings are `configs/keybindings.toml`, written to `~/.config/i3/keybindings.conf` by `write_i3_keybindings_file`. Super+Shift+K runs `up-show-keybindings`.
- i3 does not re-run a plain `exec` line on reload or on `restart` (Super+Ctrl+R). The bar is `exec_always`, and that is the only restart on a theme change. Do not also call `launch.sh` from the theme script or the desktop agent after an i3 reload. `launch.sh` must not leave its lock fd open in the polybar process.
- cliamp is AUR-only. Install `cliamp-bin` with yay (`AUR_PACKAGES`), not pacman. `music.desktop` runs `alacritty --class music -e cliamp`.
- Login curtain order is login sharp, login blur, session blur (crossfade at the blur frame when the images differ), session sharp. Frames live under `~/.local/state/up/session-curtain/{login,blend,session}/`.
- Flameshot 13+ uses the screenshot portal. i3 on X11 has no portal backend. Capture goes through `configs/scripts/screenshot.sh`, which sets `useX11LegacyScreenshot=true`.

## Conventions

- Derive paths from `UP_ROOT` (`export UP_ROOT="${UP_ROOT:-/usr/local/share/up}"`)
- Persistent user tweaks go in `~/.config/up/`, never in the vendor git tree
- `up-update` does `git reset --hard` + `git clean -fd` on `/usr/local/share/up`
- Shebang: `#!/bin/bash` with `set -euo pipefail` unless the file is meant to be sourced
- Host-safe checks live in `tests/host/`; guest suites in `tests/vm/`

## Migrations

Add the next numbered script under `migrations/`. It must be safe to re-run. Mark completion with `/var/lib/up/migrations/<id>.done` (the updater does this on success).
