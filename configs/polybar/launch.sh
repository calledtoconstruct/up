#!/usr/bin/env bash
# Polybar launch script — exactly one "main" bar.
# Always uses a user-owned config under ~/.config/polybar/ (never a
# root-only packaged path the session user cannot read).

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
USER_DIR="${HOME}/.config/polybar"
USER_CONFIG="${USER_DIR}/config.ini"
PACKAGED_CONFIG="${SCRIPT_DIR}/config.ini"
# Also try installed tree if launch.sh is the user copy
if [ ! -f "$PACKAGED_CONFIG" ]; then
    PACKAGED_CONFIG="${UP_ROOT:-/usr/local/share/up}/configs/polybar/config.ini"
fi

BAR_NAME="main"
UID_NUM="${UID:-$(id -u)}"
LOG="${XDG_RUNTIME_DIR:-/tmp}/polybar-${UID_NUM}.log"
LOCK="${XDG_RUNTIME_DIR:-/tmp}/polybar-launch-${UID_NUM}.lock"

log_msg() {
    echo "polybar launch: $*" >>"$LOG" 2>/dev/null || true
}

# Ensure ~/.config/polybar exists and is usable by this user
ensure_user_polybar_dir() {
    mkdir -p "$USER_DIR" 2>/dev/null || true
    # Fix root-owned dirs left by sudo up-update (common "permission denied")
    if [ -d "$USER_DIR" ] && [ ! -w "$USER_DIR" ]; then
        log_msg "WARNING: $USER_DIR not writable (likely root-owned); attempting fix"
        if command -v sudo >/dev/null 2>&1; then
            sudo chown -R "${UID_NUM}:${UID_NUM}" "$USER_DIR" 2>/dev/null || true
            sudo chmod u+rwx "$USER_DIR" 2>/dev/null || true
        fi
    fi
    chmod u+rwx "$USER_DIR" 2>/dev/null || true
}

# Resolve a readable config path for polybar. Prefer user file; seed if needed.
resolve_config() {
    ensure_user_polybar_dir

    # If user config is a broken/unreadable symlink, replace it
    if [ -L "$USER_CONFIG" ] && [ ! -r "$USER_CONFIG" ]; then
        log_msg "removing unreadable symlink $USER_CONFIG"
        rm -f "$USER_CONFIG" 2>/dev/null || true
    fi

    if [ -f "$USER_CONFIG" ] && [ ! -r "$USER_CONFIG" ]; then
        log_msg "WARNING: $USER_CONFIG not readable; attempting chmod/chown"
        chmod u+rw "$USER_CONFIG" 2>/dev/null || true
        if [ ! -r "$USER_CONFIG" ] && command -v sudo >/dev/null 2>&1; then
            sudo chown "${UID_NUM}:${UID_NUM}" "$USER_CONFIG" 2>/dev/null || true
            sudo chmod u+rw "$USER_CONFIG" 2>/dev/null || true
        fi
        if [ ! -r "$USER_CONFIG" ]; then
            log_msg "backing up unreadable config and reseeding"
            mv -f "$USER_CONFIG" "${USER_CONFIG}.unreadable.$$" 2>/dev/null || \
                rm -f "$USER_CONFIG" 2>/dev/null || true
        fi
    fi

    if [ ! -f "$USER_CONFIG" ] || [ ! -r "$USER_CONFIG" ]; then
        if [ -f "$PACKAGED_CONFIG" ] && [ -r "$PACKAGED_CONFIG" ]; then
            # Copy content only (no -p) so we own the file
            cp "$PACKAGED_CONFIG" "$USER_CONFIG" 2>/dev/null || true
            chmod 644 "$USER_CONFIG" 2>/dev/null || true
            log_msg "seeded $USER_CONFIG from package"
        fi
    fi

    if [ -f "$USER_CONFIG" ] && [ -r "$USER_CONFIG" ]; then
        printf '%s\n' "$USER_CONFIG"
        return 0
    fi

    # Root-owned 600 after sudo up-update: copy to a runtime file we can read
    if [ -f "$USER_CONFIG" ] && [ ! -r "$USER_CONFIG" ]; then
        local runtime_cfg="${XDG_RUNTIME_DIR:-/tmp}/polybar-${UID_NUM}-config.ini"
        if cp "$USER_CONFIG" "$runtime_cfg" 2>/dev/null || \
            { command -v sudo >/dev/null 2>&1 && sudo cat "$USER_CONFIG" >"$runtime_cfg" 2>/dev/null; }; then
            chmod 644 "$runtime_cfg" 2>/dev/null || true
            log_msg "using runtime copy of unreadable $USER_CONFIG"
            printf '%s\n' "$runtime_cfg"
            return 0
        fi
    fi

    # Absolute last resort: packaged path only if readable by this user
    if [ -f "$PACKAGED_CONFIG" ] && [ -r "$PACKAGED_CONFIG" ]; then
        log_msg "falling back to packaged config $PACKAGED_CONFIG"
        printf '%s\n' "$PACKAGED_CONFIG"
        return 0
    fi

    return 1
}

