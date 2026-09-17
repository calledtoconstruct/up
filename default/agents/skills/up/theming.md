# Themes, fonts, compositor

Read this before changing appearance.

## Commands

```bash
up-switch-theme
up-switch-theme --theme aetherweft
up-font-chooser
up-select-desktop-image
up-random-desktop-image
up-compositor-profile
```

Live apply goes through `up-desktop-request` / desktop-agent. Do not restart i3 to change a theme.

## User config

`~/.config/up/config` (TOML). Fields that matter:

```
theme = "aetherweft"
font = "DejaVu Sans Mono"
effects = "auto"          # auto | full | lite | safe
fade = true
blur = true
dim = true
ready_sound = false
```

`effects = "auto"` re-detects GPU/virt/RAM. Pin a profile if the user asked for a fixed look.

## Stock themes

Themes live under `/usr/local/share/up/configs/themes/` (vendor). Do not edit them. To fork a look, copy a TOML into a new name only if Up already loads user theme files; otherwise change `theme =` to another stock family and stop.

Backgrounds: `/usr/local/share/up/configs/backgrounds/<theme>/`.
