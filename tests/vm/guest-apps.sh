#!/bin/bash
# Apps + window-management suite, then shutdown.
# Piped into the guest over SSH (self-contained).
set -u

USER_NAME="${USER:-tester}"
export LIBGL_ALWAYS_SOFTWARE="${LIBGL_ALWAYS_SOFTWARE:-1}"
export GALLIUM_DRIVER="${GALLIUM_DRIVER:-llvmpipe}"
export WINIT_UNIX_BACKEND=x11
export MOZ_WEBRENDER="${MOZ_WEBRENDER:-0}"
export DISPLAY="${DISPLAY:-:0}"
export UP_ROOT="${UP_ROOT:-/usr/local/share/up}"
export PATH="${UP_ROOT}/bin:/usr/local/bin:/usr/bin:/bin:${PATH:-}"
LOG=/tmp/up-vm-apps.log
: > "$LOG"
FAILS=0

note() { printf '%s\n' "$*" | tee -a "$LOG"; }

check() {
    local name="$1"
    shift
    if "$@"; then
        note "CHECK_OK $name"
        return 0
    fi
    note "CHECK_FAIL $name"
    FAILS=$((FAILS + 1))
    return 1
}

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

use_repo_tree() {
    if ! findmnt /tmp/upsrc >/dev/null 2>&1; then
        mkdir -p /tmp/upsrc
        sudo mount -t 9p -o trans=virtio,version=9p2000.L,ro upsrc /tmp/upsrc 2>>"$LOG" || return 0
    fi
    if [ -x /tmp/upsrc/bin/up-system-menu ]; then
        export UP_ROOT=/tmp/upsrc
        export PATH="/tmp/upsrc/bin:$PATH"
        note "USING_REPO_TREE $UP_ROOT"
    fi
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
    return 1
}

i3q() { i3-msg -t "$1" 2>/dev/null; }

tree_has() {
    local needle="$1"
    i3q get_tree | grep -qiF -- "$needle"
}

wait_proc() {
    local pattern="$1"
    local seconds="${2:-20}"
    local i
    for i in $(seq 1 "$seconds"); do
        if pgrep -u "$USER_NAME" -f "$pattern" >/dev/null 2>&1; then
            return 0
        fi
        sleep 1
    done
    return 1
}

wait_tree() {
    local needle="$1"
    local seconds="${2:-20}"
    local i
    for i in $(seq 1 "$seconds"); do
        if tree_has "$needle"; then
            return 0
        fi
        sleep 1
    done
    return 1
}

focused_fullscreen() {
    if command -v jq >/dev/null 2>&1; then
        i3q get_tree | jq -r '.. | objects | select(.focused==true) | .fullscreen_mode' 2>/dev/null | grep -qx 1
        return $?
    fi
    i3q get_tree | grep -q '"focused":true[^}]*"fullscreen_mode":1\|"fullscreen_mode":1[^}]*"focused":true'
}

