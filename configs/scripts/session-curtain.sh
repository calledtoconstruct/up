#!/usr/bin/env bash
# Session curtain — pre-rendered wallpaper fade (blur + dim) around login.
#
# LightDM already shows the sharp wallpaper. After login we play frames that
# were generated when the theme/background last changed, then play them in
# reverse once i3 has loaded keybindings.
#
# Usage:
#   session-curtain.sh prepare [IMAGE]
#   session-curtain.sh fade-in
#   session-curtain.sh fade-out
#   session-curtain.sh reveal
#   session-curtain.sh play-sound

set -euo pipefail

export UP_ROOT="${UP_ROOT:-/usr/local/share/up}"

FRAME_COUNT="${UP_CURTAIN_FRAMES:-10}"
FRAME_DELAY="${UP_CURTAIN_DELAY:-0.032}"
CACHE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/up/session-curtain"
LOCK="$CACHE_DIR/active"
FADE_PIDFILE="$CACHE_DIR/fade-in.pid"
SOURCE_FILE="$CACHE_DIR/source"
HASH_FILE="$CACHE_DIR/source.sha256"
SOUND="${UP_ROOT}/configs/sounds/desktop-ready.wav"
CONFIG_FILE="${HOME}/.config/up/config"
BG_STATE_FILE="${HOME}/.config/up-background"

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

frame_path() {
    printf '%s/frame-%02d.jpg\n' "$CACHE_DIR" "$1"
}

resolve_source() {
    local src="${1:-}"
    if [ -n "$src" ] && [ -f "$src" ]; then
        printf '%s\n' "$src"
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

source_hash() {
    local src="$1"
    if have_cmd sha256sum; then
        sha256sum "$src" 2>/dev/null | awk '{print $1}'
    else
        cksum "$src" 2>/dev/null | awk '{print $1}'
    fi
}

frames_ready() {
    local i
    for i in $(seq 1 "$FRAME_COUNT"); do
        [ -f "$(frame_path "$i")" ] || return 1
    done
    return 0
}

# Build fade frames with ffmpeg (already a system package). Ease-in so the
# first frames stay close to the LightDM wallpaper, then blur/dim accumulate.
prepare() {
    local src
    src=$(resolve_source "${1:-}") || return 0

    mkdir -p "$CACHE_DIR"
    local new_hash
    new_hash=$(source_hash "$src")
    if frames_ready && [ -f "$HASH_FILE" ] && [ "$(tr -d '[:space:]' <"$HASH_FILE")" = "$new_hash" ]; then
        printf '%s\n' "$src" >"$SOURCE_FILE"
        return 0
    fi

    if ! have_cmd ffmpeg; then
        return 0
    fi

    local tmp base
    tmp=$(mktemp -d "${TMPDIR:-/tmp}/up-curtain.XXXXXX")
    base="$tmp/base.jpg"
    # Cover-scale once; playback is just swapping root pixmaps.
    if ! ffmpeg -hide_banner -loglevel error -y -i "$src" \
        -vf "scale=1920:1080:force_original_aspect_ratio=increase,crop=1920:1080" \
        -q:v 3 "$base" 2>/dev/null; then
        rm -rf "$tmp"
        return 0
    fi

    local i t ease sigma bright sat vf out
    for i in $(seq 1 "$FRAME_COUNT"); do
        # t in [0, 1]; ease-in (t^2) keeps early frames crisp
        t=$(awk -v i="$i" -v n="$FRAME_COUNT" 'BEGIN{printf "%.4f", (i-1)/(n-1)}')
        ease=$(awk -v t="$t" 'BEGIN{printf "%.4f", t*t}')
        sigma=$(awk -v e="$ease" 'BEGIN{printf "%.2f", e*16}')
        bright=$(awk -v e="$ease" 'BEGIN{printf "%.3f", -0.22*e}')
        sat=$(awk -v e="$ease" 'BEGIN{printf "%.3f", 1-(0.55*e)}')
        out=$(frame_path "$i")
        if awk -v s="$sigma" 'BEGIN{exit !(s < 0.2)}'; then
            vf="format=yuv420p"
        else
            vf="gblur=sigma=${sigma},eq=brightness=${bright}:saturation=${sat}"
        fi
        ffmpeg -hide_banner -loglevel error -y -i "$base" -vf "$vf" -q:v 4 "$tmp/f.jpg" 2>/dev/null \
            && mv -f "$tmp/f.jpg" "$out"
    done
    rm -rf "$tmp"

    if frames_ready; then
        printf '%s\n' "$src" >"$SOURCE_FILE"
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

play_frames() {
    local dir="$1" # forward | reverse
    frames_ready || return 0
    [ -n "${DISPLAY:-}" ] || return 0
    have_cmd feh || return 0
    local i
    if [ "$dir" = "reverse" ]; then
        for i in $(seq "$FRAME_COUNT" -1 1); do
            set_root_image "$(frame_path "$i")"
            sleep "$FRAME_DELAY"
        done
    else
        for i in $(seq 1 "$FRAME_COUNT"); do
            set_root_image "$(frame_path "$i")"
            sleep "$FRAME_DELAY"
        done
    fi
}

fade_in() {
    mkdir -p "$CACHE_DIR"
    echo $$ >"$FADE_PIDFILE"
    touch "$LOCK"
    prepare "" || true
    play_frames forward
    rm -f "$FADE_PIDFILE"
}

fade_out() {
    play_frames reverse
}

restore_wallpaper() {
    local src=""
    if [ -f "$SOURCE_FILE" ]; then
        src=$(tr -d '\n' <"$SOURCE_FILE")
    fi
    if [ -z "$src" ] || [ ! -f "$src" ]; then
        src=$(resolve_source "") || src=""
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
    # Keybindings are part of i3's parsed config; the generated file is the
    # source of those bindsyms.
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
    # Let a still-running fade-in finish so we do not reverse mid-blur
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
            "Super+Return opens a terminal. Super+Alt+Space opens the menu." \
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
    *)
        echo "Usage: $0 prepare [IMAGE] | fade-in | fade-out | reveal | play-sound" >&2
        exit 2
        ;;
esac
