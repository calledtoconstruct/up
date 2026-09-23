#!/bin/bash
# Desktop apply agent — serial worker for theme / compositor / polybar / picom
#
# Drains ~/.local/state/up/desktop/queue/*.req in batches with smart planning:
#
#   Config-changing (NOT skipped): theme, reapply, sync, compositor
#     — each is applied in queue order; consecutive same-type merges params only
#     — different config ops always run (e.g. compositor then theme both run)
#
#   Idempotent (deduped to last in batch): polybar, picom, refresh, boot
#     — multiple restarts collapse to one final action after config ops
#     — earlier duplicates are skipped (a later one remains in the plan)
#
# Started once per graphical session (i3 exec). Clients use desktop-request.sh.

set -euo pipefail

export UP_ROOT="${UP_ROOT:-/usr/local/share/up}"
SCRIPT_DIR="$UP_ROOT/configs/scripts"

# shellcheck source=desktop-request.sh
source "$SCRIPT_DIR/desktop-request.sh"

STATE_DIR=$(desktop_state_dir)
QUEUE_DIR=$(desktop_queue_dir)
DONE_DIR=$(desktop_done_dir)
LOG=$(desktop_agent_logfile)
PIDFILE=$(desktop_agent_pidfile)
LOCK="$STATE_DIR/agent.lock"
DEBOUNCE_MS="${UP_DESKTOP_DEBOUNCE_MS:-250}"

mkdir -p "$QUEUE_DIR" "$DONE_DIR" "$STATE_DIR"

log() {
    local msg
    msg="$(date -Iseconds 2>/dev/null || date) $*"
    printf '%s\n' "$msg" >>"$LOG" 2>/dev/null || true
    printf '%s\n' "$msg" >&2 || true
}

launch_polybar_direct() {
    if [ -z "${DISPLAY:-}" ] && [ -z "${WAYLAND_DISPLAY:-}" ]; then
        return 0
    fi
    if [ -x "$HOME/.config/polybar/launch.sh" ]; then
        "$HOME/.config/polybar/launch.sh" >>"$LOG" 2>&1 || true
    elif [ -x "$UP_ROOT/configs/polybar/launch.sh" ]; then
        "$UP_ROOT/configs/polybar/launch.sh" >>"$LOG" 2>&1 || true
    fi
}

# Single instance via flock on FD 8 for process lifetime
exec 8>"$LOCK"
if ! flock -n 8; then
    # flock -n fails only if another live process holds the lock
    other_pid=""
    if [ -f "$PIDFILE" ]; then
        other_pid=$(tr -d '[:space:]' <"$PIDFILE" 2>/dev/null || true)
    fi
    if [ -n "$other_pid" ] && kill -0 "$other_pid" 2>/dev/null; then
        log "another agent running pid=$other_pid; ensuring polybar then exiting"
        if ! pgrep -u "${UID:-$(id -u)}" -x polybar >/dev/null 2>&1; then
            log "peer agent alive but polybar missing — launching bar"
            launch_polybar_direct
        fi
        exit 0
    fi
    log "stale agent lock; retrying flock"
    if ! flock -w 5 8; then
        log "could not acquire agent lock; launching polybar directly and exiting"
        launch_polybar_direct
        exit 0
    fi
fi

echo $$ >"$PIDFILE"
cleanup() {
    rm -f "$PIDFILE"
}
trap cleanup EXIT
# Survive terminal/session hangup so a long-lived agent is not killed early
trap '' HUP

log "agent start pid=$$ UP_ROOT=$UP_ROOT DISPLAY=${DISPLAY:-} HOME=${HOME:-}"

have_cmd() { command -v "$1" >/dev/null 2>&1; }

wait_for_i3_ipc() {
    have_cmd i3-msg || return 0
    [ -n "${DISPLAY:-}" ] || return 0
    local i
    for ((i = 1; i <= 30; i++)); do
        i3-msg -t get_version >/dev/null 2>&1 && return 0
        sleep 0.1
    done
    return 0
}