window_workspace() {
    local needle="$1"
    if command -v jq >/dev/null 2>&1; then
        i3q get_tree | jq -r --arg n "$needle" '
          def blob:
            ((.window_properties.class // "") + " " +
             (.window_properties.instance // "") + " " +
             (.name // ""));
          def walk($ws):
            (if .type == "workspace" then ((.name // .num) | tostring) else $ws end) as $cur
            | if ((blob | ascii_downcase) | contains($n | ascii_downcase)) and ($cur != "")
              then $cur
              else (.nodes[]?, .floating_nodes[]?) | walk($cur)
              end;
          walk("")
        ' 2>/dev/null | tail -1
        return 0
    fi
    i3-msg -t get_workspaces 2>/dev/null | grep -o '"num":[0-9]*' | head -1 | cut -d: -f2
}

launch() {
    i3-msg "exec --no-startup-id $1" >/dev/null
}

run_apps() {
    wait_i3 || { note "SUITE_FAIL apps (no i3)"; return 1; }
    find_x
    use_repo_tree

    check nvim_cli test -x /usr/bin/nvim -o -x /usr/local/bin/nvim
    printf 'hello from up vm\n' > /tmp/up-vm-nvim.txt
    nvim --headless +'wq' /tmp/up-vm-nvim.txt >/dev/null 2>&1 || true
    check nvim_write grep -q 'hello from up vm' /tmp/up-vm-nvim.txt

    check btop_cli command -v btop
    check firefox_cli command -v firefox
    check thunar_cli command -v thunar
    check alacritty_cli command -v alacritty

    launch 'env LIBGL_ALWAYS_SOFTWARE=1 GALLIUM_DRIVER=llvmpipe alacritty --class up-term'
    check term_proc wait_proc '[a]lacritty --class up-term' 15
    check term_window wait_tree up-term 15

    launch 'env LIBGL_ALWAYS_SOFTWARE=1 MOZ_WEBRENDER=0 firefox --new-instance --no-remote about:blank'
    check browser_proc wait_proc '[f]irefox' 45
    check browser_window wait_tree Firefox 45

    launch thunar
    check files_proc wait_proc '[t]hunar' 15
    check files_window wait_tree Thunar 15

    launch 'env LIBGL_ALWAYS_SOFTWARE=1 alacritty --class up-nvim -e nvim /tmp/up-vm-nvim.txt'
    check nvim_proc wait_proc '[n]vim /tmp/up-vm-nvim.txt' 15
    check nvim_window wait_tree up-nvim 15

    launch 'env LIBGL_ALWAYS_SOFTWARE=1 alacritty --class up-btop -e btop'
    check btop_proc wait_proc '[b]top' 15
    check btop_window wait_tree up-btop 15

    i3-msg '[instance="up-term"] focus' >/dev/null || true
    i3-msg '[instance="up-term"] move container to workspace number 3' >/dev/null
    i3-msg 'workspace number 3' >/dev/null
    sleep 0.5
    local term_ws
    term_ws=$(window_workspace up-term)
    note "term_ws=${term_ws:-?}"
    check move_term_ws3 test "$term_ws" = "3"

    i3-msg '[class="Thunar"] move container to workspace number 4' >/dev/null
    i3-msg 'workspace number 4' >/dev/null
    sleep 0.5
    local files_ws
    files_ws=$(window_workspace Thunar)
    note "files_ws=${files_ws:-?}"
    check move_thunar_ws4 test "$files_ws" = "4"

    i3-msg 'workspace number 3' >/dev/null
    launch 'env LIBGL_ALWAYS_SOFTWARE=1 alacritty --class up-term2'
    check term2_proc wait_proc '[a]lacritty --class up-term2' 15

    i3-msg '[instance="up-term"] focus' >/dev/null || true
    i3-msg 'split v' >/dev/null
    i3-msg 'layout toggle split' >/dev/null
    check layout_toggle i3-msg 'layout toggle split'

    local before_layout after_layout
    export PATH="${UP_ROOT}/bin:/usr/local/bin:${PATH}"
    before_layout=$(up-layout-toggle --get 2>/dev/null || echo default)
    check layout_cli_toggle up-layout-toggle --toggle
    wait_i3 || true
    after_layout=$(up-layout-toggle --get 2>/dev/null || echo "")
    note "layout ${before_layout:-?} -> ${after_layout:-?}"
    check layout_orientation_changed test -n "${after_layout:-}" -a "${after_layout:-}" != "${before_layout:-}"

    i3-msg '[instance="up-term"] focus' >/dev/null || true
    i3-msg 'fullscreen enable' >/dev/null
    sleep 0.4
    check fullscreen_on focused_fullscreen
    i3-msg 'fullscreen disable' >/dev/null
    sleep 0.4
    if focused_fullscreen; then
        note "CHECK_FAIL fullscreen_off"
        FAILS=$((FAILS + 1))
    else
        note "CHECK_OK fullscreen_off"
    fi

    note "APPS_SHUTDOWN_OK"
    i3-msg 'exec --no-startup-id systemctl poweroff' >/dev/null || \
        up-system-menu --invoke system/Shutdown || \
        systemctl poweroff || true

    if [ "$FAILS" -eq 0 ]; then
        note "SUITE_OK apps"
        return 0
    fi
    note "SUITE_FAIL apps fails=$FAILS"
    return 1
}

case "${1:-run}" in
    wait-i3) wait_i3 && echo I3_OK ;;
    run) run_apps ;;
    shutdown) note "APPS_SHUTDOWN_OK"; systemctl poweroff || true ;;
    *) echo "usage: $0 wait-i3|run|shutdown" >&2; exit 2 ;;
esac
