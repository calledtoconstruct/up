#!/bin/bash
# System menu — verb-first like Omarchy's "Go" menu.
# Super+Space
set -euo pipefail

export UP_ROOT="${UP_ROOT:-/usr/local/share/up}"

# shellcheck source=rofi-menu.sh
source "$UP_ROOT/configs/scripts/rofi-menu.sh"
# shellcheck source=menu-addons.sh
source "$UP_ROOT/configs/scripts/menu-addons.sh"
load_menu_addons

resolve_up_cmd() {
    local name="$1"
    if [ -x "$UP_ROOT/bin/$name" ]; then
        printf '%s\n' "$UP_ROOT/bin/$name"
        return 0
    fi
    if [ -x "/usr/local/bin/$name" ]; then
        printf '%s\n' "/usr/local/bin/$name"
        return 0
    fi
    command -v "$name" 2>/dev/null
}

INVOKE_EXTRA=()
UP_MENU_SYNC="${UP_MENU_SYNC:-0}"

run_command() {
    local bin="$1"
    shift || true
    local resolved=""
    case "$bin" in
        up-*|up_*)
            if resolved=$(resolve_up_cmd "$bin"); then
                bin="$resolved"
            else
                if command -v notify-send >/dev/null 2>&1; then
                    notify-send -u critical "System Menu" "Command not found: $bin" 2>/dev/null || true
                fi
                return 1
            fi
            ;;
    esac
    if [ "${UP_MENU_SYNC}" = 1 ]; then
        DISPLAY="${DISPLAY:-:0}" "$bin" "$@"
    else
        DISPLAY="${DISPLAY:-:0}" "$bin" "$@" &
    fi
}

run_in_terminal() {
    local cmd="$1"
    run_command alacritty -e bash -lc "$cmd; echo; read -r -p 'Press Enter to close...'"
}

menu_done() {
    menu_stack_reset
}

menu_title() {
    case "$1" in
        main)      echo "Go" ;;
        learn)     echo "Learn" ;;
        capture)   echo "Capture" ;;
        style)     echo "Style" ;;
        wallpaper) echo "Background" ;;
        setup)     echo "Setup" ;;
        install)   echo "Install" ;;
        session)   echo "Session" ;;
        system)    echo "System" ;;
        *)
            if addon_menu_title "$1"; then
                return 0
            fi
            echo "Menu"
            ;;
    esac
}

menu_options() {
    case "$1" in
        main)
            printf '%s\n' \
                "󰀻  Apps" \
                "󰧑  Learn" \
                "  Capture" \
                "  Style" \
                "  Setup" \
                "󰉉  Install"
            addon_main_items
            printf '%s\n' \
                "  Update" \
                "  Session" \
                "  System"
            ;;
        learn)
            printf '%s\n' \
                "  Keybindings" \
                "📖  Quick Start" \
                "󰋖  Help"
            ;;
        capture)
            printf '%s\n' \
                "  Screenshot" \
                "  Screen Record" \
                "󰃉  Color Picker"
            ;;
        style)
            printf '%s\n' \
                "󰸌  Theme" \
                "  Background" \
                "  Font"
            ;;
        wallpaper)
            printf '%s\n' \
                "🎯  Select" \
                "🎲  Random"
            ;;
        setup)
            printf '%s\n' \
                "  Audio" \
                "  WiFi" \
                "󰂯  Bluetooth" \
                "󱐋  Power Profile" \
                "󰔎  Night Light" \
                "󰍹  Display Scale" \
                "  Idle Lock" \
                "  Ready Sound" \
                "  Login Screen" \
                "👤  Add User" \
                "󰚩  Agent" \
                "󰯃  Crash capture"
            ;;
        install)
            printf '%s\n' \
                "󰣇  Package" \
                "󰣇  AUR"
            addon_install_items
            printf '%s\n' \
                "📝  Tools" \
                "󰆴  Remove package"
            ;;
        session)
            printf '%s\n' \
                "🔄  Reload i3" \
                "🔃  Restart i3" \
                "⬌  Layout Toggle"
            ;;
        system)
            printf '%s\n' \
                "  Lock" \
                "󰍃  Logout" \
                "󰒲  Suspend" \
                "󰜉  Restart" \
                "󰐥  Shutdown"
            ;;
        *)
            addon_menu_options "$1"
            ;;
    esac
}