reload_i3() {
    have_cmd i3-msg || return 0
    [ -n "${DISPLAY:-}" ] || return 0
    i3-msg reload >/dev/null 2>&1 || true
    wait_for_i3_ipc
    sleep 0.15
}

restart_polybar() {
    local launcher=""
    # Prefer user launch.sh (same dir as themed config.ini)
    mkdir -p "$HOME/.config/polybar" 2>/dev/null || true
    # Heal root-owned tree from sudo updates
    if [ -d "$HOME/.config/polybar" ] && [ ! -w "$HOME/.config/polybar" ]; then
        log "WARNING: ~/.config/polybar not writable — permission denied likely"
    fi
    if [ -f "$UP_ROOT/configs/polybar/launch.sh" ]; then
        cp "$UP_ROOT/configs/polybar/launch.sh" "$HOME/.config/polybar/launch.sh" 2>/dev/null || true
        chmod 755 "$HOME/.config/polybar/launch.sh" 2>/dev/null || true
    fi
    if [ -x "$HOME/.config/polybar/launch.sh" ]; then
        launcher="$HOME/.config/polybar/launch.sh"
    elif [ -x "$UP_ROOT/configs/polybar/launch.sh" ]; then
        launcher="$UP_ROOT/configs/polybar/launch.sh"
    fi
    if [ -z "$launcher" ]; then
        log "polybar launch.sh missing"
        return 0
    fi
    # Seed user config.ini (never leave polybar pointed at unreadable package path)
    if [ ! -f "$HOME/.config/polybar/config.ini" ] \
        && [ -f "$UP_ROOT/configs/polybar/config.ini" ]; then
        cp "$UP_ROOT/configs/polybar/config.ini" "$HOME/.config/polybar/config.ini" 2>/dev/null || true
        chmod 644 "$HOME/.config/polybar/config.ini" 2>/dev/null || true
        log "seeded missing polybar config.ini"
    fi
    chmod u+rw "$HOME/.config/polybar/config.ini" 2>/dev/null || true
    wait_for_i3_ipc
    log "running polybar launcher: $launcher"
    # Export DISPLAY explicitly for i3 --no-startup-id edge cases
    # FORCE so a theme-reload defer stamp cannot swallow this restart.
    UP_POLYBAR_QUICK=1 UP_POLYBAR_FORCE=1 \
        DISPLAY="${DISPLAY:-:0}" "$launcher" >>"$LOG" 2>&1 || log "polybar launcher exit=$?"
    if pgrep -u "${UID:-$(id -u)}" -x polybar >/dev/null 2>&1; then
        log "polybar is running"
    else
        log "WARNING: polybar still not running after launch"
    fi
}

restart_picom() {
    have_cmd picom || return 0
    pkill -u "${UID:-$(id -u)}" -x picom 2>/dev/null || true
    sleep 0.2
    picom --daemon --config "$HOME/.config/picom/config" >>"$LOG" 2>&1 || true
}

file_hash() {
    local f="$1"
    if [ -f "$f" ]; then
        sha256sum "$f" 2>/dev/null | awk '{print $1}'
    else
        echo "missing"
    fi
}

apply_theme_files() {
    local mode="$1" # theme name or empty for reapply
    local st="$SCRIPT_DIR/switch-theme.sh"
    [ -x "$st" ] || return 0
    if [ -n "$mode" ]; then
        "$st" --theme "$mode" --no-reload >>"$LOG" 2>&1 || true
    else
        "$st" --reapply --no-reload >>"$LOG" 2>&1 || true
    fi
}

apply_compositor() {
    local force="${1:-0}"
    local ap="$SCRIPT_DIR/apply-compositor-profile.sh"
    [ -x "$ap" ] || return 0
    if [ "$force" = "1" ] || [ "$force" = "true" ]; then
        "$ap" --force --no-theme >>"$LOG" 2>&1 || true
    else
        "$ap" --no-theme >>"$LOG" 2>&1 || true
    fi
}

