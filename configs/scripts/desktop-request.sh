#!/bin/bash
# Desktop apply queue — client API
#
# Enqueue work for desktop-agent.sh (serial worker). Callers never restart
# polybar/picom/i3 themselves when the agent is available.
#
# Architecture:
#   - Scripts (theme/font/menu) → enqueue directly (preferred)
#   - config-watcher → enqueue only for *external* edits to ~/.config/up/config
#   - Agent may rewrite that config (fade/theme materialization). Without guards
#     that re-fires the watcher → infinite loop. Use watch suppress + content hash.
#
# Usage:
#   desktop-request.sh <type> [key=value ...]
#   desktop-request.sh theme name=aetherweft
#   desktop-request.sh reapply
#   desktop-request.sh sync [force=1]
#   desktop-request.sh compositor [force=1]
#   desktop-request.sh polybar
#   desktop-request.sh picom
#   desktop-request.sh refresh
#   desktop-request.sh --wait <type> ...   # block until request is done
#   desktop-request.sh --ensure-agent      # start agent if not running
#
# Sourceable:
#   source desktop-request.sh
#   desktop_request reapply
#   desktop_request_wait theme name=aetherweft
#   desktop_request_from_watch   # for config-watcher only

set -euo pipefail

export UP_ROOT="${UP_ROOT:-/usr/local/share/up}"

# Cool-off after agent releases suppress (covers delayed inotify events)
DESKTOP_WATCH_COOLOFF_SEC="${DESKTOP_WATCH_COOLOFF_SEC:-2}"

desktop_state_dir() {
    printf '%s\n' "${XDG_STATE_HOME:-$HOME/.local/state}/up/desktop"
}

desktop_queue_dir() {
    printf '%s\n' "$(desktop_state_dir)/queue"
}

desktop_done_dir() {
    printf '%s\n' "$(desktop_state_dir)/done"
}

desktop_agent_pidfile() {
    printf '%s\n' "$(desktop_state_dir)/agent.pid"
}

desktop_agent_logfile() {
    printf '%s\n' "$(desktop_state_dir)/agent.log"
}

desktop_watch_suppress_path() {
    printf '%s\n' "$(desktop_state_dir)/watch-suppress"
}

desktop_watch_cooloff_path() {
    printf '%s\n' "$(desktop_state_dir)/watch-cooloff-until"
}

desktop_config_applied_hash_path() {
    printf '%s\n' "$(desktop_state_dir)/config-applied.sha256"
}

desktop_user_config_path() {
    printf '%s\n' "${HOME}/.config/up/config"
}

desktop_config_hash() {
    local f
    f=$(desktop_user_config_path)
    if [ ! -f "$f" ]; then
        printf 'missing\n'
        return 0
    fi
    sha256sum "$f" 2>/dev/null | awk '{print $1}'
}

# Agent holds this while it may write ~/.config/up/config (or related state).
desktop_watch_suppress_begin() {
    mkdir -p "$(desktop_state_dir)"
    printf 'pid=%s\nstarted=%s\n' "$$" "$(date +%s)" >"$(desktop_watch_suppress_path)"
}

desktop_watch_suppress_end() {
    local until
    until=$(( $(date +%s) + DESKTOP_WATCH_COOLOFF_SEC ))
    printf '%s\n' "$until" >"$(desktop_watch_cooloff_path)"
    rm -f "$(desktop_watch_suppress_path)"
    # Record config hash after agent mutations so late events are no-ops
    desktop_config_hash >"$(desktop_config_applied_hash_path)" 2>/dev/null || true
}

# True if watcher must ignore filesystem events (agent applying or cool-off).
desktop_watch_suppressed() {
    local sp cp now until pid started
    sp=$(desktop_watch_suppress_path)
    if [ -f "$sp" ]; then
        pid=$(grep -E '^pid=' "$sp" 2>/dev/null | head -1 | cut -d= -f2- || true)
        started=$(grep -E '^started=' "$sp" 2>/dev/null | head -1 | cut -d= -f2- || true)
        # Live suppress from running process
        if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
            return 0
        fi
        # Stale suppress (crashed agent): expire after 120s
        now=$(date +%s)
        if [ -n "$started" ] && [ $((now - started)) -lt 120 ]; then
            return 0
        fi
        rm -f "$sp"
    fi
    cp=$(desktop_watch_cooloff_path)
    if [ -f "$cp" ]; then
        until=$(tr -d '[:space:]' <"$cp" 2>/dev/null || true)
        now=$(date +%s)
        if [ -n "$until" ] && [ "$now" -lt "$until" ] 2>/dev/null; then
            return 0
        fi
        rm -f "$cp"
    fi
    return 1
}

