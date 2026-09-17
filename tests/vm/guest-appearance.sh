#!/bin/bash
# Appearance suite: CLI + system-menu theme/font/wallpaper, then menu shutdown.
# Piped into the guest over SSH (self-contained).
set -u

USER_NAME="${USER:-tester}"
export LIBGL_ALWAYS_SOFTWARE="${LIBGL_ALWAYS_SOFTWARE:-1}"
export GALLIUM_DRIVER="${GALLIUM_DRIVER:-llvmpipe}"
export WINIT_UNIX_BACKEND=x11
export DISPLAY="${DISPLAY:-:0}"
export UP_ROOT="${UP_ROOT:-/usr/local/share/up}"
export PATH="${UP_ROOT}/bin:/usr/local/bin:/usr/bin:/bin:${PATH:-}"
LOG=/tmp/up-vm-appearance.log
: > "$LOG"
FAILS=0

note() { printf '%s\n' "$*" | tee -a "$LOG"; }

up_cmd() {
    local name="$1"
    shift
    local bin
    for bin in "${UP_ROOT}/bin/${name}" "/usr/local/bin/${name}" "/usr/local/share/up/bin/${name}"; do
        if [ -x "$bin" ]; then
            "$bin" "$@"
            return $?
        fi
    done
    echo "command not found: $name (UP_ROOT=$UP_ROOT PATH=$PATH)" >&2
    return 127
}