_run_update() {
    local up_update="${UP_ROOT}/bin/up-update"
    if [ ! -f "$up_update" ]; then
        up_update="/usr/local/bin/up-update"
    fi
    if [ ! -f "$up_update" ]; then
        up_update=$(command -v up-update 2>/dev/null || true)
    fi
    if [ -z "${up_update:-}" ] || [ ! -f "$up_update" ]; then
        run_in_terminal 'echo "up-update not found. Is Up installed at /usr/local/share/up?"'
    else
        run_command alacritty -e bash -lc \
            "echo 'Starting Up system update...'; sudo -E \"$up_update\"; echo; read -r -p 'Press Enter to close...'"
    fi
}

_dex_or() {
    local desktop="$1"
    shift
    if [ -f "$HOME/.local/share/applications/$desktop" ]; then
        run_command dex "$HOME/.local/share/applications/$desktop"
    else
        run_command "$@"
    fi
}

handle_menu_choice() {
    local id="$1"
    local choice="$2"

    case "$id" in
        main)
            case "$choice" in
                *Apps*)     run_command rofi -show drun; menu_done ;;
                *Learn*)    menu_stack_push "learn" ;;
                *Capture*)  menu_stack_push "capture" ;;
                *Style*)    menu_stack_push "style" ;;
                *Setup*)    menu_stack_push "setup" ;;
                *Install*)  menu_stack_push "install" ;;
                *Update*)   _run_update; menu_done ;;
                *Session*)  menu_stack_push "session" ;;
                *System*)   menu_stack_push "system" ;;
                *)
                    addon_handle_choice "$id" "$choice" || true
                    ;;
            esac
            ;;
        learn)
            case "$choice" in
                *Keybindings*) run_command up-show-keybindings; menu_done ;;
                *Quick*Start*) run_command up-quickstart; menu_done ;;
                *Help*)        run_command up-help; menu_done ;;
            esac
            ;;
        capture)
            case "$choice" in
                *Screenshot*)    run_command flameshot gui; menu_done ;;
                *Screen*Record*) run_command up-screen-record; menu_done ;;
                *Color*)         run_command up-color-picker; menu_done ;;
            esac
            ;;
        style)
            case "$choice" in
                *Theme*)      run_command up-switch-theme "${INVOKE_EXTRA[@]}"; menu_done ;;
                *Background*) menu_stack_push "wallpaper" ;;
                *Font*)       run_command up-font-chooser "${INVOKE_EXTRA[@]}"; menu_done ;;
            esac
            ;;
        wallpaper)
            case "$choice" in
                *Select*) run_command up-select-desktop-image "${INVOKE_EXTRA[@]}"; menu_done ;;
                *Random*) run_command up-random-desktop-image "${INVOKE_EXTRA[@]}"; menu_done ;;
            esac
            ;;
        setup)
            case "$choice" in
                *Audio*)          _dex_or audio-controls.desktop pavucontrol; menu_done ;;
                *WiFi*)           _dex_or wifi-controls.desktop nm-connection-editor; menu_done ;;
                *Bluetooth*)      _dex_or bluetooth-controls.desktop blueman-manager; menu_done ;;
                *Power*)          run_command up-power-profile; menu_done ;;
                *Night*)          run_command up-night-light; menu_done ;;
                *Display*)        run_command up-display-scale; menu_done ;;
                *Idle*)           run_command up-idle-lock; menu_done ;;
                *Ready*Sound*)    run_command up-ready-sound; menu_done ;;
                *Login*)          run_command lightdm-gtk-greeter-settings; menu_done ;;
                *Add*User*)       run_command alacritty -e sudo up-add-user; menu_done ;;
                *Agent*)          run_command up-default-agent-pick; menu_done ;;
                *Crash*)          run_in_terminal "up-toggle-crash-capture"; menu_done ;;
            esac
            ;;
        install)
            case "$choice" in
                *Remove*)
                    run_in_terminal "up-pkg-remove"
                    menu_done
                    ;;
                *AUR*)
                    if command -v yay >/dev/null 2>&1; then
                        run_in_terminal "up-pkg-aur-install"
                    else
                        run_in_terminal 'echo "yay is not installed, so AUR install is unavailable."'
                    fi
                    menu_done
                    ;;
                *Tools*)
                    run_command up-install-tools
                    menu_done
                    ;;
                *Package*)
                    run_in_terminal "up-pkg-install"
                    menu_done
                    ;;
                *)
                    addon_handle_choice "$id" "$choice" || true
                    ;;
            esac
            ;;
        session)
            case "$choice" in
                *Reload*)  run_command i3-msg reload; menu_done ;;
                *Restart*) run_command i3-msg restart; menu_done ;;
                *Layout*)  run_command up-layout-toggle "${INVOKE_EXTRA[@]}"; menu_done ;;
            esac
            ;;
        system)
            case "$choice" in
                *Lock*)     run_command i3lock -c 000000; menu_done ;;
                *Logout*)   run_command i3-msg exit; menu_done ;;
                *Suspend*)  run_command systemctl suspend --no-ask-password || run_command sudo -n systemctl suspend; menu_done ;;
                *Restart*)  run_command systemctl reboot --no-ask-password || run_command sudo -n systemctl reboot; menu_done ;;
                *Shutdown*) run_command systemctl poweroff --no-ask-password || run_command sudo -n systemctl poweroff; menu_done ;;
            esac
            ;;
        *)
            addon_handle_choice "$id" "$choice" || true
            ;;
    esac
}