# Record that the given config hash is already reflected on the desktop.
desktop_mark_config_applied() {
    local h="${1:-}"
    mkdir -p "$(desktop_state_dir)"
    if [ -z "$h" ]; then
        h=$(desktop_config_hash)
    fi
    printf '%s\n' "$h" >"$(desktop_config_applied_hash_path)"
}

# For config-watcher: enqueue sync only on real external config changes.
# Returns 0 if enqueued, 1 if skipped (suppressed / unchanged / error).
desktop_request_from_watch() {
    local force="${1:-1}"
    local h applied

    if desktop_watch_suppressed; then
        return 1
    fi

    h=$(desktop_config_hash)
    applied=""
    if [ -f "$(desktop_config_applied_hash_path)" ]; then
        applied=$(tr -d '[:space:]' <"$(desktop_config_applied_hash_path)" 2>/dev/null || true)
    fi
    if [ -n "$applied" ] && [ "$h" = "$applied" ]; then
        # Agent (or prior sync) already applied this exact config content
        return 1
    fi

    # Avoid flooding: if an identical sync is already queued, skip
    if desktop_queue_has_type sync; then
        return 1
    fi

    desktop_request sync "force=${force}" >/dev/null
    # Optimistic: do not mark applied yet — agent will after success.
    # Track last enqueued hash to collapse duplicate events before agent runs.
    printf '%s\n' "$h" >"$(desktop_state_dir)/config-enqueued.sha256"
    return 0
}

