#!/usr/bin/env bash
# Session curtain — pre-rendered wallpaper fade around login.
#
# LightDM shows the login wallpaper. After login we blur that image, crossfade
# at full blur onto the session wallpaper, then unblur to the sharp desktop.
#
# Sequence: login sharp → login blur → session blur → session sharp
#
# Usage:
#   session-curtain.sh prepare [IMAGE]
#   session-curtain.sh fade-in
#   session-curtain.sh fade-out
#   session-curtain.sh reveal
#   session-curtain.sh play-sound
#   session-curtain.sh playback-list

set -euo pipefail

export UP_ROOT="${UP_ROOT:-/usr/local/share/up}"

FRAME_COUNT="${UP_CURTAIN_FRAMES:-10}"
BLEND_COUNT="${UP_CURTAIN_BLEND_FRAMES:-8}"
FRAME_DELAY="${UP_CURTAIN_DELAY:-0.032}"
CACHE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/up/session-curtain"
LOCK="$CACHE_DIR/active"
FADE_PIDFILE="$CACHE_DIR/fade-in.pid"
SOURCE_FILE="$CACHE_DIR/source"
LOGIN_SOURCE_FILE="$CACHE_DIR/login-source"
HASH_FILE="$CACHE_DIR/source.sha256"
SOUND="${UP_ROOT}/configs/sounds/desktop-ready.wav"
CONFIG_FILE="${HOME}/.config/up/config"
BG_STATE_FILE="${HOME}/.config/up-background"
GREETER_BG_FILE="/usr/share/backgrounds/up/current.jpg"
GREETER_CONF="/etc/lightdm/lightdm-gtk-greeter.conf"

have_cmd() { command -v "$1" >/dev/null 2>&1; }

read_config_key() {
    local key="$1"
    [ -f "$CONFIG_FILE" ] || { echo ""; return 0; }
    grep -E "^[[:space:]]*${key}[[:space:]]*=" "$CONFIG_FILE" 2>/dev/null \
        | head -1 \
        | sed 's/^[^=]*=[[:space:]]*//' \
        | tr -d ' "'"'"'"' \
        || echo ""
}

seq_dir() {
    printf '%s/%s\n' "$CACHE_DIR" "$1"
}

frame_path() {
    printf '%s/%s/frame-%02d.jpg\n' "$CACHE_DIR" "$1" "$2"
}

resolve_session() {
    local src="${1:-}"
    if [ -n "$src" ] && [ -f "$src" ]; then
        printf '%s\n' "$src"
        return 0
    fi
    if [ -n "${UP_CURTAIN_SESSION:-}" ] && [ -f "${UP_CURTAIN_SESSION}" ]; then
        printf '%s\n' "$UP_CURTAIN_SESSION"
        return 0
    fi
    if [ -f "$BG_STATE_FILE" ]; then
        src=$(tr -d '\n' <"$BG_STATE_FILE")
        if [ -n "$src" ] && [ -f "$src" ]; then
            printf '%s\n' "$src"
            return 0
        fi
    fi
    return 1
}

greeter_conf_background() {
    local conf="${1:-$GREETER_CONF}"
    [ -f "$conf" ] || return 1
    grep -E '^[[:space:]]*background[[:space:]]*=' "$conf" 2>/dev/null \
        | tail -1 \
        | sed 's/^[^=]*=[[:space:]]*//' \
        | tr -d ' "'"'"'"'
}

resolve_login() {
    local src="${UP_CURTAIN_LOGIN:-}"
    if [ -n "$src" ] && [ -f "$src" ]; then
        printf '%s\n' "$src"
        return 0
    fi
    if [ -f "$GREETER_BG_FILE" ]; then
        printf '%s\n' "$GREETER_BG_FILE"
        return 0
    fi
    src=$(greeter_conf_background "$GREETER_CONF" || true)
    if [ -n "$src" ] && [ -f "$src" ]; then
        printf '%s\n' "$src"
        return 0
    fi
    resolve_session "${1:-}"
}

source_hash() {
    local src="$1"
    if have_cmd sha256sum; then
        sha256sum "$src" 2>/dev/null | awk '{print $1}'
    else
        cksum "$src" 2>/dev/null | awk '{print $1}'
    fi
}

frames_ready_in() {
    local name="$1" count="$2"
    local i
    for i in $(seq 1 "$count"); do
        [ -f "$(frame_path "$name" "$i")" ] || return 1
    done
    return 0
}

frames_ready() {
    frames_ready_in login "$FRAME_COUNT" || return 1
    frames_ready_in session "$FRAME_COUNT" || return 1
}

cover_scale() {
    local src="$1" dest="$2"
    ffmpeg -hide_banner -loglevel error -y -i "$src" \
        -vf "scale=1920:1080:force_original_aspect_ratio=increase,crop=1920:1080" \
        -q:v 3 "$dest"
}

