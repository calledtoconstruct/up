#!/usr/bin/env bash
# Apply a compositor capability profile to user config + picom fragments.
#
# Reads effects from ~/.config/up/config:
#   auto  — detect and materialize fade/blur/dim (default)
#   full | lite | safe — force that profile
#
# Writes:
#   ~/.config/up/config          (fade/blur/dim when auto or tier)
#   ~/.config/picom/capability.conf
#   ~/.config/up/compositor-capability  (cache)
#
# Usage:
#   apply-compositor-profile.sh [--force] [--dry-run] [--home DIR] [--no-theme]
#
# Intended callers: setup.sh, start-session.sh, config-watcher, manual re-probe.

set -euo pipefail

# Prefer installed tree; fall back to this script's directory (same layouts).
_SCRIPT_PATH="${BASH_SOURCE[0]:-$0}"
_SCRIPT_DIR="$(cd "$(dirname "$_SCRIPT_PATH")" && pwd)"
export UP_ROOT="${UP_ROOT:-/usr/local/share/up}"
if [ ! -d "$UP_ROOT/configs/scripts" ] && [ -f "$_SCRIPT_DIR/detect-compositor-capability.sh" ]; then
    # Running from a checkout where UP_ROOT is unset/uninstalled
    UP_ROOT="$(cd "$_SCRIPT_DIR/../.." && pwd)"
    export UP_ROOT
fi
SCRIPT_DIR="${UP_ROOT}/configs/scripts"
DETECT="${SCRIPT_DIR}/detect-compositor-capability.sh"
if [ ! -f "$DETECT" ] && [ -f "$_SCRIPT_DIR/detect-compositor-capability.sh" ]; then
    DETECT="$_SCRIPT_DIR/detect-compositor-capability.sh"
    SCRIPT_DIR="$_SCRIPT_DIR"
fi

FORCE=false
DRY_RUN=false
NO_THEME=false
HOME_OVERRIDE=""

while [ $# -gt 0 ]; do
    case "$1" in
        --force) FORCE=true; shift ;;
        --dry-run) DRY_RUN=true; shift ;;
        --no-theme) NO_THEME=true; shift ;;
        --home)
            HOME_OVERRIDE="${2:-}"
            shift 2
            ;;
        -h|--help)
            cat <<'EOF'
Usage: apply-compositor-profile.sh [--force] [--dry-run] [--no-theme] [--home DIR]

Detect (or honor effects= full|lite|safe) and write picom capability settings.
With effects=auto, re-detects when machine fingerprint changes or --force is set.
EOF
            exit 0
            ;;
        *)
            echo "Unknown option: $1" >&2
            exit 2
            ;;
    esac
done

if [ -n "$HOME_OVERRIDE" ]; then
    export HOME="$HOME_OVERRIDE"
fi

CONFIG_FILE="${HOME}/.config/up/config"
CACHE_FILE="${HOME}/.config/up/compositor-capability"
PICOM_DIR="${HOME}/.config/picom"
CAP_FILE="${PICOM_DIR}/capability.conf"
STATE_DIR="${HOME}/.local/state/up"
LOG_FILE="${STATE_DIR}/compositor-capability.log"

mkdir -p "${HOME}/.config/up" "$PICOM_DIR" "$STATE_DIR"

# --- config helpers ----------------------------------------------------------

read_config_key() {
    local key="$1"
    local file="${2:-$CONFIG_FILE}"
    [ -f "$file" ] || { echo ""; return 0; }
    grep -E "^[[:space:]]*${key}[[:space:]]*=" "$file" 2>/dev/null \
        | head -1 \
        | sed 's/^[^=]*=[[:space:]]*//' \
        | tr -d ' "'"'"'"' \
        || echo ""
}

