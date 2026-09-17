#!/bin/bash
# Shared rofi hierarchical menu helpers
# Source from menu scripts: source "$UP_ROOT/configs/scripts/rofi-menu.sh"
#
# Navigation model:
#   - A stack of menu IDs drives which screen is shown
#   - Every non-root menu automatically gets a "←  Back" row
#   - Escape / empty selection = Back (pop) on nested menus, Cancel (exit) on root
#   - Selecting Back = same as Escape
#
# Typical loop:
#   menu_stack_reset
#   menu_stack_push "main"
#   while menu_stack_depth >/dev/null && [ "$(menu_stack_depth)" -gt 0 ]; do
#     ... build options for $(menu_stack_peek) ...
#     if menu_pick "$title" "$options"; then
#       handle "$MENU_CHOICE"   # may push/pop/reset
#     else
#       case $? in
#         "$MENU_RESULT_BACK") menu_stack_pop ;;
#         *) break ;;  # cancel at root
#       esac
#     fi
#   done

# Guard against multiple sourcing
if [ -n "${ROFI_MENU_LOADED:-}" ]; then
    return 0 2>/dev/null || exit 0
fi
ROFI_MENU_LOADED=1

# Canonical back row (two spaces after arrow — match all menus)
MENU_BACK_LABEL="←  Back"

# menu_pick return codes
MENU_RESULT_SELECT=0
MENU_RESULT_BACK=1
MENU_RESULT_CANCEL=2

# Selected row text when MENU_RESULT_SELECT
MENU_CHOICE=""

# Stack of menu IDs (bash 4+ array)
declare -a MENU_STACK=()

menu_stack_reset() {
    MENU_STACK=()
}

menu_stack_push() {
    local id="${1:-}"
    if [ -z "$id" ]; then
        echo "menu_stack_push: empty id" >&2
        return 1
    fi
    MENU_STACK+=("$id")
}

menu_stack_pop() {
    local n=${#MENU_STACK[@]}
    if [ "$n" -eq 0 ]; then
        return 1
    fi
    unset "MENU_STACK[$((n - 1))]"
    # Re-compact (bash sparse arrays after unset)
    MENU_STACK=("${MENU_STACK[@]}")
}

menu_stack_peek() {
    local n=${#MENU_STACK[@]}
    if [ "$n" -eq 0 ]; then
        return 1
    fi
    printf '%s\n' "${MENU_STACK[$((n - 1))]}"
}

menu_stack_depth() {
    printf '%s\n' "${#MENU_STACK[@]}"
}

menu_stack_is_root() {
    [ "${#MENU_STACK[@]}" -le 1 ]
}

# True if the row is the Back control (exact or minor spacing variants)
menu_is_back() {
    local choice="${1:-}"
    [ -z "$choice" ] && return 1
    # Exact canonical label
    [ "$choice" = "$MENU_BACK_LABEL" ] && return 0
    # Tolerate single-space or no-space variants from older menus
    case "$choice" in
        "← Back"|"←Back"|"←  Back"|"⬅  Back"|"⬅ Back") return 0 ;;
    esac
    # Arrow + Back only (avoid matching "Bluetooth", "Background", etc.)
    if [[ "$choice" =~ ^[[:space:]]*←[[:space:]]+Back[[:space:]]*$ ]]; then
        return 0
    fi
    return 1
}

# Normalize option list: accept \n-escaped string or real newlines; trim trailing empties
menu_normalize_options() {
    local raw="$1"
    # Interpret \n sequences if present (legacy call style)
    if [[ "$raw" == *'\n'* ]]; then
        raw=$(printf '%b' "$raw")
    fi
    # Drop empty trailing lines
    printf '%s\n' "$raw" | sed '/^$/d'
}

# Show a rofi dmenu picker.
# Arguments:
#   $1 prompt
#   $2 options (newline or \n separated; do NOT include Back)
#   $3 optional visible lines (default: count of rows)
#   $4 optional width (default: 400)
#
# Sets MENU_CHOICE on select.
# Returns:
#   MENU_RESULT_SELECT (0) — user chose a normal row
#   MENU_RESULT_BACK   (1) — Back row or Escape/empty when not at root
#   MENU_RESULT_CANCEL (2) — Escape/empty at root (exit menu tree)
menu_pick() {
    local prompt="${1:-Menu}"
    local options_raw="${2:-}"
    local lines="${3:-}"
    local width="${4:-400}"

    local options
    options=$(menu_normalize_options "$options_raw")

    local is_root=false
    if menu_stack_is_root; then
        is_root=true
    fi

    if [ "$is_root" = false ]; then
        if [ -n "$options" ]; then
            options="${options}"$'\n'"${MENU_BACK_LABEL}"
        else
            options="${MENU_BACK_LABEL}"
        fi
    fi

    if [ -z "$options" ]; then
        MENU_CHOICE=""
        if [ "$is_root" = true ]; then
            return "$MENU_RESULT_CANCEL"
        fi
        return "$MENU_RESULT_BACK"
    fi

    local count
    count=$(printf '%s\n' "$options" | wc -l)
    if [ -z "$lines" ] || [ "$lines" -lt 1 ] 2>/dev/null; then
        lines=$count
    fi
    # Cap visible lines so tall lists still scroll
    if [ "$lines" -gt 15 ]; then
        lines=15
    fi

    local choice=""
    local rc=0
    # Never let rofi non-zero (Escape) abort the whole script under set -e
    choice=$(printf '%s\n' "$options" | rofi -dmenu -i -p "$prompt" \
        -lines "$lines" -width "$width" -kb-cancel Escape) || rc=$?

    # Escape, empty, or cancel → back or exit depending on stack depth
    if [ -z "$choice" ] || [ "$rc" -ne 0 ]; then
        MENU_CHOICE=""
        if [ "$is_root" = true ]; then
            return "$MENU_RESULT_CANCEL"
        fi
        return "$MENU_RESULT_BACK"
    fi

    if menu_is_back "$choice"; then
        MENU_CHOICE=""
        return "$MENU_RESULT_BACK"
    fi

    MENU_CHOICE="$choice"
    return "$MENU_RESULT_SELECT"
}

# Run the stack loop. Caller provides a function name that:
#   menu_render <id>  → prints two lines? or sets globals?
#
# Simpler: menu_run_loop RENDER_FN HANDLE_FN
#   RENDER_FN id → echoes "TITLE"$'\t'"options with real newlines..."
#   HANDLE_FN id choice → may call menu_stack_push/pop/reset; return 0
#
# Actually keep the loop in system-menu for clarity; library only provides primitives.
export MENU_BACK_LABEL MENU_RESULT_SELECT MENU_RESULT_BACK MENU_RESULT_CANCEL
export -f menu_stack_reset menu_stack_push menu_stack_pop menu_stack_peek \
    menu_stack_depth menu_stack_is_root menu_is_back menu_normalize_options menu_pick \
    2>/dev/null || true