desktop_queue_has_type() {
    local typ="$1"
    local f
    for f in "$(desktop_queue_dir)"/*.req; do
        [ -f "$f" ] || continue
        if grep -qE "^type=${typ}\$" "$f" 2>/dev/null; then
            return 0
        fi
    done
    return 1
}

desktop_agent_script() {
    if [ -x "$UP_ROOT/configs/scripts/desktop-agent.sh" ]; then
        printf '%s\n' "$UP_ROOT/configs/scripts/desktop-agent.sh"
    elif [ -x "$(dirname "${BASH_SOURCE[0]:-$0}")/desktop-agent.sh" ]; then
        printf '%s\n' "$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)/desktop-agent.sh"
    else
        return 1
    fi
}

desktop_agent_running() {
    local pf pid
    pf=$(desktop_agent_pidfile)
    [ -f "$pf" ] || return 1
    pid=$(tr -d '[:space:]' <"$pf" 2>/dev/null || true)
    [ -n "$pid" ] || return 1
    kill -0 "$pid" 2>/dev/null
}

# Start agent in background if not already running.
# Requires a graphical session — never spawn during install/chroot/TTY.
desktop_ensure_agent() {
    if desktop_agent_running; then
        return 0
    fi
    if [ -z "${DISPLAY:-}" ] && [ -z "${WAYLAND_DISPLAY:-}" ]; then
        return 1
    fi
    if [ -n "${UP_INSTALL:-}" ] || [ -f /run/up-installing ] || [ -f /etc/up-installing ]; then
        return 1
    fi
    # Chroot detection (setup.sh inside arch-chroot)
    if [ -e /proc/1/root ] && [ -e / ]; then
        local root_id proc_id
        root_id=$(stat -c '%d:%i' / 2>/dev/null || true)
        proc_id=$(stat -c '%d:%i' /proc/1/root 2>/dev/null || true)
        if [ -n "$root_id" ] && [ -n "$proc_id" ] && [ "$root_id" != "$proc_id" ]; then
            return 1
        fi
    fi
    local agent
    agent=$(desktop_agent_script) || {
        echo "desktop-request: desktop-agent.sh not found" >&2
        return 1
    }
    mkdir -p "$(desktop_state_dir)"
    nohup "$agent" >>"$(desktop_agent_logfile)" 2>&1 &
    local i
    for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
        desktop_agent_running && return 0
        sleep 0.1
    done
    # Agent may still be starting; enqueue is safe either way
    return 0
}

# Enqueue a request. Prints request id on stdout.
# Args: type [key=value ...]
desktop_request() {
    local type="${1:-}"
    shift || true
    if [ -z "$type" ]; then
        echo "desktop_request: type required" >&2
        return 1
    fi

    local q d id tmp
    q=$(desktop_queue_dir)
    d=$(desktop_done_dir)
    mkdir -p "$q" "$d"

    id="$(date +%s%N 2>/dev/null || date +%s)-${$}-${RANDOM}"
    tmp="$q/.tmp.$id"
    {
        printf 'type=%s\n' "$type"
        printf 'created=%s\n' "$(date -Iseconds 2>/dev/null || date)"
        local kv
        for kv in "$@"; do
            printf '%s\n' "$kv"
        done
    } >"$tmp"
    mv "$tmp" "$q/${id}.req"
    printf '%s\n' "$id"
}

# Wait until request id is marked done (or timeout seconds).
desktop_request_wait_id() {
    local id="${1:-}"
    local timeout="${2:-60}"
    local donef
    donef="$(desktop_done_dir)/${id}.done"
    local i=0
    local max=$((timeout * 10))
    while [ "$i" -lt "$max" ]; do
        if [ -f "$donef" ]; then
            local st
            st=$(grep -E '^status=' "$donef" 2>/dev/null | head -1 | cut -d= -f2- || echo ok)
            [ "$st" = "ok" ] || [ "$st" = "0" ] && return 0
            return 1
        fi
        # Agent died?
        if [ "$i" -gt 20 ] && ! desktop_agent_running; then
            desktop_ensure_agent || true
        fi
        sleep 0.1
        i=$((i + 1))
    done
    echo "desktop-request: timeout waiting for $id" >&2
    return 1
}

# Enqueue and wait.
desktop_request_wait() {
    local id
    id=$(desktop_request "$@")
    desktop_ensure_agent || true
    desktop_request_wait_id "$id"
}

# CLI entry when executed (not sourced)
_desktop_request_cli() {
    local wait=false
    local ensure=false
    local args=()
    while [ $# -gt 0 ]; do
        case "$1" in
            --wait) wait=true; shift ;;
            --ensure-agent) ensure=true; shift ;;
            -h|--help)
                cat <<'EOF'
Usage: desktop-request.sh [--wait] [--ensure-agent] <type> [key=value ...]

Types:
  theme name=NAME     Apply theme (files + ordered desktop refresh)
  reapply             Re-apply current theme + refresh desktop
  sync [force=1]      Compositor profile + theme + refresh + picom if needed
  compositor [force=1]
  polybar             Restart polybar only
  picom               Restart picom only
  refresh             i3 reload + polybar (after files already written)

Loop safety:
  Agent sets watch-suppress while mutating ~/.config/up/config.
  config-watcher must use desktop_request_from_watch (hash + suppress).
  Direct scripts should call desktop_request (not rely on the watcher).

Examples:
  desktop-request.sh reapply
  desktop-request.sh --wait theme name=aetherweft
  desktop-request.sh sync force=1
EOF
                return 0
                ;;
            *)
                args+=("$1")
                shift
                ;;
        esac
    done

    if [ "$ensure" = true ] || [ "$wait" = true ]; then
        desktop_ensure_agent || true
    fi

    if [ ${#args[@]} -eq 0 ]; then
        if [ "$ensure" = true ]; then
            return 0
        fi
        echo "desktop-request: type required" >&2
        return 1
    fi

    if [ "$wait" = true ]; then
        desktop_request_wait "${args[@]}"
    else
        desktop_request "${args[@]}"
        # Best-effort: ensure worker is up to drain the queue
        desktop_ensure_agent || true
    fi
}

# Only run CLI when executed directly
if [ "${BASH_SOURCE[0]:-}" = "${0:-}" ]; then
    _desktop_request_cli "$@"
fi