# Parse key=value file into variables with prefix R_
parse_req() {
    local f="$1"
    # shellcheck disable=SC2034
    R_type="" R_name="" R_force="" R_theme=""
    local line key val
    while IFS= read -r line || [ -n "$line" ]; do
        [ -z "$line" ] && continue
        case "$line" in
            \#*) continue ;;
        esac
        key=${line%%=*}
        val=${line#*=}
        case "$key" in
            type) R_type=$val ;;
            name|theme) R_name=$val; R_theme=$val ;;
            force) R_force=$val ;;
        esac
    done <"$f"
}

mark_done() {
    local id="$1"
    local status="${2:-ok}"
    local df="$DONE_DIR/${id}.done"
    {
        echo "status=$status"
        echo "finished=$(date -Iseconds 2>/dev/null || date)"
    } >"$df"
    # Prune old done markers (keep last ~100)
    local n
    n=$(find "$DONE_DIR" -name '*.done' 2>/dev/null | wc -l || echo 0)
    if [ "${n:-0}" -gt 100 ]; then
        find "$DONE_DIR" -name '*.done' -printf '%T@ %p\n' 2>/dev/null \
            | sort -n | head -n 50 | awk '{print $2}' | xargs -r rm -f
    fi
}

# Request classification
#   config-changing: must run (in order); only consecutive same-type may merge
#   idempotent: safe to run once; earlier duplicates skipped if a later one exists
is_config_changing() {
    case "$1" in
        theme|reapply|sync|compositor) return 0 ;;
        *) return 1 ;;
    esac
}

is_idempotent() {
    case "$1" in
        polybar|picom|refresh|boot) return 0 ;;
        *) return 1 ;;
    esac
}

force_is_true() {
    case "${1:-}" in
        1|true|yes|on) return 0 ;;
        *) return 1 ;;
    esac
}

