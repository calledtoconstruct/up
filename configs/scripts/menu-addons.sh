#!/bin/bash
# Optional menu fragments from /usr/local/share/up-addons/*/menu.sh
# Sourced by the system menu. Empty directory means no extra items.

if [ -n "${MENU_ADDONS_LOADED:-}" ]; then
    return 0
fi
MENU_ADDONS_LOADED=1

UP_ADDONS_DIR="${UP_ADDONS_DIR:-/usr/local/share/up-addons}"

addon_main_items() { :; }
addon_install_items() { :; }
addon_menu_title() { return 1; }
addon_menu_options() { return 1; }
addon_handle_choice() { return 1; }

load_menu_addons() {
    local f
    [ -d "$UP_ADDONS_DIR" ] || return 0
    for f in "$UP_ADDONS_DIR"/*/menu.sh; do
        [ -f "$f" ] || continue
        # shellcheck source=/dev/null
        source "$f"
    done
}