# Ease-in blur/dim so early frames stay close to the source wallpaper.
render_blur_sequence() {
    local src="$1" name="$2"
    local tmp base i t ease sigma bright sat vf out dir
    dir=$(seq_dir "$name")
    mkdir -p "$dir"
    tmp=$(mktemp -d "${TMPDIR:-/tmp}/up-curtain.XXXXXX")
    base="$tmp/base.jpg"
    if ! cover_scale "$src" "$base" 2>/dev/null; then
        rm -rf "$tmp"
        return 1
    fi
    for i in $(seq 1 "$FRAME_COUNT"); do
        t=$(awk -v i="$i" -v n="$FRAME_COUNT" 'BEGIN{printf "%.4f", (i-1)/(n-1)}')
        ease=$(awk -v t="$t" 'BEGIN{printf "%.4f", t*t}')
        sigma=$(awk -v e="$ease" 'BEGIN{printf "%.2f", e*16}')
        bright=$(awk -v e="$ease" 'BEGIN{printf "%.3f", -0.22*e}')
        sat=$(awk -v e="$ease" 'BEGIN{printf "%.3f", 1-(0.55*e)}')
        out=$(frame_path "$name" "$i")
        if awk -v s="$sigma" 'BEGIN{exit !(s < 0.2)}'; then
            vf="format=yuv420p"
        else
            vf="gblur=sigma=${sigma},eq=brightness=${bright}:saturation=${sat}"
        fi
        ffmpeg -hide_banner -loglevel error -y -i "$base" -vf "$vf" -q:v 4 "$tmp/f.jpg" 2>/dev/null \
            && mv -f "$tmp/f.jpg" "$out"
    done
    rm -rf "$tmp"
    frames_ready_in "$name" "$FRAME_COUNT"
}

render_blend_sequence() {
    local a="$1" b="$2"
    local tmp i t out dir
    dir=$(seq_dir blend)
    mkdir -p "$dir"
    [ -f "$a" ] && [ -f "$b" ] || return 1
    tmp=$(mktemp -d "${TMPDIR:-/tmp}/up-curtain-blend.XXXXXX")
    for i in $(seq 1 "$BLEND_COUNT"); do
        t=$(awk -v i="$i" -v n="$BLEND_COUNT" 'BEGIN{printf "%.4f", (i-1)/(n-1)}')
        out=$(frame_path blend "$i")
        ffmpeg -hide_banner -loglevel error -y -i "$a" -i "$b" \
            -filter_complex "blend=all_expr='A*(1-${t})+B*${t}'" \
            -q:v 4 "$tmp/f.jpg" 2>/dev/null \
            && mv -f "$tmp/f.jpg" "$out"
    done
    rm -rf "$tmp"
    frames_ready_in blend "$BLEND_COUNT"
}

prepare() {
    local session_src login_src
    session_src=$(resolve_session "${1:-}") || session_src=""
    login_src=$(resolve_login "$session_src") || login_src=""
    if [ -z "$session_src" ] && [ -n "$login_src" ]; then
        session_src="$login_src"
    fi
    if [ -z "$login_src" ] && [ -n "$session_src" ]; then
        login_src="$session_src"
    fi
    [ -n "$session_src" ] && [ -f "$session_src" ] || return 0
    [ -n "$login_src" ] && [ -f "$login_src" ] || login_src="$session_src"

    mkdir -p "$CACHE_DIR"
    local new_hash login_hash session_hash
    login_hash=$(source_hash "$login_src")
    session_hash=$(source_hash "$session_src")
    new_hash="${login_hash} ${session_hash}"
    if frames_ready && [ -f "$HASH_FILE" ] && [ "$(tr -d '\n' <"$HASH_FILE")" = "$new_hash" ]; then
        printf '%s\n' "$session_src" >"$SOURCE_FILE"
        printf '%s\n' "$login_src" >"$LOGIN_SOURCE_FILE"
        return 0
    fi

    if ! have_cmd ffmpeg; then
        return 0
    fi

    rm -rf "$(seq_dir login)" "$(seq_dir session)" "$(seq_dir blend)"
    # Drop the old single-sequence layout (frame-01.jpg at cache root).
    rm -f "$CACHE_DIR"/frame-*.jpg

    render_blur_sequence "$login_src" login || return 0
    if [ "$login_hash" = "$session_hash" ]; then
        cp -a "$(seq_dir login)" "$(seq_dir session)"
        rm -rf "$(seq_dir blend)"
    else
        render_blur_sequence "$session_src" session || return 0
        render_blend_sequence "$(frame_path login "$FRAME_COUNT")" "$(frame_path session "$FRAME_COUNT")" || true
    fi

    if frames_ready; then
        printf '%s\n' "$session_src" >"$SOURCE_FILE"
        printf '%s\n' "$login_src" >"$LOGIN_SOURCE_FILE"
        printf '%s\n' "$new_hash" >"$HASH_FILE"
    fi
}

