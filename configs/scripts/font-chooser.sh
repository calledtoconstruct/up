#!/bin/bash
# Font Chooser - Rofi picker for monospace fonts used by terminals / UI chrome
# Updates ~/.config/up/config and re-applies the current theme

set -euo pipefail

export UP_ROOT="${UP_ROOT:-/usr/local/share/up}"

WANT_FONT=""
LIST_ONLY=false
while [ $# -gt 0 ]; do
    case "$1" in
        --font)
            WANT_FONT="${2:-}"
            shift 2
            ;;
        --list)
            LIST_ONLY=true
            shift
            ;;
        -h|--help)
            cat <<'EOF'
Usage: font-chooser.sh [--list | --font NAME]

  (no args)  Open the rofi picker
  --list     Print available monospace families
  --font N   Apply family N without prompting
EOF
            exit 0
            ;;
        *)
            echo "Unknown option: $1" >&2
            exit 2
            ;;
    esac
done

# Preferred fonts first (packages Up installs + common coding fonts).
# Only entries that resolve on this machine appear in the menu.
# Order = display order among curated matches.
CURATED_FONTS=(
    "JetBrains Mono"
    "JetBrainsMono Nerd Font"
    "JetBrainsMono Nerd Font Mono"
    "Fira Code"
    "FiraCode Nerd Font"
    "FiraCode Nerd Font Mono"
    "DejaVu Sans Mono"
    "Ubuntu Mono"
    "Liberation Mono"
    "Noto Sans Mono"
    "Source Code Pro"
    "SauceCodePro Nerd Font"
    "Hack"
    "Hack Nerd Font"
    "Cascadia Code"
    "CaskaydiaCove Nerd Font"
    "Iosevka"
    "Iosevka Nerd Font"
    "MesloLGS NF"
    "MesloLGM Nerd Font"
    "Roboto Mono"
    "Inconsolata"
    "Inconsolata Nerd Font"
    "IBM Plex Mono"
    "Go Mono"
    "Anonymous Pro"
    "Cousine"
    "Nimbus Mono PS"
    "Adwaita Mono"
    "FreeMono"
    "Monospace"
)

# True if fontconfig can resolve the family (exact or as a match that keeps the name).
font_available() {
    local font="$1"
    if ! command -v fc-list >/dev/null 2>&1; then
        return 1
    fi
    # Exact family present
    if fc-list : family 2>/dev/null | awk -F',' '{for(i=1;i<=NF;i++){gsub(/^ +| +$/,"",$i); print $i}}' \
        | grep -Fxq -- "$font"; then
        return 0
    fi
    # Case-insensitive family substring (covers "JetBrainsMono Nerd Font" vs curated name)
    if fc-list : family 2>/dev/null | grep -qiF -- "$font"; then
        return 0
    fi
    # fc-match fallback: accept only if match still looks like the request
    if command -v fc-match >/dev/null 2>&1; then
        local matched
        matched=$(fc-match -f '%{family}\n' "$font" 2>/dev/null | head -1 | cut -d',' -f1 | sed 's/^ *//;s/ *$//')
        if [ -n "$matched" ] && printf '%s' "$matched" | grep -qiF -- "${font%% *}"; then
            return 0
        fi
    fi
    return 1
}

# Resolve the best installed family name for a curated entry.
# Prefer an exact fc-list family when the curated string is only approximate.
resolve_family() {
    local want="$1"
    local exact
    exact=$(fc-list : family 2>/dev/null \
        | awk -F',' '{for(i=1;i<=NF;i++){gsub(/^ +| +$/,"",$i); if($i!="") print $i}}' \
        | grep -Fx -- "$want" | head -1 || true)
    if [ -n "$exact" ]; then
        printf '%s\n' "$exact"
        return 0
    fi
    # Prefer the shortest family that contains the curated name (avoid style-weight duplicates)
    local hit
    hit=$(fc-list : family 2>/dev/null \
        | awk -F',' '{for(i=1;i<=NF;i++){gsub(/^ +| +$/,"",$i); if($i!="") print $i}}' \
        | grep -iF -- "$want" | awk '{ print length, $0 }' | sort -n | head -1 | cut -d' ' -f2- || true)
    if [ -n "$hit" ]; then
        printf '%s\n' "$hit"
        return 0
    fi
    printf '%s\n' "$want"
}

# Discover monospace (and mono-spacing) families installed on the system.
discover_mono_families() {
    if ! command -v fc-list >/dev/null 2>&1; then
        return 0
    fi
    {
        # spacing=mono (symbolic) and spacing=100 (absolute mono)
        fc-list :spacing=mono family 2>/dev/null || true
        fc-list :spacing=100 family 2>/dev/null || true
        # Name heuristics for fonts that mis-report spacing
        fc-list : family 2>/dev/null | grep -iE \
            'mono|nerd font|code|consolas|hack|cascadia|iosevka|jetbrains|fira|inconsolata|meslo|cousine|plex mono|source code|saucecode|adwaita mono' \
            || true
    } | awk -F',' '{
            for (i = 1; i <= NF; i++) {
                gsub(/^ +| +$/, "", $i)
                if ($i != "") print $i
            }
        }' \
      | grep -viE 'emoji|symbol|icon|awesome|font awesome|material|weather|powerline symbols only' \
      | sort -u
}