# Set or append KEY = value in a simple TOML-ish config (flat keys only).
# No-ops when the effective value is already set so watchers do not loop.
set_config_key() {
    local key="$1"
    local value="$2"
    local file="${3:-$CONFIG_FILE}"
    local tmp
    local current=""
    local current_norm=""
    local value_norm=""

    mkdir -p "$(dirname "$file")"
    if [ ! -f "$file" ]; then
        if [ "$DRY_RUN" = true ]; then
            echo "[dry-run] would create $file with $key = $value"
            return 0
        fi
        printf '%s = %s\n' "$key" "$value" >"$file"
        return 0
    fi

    if grep -qE "^[[:space:]]*${key}[[:space:]]*=" "$file" 2>/dev/null; then
        current=$(grep -E "^[[:space:]]*${key}[[:space:]]*=" "$file" | head -1 \
            | sed 's/^[^=]*=[[:space:]]*//' | tr -d ' ')
        current_norm=$(printf '%s' "$current" | tr -d "\"'")
        value_norm=$(printf '%s' "$value" | tr -d "\"'")
        if [ "$current_norm" = "$value_norm" ]; then
            return 0
        fi
        if [ "$DRY_RUN" = true ]; then
            echo "[dry-run] would set $key = $value in $file"
            return 0
        fi
        tmp=$(mktemp)
        # Preserve quoting style for string values already quoted
        if printf '%s' "$value" | grep -q '^"'; then
            sed -E "s|^[[:space:]]*${key}[[:space:]]*=.*|${key} = ${value}|" "$file" >"$tmp"
        else
            sed -E "s|^[[:space:]]*${key}[[:space:]]*=.*|${key} = ${value}|" "$file" >"$tmp"
        fi
        mv "$tmp" "$file"
    else
        if [ "$DRY_RUN" = true ]; then
            echo "[dry-run] would append $key = $value to $file"
            return 0
        fi
        # Ensure trailing newline then append
        [ -s "$file" ] && [ "$(tail -c1 "$file" | wc -l)" -eq 0 ] && printf '\n' >>"$file"
        printf '%s = %s\n' "$key" "$value" >>"$file"
    fi
}

# --- detect ------------------------------------------------------------------

if [ ! -x "$DETECT" ]; then
    if [ -f "$DETECT" ]; then
        chmod +x "$DETECT" 2>/dev/null || true
    else
        echo "Error: detector not found: $DETECT" >&2
        exit 1
    fi
fi

# Cheap skip: do not spawn glxinfo / full scoring when the cache still matches.
# Re-probe the first time DISPLAY is set so llvmpipe sessions drop to "safe".
if [ "$FORCE" = false ] && [ -f "$CACHE_FILE" ] && [ -f "$CAP_FILE" ]; then
    _cached_effects=$(grep -E '^effects=' "$CACHE_FILE" 2>/dev/null | head -1 | cut -d= -f2- || true)
    _cached_machine_id=$(grep -E '^machine_id=' "$CACHE_FILE" 2>/dev/null | head -1 | cut -d= -f2- || true)
    _cached_display_probed=$(grep -E '^display_probed=' "$CACHE_FILE" 2>/dev/null | head -1 | cut -d= -f2- || true)
    _effects_now=$(read_config_key "effects")
    _effects_now=$(printf '%s' "${_effects_now:-auto}" | tr 'A-Z' 'a-z')
    [ -z "$_effects_now" ] && _effects_now="auto"
    _need_display_probe=false
    if [ -n "${DISPLAY:-}" ] && [ "${_cached_display_probed:-false}" != "true" ]; then
        _need_display_probe=true
    fi
    if [ "$_need_display_probe" = false ] && [ "$_effects_now" = "$_cached_effects" ]; then
        _cheap_id=""
        _cheap_id=$("$DETECT" --id-only 2>/dev/null | grep -E '^machine_id=' | head -1 | cut -d= -f2- | tr -d "'")
        if [ -n "$_cheap_id" ] && [ "$_cheap_id" = "$_cached_machine_id" ]; then
            echo "Compositor profile unchanged (cache hit, skipped detect)"
            unset _cached_effects _cached_machine_id _cached_display_probed
            unset _effects_now _need_display_probe _cheap_id
            exit 0
        fi
    fi
    unset _cached_effects _cached_machine_id _cached_display_probed
    unset _effects_now _need_display_probe _cheap_id
