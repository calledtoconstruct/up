#!/bin/bash
# Shared utility functions for theme scripts
# Source this file: source /path/to/theme-utils.sh

set -euo pipefail

# Guard against multiple sourcing
if [ -n "${THEME_UTILS_LOADED:-}" ]; then
    return 0
fi
THEME_UTILS_LOADED=1

# Config file location
CONFIG_FILE="$HOME/.config/up/config"

# Function to read config values
read_config() {
    local key="$1"
    grep "^[^#]*${key} =" "$CONFIG_FILE" 2>/dev/null | sed 's/.*= *//' | tr -d ' ' || echo ""
}

# Function to apply theme changes if needed
# Returns: true if theme was changed, false otherwise
apply_theme_if_changed() {
    local config_theme="$1"
    local state_file="$2"

    # Read current applied state
    local current_theme=""
    if [ -f "$state_file" ]; then
        current_theme=$(cat "$state_file")
    fi

    # Check if theme needs to be applied (files only — desktop agent reloads UI)
    if [ -n "$config_theme" ] && [ "$config_theme" != "$current_theme" ]; then
        echo "Theme change detected: $current_theme -> $config_theme"
        if UP_DESKTOP_INLINE=1 \
            "$UP_ROOT/configs/scripts/switch-theme.sh" --theme "$config_theme" --no-reload >/dev/null 2>&1; then
            echo "Applied theme files: $config_theme"
            return 0  # true
        else
            echo "Failed to apply theme: $config_theme"
            return 1  # false
        fi
    fi
    return 1  # false, no change needed
}

# Get the themes directory
get_themes_dir() {
    echo "$UP_ROOT/configs/themes"
}

# Get nested theme value from TOML
# Usage: get_theme_nested "theme_name" "section" "key"
get_theme_nested() {
    local theme="$1"
    local section="$2"
    local key="$3"
    local themes_dir="${THEMES_DIR:-$(get_themes_dir)}"
    
    # First try app-specific section
    local value=$(sed -n "/^\[$section\]/,/^\[/p" "$themes_dir/${theme}.toml" 2>/dev/null | grep "^${key} = " | sed 's/.*= *"\?\([^"]*\)"\?/\1/' | tr -d ' ')
    
    # If not found and section is not "colors", try standard [colors] section
    if [ -z "$value" ] && [ "$section" != "colors" ]; then
        value=$(sed -n "/^\[colors\]/,/^\[/p" "$themes_dir/${theme}.toml" 2>/dev/null | grep "^${key} = " | sed 's/.*= *"\?\([^"]*\)"\?/\1/' | tr -d ' ')
    fi
    
    echo "$value"
}