check() {
    local name="$1"
    shift
    local out rc
    out=$("$@" 2>&1)
    rc=$?
    if [ "$rc" -eq 0 ]; then
        note "CHECK_OK $name"
        return 0
    fi
    note "CHECK_FAIL $name ${out:-exit $rc}"
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
    # Installed guests may predate --invoke/--font/--image. Prefer the 9p repo
    # tree QEMU still exports so --skip-install can test the current scripts.
    if ! findmnt /tmp/upsrc >/dev/null 2>&1; then
        mkdir -p /tmp/upsrc
        sudo mount -t 9p -o trans=virtio,version=9p2000.L,ro upsrc /tmp/upsrc 2>>"$LOG" || return 0
    fi
    if [ -x /tmp/upsrc/bin/up-system-menu ]; then
        export UP_ROOT=/tmp/upsrc
        export PATH="/tmp/upsrc/bin:$PATH"
        note "USING_REPO_TREE $UP_ROOT"
        # Session agent was started from /usr/local/share/up. Copy the
        # wallpaper-keep scripts there and restart it so --no-reload cannot
        # clobber a just-selected image.
        local v=/usr/local/share/up/configs/scripts
        if [ -d "$v" ] && command -v sudo >/dev/null 2>&1; then
            sudo -n cp /tmp/upsrc/configs/scripts/switch-theme.sh "$v/switch-theme.sh" 2>>"$LOG" || true
            sudo -n cp /tmp/upsrc/configs/scripts/theme-utils.sh "$v/theme-utils.sh" 2>>"$LOG" || true
            sudo -n cp /tmp/upsrc/configs/scripts/font-chooser.sh "$v/font-chooser.sh" 2>>"$LOG" || true
            local pf pid
            pf="${XDG_STATE_HOME:-$HOME/.local/state}/up/desktop/agent.pid"
            pid=""
            [ -f "$pf" ] && pid=$(tr -d ' \n' < "$pf")
            [ -n "$pid" ] && kill "$pid" 2>/dev/null || true
            pkill -u "$USER_NAME" -f 'desktop-agent.sh' 2>/dev/null || true
            sleep 0.2
            rm -f "${XDG_STATE_HOME:-$HOME/.local/state}/up/desktop/queue/"*.req 2>/dev/null || true
            DISPLAY="${DISPLAY:-:0}" /usr/local/share/up/configs/scripts/desktop-agent.sh \
                >/tmp/up-desktop-agent.log 2>&1 &
            note "REFRESHED_VENDOR_AGENT"
        fi
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

current_theme() {
    if [ -f "$HOME/.config/up-theme" ]; then
        tr -d '[:space:]' < "$HOME/.config/up-theme"
    fi
}

current_font() {
    grep -E '^[[:space:]]*font[[:space:]]*=' "$HOME/.config/up/config" 2>/dev/null \
        | head -1 | sed 's/.*= *//' | sed 's/^"//' | sed 's/"$//'
}

current_bg() {
    if [ -f "$HOME/.config/up-background" ]; then
        cat "$HOME/.config/up-background"
    fi
}

theme_is() { [ "$(current_theme)" = "$1" ]; }
font_has() { printf '%s' "$(current_font)" | grep -qiF -- "$1"; }
bg_is() {
    local want="$1" have
    have=$(current_bg)
    if [ "$have" = "$want" ]; then
        return 0
    fi
    note "bg_is want=$want have=$have"
    return 1
}

run_appearance() {
    wait_i3 || { note "SUITE_FAIL appearance (no i3)"; return 1; }
    find_x
    use_repo_tree

    note "start theme=$(current_theme) font=$(current_font) bg=$(current_bg)"

    check cli_theme_rift-nebula up_cmd up-switch-theme --theme rift-nebula
    wait_i3 || true
    check cli_theme_rift-nebula_state theme_is rift-nebula

    check cli_font_dejavu up_cmd up-font-chooser --font "DejaVu Sans Mono"
    check cli_font_dejavu_state font_has "DejaVu Sans Mono"

    check cli_theme_aetherweft up_cmd up-switch-theme --theme aetherweft
    wait_i3 || true
    check cli_theme_aetherweft_state theme_is aetherweft

    local images img other
    images=$(up_cmd up-select-desktop-image --list 2>/dev/null || true)
    img=$(printf '%s\n' "$images" | awk 'NF' | head -1)
    other=$(printf '%s\n' "$images" | awk 'NF' | grep -vxF -- "${img:-}" | head -1)
    note "images: $(printf '%s\n' "$images" | awk 'NF' | wc -l) first=${img:-none}"

    if [ -n "${img:-}" ]; then
        check cli_select_image up_cmd up-select-desktop-image --image "$img"
        check cli_select_image_state bg_is "$img"
    else
        note "CHECK_FAIL cli_select_image (no images listed)"
        FAILS=$((FAILS + 1))
    fi

    local before_rand
    before_rand=$(current_bg)
    check cli_random_image up_cmd up-random-desktop-image
    if [ -n "${other:-}" ]; then
        check cli_random_image_changed test "$(current_bg)" != "$before_rand"
    else
        check cli_random_image_state test -n "$(current_bg)"
    fi

    check menu_theme_bloom-shadow \
        up_cmd up-system-menu --invoke style/Theme -- --theme bloom-shadow
    wait_i3 || true
    check menu_theme_bloom-shadow_state theme_is bloom-shadow

    check menu_font_jetbrains \
        up_cmd up-system-menu --invoke style/Font -- --font "JetBrains Mono"
    check menu_font_jetbrains_state font_has "JetBrains Mono"

    check menu_random_image up_cmd up-system-menu --invoke style/Background/Random
    check menu_random_image_state test -s "$HOME/.config/up-background"

    images=$(up_cmd up-select-desktop-image --list 2>/dev/null || true)
    img=$(printf '%s\n' "$images" | awk 'NF' | tail -1)
    if [ -n "${img:-}" ]; then
        check menu_select_image \
            up_cmd up-system-menu --invoke style/Background/Select -- --image "$img"
        check menu_select_image_state bg_is "$img"
    else
        note "CHECK_FAIL menu_select_image (no images listed)"
        FAILS=$((FAILS + 1))
    fi

    note "MENU_SHUTDOWN_OK"
    up_cmd up-system-menu --invoke system/Shutdown || true

    if [ "$FAILS" -eq 0 ]; then
        note "SUITE_OK appearance"
        return 0
    fi
    note "SUITE_FAIL appearance fails=$FAILS"
    return 1
}

case "${1:-run}" in
    wait-i3) wait_i3 && echo I3_OK ;;
    run) run_appearance ;;
    shutdown) note "MENU_SHUTDOWN_OK"; up_cmd up-system-menu --invoke system/Shutdown || true ;;
    *) echo "usage: $0 wait-i3|run|shutdown" >&2; exit 2 ;;
esac