set_root_image() {
    local img="$1"
    [ -f "$img" ] || return 0
    have_cmd feh || return 0
    [ -n "${DISPLAY:-}" ] || return 0
    feh --bg-fill --no-fehbg "$img" 2>/dev/null || true
}

playback_list() {
    local i
    for i in $(seq 1 "$FRAME_COUNT"); do
        printf '%s\n' "$(frame_path login "$i")"
    done
    if frames_ready_in blend "$BLEND_COUNT"; then
        for i in $(seq 1 "$BLEND_COUNT"); do
            printf '%s\n' "$(frame_path blend "$i")"
        done
    fi
    for i in $(seq "$FRAME_COUNT" -1 1); do
        printf '%s\n' "$(frame_path session "$i")"
    done
}

play_paths() {
    local img
    [ -n "${DISPLAY:-}" ] || return 0
    have_cmd feh || return 0
    while IFS= read -r img; do
        [ -n "$img" ] || continue
        set_root_image "$img"
        sleep "$FRAME_DELAY"
    done
}

fade_in_list() {
    local i
    for i in $(seq 1 "$FRAME_COUNT"); do
        printf '%s\n' "$(frame_path login "$i")"
    done
}

reveal_list() {
    local i
    if frames_ready_in blend "$BLEND_COUNT"; then
        for i in $(seq 1 "$BLEND_COUNT"); do
            printf '%s\n' "$(frame_path blend "$i")"
        done
    fi
    for i in $(seq "$FRAME_COUNT" -1 1); do
        printf '%s\n' "$(frame_path session "$i")"
    done
}

fade_in() {
    mkdir -p "$CACHE_DIR"
    echo $$ >"$FADE_PIDFILE"
    touch "$LOCK"
    prepare "" || true
    fade_in_list | play_paths
    rm -f "$FADE_PIDFILE"
}

fade_out() {
    reveal_list | play_paths
}

restore_wallpaper() {
    local src=""
    if [ -f "$SOURCE_FILE" ]; then
        src=$(tr -d '\n' <"$SOURCE_FILE")
    fi
    if [ -z "$src" ] || [ ! -f "$src" ]; then
        src=$(resolve_session "") || src=""
    fi
    if [ -n "$src" ] && [ -f "$src" ]; then
        set_root_image "$src"
    fi
}

ready_sound_enabled() {
    local v
    v=$(read_config_key "ready_sound" | tr 'A-Z' 'a-z')
    case "$v" in
        1|true|yes|on) return 0 ;;
        *) return 1 ;;
    esac
}

play_sound() {
    ready_sound_enabled || return 0
    [ -f "$SOUND" ] || return 0
    if have_cmd pw-play; then
        pw-play "$SOUND" >/dev/null 2>&1 || true
    elif have_cmd paplay; then
        paplay "$SOUND" >/dev/null 2>&1 || true
    elif have_cmd ffplay; then
        ffplay -nodisp -autoexit -loglevel quiet "$SOUND" >/dev/null 2>&1 || true
    fi
}

wait_for_ready() {
    local i
    if have_cmd i3-msg && [ -n "${DISPLAY:-}" ]; then
        for i in $(seq 1 40); do
            i3-msg -t get_version >/dev/null 2>&1 && break
            sleep 0.05
        done
    fi
    for i in $(seq 1 20); do
        [ -s "$HOME/.config/i3/keybindings.conf" ] && break
        sleep 0.05
    done
    if have_cmd pgrep; then
        for i in $(seq 1 20); do
            pgrep -u "$(id -u)" -x polybar >/dev/null 2>&1 && break
            sleep 0.05
        done
    fi
    if [ -f "$FADE_PIDFILE" ]; then
        local pid
        pid=$(tr -d '[:space:]' <"$FADE_PIDFILE" 2>/dev/null || true)
        if [ -n "$pid" ]; then
            local n=0
            while kill -0 "$pid" 2>/dev/null && [ "$n" -lt 40 ]; do
                sleep 0.05
                n=$((n + 1))
            done
        fi
    fi
}

reveal() {
    wait_for_ready
    fade_out
    restore_wallpaper
    rm -f "$LOCK" "$FADE_PIDFILE"
    if have_cmd notify-send; then
        notify-send -u low -t 2500 \
            "Desktop ready" \
            "Super+Return opens a terminal. Super+Space opens the menu." \
            2>/dev/null || true
    fi
    play_sound
}

cmd="${1:-reveal}"
case "$cmd" in
    prepare) prepare "${2:-}" ;;
    fade-in) fade_in ;;
    fade-out) fade_out ;;
    reveal) reveal ;;
    play-sound) play_sound ;;
    playback-list) playback_list ;;
    *)
        echo "Usage: $0 prepare [IMAGE] | fade-in | fade-out | reveal | play-sound | playback-list" >&2
        exit 2
        ;;
esac
