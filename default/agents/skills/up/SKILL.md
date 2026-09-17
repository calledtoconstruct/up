---
name: up
description: >
  REQUIRED for end-user customization of an installed Up Linux desktop.
  Use when editing ~/.config/up/, ~/.config/up/overrides/, keybindings-overrides.toml,
  or when changing theme, font, compositor, i3 extra binds, or running up-* commands.
  Triggers: Up Linux, i3-up, polybar, picom, LightDM greeter, up-switch-theme,
  up-update, user overrides, desktop-agent. Not for hacking the Up git repo.
---

# Up Linux (installed system)

This skill is for customizing a machine that already runs Up. It is not for contributing to the Up source tree. If you are editing a git clone of Up on a development host, stop and follow the repo `AGENTS.md` instead.

## When this skill MUST be used

- Any edit under `~/.config/up/`
- Extra i3 lines, keybinding overlays, theme, font, compositor effects
- User-facing `up-*` commands (`up-switch-theme`, `up-update`, `up-font-chooser`, …)

If you are about to edit a config file in `~/.config/` on this system, read this skill first.

## Never edit the vendor tree

Never edit `/usr/local/share/up`. It is the git checkout `up-update` resets. Local edits there are discarded.

```
/usr/local/share/up     # READ-ONLY for customization. Reading is useful.
~/.config/up/config     # theme, font, effects, ready_sound, agent. Survives updates.
~/.config/up/overrides/i3.conf
~/.config/up/keybindings-overrides.toml
```

Stock copies such as `~/.config/i3/config` are replaced on update (a backup is kept). Persistent tweaks belong in the user-intent files above.

Never run `bootstrap.sh` or `install.sh` on a machine that is already the live desktop.

## Prefer commands

```bash
up-switch-theme                 # interactive; or --theme aetherweft
up-font-chooser
up-compositor-profile
up-show-keybindings
up-update                       # git + migrations + packages; not raw pacman -Syu
up-pkg-install
up-pkg-aur-install
```

Read a command with `cat "$(command -v up-switch-theme)"` if you need to see how it works.

## Theme, font, compositor

See [`theming.md`](theming.md).

## Keybindings and extra i3

See [`keybindings.md`](keybindings.md).

## Default coding agent

```bash
up-default-agent                # print current name, or empty if unset
up-default-agent grok           # grok | claude | codex | opencode
up-agent                        # launch it
up-agent-prompt "Review this"   # launch with a task
```

Agents launched from the keybinding or crash toast skip permission prompts. Use plan mode for config changes, then apply.

## Decision order

1. Is there an `up-*` command? Run it.
2. Config edit? User-intent files only.
3. Theme/font/effects? `~/.config/up/config` then the matching `up-*` tool.
4. Unsure? Read `/usr/local/share/up/docs/ARCHITECTURE.md`. Do not invent new layers.