# Build available list: curated (resolved) first, then other discovered mono fonts
declare -a AVAILABLE_FONTS=()
declare -A SEEN=()

add_font() {
    local f="$1"
    [ -z "$f" ] && return 0
    # Skip weight-only style families that pollute the list
    case "$f" in
        *" Black"|*" Light"|*" Thin"|*" Medium"|*" ExtraBold"|*" ExtraLight"|*" SemiBold"|*" Bold")
            return 0
            ;;
    esac
    if [ -z "${SEEN[$f]:-}" ]; then
        SEEN[$f]=1
        AVAILABLE_FONTS+=("$f")
    fi
}

# 1) Curated preferences that are installed
for font in "${CURATED_FONTS[@]}"; do
    if font_available "$font"; then
        add_font "$(resolve_family "$font")"
    fi
done

# 2) Everything else monospace on the system
while IFS= read -r family; do
    [ -z "$family" ] && continue
    add_font "$family"
done < <(discover_mono_families)

# Fallback if discovery found nothing
if [ ${#AVAILABLE_FONTS[@]} -eq 0 ]; then
    AVAILABLE_FONTS=("DejaVu Sans Mono" "Monospace")
fi

# Current font from config
CONFIG_FILE="$HOME/.config/up/config"
CURRENT_FONT="DejaVu Sans Mono"
if [ -f "$CONFIG_FILE" ]; then
    CURRENT_FONT=$(grep -E '^[[:space:]]*font[[:space:]]*=' "$CONFIG_FILE" 2>/dev/null \
        | head -1 | sed 's/.*= *//' | sed 's/^"//' | sed 's/"$//' || echo "DejaVu Sans Mono")
    [ -z "$CURRENT_FONT" ] && CURRENT_FONT="DejaVu Sans Mono"
fi

# Ensure current font appears even if not in discovery
add_font "$CURRENT_FONT"

apply_selected_font() {
    local selected_font="$1"
    [ -n "$selected_font" ] || return 1
    mkdir -p "$(dirname "$CONFIG_FILE")"
    if [ -f "$CONFIG_FILE" ] && grep -qE '^[[:space:]]*font[[:space:]]*=' "$CONFIG_FILE" 2>/dev/null; then
        sed -i "s/^[[:space:]]*font[[:space:]]*=.*/font = \"$selected_font\"/" "$CONFIG_FILE"
    else
        if [ ! -f "$CONFIG_FILE" ]; then
            cat > "$CONFIG_FILE" << EOF
effects = "auto"
fade = true
blur = true
dim = true
font = "$selected_font"
EOF
        else
            printf '\nfont = "%s"\n' "$selected_font" >> "$CONFIG_FILE"
        fi
    fi

    if [ -x "$UP_ROOT/configs/scripts/desktop-request.sh" ]; then
        # shellcheck source=desktop-request.sh
        source "$UP_ROOT/configs/scripts/desktop-request.sh"
        desktop_ensure_agent || true
        desktop_request reapply >/dev/null || true
    elif [ -x "$UP_ROOT/configs/scripts/switch-theme.sh" ]; then
        "$UP_ROOT/configs/scripts/switch-theme.sh" --reapply --no-reload >/dev/null 2>&1 || true
    fi

    notify-send "Font" "Changed to: $selected_font" 2>/dev/null || echo "Font changed to: $selected_font"
}

if [ "$LIST_ONLY" = true ]; then
    printf '%s\n' "${AVAILABLE_FONTS[@]}"
    exit 0
fi

if [ -n "$WANT_FONT" ]; then
    SELECTED_FONT=$(resolve_family "$WANT_FONT")
    apply_selected_font "$SELECTED_FONT"
    exit 0
fi

# Build menu with current font marked; put current at top if present
MENU_ITEMS=()
# Current first
for font in "${AVAILABLE_FONTS[@]}"; do
    if [ "$font" = "$CURRENT_FONT" ]; then
        MENU_ITEMS+=("✓ $font")
    fi
done
for font in "${AVAILABLE_FONTS[@]}"; do
    if [ "$font" != "$CURRENT_FONT" ]; then
        MENU_ITEMS+=("  $font")
    fi
done

if [ ${#MENU_ITEMS[@]} -eq 0 ]; then
    notify-send "Font Chooser" "No fonts found." 2>/dev/null || echo "No fonts found." >&2
    exit 1
fi

# Prefer a readable list height
LINES=${#MENU_ITEMS[@]}
[ "$LINES" -gt 15 ] && LINES=15

SELECTED=$(printf '%s\n' "${MENU_ITEMS[@]}" | rofi -dmenu -i -p "Choose Font (${#MENU_ITEMS[@]} available)" \
    -lines "$LINES" -width 500 -kb-cancel Escape || true)

if [ -z "$SELECTED" ]; then
    exit 0
fi

# Strip checkmark / leading spaces
SELECTED_FONT=$(printf '%s' "$SELECTED" | sed 's/^[* ✓]* *//')
if [ -z "$SELECTED_FONT" ]; then
    exit 0
fi

apply_selected_font "$SELECTED_FONT"
