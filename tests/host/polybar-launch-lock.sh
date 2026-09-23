#!/bin/bash
# launch.sh must not leave its flock open in the polybar process.
# A leaked fd blocks the next theme restart, so the bar keeps old colors.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
tmp=$(mktemp -d)
trap 'pkill -u "$(id -u)" -x polybar >/dev/null 2>&1 || true; rm -rf "$tmp"' EXIT

export HOME="$tmp/home"
export XDG_RUNTIME_DIR="$tmp/run"
export UP_POLYBAR_QUICK=1
unset DISPLAY || true
mkdir -p "$HOME/.config/polybar" "$XDG_RUNTIME_DIR" "$tmp/bin"
printf '%s\n' '[colors]' 'background = #111111' 'foreground = #eeeeee' \
    >"$HOME/.config/polybar/config.ini"

UID_NUM="$(id -u)"
LOCK="$XDG_RUNTIME_DIR/polybar-launch-${UID_NUM}.lock"
RECORD="$tmp/record"

cat >"$tmp/bin/polybar" <<'EOF'
#!/bin/bash
# Stay this process. An external sleep would inherit fd 9 and keep the lock
# after pkill -x polybar killed the shell.
hold() {
    local fifo
    fifo=$(mktemp -u)
    mkfifo "$fifo"
    exec 7<>"$fifo"
    rm -f "$fifo"
    read -r -t 60 _ <&7 || true
}

if [ "${1:-}" = "--hold-lock" ]; then
    exec 9>"$POLYBAR_TEST_LOCK"
    flock -n 9 || exit 1
    printf '%s\n' "$$" >"$POLYBAR_TEST_HOLDER"
    hold
    exit 0
fi
if { true >&9; } 2>/dev/null; then
    printf '%s\n' "leaked $$" >>"$POLYBAR_TEST_RECORD"
else
    printf '%s\n' "closed $$" >>"$POLYBAR_TEST_RECORD"
fi
hold
EOF
chmod +x "$tmp/bin/polybar"
export PATH="$tmp/bin:${PATH}"
export POLYBAR_TEST_LOCK="$LOCK"
export POLYBAR_TEST_RECORD="$RECORD"
export POLYBAR_TEST_HOLDER="$tmp/holder"

fail=0
ok() { printf 'OK  %s\n' "$1"; }
bad() { printf 'FAIL %s\n' "$1"; fail=1; }

# i3 restart/reload does not re-run plain exec. The bar would redraw and
# keep the colors it parsed at login.
if grep -q 'exec_always --no-startup-id .*/polybar/launch.sh' "$ROOT/configs/i3/config"; then
    ok "i3 restarts polybar on reload and restart"
else
    bad "i3 config does not exec_always polybar/launch.sh"
fi

# During i3 reload, exec_always must not be the copy that kills the bar.
# The theme script restarts it once after reload returns.
theme_live=$(awk '
    /elif is_graphical_session; then/ { grab=1 }
    grab { print }
    /Theme files written \(no graphical session\)/ { grab=0 }
' "$ROOT/configs/scripts/switch-theme.sh")
if printf '%s\n' "$theme_live" | grep -q 'polybar-launch-defer' \
    && printf '%s\n' "$theme_live" | grep -q 'reload_i3_if_running' \
    && printf '%s\n' "$theme_live" | grep -q 'restart_polybar_once'; then
    ok "theme reload defers exec_always and restarts polybar once after"
else
    bad "theme path does not defer the in-reload bar restart"
fi

launch() {
    env -u DISPLAY UP_POLYBAR_QUICK=1 \
        UP_POLYBAR_FORCE="${UP_POLYBAR_FORCE:-0}" \
        HOME="$HOME" XDG_RUNTIME_DIR="$XDG_RUNTIME_DIR" \
        PATH="$PATH" POLYBAR_TEST_LOCK="$LOCK" \
        POLYBAR_TEST_RECORD="$RECORD" \
        "$ROOT/configs/polybar/launch.sh"
}

if launch; then
    ok "first launch"
else
    bad "first launch exit=$?"
fi

if grep -q '^closed ' "$RECORD" 2>/dev/null; then
    ok "polybar did not inherit the lock fd"
else
    bad "polybar inherited the lock fd ($(tr '\n' ' ' <"$RECORD" 2>/dev/null || echo missing))"
fi

if flock -n "$LOCK" -c true 2>/dev/null; then
    ok "launch lock is free while polybar is running"
else
    bad "launch lock still held by the running bar"
fi

live_pid=$(awk '/^closed / { print $2; exit }' "$RECORD")
printf '%s\n' "$(($(date +%s) + 30))" \
    >"$XDG_RUNTIME_DIR/polybar-launch-defer-${UID_NUM}"
: >"$RECORD"
UP_POLYBAR_FORCE=0 launch || bad "deferred launch failed"
if [ ! -s "$RECORD" ] && [ -n "$live_pid" ] && kill -0 "$live_pid" 2>/dev/null; then
    ok "defer stamp leaves the running bar alone"
else
    bad "defer stamp restarted or killed the bar"
fi
UP_POLYBAR_FORCE=1 launch || bad "forced launch failed"
unset UP_POLYBAR_FORCE
if awk '/^closed / { found=1 } END { exit !found }' "$RECORD"; then
    ok "forced launch replaces the bar after a defer stamp"
else
    bad "forced launch did not start a new bar"
fi

: >"$RECORD"
rm -f "$XDG_RUNTIME_DIR/polybar-launch-defer-${UID_NUM}"
pkill -u "$UID_NUM" -x polybar >/dev/null 2>&1 || true
sleep 0.2

"$tmp/bin/polybar" --hold-lock &
holder=$!
ready=0
for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
    if [ -s "$tmp/holder" ] && kill -0 "$holder" 2>/dev/null; then
        ready=1
        break
    fi
    sleep 0.05
done
if [ "$ready" -eq 1 ]; then
    ok "leftover bar is holding the launch lock"
else
    bad "could not start a lock-holding polybar"
fi

if launch; then
    ok "relaunch while a leftover bar holds the lock"
else
    bad "relaunch failed (lock not recovered)"
fi

if ! kill -0 "$holder" 2>/dev/null; then
    ok "leftover polybar was stopped"
else
    bad "leftover polybar still running"
    kill "$holder" 2>/dev/null || true
fi

if grep -q '^closed ' "$RECORD" 2>/dev/null; then
    ok "replacement bar started without the lock fd"
else
    bad "replacement bar did not start cleanly ($(tr '\n' ' ' <"$RECORD" 2>/dev/null || echo missing))"
fi

if [ "$fail" -ne 0 ]; then
    echo "polybar-launch-lock: FAIL"
    exit 1
fi
echo "polybar-launch-lock: OK"