mkdir -p "$(dirname "$LOCK")" 2>/dev/null || true

exec 9>"$LOCK"
# A live launcher holds this only for the length of the script. If it is
# still busy after a couple of seconds, a previous polybar inherited fd 9
# and will keep the lock (and the old colors) until it exits.
if ! flock -w 2 9; then
    log_msg "lock busy; stopping polybar that may still hold it"
    pkill -u "$UID_NUM" -x polybar 2>/dev/null || true
    _i=0
    while [ "$_i" -lt 15 ]; do
        pgrep -u "$UID_NUM" -x polybar >/dev/null 2>&1 || break
        _i=$((_i + 1))
        sleep 0.1
    done
    unset _i
    pkill -9 -u "$UID_NUM" -x polybar 2>/dev/null || true
    sleep 0.1
    if ! flock -w 2 9; then
        log_msg "could not acquire lock"
        exit 1
    fi
    log_msg "acquired lock after stopping leftover polybar"
fi

stop_polybar() {
    # Kill and wait — polybar-msg restart/quit leaves stale colors in-process.
    pkill -u "$UID_NUM" -x polybar 2>/dev/null || true
    local i
    for i in 1 2 3 4 5 6 7 8 9 10; do
        pgrep -u "$UID_NUM" -x polybar >/dev/null 2>&1 || return 0
        pkill -u "$UID_NUM" -x polybar 2>/dev/null || true
        sleep 0.1
    done
    pkill -9 -u "$UID_NUM" -x polybar 2>/dev/null || true
    sleep 0.15
    return 0
}

# Leave the current bar up until i3 answers. Killing first, then waiting,
# is a visible gap, and a second launcher can start another gap on top.
if [ "${UP_POLYBAR_QUICK:-0}" != 1 ] \
    && command -v i3-msg >/dev/null 2>&1 && [ -n "${DISPLAY:-}" ]; then
    _i=0
    while [ "$_i" -lt 30 ]; do
        i3-msg -t get_version >/dev/null 2>&1 && break
        _i=$((_i + 1))
        sleep 0.1
    done
    unset _i
fi

if [ -n "${MONITOR:-}" ]; then
    export MONITOR
elif command -v xrandr >/dev/null 2>&1; then
    _xr=$(xrandr --query 2>/dev/null || true)
    _n=$(printf '%s\n' "$_xr" | grep -c ' connected' || true)
    if [ "${_n:-0}" -eq 1 ]; then
        MONITOR=$(printf '%s\n' "$_xr" | awk '/ connected/{print $1; exit}')
        export MONITOR
    fi
    unset _n _xr
fi

CONFIG=""
if ! CONFIG=$(resolve_config); then
    log_msg "ERROR: no readable config.ini (checked $USER_CONFIG and $PACKAGED_CONFIG)"
    log_msg "fix: sudo chown -R \"\$USER:\$USER\" ~/.config/polybar && chmod 755 ~/.config/polybar && chmod 644 ~/.config/polybar/config.ini"
    exit 1
fi

if ! command -v polybar >/dev/null 2>&1; then
    log_msg "polybar binary not in PATH"
    exit 1
fi

{
    echo "---- $(date -Iseconds 2>/dev/null || date) launch bar=$BAR_NAME monitor=${MONITOR:-} config=$CONFIG display=${DISPLAY:-} uid=$UID_NUM ----"
    ls -la "$USER_DIR" 2>/dev/null || true
    ls -la "$CONFIG" 2>/dev/null || true
} >>"$LOG" 2>/dev/null || true

# Final read check — polybar's error is opaque "permission denied"
if [ ! -r "$CONFIG" ]; then
    log_msg "ERROR: config not readable: $CONFIG"
    exit 1
fi

stop_polybar

# Do not let polybar inherit fd 9. Otherwise the flock stays held for the
# life of the bar and the next theme launch cannot re-exec it.
polybar -c "$CONFIG" "$BAR_NAME" >>"$LOG" 2>&1 9>&- &
polybar_pid=$!
disown "$polybar_pid" 2>/dev/null || true

sleep 0.3
if ! kill -0 "$polybar_pid" 2>/dev/null && ! pgrep -u "$UID_NUM" -x polybar >/dev/null 2>&1; then
    log_msg "process exited immediately — see log (often permission denied on config.ini)"
    exit 1
fi

# A raced peer can spawn a second bar after our pkill. Keep only this one.
for pid in $(pgrep -u "$UID_NUM" -x polybar 2>/dev/null || true); do
    [ "$pid" = "$polybar_pid" ] && continue
    log_msg "reaping extra polybar pid=$pid"
    kill "$pid" 2>/dev/null || true
done

exit 0