# Append or merge a config op into ordered plan arrays:
#   plan_types[], plan_theme[], plan_force[]
# Consecutive same type merges (theme name last-wins, force OR'd).
# Non-consecutive same type is a new step (both execute).
plan_push_config() {
    local typ="$1"
    local theme="${2:-}"
    local force="${3:-0}"
    local n=${#plan_types[@]}

    if [ "$n" -gt 0 ] && [ "${plan_types[$((n - 1))]}" = "$typ" ]; then
        local i=$((n - 1))
        # Merge into previous consecutive op
        if [ -n "$theme" ]; then
            plan_theme[$i]="$theme"
        fi
        if force_is_true "$force" || force_is_true "${plan_force[$i]:-0}"; then
            plan_force[$i]=1
        fi
        log "plan merge consecutive $typ (theme=${plan_theme[$i]:-} force=${plan_force[$i]:-0})"
        return 0
    fi

    plan_types+=("$typ")
    plan_theme+=("$theme")
    if force_is_true "$force"; then
        plan_force+=(1)
    else
        plan_force+=(0)
    fi
    log "plan config +$typ theme=${theme:-} force=${plan_force[$((${#plan_force[@]} - 1))]}"
}

# Drain queue → ordered config plan + deduped idempotent tail; returns 0 if work found
coalesce_and_run() {
    local files=()
    local f id
    while IFS= read -r f; do
        [ -n "$f" ] && files+=("$f")
    done < <(find "$QUEUE_DIR" -maxdepth 1 -type f -name '*.req' 2>/dev/null | sort)

    if [ ${#files[@]} -eq 0 ]; then
        return 1
    fi

    local ids=()
    local plan_types=()
    local plan_theme=()
    local plan_force=()

    # Idempotent: last occurrence wins (earlier dups skipped)
    local want_polybar=0 want_picom=0 want_i3=0
    local picom_explicit=0
    local skipped_idempotent=0

    local seen_polybar=0 seen_picom=0 seen_refresh=0 seen_boot=0

    # First pass: count idempotent so we can skip early duplicates
    local types_order=()
    local themes_order=()
    local forces_order=()
    local id_list=()

    for f in "${files[@]}"; do
        id=$(basename "$f" .req)
        id_list+=("$id")
        parse_req "$f"
        types_order+=("${R_type:-}")
        themes_order+=("${R_name:-${R_theme:-}}")
        if force_is_true "${R_force:-}"; then
            forces_order+=(1)
        else
            forces_order+=(0)
        fi
        rm -f "$f"
    done
    ids=("${id_list[@]}")

    # Second pass: which idempotent types appear later? (index of last occurrence)
    local last_polybar=-1 last_picom=-1 last_refresh=-1 last_boot=-1
    local i n=${#types_order[@]}
    for ((i = 0; i < n; i++)); do
        case "${types_order[$i]}" in
            polybar) last_polybar=$i ;;
            picom)   last_picom=$i ;;
            refresh) last_refresh=$i ;;
            boot)    last_boot=$i ;;
        esac
    done

    for ((i = 0; i < n; i++)); do
        local typ="${types_order[$i]}"
        local th="${themes_order[$i]}"
        local fr="${forces_order[$i]}"

        if is_config_changing "$typ"; then
            case "$typ" in
                theme)
                    plan_push_config theme "$th" 0
                    want_i3=1
                    want_polybar=1
                    want_picom=1
                    ;;
                reapply)
                    plan_push_config reapply "" 0
                    want_i3=1
                    want_polybar=1
                    want_picom=1
                    ;;
                sync)
                    plan_push_config sync "" "$fr"
                    want_i3=1
                    want_polybar=1
                    want_picom=1
                    ;;
                compositor)
                    plan_push_config compositor "" "$fr"
                    # compositor changes fade/blur/dim → theme fragments need refresh
                    plan_push_config reapply "" 0
                    want_polybar=1
                    want_picom=1
                    ;;
            esac
            continue
        fi

        if is_idempotent "$typ"; then
            # Skip if not the last request of this idempotent type in the batch
            case "$typ" in
                polybar)
                    if [ "$i" -ne "$last_polybar" ]; then
                        skipped_idempotent=$((skipped_idempotent + 1))
                        log "dedupe skip polybar (later polybar at index $last_polybar)"
                        continue
                    fi
                    want_polybar=1
                    seen_polybar=1
                    ;;
                picom)
                    if [ "$i" -ne "$last_picom" ]; then
                        skipped_idempotent=$((skipped_idempotent + 1))
                        log "dedupe skip picom (later picom at index $last_picom)"
                        continue
                    fi
                    want_picom=1
                    picom_explicit=1
                    seen_picom=1
                    ;;
                refresh)
                    if [ "$i" -ne "$last_refresh" ]; then
                        skipped_idempotent=$((skipped_idempotent + 1))
                        log "dedupe skip refresh (later refresh at index $last_refresh)"
                        continue
                    fi
                    want_i3=1
                    want_polybar=1
                    seen_refresh=1
                    ;;
                boot)
                    if [ "$i" -ne "$last_boot" ]; then
                        skipped_idempotent=$((skipped_idempotent + 1))
                        log "dedupe skip boot (later boot at index $last_boot)"
                        continue
                    fi
                    want_polybar=1
                    seen_boot=1
                    ;;
            esac
            continue
        fi

        log "unknown request type: $typ"
    done

    if [ ${#plan_types[@]} -eq 0 ] && [ "$want_polybar" -eq 0 ] && [ "$want_picom" -eq 0 ] && [ "$want_i3" -eq 0 ]; then
        log "batch empty after plan (ids=${ids[*]})"
        local rid
        for rid in "${ids[@]}"; do
            mark_done "$rid" ok
        done
        return 0
    fi

    log "batch ids=${ids[*]} config_steps=${#plan_types[@]} i3=$want_i3 polybar=$want_polybar picom=$want_picom picom_explicit=$picom_explicit skipped_idempotent=$skipped_idempotent"

    local before_cap before_theme picom_dir
    picom_dir="$HOME/.config/picom"
    before_cap=$(file_hash "$picom_dir/capability.conf")
    before_theme=$(file_hash "$picom_dir/theme.conf")

    local status=ok
    set +e

    # Suppress config-watcher for the whole apply so materializing fade/theme
    # into ~/.config/up/config cannot re-enqueue sync (infinite loop).
    desktop_watch_suppress_begin
    # shellcheck disable=SC2064
    trap 'desktop_watch_suppress_end' RETURN

    # --- Execute every config-changing step (in order) ---
    local step typ th fr
    for ((step = 0; step < ${#plan_types[@]}; step++)); do
        typ="${plan_types[$step]}"
        th="${plan_theme[$step]:-}"
        fr="${plan_force[$step]:-0}"
        case "$typ" in
            theme)
                log "exec config[$step] theme name=$th"
                apply_theme_files "$th"
                ;;
            reapply)
                log "exec config[$step] reapply"
                apply_theme_files ""
                ;;
            sync)
                log "exec config[$step] sync force=$fr"
                apply_compositor "$fr"
                apply_theme_files ""
                ;;
            compositor)
                log "exec config[$step] compositor force=$fr"
                apply_compositor "$fr"
                ;;
        esac
    done

    # --- Idempotent desktop refresh (once each) ---
    if [ "$want_i3" -eq 1 ]; then
        # While this stamp is fresh, exec_always's launch.sh exits without
        # killing the bar. The restart below is the one that re-reads colors.
        if [ "$want_polybar" -eq 1 ]; then
            printf '%s\n' "$(($(date +%s) + 4))" \
                >"${XDG_RUNTIME_DIR:-/tmp}/polybar-launch-defer-${UID:-$(id -u)}"
        fi
        log "exec idempotent reload i3"
        reload_i3
    fi
    if [ "$want_polybar" -eq 1 ]; then
        log "exec idempotent restart polybar"
        restart_polybar
    fi
    if [ "$want_picom" -eq 1 ]; then
        local after_cap after_theme
        after_cap=$(file_hash "$picom_dir/capability.conf")
        after_theme=$(file_hash "$picom_dir/theme.conf")
        if [ "$picom_explicit" -eq 1 ]; then
            log "exec idempotent restart picom (explicit request)"
            restart_picom
        elif [ "$before_cap" != "$after_cap" ] || [ "$before_theme" != "$after_theme" ]; then
            log "exec idempotent restart picom (config fragments changed)"
            restart_picom
        else
            log "skip picom restart (idempotent: fragments unchanged, no explicit picom)"
        fi
    fi
    set -e

    # Mark applied hash before cool-off so delayed inotify is ignored
    desktop_mark_config_applied
    desktop_watch_suppress_end
    trap - RETURN

    local rid
    for rid in "${ids[@]}"; do
        mark_done "$rid" "$status"
    done
    log "batch complete status=$status"
    return 0
}