fi

# shellcheck disable=SC1090
eval "$("$DETECT")"

detected_profile="${profile}"
detected_machine_id="${machine_id}"

effects=$(read_config_key "effects")
effects=$(printf '%s' "$effects" | tr 'A-Z' 'a-z')
if [ -z "$effects" ]; then
    effects="auto"
fi

case "$effects" in
    auto|full|lite|safe) ;;
    *)
        echo "Warning: unknown effects='$effects', treating as auto" >&2
        effects="auto"
        ;;
esac

# Resolve effective profile
if [ "$effects" = "auto" ]; then
    effective_profile="$detected_profile"
else
    effective_profile="$effects"
    # Still take backend/fence hints from detection for the forced tier
fi

# Re-map fade/blur/dim/shadow/backend for forced tiers (and normalize auto)
case "$effective_profile" in
    full)
        fade=true; blur=true; dim=true; shadow=true
        if [ "${software_gl:-false}" = "true" ]; then
            backend="xrender"
            blur=false
        else
            backend="glx"
        fi
        ;;
    lite)
        fade=true; blur=false; dim=true; shadow=true
        if [ "${software_gl:-false}" = "true" ]; then
            backend="xrender"
        else
            backend="glx"
        fi
        ;;
    safe)
        fade=false; blur=false; dim=false; shadow=false
        backend="xrender"
        ;;
esac

# NVIDIA fence only meaningful on glx
if [ "${has_nvidia:-false}" = "true" ] && [ "$backend" = "glx" ]; then
    xrender_sync_fence=true
else
    xrender_sync_fence=false
fi

# --- cache / skip ------------------------------------------------------------

cached_profile=""
cached_machine_id=""
cached_effects=""
if [ -f "$CACHE_FILE" ]; then
    # shellcheck disable=SC1090
    cached_profile=$(grep -E '^profile=' "$CACHE_FILE" 2>/dev/null | head -1 | cut -d= -f2- || true)
    cached_machine_id=$(grep -E '^machine_id=' "$CACHE_FILE" 2>/dev/null | head -1 | cut -d= -f2- || true)
    cached_effects=$(grep -E '^effects=' "$CACHE_FILE" 2>/dev/null | head -1 | cut -d= -f2- || true)
fi

need_apply=false
if [ "$FORCE" = true ]; then
    need_apply=true
elif [ ! -f "$CAP_FILE" ]; then
    need_apply=true
elif [ "$effects" != "$cached_effects" ]; then
    need_apply=true
elif [ "$effects" = "auto" ] && [ "$detected_machine_id" != "$cached_machine_id" ]; then
    need_apply=true
elif [ "$effective_profile" != "$cached_profile" ]; then
    need_apply=true
fi

if [ "$need_apply" = false ]; then
    echo "Compositor profile unchanged: $effective_profile (effects=$effects)"
    exit 0
fi

echo "Compositor profile: $effective_profile (effects=$effects, detected=$detected_profile, score=${score:-?})"
echo "  reason: ${reason:-unknown}"
echo "  backend=$backend blur=$blur fade=$fade dim=$dim fence=$xrender_sync_fence"

# --- write capability.conf ---------------------------------------------------

