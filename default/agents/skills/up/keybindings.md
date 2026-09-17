# Keybindings and extra i3

Vendor bindings are generated from `/usr/local/share/up/configs/keybindings.toml` into `~/.config/i3/keybindings.conf`. That generated file is not sacred.

## Persistent extra keys

Edit `~/.config/up/keybindings-overrides.toml` (same TOML shape as the vendor file). It is merged on generate. Then:

```bash
# regenerate from the desktop session after an override edit
up-desktop-request refresh
```

If you only have a shell, ask the user to reload i3 (`Super+Ctrl+R`) after the override is written.

## Extra i3 lines

`~/.config/up/overrides/i3.conf` is included last by i3. `up-update` never overwrites it.

```
bindsym $mod+Shift+x exec --no-startup-id firefox
for_window [class="^Gimp$"] floating enable
```

Prefer the TOML overlay for new keybindings so `up-show-keybindings` still lists them.

## Do not

- Hand-edit `~/.config/i3/config` for lasting tweaks (replaced on update).
- Hand-edit `/usr/local/share/up/configs/i3/config` or `keybindings.toml` on an installed system.
