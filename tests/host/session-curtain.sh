#!/bin/bash
# Login curtain playback: login sharp → login blur → session blur → session sharp.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$ROOT/configs/scripts/session-curtain.sh"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

fail=0
ok() { printf 'OK  %s\n' "$1"; }
bad() { printf 'FAIL %s\n' "$1"; fail=1; }

export HOME="$tmp/home"
export XDG_STATE_HOME="$tmp/state"
export UP_ROOT="$ROOT"
export UP_CURTAIN_FRAMES=4
export UP_CURTAIN_BLEND_FRAMES=3
mkdir -p "$HOME/.config" "$XDG_STATE_HOME"

cache="$XDG_STATE_HOME/up/session-curtain"
login="$tmp/login.jpg"
session="$tmp/session.jpg"

make_jpeg() {
    local color="$1" dest="$2"
    if ! command -v ffmpeg >/dev/null 2>&1; then
        return 1
    fi
    ffmpeg -hide_banner -loglevel error -y -f lavfi -i "color=c=${color}:s=64x64" -frames:v 1 "$dest"
}

if ! make_jpeg red "$login" || ! make_jpeg blue "$session"; then
    echo "session-curtain: SKIP (ffmpeg not available)"
    exit 0
fi

printf '%s\n' "$session" >"$HOME/.config/up-background"
export UP_CURTAIN_LOGIN="$login"

if ! "$SCRIPT" prepare "$session"; then
    bad "prepare exited non-zero"
fi

for i in 01 02 03 04; do
    if [ -f "$cache/login/frame-$i.jpg" ]; then
        ok "login frame $i"
    else
        bad "missing login/frame-$i.jpg"
    fi
    if [ -f "$cache/session/frame-$i.jpg" ]; then
        ok "session frame $i"
    else
        bad "missing session/frame-$i.jpg"
    fi
done

for i in 01 02 03; do
    if [ -f "$cache/blend/frame-$i.jpg" ]; then
        ok "blend frame $i"
    else
        bad "missing blend/frame-$i.jpg (login and session differ)"
    fi
done

plan=$("$SCRIPT" playback-list)
first=$(printf '%s\n' "$plan" | head -1)
last=$(printf '%s\n' "$plan" | tail -1)

case "$first" in
    */login/frame-01.jpg) ok "playback starts at login sharp" ;;
    *) bad "playback starts at '$first' (want login/frame-01.jpg)" ;;
esac

case "$last" in
    */session/frame-01.jpg) ok "playback ends at session sharp" ;;
    *) bad "playback ends at '$last' (want session/frame-01.jpg)" ;;
esac

if printf '%s\n' "$plan" | grep -q '/login/frame-04.jpg'; then
    ok "playback includes login blur"
else
    bad "playback missing login blur (login/frame-04.jpg)"
fi

if printf '%s\n' "$plan" | grep -q '/blend/frame-'; then
    ok "playback includes login-blur to session-blur blend"
else
    bad "playback missing blend frames"
fi

if printf '%s\n' "$plan" | grep -q '/session/frame-04.jpg'; then
    ok "playback includes session blur"
else
    bad "playback missing session blur (session/frame-04.jpg)"
fi

# Same image: no blend, still login→blur→sharp of that image.
export UP_CURTAIN_LOGIN="$session"
rm -rf "$cache"
"$SCRIPT" prepare "$session" || bad "prepare same-image exited non-zero"

if [ -d "$cache/blend" ] && ls "$cache/blend"/frame-*.jpg >/dev/null 2>&1; then
    bad "blend frames should not exist when login == session"
else
    ok "no blend when login and session match"
fi

same=$("$SCRIPT" playback-list)
case "$(printf '%s\n' "$same" | head -1)" in
    */login/frame-01.jpg|*/session/frame-01.jpg) ok "same-image playback starts sharp" ;;
    *) bad "same-image playback starts at '$(printf '%s\n' "$same" | head -1)'" ;;
esac
case "$(printf '%s\n' "$same" | tail -1)" in
    */session/frame-01.jpg|*/login/frame-01.jpg) ok "same-image playback ends sharp" ;;
    *) bad "same-image playback ends at '$(printf '%s\n' "$same" | tail -1)'" ;;
esac

if [ "$fail" -ne 0 ]; then
    echo "session-curtain: FAIL"
    exit 1
fi
echo "session-curtain: OK"