invoke_path() {
    local path="$1"
    local -a parts=()
    local start="main" i=0 id
    # --invoke must wait for leaf commands (wallpaper, theme, shutdown).
    export UP_MENU_SYNC=1

    IFS='/' read -ra parts <<< "$path"
    if [ ${#parts[@]} -eq 0 ] || [ -z "${parts[0]:-}" ]; then
        echo "Error: empty --invoke path" >&2
        return 2
    fi

    if menu_options "${parts[0]}" >/dev/null 2>&1; then
        start="${parts[0]}"
        i=1
    fi

    menu_stack_reset
    menu_stack_push "$start"
    for (( ; i < ${#parts[@]}; i++ )); do
        id=$(menu_stack_peek)
        handle_menu_choice "$id" "${parts[$i]}" || true
    done
    wait || true
}

usage() {
    cat <<'EOF'
Usage: up-system-menu [MENU]
       up-system-menu --invoke PATH [-- ARGS...]

MENU jumps to a submenu (install, style, system, ...).

--invoke walks the same handlers as the rofi menu without opening it.
Trailing ARGS after -- are passed to the leaf command.

Examples:
  up-system-menu --invoke style/Theme -- --theme aetherweft
  up-system-menu --invoke style/Font -- --font "JetBrains Mono"
  up-system-menu --invoke style/Background/Random
  up-system-menu --invoke style/Background/Select -- --image dark/002.jpg
  up-system-menu --invoke system/Shutdown
  up-system-menu --invoke install/Package
EOF
}

main() {
    local start="main"
    local invoke=""

    while [ $# -gt 0 ]; do
        case "$1" in
            --invoke)
                invoke="${2:-}"
                shift 2
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            --)
                shift
                INVOKE_EXTRA=("$@")
                break
                ;;
            *)
                start="$1"
                shift
                ;;
        esac
    done

    if [ -n "$invoke" ]; then
        export UP_MENU_SYNC=1
        invoke_path "$invoke"
        return 0
    fi

    if ! command -v rofi >/dev/null 2>&1; then
        echo "Error: rofi is required for the system menu" >&2
        exit 1
    fi

    menu_stack_reset
    menu_stack_push "$start"

    while [ "$(menu_stack_depth)" -gt 0 ]; do
        local id title options pick_status=0
        id=$(menu_stack_peek)
        title=$(menu_title "$id")
        options=$(menu_options "$id")

        if menu_pick "$title" "$options"; then
            handle_menu_choice "$id" "$MENU_CHOICE" || true
        else
            pick_status=$?
            if [ "$pick_status" -eq "$MENU_RESULT_BACK" ]; then
                menu_stack_pop || true
            else
                break
            fi
        fi
    done
}

main "$@"