# Unique image paths for a theme (TOML directory, name-matched tree, Arch fallbacks).
# Usage: list_theme_backgrounds "theme_name"
list_theme_backgrounds() {
    local theme="$1"
    local themes_dir="${THEMES_DIR:-$(get_themes_dir)}"
    local up_root="${UP_ROOT:-/usr/local/share/up}"
    local bg_directory base variant dir
    local found

    found=$(
        {
            bg_directory=$(get_theme_nested "$theme" "background" "directory" 2>/dev/null || true)
            if [ -n "$bg_directory" ]; then
                if [[ "$bg_directory" == ../* ]]; then
                    bg_directory="$(dirname "$themes_dir/${theme}.toml")/$bg_directory"
                fi
                if [ -d "$bg_directory" ]; then
                    find "$bg_directory" \( -name "*.jpg" -o -name "*.jpeg" -o -name "*.png" \) 2>/dev/null || true
                fi
            fi

            base="$theme"
            variant=""
            case "$theme" in
                *-light) base="${theme%-light}"; variant=light ;;
                *-dark)  base="${theme%-dark}";  variant=dark ;;
            esac
            for dir in \
                "$up_root/configs/backgrounds/$theme" \
                "$up_root/configs/backgrounds/$base" \
                ${variant:+"$up_root/configs/backgrounds/$base/$variant"}; do
                [ -d "$dir" ] || continue
                find "$dir" \( -name "*.jpg" -o -name "*.jpeg" -o -name "*.png" \) 2>/dev/null || true
            done
        } | while IFS= read -r f; do
            [ -f "$f" ] || continue
            readlink -f "$f" 2>/dev/null || printf '%s\n' "$f"
        done | awk 'NF && !seen[$0]++'
    )

    if [ -z "$found" ] && [ -d /usr/share/backgrounds/archlinux ]; then
        found=$(find /usr/share/backgrounds/archlinux \( -name "*.jpg" -o -name "*.jpeg" -o -name "*.png" \) 2>/dev/null | sort)
    fi
    printf '%s\n' "$found"
}

# True if path is an existing image under this theme's background tree.
# Matches both the vendor copy and a live overlay (e.g. /tmp/upsrc/...).
wallpaper_is_for_theme() {
    local path="$1"
    local theme="$2"
    [ -n "$path" ] && [ -f "$path" ] || return 1
    local canon base
    canon=$(readlink -f "$path" 2>/dev/null || printf '%s' "$path")
    base="$theme"
    case "$theme" in
        *-light) base="${theme%-light}" ;;
        *-dark)  base="${theme%-dark}" ;;
    esac
    case "$canon" in
        */backgrounds/"$theme"/*|*/backgrounds/"$theme") return 0 ;;
        */backgrounds/"$base"/*|*/backgrounds/"$base") return 0 ;;
    esac
    return 1
}

# Apply a wallpaper path (feh + state file + LightDM when writable).
apply_desktop_image() {
    local path="$1"
    if [ ! -f "$path" ]; then
        echo "Error: background not found: $path" >&2
        return 1
    fi
    if command -v feh >/dev/null 2>&1; then
        feh --bg-fill --no-fehbg "$path"
    fi
    mkdir -p "$(dirname "$HOME/.config/up-background")"
    printf '%s\n' "$path" > "$HOME/.config/up-background"
    set_lightdm_background "$path" || true
    # Pre-render login curtain frames (blur/dim) for the next session
    if [ -x "${UP_ROOT}/configs/scripts/session-curtain.sh" ]; then
        "${UP_ROOT}/configs/scripts/session-curtain.sh" prepare "$path" || true
    fi
}

# Find a background image for a theme
# Usage: find_background "theme_name"
# Returns: path to background image or empty string
find_background() {
    local theme="$1"
    local bg_path=""
    local themes_dir="${THEMES_DIR:-$(get_themes_dir)}"

    # Get background config from theme TOML
    local bg_image=$(get_theme_nested "$theme" "background" "image" 2>/dev/null || true)
    local bg_directory=$(get_theme_nested "$theme" "background" "directory" 2>/dev/null || true)
    local bg_fallback=$(get_theme_nested "$theme" "background" "fallback" 2>/dev/null || true)

    # Priority 1: Explicit image path in theme config
    if [ -n "$bg_image" ] && [ -f "$bg_image" ]; then
        echo "$bg_image"
        return
    # Priority 2: User custom background by theme name
    elif [ -f "$HOME/.config/up/backgrounds/${theme}.jpg" ]; then
        echo "$HOME/.config/up/backgrounds/${theme}.jpg"
        return
    elif [ -f "$HOME/.config/up/backgrounds/${theme}.png" ]; then
        echo "$HOME/.config/up/backgrounds/${theme}.png"
        return
    # Priority 3: System backgrounds directory (installed backgrounds)
    elif [ -f "$UP_ROOT/configs/backgrounds/${theme}.jpg" ]; then
        echo "$UP_ROOT/configs/backgrounds/${theme}.jpg"
        return
    elif [ -f "$UP_ROOT/configs/backgrounds/${theme}.png" ]; then
        echo "$UP_ROOT/configs/backgrounds/${theme}.png"
        return
    # Priority 4: Theme-specific wallpaper package directory (resolve relative paths)
    elif [ -n "$bg_directory" ]; then
        # Resolve relative paths from theme file location
        if [[ "$bg_directory" == ../* ]]; then
            # Relative path - resolve from themes directory
            local theme_dir=$(dirname "$themes_dir/${theme}.toml")
            bg_directory="$theme_dir/$bg_directory"
        fi
        if [ -d "$bg_directory" ]; then
            bg_path=$(find "$bg_directory" -maxdepth 1 \( -name "*.jpg" -o -name "*.jpeg" -o -name "*.png" \) 2>/dev/null | head -1)
            if [ -n "$bg_path" ]; then
                echo "$bg_path"
                return
            fi
        fi
    fi

    # Theme trees live at configs/backgrounds/<family>/{dark,light}/ — not
    # backgrounds/<theme>.jpg. list_theme_backgrounds finds those.
    bg_path=$(list_theme_backgrounds "$theme" | head -1)
    if [ -n "$bg_path" ] && [ -f "$bg_path" ]; then
        echo "$bg_path"
        return
    fi

    if [ -f "$HOME/.config/up/backgrounds/default.jpg" ]; then
        echo "$HOME/.config/up/backgrounds/default.jpg"
        return
    fi
    if [ -f "$HOME/.config/up/backgrounds/default.png" ]; then
        echo "$HOME/.config/up/backgrounds/default.png"
        return
    fi
    if [ -n "$bg_fallback" ] && [ -f "$bg_fallback" ]; then
        echo "$bg_fallback"
        return
    fi
    if [ -f "/usr/share/backgrounds/archlinux/mountain.jpg" ]; then
        echo "/usr/share/backgrounds/archlinux/mountain.jpg"
        return
    fi

    echo ""
}

# LightDM GTK greeter only reads /etc/lightdm/lightdm-gtk-greeter.conf
# (not conf.d). Copy a world-readable still so the lightdm user can open it.
GREETER_CONF="/etc/lightdm/lightdm-gtk-greeter.conf"
GREETER_BG_DIR="/usr/share/backgrounds/up"
GREETER_BG_FILE="$GREETER_BG_DIR/current.jpg"

set_lightdm_background() {
    local path="$1"
    [ -n "$path" ] && [ -f "$path" ] || return 0

    local helper=""
    if [ -x /usr/local/bin/up-set-greeter-background ]; then
        helper=/usr/local/bin/up-set-greeter-background
    elif [ -x "${UP_ROOT}/bin/up-set-greeter-background" ]; then
        helper="${UP_ROOT}/bin/up-set-greeter-background"
    fi

    # Prefer the root helper so the greeter file and world-readable copy
    # update even when the session user cannot write /etc/lightdm.
    if [ "$(id -u)" -eq 0 ] && [ -n "$helper" ]; then
        "$helper" "$path" || true
        return 0
    fi
    if [ -n "$helper" ] && command -v sudo >/dev/null 2>&1; then
        if sudo -n "$helper" "$path" >/dev/null 2>&1; then
            return 0
        fi
    fi

    local dest="$path"
    if mkdir -p "$GREETER_BG_DIR" 2>/dev/null && [ -w "$GREETER_BG_DIR" ]; then
        if cp -f "$path" "$GREETER_BG_FILE" 2>/dev/null; then
            chmod 644 "$GREETER_BG_FILE" 2>/dev/null || true
            dest="$GREETER_BG_FILE"
        fi
    fi

    # sed -i needs a writable directory for its tempfile, not just a writable file.
    if [ -f "$GREETER_CONF" ] && [ -w "$GREETER_CONF" ] && [ -w "$(dirname "$GREETER_CONF")" ]; then
        if grep -qE '^[[:space:]]*background[[:space:]]*=' "$GREETER_CONF"; then
            sed -i "s|^[[:space:]]*background[[:space:]]*=.*|background = $dest|" "$GREETER_CONF" || true
        else
            printf '\nbackground = %s\n' "$dest" >>"$GREETER_CONF"
        fi
    fi

    local theme_conf="/etc/lightdm/lightdm-gtk-greeter.conf.d/theme.conf"
    if [ -f "$theme_conf" ] && [ -w "$theme_conf" ] && [ -w "$(dirname "$theme_conf")" ]; then
        sed -i "s|^background = .*|background = $dest|" "$theme_conf" || true
    fi
    return 0
}
