#!/bin/sh
# Up Linux i3 Session Starter
# Replaces .xinitrc for LightDM native session (no xinit-xsession AUR dependency needed)
#
# Pre-i3 work is files-only. desktop-agent (started by i3) owns polybar and
# ordered live reloads after the session is up.

export UP_ROOT="${UP_ROOT:-/usr/local/share/up}"
# Force file-only theme/compositor helpers during early session setup
export UP_DESKTOP_INLINE=1

# LightDM already showed the sharp wallpaper. Fade the pre-rendered
# blur/dim curtain in while we sync config (before i3 grabs keys).
if [ -x "$UP_ROOT/configs/scripts/session-curtain.sh" ]; then
    _curtain_dir="${XDG_STATE_HOME:-$HOME/.local/state}/up/session-curtain"
    mkdir -p "$_curtain_dir"
    touch "$_curtain_dir/active"
    "$UP_ROOT/configs/scripts/session-curtain.sh" fade-in &
    echo $! >"$_curtain_dir/fade-in.pid"
    unset _curtain_dir
fi

# One file-only pass (compositor cache + theme if config changed).
# Do not call apply-compositor-profile here — config-sync already does.
"$UP_ROOT/configs/scripts/config-sync.sh" || true

# Start picom compositor (daemon mode)
picom --daemon --config "$HOME/.config/picom/config" &

# Clear inline flag so post-login tools can use the desktop queue
unset UP_DESKTOP_INLINE

if command -v systemctl >/dev/null 2>&1; then
    systemctl --user start up-crash-watch.service 2>/dev/null || true
fi

# Start i3 window manager (exec replaces this process; agent starts from i3 config)
exec i3