# Debounce: after seeing activity, wait briefly for more requests
debounce_ms() {
    local ms="${1:-250}"
    sleep "$(awk -v m="$ms" 'BEGIN{printf "%.3f", m/1000}')" 2>/dev/null \
        || sleep 0.3
}

# On start: give i3's exec launch.sh a moment, then start the bar only if
# it is still missing. Never restart a running bar here (that races a twin).
startup_once() {
    if [ -z "${DISPLAY:-}" ] && [ -z "${WAYLAND_DISPLAY:-}" ]; then
        log "startup: no DISPLAY; skip polybar"
        return 0
    fi
    wait_for_i3_ipc || true
    sleep 0.4
    if pgrep -u "${UID:-$(id -u)}" -x polybar >/dev/null 2>&1; then
        log "startup: polybar already running; skip"
        return 0
    fi
    log "startup: polybar missing; launching"
    restart_polybar || true
}

startup_once || log "startup_once failed (continuing)"

# Prefer inotify; fall back to poll
use_inotify=false
if have_cmd inotifywait; then
    use_inotify=true
fi

if [ "$use_inotify" = true ]; then
    log "watching queue with inotify: $QUEUE_DIR"
    # Process anything already queued
    while coalesce_and_run; do :; done

    inotifywait -m -e close_write,moved_to,create --format '%f' "$QUEUE_DIR" 2>>"$LOG" \
        | while read -r _file; do
            # Debounce burst of enqueues
            debounce_ms "$DEBOUNCE_MS"
            while coalesce_and_run; do
                debounce_ms 50
            done
        done
else
    log "inotifywait missing; polling queue every 0.5s"
    while true; do
        if coalesce_and_run; then
            debounce_ms 50
            continue
        fi
        sleep 0.5
    done
fi
