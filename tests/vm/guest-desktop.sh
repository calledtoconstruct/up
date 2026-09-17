#!/bin/bash
# Run inside the installed guest over SSH as the desktop user.
set -u

USER_NAME="${USER:-tester}"
export LIBGL_ALWAYS_SOFTWARE="${LIBGL_ALWAYS_SOFTWARE:-1}"
export GALLIUM_DRIVER="${GALLIUM_DRIVER:-llvmpipe}"
export WINIT_UNIX_BACKEND=x11
LOG=/tmp/up-vm-desktop.log
: > "$LOG"
note() { printf '%s\n' "$*" | tee -a "$LOG"; }

find_x() {
    export DISPLAY="${DISPLAY:-:0}"
    if [ -z "${XAUTHORITY:-}" ]; then
        if [ -f "$HOME/.Xauthority" ]; then
            export XAUTHORITY="$HOME/.Xauthority"
        else
            local auth
            auth=$(ls /run/user/"$(id -u)"/.mutter* \
                /run/user/"$(id -u)"/gdm/Xauthority \
                /var/run/lightdm/"$USER_NAME"/xauthority 2>/dev/null | head -1 || true)
            [ -n "$auth" ] && export XAUTHORITY="$auth"
        fi
    fi
    local sock
    sock=$(ls /run/user/"$(id -u)"/i3/ipc-socket.* 2>/dev/null | head -1 || true)
    [ -n "$sock" ] && export I3SOCK="$sock"
}

wait_i3() {
    local i
    for i in $(seq 1 60); do
        if pgrep -u "$USER_NAME" -x i3 >/dev/null 2>&1 && [ -S /tmp/.X11-unix/X0 ]; then
            find_x
            if DISPLAY="${DISPLAY}" XAUTHORITY="${XAUTHORITY:-}" \
                xdotool getdisplaygeometry >/dev/null 2>&1; then
                return 0
            fi
        fi
        sleep 2
    done
    note "WAIT_I3_FAIL"
    pgrep -a -u "$USER_NAME" >>"$LOG" 2>&1 || true
    cat "$LOG"
    return 1
}

send_super_return() {
    # --clearmodifiers + --window root often fails to hit i3's XGrabKey.
    # Press Super_L, tap Return, release — same physical chord as Super+Enter.
    xdotool keyup Super Super_L Super_R Alt Alt_L Control_L 2>/dev/null || true
    xdotool keydown Super_L
    sleep 0.05
    xdotool key Return
    sleep 0.05
    xdotool keyup Super_L
}

open_term() {
    wait_i3 || return 1
    find_x
    note "DISPLAY=$DISPLAY XAUTHORITY=${XAUTHORITY:-} I3SOCK=${I3SOCK:-}"
    note "=== bindings ==="
    grep -E 'bindsym.*(Return|Return)' "$HOME/.config/i3/keybindings.conf" 2>/dev/null | tee -a "$LOG" || true
    note "=== xmodmap modifiers ==="
    xmodmap -pm 2>/dev/null | tee -a "$LOG" || true

    pkill -u "$USER_NAME" -x alacritty 2>/dev/null || true
    sleep 0.4
    send_super_return

    local i
    for i in $(seq 1 20); do
        if pgrep -u "$USER_NAME" -x alacritty >/dev/null 2>&1; then
            note "TERM_OK"
            cat "$LOG"
            return 0
        fi
        sleep 0.5
    done

    note "TERM_FAIL after Super+Return"
    note "=== i3-msg exec probe ==="
    i3-msg 'exec --no-startup-id env LIBGL_ALWAYS_SOFTWARE=1 alacritty -e sleep 8' >>"$LOG" 2>&1 || true
    sleep 1
    if pgrep -u "$USER_NAME" -x alacritty >/dev/null 2>&1; then
        note "I3MSG_ALACRITTY_OK (binding/xdotool problem, binary works)"
        pkill -u "$USER_NAME" -x alacritty 2>/dev/null || true
    else
        note "I3MSG_ALACRITTY_FAIL"
    fi
    note "=== direct alacritty stderr ==="
    timeout 6 env LIBGL_ALWAYS_SOFTWARE=1 GALLIUM_DRIVER=llvmpipe \
        alacritty -e true >>"$LOG" 2>&1 || note "alacritty_exit=$?"
    note "=== procs ==="
    pgrep -a -u "$USER_NAME" >>"$LOG" 2>&1 || true
    cat "$LOG"
    return 1
}

type_shutdown() {
    find_x
    local wid
    wid=$(xdotool search --class Alacritty 2>/dev/null | tail -1 || true)
    if [ -n "$wid" ]; then
        xdotool windowactivate --sync "$wid"
    fi
    xdotool type --delay 30 'systemctl poweroff'
    xdotool key Return
    echo "TYPED_SHUTDOWN"
}

case "${1:-open-term}" in
    wait-i3) wait_i3 && echo I3_OK ;;
    open-term) open_term ;;
    shutdown) type_shutdown ;;
    *) echo "usage: $0 wait-i3|open-term|shutdown" >&2; exit 2 ;;
esac