write_capability_conf() {
    local fence_line shadow_block blur_block
    if [ "$xrender_sync_fence" = "true" ]; then
        fence_line="xrender-sync-fence = true;"
    else
        fence_line="xrender-sync-fence = false;"
    fi

    if [ "$shadow" = "true" ]; then
        shadow_block="# shadow left to main/theme config"
    else
        shadow_block="shadow = false;"
    fi

    if [ "$blur" = "true" ]; then
        blur_block="# blur enabled via theme.conf (dual_kawase + glx)"
    else
        blur_block=$(cat <<'BLK'
blur: {
    method = "none";
};
blur-background = false;
BLK
)
    fi

    cat <<EOF
# Generated by apply-compositor-profile.sh — do not hand-edit
# profile=$effective_profile effects=$effects
# detected=$detected_profile score=${score:-} reason=${reason:-}
# machine_id=$detected_machine_id

backend = "$backend";
$fence_line
$shadow_block
$blur_block
EOF
}

if [ "$DRY_RUN" = true ]; then
    echo "[dry-run] capability.conf would be:"
    write_capability_conf
else
    # Only rewrite when content changes (avoids picom restart loops)
    _new_cap=$(write_capability_conf)
    if [ ! -f "$CAP_FILE" ] || [ "$(cat "$CAP_FILE")" != "$_new_cap" ]; then
        printf '%s\n' "$_new_cap" >"$CAP_FILE"
    fi
    unset _new_cap
fi

# --- materialize user config -------------------------------------------------

# Ensure effects key exists (default auto)
if [ -z "$(read_config_key "effects")" ]; then
    set_config_key "effects" "\"auto\""
fi

# Always materialize booleans so switch-theme / docs stay consistent
set_config_key "fade" "$fade"
set_config_key "blur" "$blur"
set_config_key "dim" "$dim"

# --- cache -------------------------------------------------------------------

if [ "$DRY_RUN" = false ]; then
    cat >"$CACHE_FILE" <<EOF
profile=$effective_profile
effects=$effects
detected_profile=$detected_profile
machine_id=$detected_machine_id
score=${score:-}
reason=${reason:-}
backend=$backend
fade=$fade
blur=$blur
dim=$dim
shadow=$shadow
xrender_sync_fence=$xrender_sync_fence
display_probed=$([ -n "${DISPLAY:-}" ] && echo true || echo false)
updated=$(date -Iseconds 2>/dev/null || date)
EOF
    {
        echo "$(date -Iseconds 2>/dev/null || date) profile=$effective_profile effects=$effects reason=${reason:-}"
    } >>"$LOG_FILE" 2>/dev/null || true
fi

# --- refresh picom theme fragment --------------------------------------------

if [ "$NO_THEME" = false ] && [ "$DRY_RUN" = false ]; then
    if [ -x "${SCRIPT_DIR}/switch-theme.sh" ]; then
        # Re-apply theme files so picom theme.conf picks up fade/blur/dim.
        # Install / --home / headless: files only (no desktop-agent).
        # Live session: --reapply may queue a desktop refresh.
        theme_args=(--reapply)
        if [ -n "$HOME_OVERRIDE" ]; then
            theme_args+=(--home "$HOME_OVERRIDE" --no-reload)
            UP_DESKTOP_INLINE=1 \
                "${SCRIPT_DIR}/switch-theme.sh" "${theme_args[@]}" >/dev/null 2>&1 || \
                echo "Warning: switch-theme.sh failed after profile apply" >&2
        elif [ -z "${DISPLAY:-}" ] && [ -z "${WAYLAND_DISPLAY:-}" ]; then
            theme_args+=(--no-reload)
            UP_DESKTOP_INLINE=1 \
                "${SCRIPT_DIR}/switch-theme.sh" "${theme_args[@]}" >/dev/null 2>&1 || \
                echo "Warning: switch-theme.sh failed after profile apply" >&2
        else
            theme_args+=(--no-reload)
            "${SCRIPT_DIR}/switch-theme.sh" "${theme_args[@]}" >/dev/null 2>&1 || \
                echo "Warning: switch-theme.sh failed after profile apply" >&2
        fi
    fi
fi

echo "→ Wrote $CAP_FILE"
echo "→ Updated fade/blur/dim in $CONFIG_FILE"
