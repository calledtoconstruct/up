#!/bin/bash
# Theme Switcher - Uses rofi to pick from the Up theme set
# Applies selected theme to i3, Alacritty, Rofi, picom, tmux, zsh, starship, nvim

set -euo pipefail

# Get script directory and source utilities
SCRIPT_DIR="$UP_ROOT/configs/scripts"
source "$SCRIPT_DIR/theme-utils.sh"

# Set themes directory from shared function
THEMES_DIR=$(get_themes_dir)

# Resolve symlinks in themes directory path
if [ -L "$THEMES_DIR" ]; then
    THEMES_DIR=$(readlink -f "$THEMES_DIR")
fi

# Allow overriding HOME for setup.sh (chroot environment)
# Usage: --home /home/username
HOME_OVERRIDE=""

# Default theme (used during setup)
DEFAULT_THEME="aetherweft"

# Modes:
#   --interactive — rofi theme picker (hotkey / system menu / up-switch-theme)
#   --theme NAME  — apply NAME non-interactively
#   --reapply     — re-apply current theme from config/state (no picker)
#   --no-reload   — write theme files only (desktop-agent handles i3/polybar/picom)
#   (no mode)     — re-apply known theme if set; only open picker when none is known
# Automation and session start must never open the picker. Prefer --reapply/--theme.
REAPPLY=false
WANT_INTERACTIVE=false
TARGET_THEME=""
NO_RELOAD=false

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --theme)
            # Apply specific theme without rofi
            TARGET_THEME="${2:-$DEFAULT_THEME}"
            REAPPLY=false
            WANT_INTERACTIVE=false
            shift 2
            ;;
        --reapply)
            # Re-apply configured/current theme without opening the picker
            REAPPLY=true
            WANT_INTERACTIVE=false
            shift
            ;;
        --interactive)
            # Explicit user request for the rofi picker
            WANT_INTERACTIVE=true
            REAPPLY=false
            shift
            ;;
        --no-reload)
            # Files only; desktop-agent (or caller) performs ordered desktop refresh
            NO_RELOAD=true
            shift
            ;;
        --home)
            # Override HOME directory for writing config files
            HOME_OVERRIDE="$2"
            shift 2
            ;;
        -h|--help)
            cat <<'EOF'
Usage: switch-theme.sh [--interactive | --theme NAME | --reapply] [--no-reload] [--home DIR]

  --interactive Open the rofi theme picker
  --theme NAME  Apply NAME without prompting
  --reapply     Re-apply theme from ~/.config/up/config (or state file)
  --no-reload   Write files only (no i3/polybar restart; use desktop-agent)
  (no mode)     Re-apply known theme if set; picker only when none is known
  --home DIR    Write configs under DIR as HOME
EOF
            exit 0
            ;;
        *)
            shift
            ;;
    esac
done

# Set HOME for config file writes (use override if provided)
if [ -n "$HOME_OVERRIDE" ]; then
    HOME="$HOME_OVERRIDE"
fi

# Read user config (refresh path after possible HOME override)
USER_CONFIG="$HOME/.config/up/config"
CONFIG_FILE="$USER_CONFIG"
FADE=true
BLUR=true
DIM=true
FONT="JetBrains Mono"

if [ -f "$USER_CONFIG" ]; then
    FADE=$(grep "^fade =" "$USER_CONFIG" | sed 's/.*= *//' | tr -d ' ')
    BLUR=$(grep "^blur =" "$USER_CONFIG" | sed 's/.*= *//' | tr -d ' ')
    DIM=$(grep "^dim =" "$USER_CONFIG" | sed 's/.*= *//' | tr -d ' ')
    FONT=$(grep "^font =" "$USER_CONFIG" | sed 's/.*= *//' | sed 's/^"//' | sed 's/"$//')
fi

# Now set STATE_FILE after HOME is finalized
STATE_FILE="$HOME/.config/up-theme"

# Read theme from config file
CONFIG_THEME=$(read_config "theme" | sed 's/^"//' | sed 's/"$//')

# Get current applied theme from state file
CURRENT_THEME=""
if [ -f "$STATE_FILE" ]; then
    CURRENT_THEME=$(tr -d '[:space:]' < "$STATE_FILE")
fi

# Resolve interactive vs non-interactive mode
if [ "$WANT_INTERACTIVE" = true ]; then
    INTERACTIVE=true
elif [ -n "$TARGET_THEME" ]; then
    INTERACTIVE=false
elif [ "$REAPPLY" = true ]; then
    # Prefer config theme, fall back to last applied state
    TARGET_THEME="${CONFIG_THEME:-$CURRENT_THEME}"
    if [ -z "$TARGET_THEME" ]; then
        echo "Error: --reapply requires a theme in $USER_CONFIG or $STATE_FILE" >&2
        exit 1
    fi
    INTERACTIVE=false
elif [ -n "$CONFIG_THEME" ] && [ "$CONFIG_THEME" != "$CURRENT_THEME" ]; then
    # Config was edited to a different theme — apply it without the picker
    echo "Config theme '$CONFIG_THEME' differs from current '$CURRENT_THEME', applying..."
    TARGET_THEME="$CONFIG_THEME"
    INTERACTIVE=false
elif [ -n "${CONFIG_THEME:-$CURRENT_THEME}" ]; then
    # Known theme: re-apply silently. Prevents session/watcher loops from
    # opening the picker when callers omit flags.
    TARGET_THEME="${CONFIG_THEME:-$CURRENT_THEME}"
    INTERACTIVE=false
else
    # No theme configured yet — first-run picker
    INTERACTIVE=true
fi

have_cmd() {
    command -v "$1" >/dev/null 2>&1
}

is_graphical_session() {
    [ -n "${DISPLAY:-}" ]
}

set_gsettings_value() {
    local schema="$1"
    local key="$2"
    local value="$3"

    if is_graphical_session && have_cmd gsettings; then
        gsettings set "$schema" "$key" "$value" 2>/dev/null || true
    fi
}

ensure_xsettingsd_running() {
    if ! is_graphical_session || ! have_cmd xsettingsd; then
        return
    fi

    if ! pgrep -x xsettingsd >/dev/null 2>&1; then
        xsettingsd >/dev/null 2>&1 &
    fi
}

reload_i3_if_running() {
    if is_graphical_session && have_cmd i3-msg; then
        i3-msg reload >/dev/null 2>&1 || true
    fi
}

# Wait until i3 IPC answers — polybar's internal/i3 module stays empty if it
# connects mid-reload (theme/font apply path).
wait_for_i3_ipc() {
    if ! is_graphical_session || ! have_cmd i3-msg; then
        return 0
    fi
    local i
    for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
        if i3-msg -t get_version >/dev/null 2>&1; then
            # Brief settle so workspace list is consistent after reload
            sleep 0.15
            return 0
        fi
        sleep 0.1
    done
    return 0
}

# Get theme color value by key (simple version for single-section keys)
get_theme_color() {
    local theme="$1"
    local key="$2"
    grep "^${key} = " "$THEMES_DIR/${theme}.toml" 2>/dev/null | sed 's/.*= *"\?\([^"]*\)"\?/\1/' | tr -d ' '
}

# Get alacritty color with fallback to standard colors
get_alacritty_color() {
    local theme="$1"
    local subsection="$2"  # "normal" or "bright"
    local key="$3"
    
    # First try alacritty.normal or alacritty.bright section
    local color=$(sed -n "/^\[alacritty.$subsection\]/,/^\[/p" "$THEMES_DIR/${theme}.toml" 2>/dev/null | grep "^${key} = " | sed 's/.*= *"\?\([^"]*\)"\?/\1/' | tr -d ' ')
    
    # Fall back to standard colors section
    if [ -z "$color" ]; then
        color=$(sed -n "/^\[colors\]/,/^\[/p" "$THEMES_DIR/${theme}.toml" 2>/dev/null | grep "^${key} = " | sed 's/.*= *"\?\([^"]*\)"\?/\1/' | tr -d ' ')
    fi
    
    echo "$color"
}

# Apply theme to i3
apply_i3() {
    local theme="$1"
    local bg=$(get_theme_nested "$theme" "i3" "bg")
    local fg=$(get_theme_nested "$theme" "i3" "fg")
    local accent=$(get_theme_nested "$theme" "i3" "accent")
    local urgent=$(get_theme_nested "$theme" "i3" "urgent")

    mkdir -p "$HOME/.config/i3"
    cat > "$HOME/.config/i3/theme.conf" <<EOF
# Theme: $theme
# Variable definitions (used by window colors)
set \$bg     $bg
set \$fg     $fg
set \$accent $accent
set \$urgent $urgent

# Window colors
client.focused          $accent $accent $fg
client.focused_inactive $bg     $bg     $fg
client.unfocused        $bg     $bg     $fg
client.urgent           $urgent $bg     $fg

# Note: Bar is handled by polybar (started via xinitrc or i3 autostart)
EOF
    echo "→ Applied theme to i3"
}

# Apply theme colors/font into polybar config.ini (does not start polybar).
# Process refresh is restart_polybar_once() after i3 reload.
apply_polybar() {
    local theme="$1"
    local bg fg accent urgent font_name config_file stock
    bg=$(get_theme_nested "$theme" "i3" "bg")
    fg=$(get_theme_nested "$theme" "i3" "fg")
    accent=$(get_theme_nested "$theme" "i3" "accent")
    urgent=$(get_theme_nested "$theme" "i3" "urgent")
    # Fall back to [colors] if i3 section omits a key (themes use background/foreground)
    [ -z "$bg" ] && bg=$(get_theme_nested "$theme" "colors" "background")
    [ -z "$fg" ] && fg=$(get_theme_nested "$theme" "colors" "foreground")
    [ -z "$accent" ] && accent=$(get_theme_nested "$theme" "colors" "accent")
    [ -z "$urgent" ] && urgent=$(get_theme_nested "$theme" "colors" "urgent")
    font_name="${FONT:-DejaVu Sans Mono}"
    [ -z "$font_name" ] && font_name="DejaVu Sans Mono"

    mkdir -p "$HOME/.config/polybar"
    config_file="$HOME/.config/polybar/config.ini"
    stock="${UP_ROOT}/configs/polybar/config.ini"

    # Seed stock config if missing so sed has a [colors] section to edit
    if [ ! -f "$config_file" ] && [ -f "$stock" ]; then
        cp -p "$stock" "$config_file" 2>/dev/null || true
    fi

    if [ ! -f "$config_file" ]; then
        echo "→ Warning: polybar config missing at $config_file" >&2
        return 0
    fi

    if [ -z "$bg" ] || [ -z "$fg" ]; then
        echo "→ Warning: theme '$theme' missing polybar/i3 colors" >&2
    else
        # Rewrite [colors] keys reliably (range ends at next [section])
        local tmp
        tmp=$(mktemp)
        awk -v bg="$bg" -v fg="$fg" -v accent="$accent" -v urgent="$urgent" '
            BEGIN { in_colors = 0 }
            /^\[colors\]/ { in_colors = 1; print; next }
            /^\[/ {
                if (in_colors) in_colors = 0
                print
                next
            }
            in_colors && /^[[:space:]]*background[[:space:]]*=/ {
                print "background = " bg
                next
            }
            in_colors && /^[[:space:]]*foreground[[:space:]]*=/ {
                print "foreground = " fg
                next
            }
            in_colors && /^[[:space:]]*accent[[:space:]]*=/ {
                print "accent = " accent
                next
            }
            in_colors && /^[[:space:]]*urgent[[:space:]]*=/ {
                print "urgent = " urgent
                next
            }
            { print }
        ' "$config_file" >"$tmp" && mv "$tmp" "$config_file"
        chmod 644 "$config_file" 2>/dev/null || true
    fi

    # Keep bar text font in sync with ~/.config/up/config font=
    # Escape sed replacement specials in font family names
    local font_esc
    font_esc=$(printf '%s' "$font_name" | sed 's/[&|\\]/\\&/g')
    sed -i "s|^font-0 = .*|font-0 = ${font_esc}:size=10;2|" "$config_file" 2>/dev/null || true

    # Heal workspace module settings that make tabs disappear (older installs)
    if grep -q '^\[module/i3\]' "$config_file" 2>/dev/null; then
        sed -i 's/^pin-workspaces = .*/pin-workspaces = false/' "$config_file" 2>/dev/null || true
        sed -i 's/^strip-wsnumbers = .*/strip-wsnumbers = false/' "$config_file" 2>/dev/null || true
        if ! grep -q '^index-sort' "$config_file" 2>/dev/null; then
            sed -i '/^\[module\/i3\]/a index-sort = true' "$config_file" 2>/dev/null || true
        fi
        if ! grep -qE '^format = .*label-state' "$config_file" 2>/dev/null; then
            sed -i '/^\[module\/i3\]/a format = <label-state> <label-mode>' "$config_file" 2>/dev/null || true
        fi
        # Ensure modules-left still includes i3
        if grep -qE '^modules-left\s*=' "$config_file" 2>/dev/null; then
            if ! grep -qE '^modules-left\s*=.*\bi3\b' "$config_file" 2>/dev/null; then
                sed -i 's/^modules-left = \(.*\)/modules-left = \1 i3/' "$config_file" 2>/dev/null || true
                sed -i 's/^modules-left =  */modules-left = /' "$config_file" 2>/dev/null || true
            fi
        fi
    fi

    # Ensure launch.sh is the current serialized version (theme apply needs full re-exec)
    if [ -f "${UP_ROOT}/configs/polybar/launch.sh" ]; then
        cp -p "${UP_ROOT}/configs/polybar/launch.sh" "$HOME/.config/polybar/launch.sh" 2>/dev/null || true
        chmod +x "$HOME/.config/polybar/launch.sh" 2>/dev/null || true
    fi

    echo "→ Applied theme to polybar config (bg=$bg fg=$fg)"
}

# Kill+start a single polybar so it re-reads config.ini (colors/font).
# launch.sh uses flock so concurrent i3 exec_always cannot leave two bars.
restart_polybar_once() {
    if ! is_graphical_session; then
        return 0
    fi
    local launcher=""
    # Prefer tree copy so post-update fixes apply without waiting for full refresh
    if [ -x "$UP_ROOT/configs/polybar/launch.sh" ]; then
        launcher="$UP_ROOT/configs/polybar/launch.sh"
    elif [ -x "$HOME/.config/polybar/launch.sh" ]; then
        launcher="$HOME/.config/polybar/launch.sh"
    fi
    if [ -n "$launcher" ]; then
        UP_POLYBAR_QUICK=1 \
            DISPLAY="${DISPLAY:-:0}" "$launcher" \
            >>"${XDG_RUNTIME_DIR:-/tmp}/polybar-${UID:-$(id -u)}.log" 2>&1 || true
    fi
}

# Apply theme to picom (picom v12+ options; included via @include "theme.conf")
apply_picom() {
    local theme="$1"
    local shadow=$(get_theme_nested "$theme" "picom" "shadow")
    local alpha=$(get_theme_nested "$theme" "picom" "shadow_alpha")

    # Sensible defaults when theme omits picom keys
    [ -z "$shadow" ] && shadow="#000000"
    [ -z "$alpha" ] && alpha="0.3"

    mkdir -p "$HOME/.config/picom"
    cat > "$HOME/.config/picom/theme.conf" <<EOF
# Theme: $theme (auto-generated by switch-theme.sh — do not edit)
# picom v12+ fragment; scalar options here override configs/picom/config
shadow = true;
shadow-color = "$shadow";
shadow-opacity = $alpha;
EOF

    # Fade: toggle full fading, not only open/close
    if [ "$FADE" = "true" ]; then
        cat >> "$HOME/.config/picom/theme.conf" <<EOF
fading = true;
fade-in-step = 0.028;
fade-out-step = 0.03;
no-fading-openclose = false;
EOF
    else
        cat >> "$HOME/.config/picom/theme.conf" <<EOF
fading = false;
no-fading-openclose = true;
EOF
    fi

    # Blur: dual_kawase needs glx (set in main config). Strength range is 0-20.
    # gaussian also needs glx; do not pair either with backend = "xrender".
    if [ "$BLUR" = "true" ]; then
        cat >> "$HOME/.config/picom/theme.conf" <<EOF
blur: {
    method = "dual_kawase";
    strength = 4;
};
blur-background = true;
EOF
    else
        cat >> "$HOME/.config/picom/theme.conf" <<EOF
blur: {
    method = "none";
};
blur-background = false;
EOF
    fi

    # Dim: picom v12+ ignores global inactive-dim when `rules` is set (and
    # warns). Write the packaged rules with dim on the unfocused window.
    local dim_val="0.15"
    if [ "$DIM" != "true" ]; then
        dim_val="0.0"
    fi
    local rules_src="$UP_ROOT/configs/picom/rules.conf"
    local rules_dst="$HOME/.config/picom/rules.conf"
    if [ -f "$rules_src" ]; then
        sed -E "s/^([[:space:]]*dim = )[0-9.]+;[[:space:]]*# up-inactive-dim/\\1${dim_val};  # up-inactive-dim/" \
            "$rules_src" >"$rules_dst"
    fi

    echo "→ Applied theme to picom"
}

# Apply theme to Rofi
apply_rofi() {
    local theme="$1"
    
    # Get colors from rofi section, falling back to [colors] via get_theme_nested
    local bg=$(get_theme_nested "$theme" "rofi" "background")
    local fg=$(get_theme_nested "$theme" "rofi" "foreground")
    local selected=$(get_theme_nested "$theme" "rofi" "selected")
    local urgent=$(get_theme_nested "$theme" "rofi" "urgent")
    local alternate=$(get_theme_nested "$theme" "rofi" "alternate")
    local hover=$(get_theme_nested "$theme" "rofi" "hover")
    local active=$(get_theme_nested "$theme" "rofi" "active")
    local border=$(get_theme_nested "$theme" "rofi" "border")
    local accent=$(get_theme_nested "$theme" "colors" "accent")
    local transparent=$(get_theme_nested "$theme" "rofi" "transparent")

    # Also try standard [colors] keys when rofi section is incomplete
    [ -z "$bg" ] && bg=$(get_theme_nested "$theme" "colors" "background")
    [ -z "$fg" ] && fg=$(get_theme_nested "$theme" "colors" "foreground")
    [ -z "$alternate" ] && alternate=$(get_theme_nested "$theme" "colors" "alternate")
    [ -z "$urgent" ] && urgent=$(get_theme_nested "$theme" "colors" "urgent")
    [ -z "$hover" ] && hover=$(get_theme_nested "$theme" "colors" "hover")
    [ -z "$active" ] && active=$(get_theme_nested "$theme" "colors" "active")

    # Hard defaults so theme.rasi never contains empty color tokens (parse errors)
    bg=${bg:-"#1e1e2e"}
    fg=${fg:-"#cdd6f4"}
    accent=${accent:-"#89b4fa"}
    alternate=${alternate:-"#313244"}
    selected=${selected:-$accent}
    urgent=${urgent:-"#f38ba8"}
    hover=${hover:-$alternate}
    active=${active:-$accent}
    border=${border:-$selected}
    transparent=${transparent:-"rgba(0, 0, 0, 0.5)"}

    local font_name="${FONT:-DejaVu Sans Mono}"
    # Rasi is picky: empty font breaks the theme load
    [ -z "$font_name" ] && font_name="DejaVu Sans Mono"

    mkdir -p "$HOME/.config/rofi"
    # Ensure config.rasi points at same-dir theme (fix broken path on update)
    if [ -f "$HOME/.config/rofi/config.rasi" ] && \
       grep -qE '@theme[[:space:]]+"\.config/rofi/theme\.rasi"' "$HOME/.config/rofi/config.rasi" 2>/dev/null; then
        sed -i 's|@theme[[:space:]]*"\.config/rofi/theme\.rasi"|@theme "theme.rasi"|' \
            "$HOME/.config/rofi/config.rasi" 2>/dev/null || true
    fi

    cat > "$HOME/.config/rofi/theme.rasi" <<EOF
/* Theme: $theme */
/* Generated by switch-theme.sh — loaded via @theme "theme.rasi" in config.rasi */

* {
    font:   "$font_name 10";

    // Color palette from theme
    bg0:     $bg;
    bg1:     $alternate;
    fg0:     $fg;

    accent-color:  $active;
    urgent-color:  $urgent;
    selected-color: $selected;

    background-color:   transparent;
    text-color:         $fg;

    margin:     0;
    padding:    0;
    spacing:    0;
}

window {
    location:   center;
    width:      480px;
    transparency: "real";
    padding:    10px;

    background-color:   $bg;
    border-color:       $border;
    border:             2px;
}

inputbar {
    spacing:    2px;
    padding:    2px;

    background-color:   $alternate;
    children:   [ prompt, entry ];
}

prompt, entry, element-icon, element-text {
    vertical-align: 0.5;
}

prompt {
    text-color: $active;
}

entry {
    text-color: $fg;
    placeholder-color: $alternate;
}

textbox {
    padding:            8px;
    background-color:   $alternate;
}

listview {
    padding:    2px 0;
    lines:      10;
    columns:    1;

    fixed-height:   false;
}

element {
    padding:    4px;
    spacing:    4px;
}

element normal normal {
    text-color: $fg;
}

element normal urgent {
    text-color: $urgent;
}

element normal active {
    text-color: $active;
}

element alternate active {
    text-color: $active;
}

element selected {
    text-color: $bg;
}

element selected normal, element selected active {
    background-color:   $selected;
}

element selected urgent {
    background-color:   $urgent;
}

element-icon {
    size:   0.8em;
}

element-text {
    text-color: inherit;
}
EOF
    echo "→ Applied theme to Rofi"
}

# Apply theme to Alacritty
apply_alacritty() {
    local theme="$1"
    local bg=$(get_theme_nested "$theme" "alacritty" "primary_bg")
    local fg=$(get_theme_nested "$theme" "alacritty" "primary_fg")
    local cursor=$(get_theme_nested "$theme" "alacritty" "cursor")
    local n_black=$(get_alacritty_color "$theme" "normal" "black")
    local n_red=$(get_alacritty_color "$theme" "normal" "red")
    local n_green=$(get_alacritty_color "$theme" "normal" "green")
    local n_yellow=$(get_alacritty_color "$theme" "normal" "yellow")
    local n_blue=$(get_alacritty_color "$theme" "normal" "blue")
    local n_magenta=$(get_alacritty_color "$theme" "normal" "magenta")
    local n_cyan=$(get_alacritty_color "$theme" "normal" "cyan")
    local n_white=$(get_alacritty_color "$theme" "normal" "white")
    local b_black=$(get_alacritty_color "$theme" "bright" "black")
    local b_red=$(get_alacritty_color "$theme" "bright" "red")
    local b_green=$(get_alacritty_color "$theme" "bright" "green")
    local b_yellow=$(get_alacritty_color "$theme" "bright" "yellow")
    local b_blue=$(get_alacritty_color "$theme" "bright" "blue")
    local b_magenta=$(get_alacritty_color "$theme" "bright" "magenta")
    local b_cyan=$(get_alacritty_color "$theme" "bright" "cyan")
    local b_white=$(get_alacritty_color "$theme" "bright" "white")

    mkdir -p "$HOME/.config/alacritty"
    
    # Check if config exists, if not create from default
    if [ ! -f "$HOME/.config/alacritty/alacritty.toml" ]; then
        cp "$UP_ROOT/configs/alacritty/alacritty.toml" "$HOME/.config/alacritty/alacritty.toml" 2>/dev/null || true
    fi

    local alacritty_config="$HOME/.config/alacritty/alacritty.toml"

    # Update font family
    sed -i "s/font.family = .*/font.family = \"$FONT\"/" "$alacritty_config" 2>/dev/null || true
    
    # Create or update the theme section with proper markers
    if grep -q "# ===== THEME COLORS" "$alacritty_config" 2>/dev/null; then
        # Replace existing theme section
        sed -i "/# ===== THEME COLORS =====/,/# ===== END THEME COLORS =====/c\\
# ===== THEME COLORS =====\\
# Auto-generated by switch-theme.sh\\
\\
[colors]\\
primary.background = \"$bg\"\\
primary.foreground = \"$fg\"\\
\\
[colors.cursor]\\
text   = \"$cursor\"\\
cursor = \"$cursor\"\\
\\
[colors.normal]\\
black   = \"$n_black\"\\
red     = \"$n_red\"\\
green   = \"$n_green\"\\
yellow  = \"$n_yellow\"\\
blue    = \"$n_blue\"\\
magenta = \"$n_magenta\"\\
cyan    = \"$n_cyan\"\\
white   = \"$n_white\"\\
\\
[colors.bright]\\
black   = \"$b_black\"\\
red     = \"$b_red\"\\
green   = \"$b_green\"\\
yellow  = \"$b_yellow\"\\
blue    = \"$b_blue\"\\
magenta = \"$b_magenta\"\\
cyan    = \"$b_cyan\"\\
white   = \"$b_white\"\\
\\
# ===== END THEME COLORS =====" "$alacritty_config"
    else
        # Append theme section
        cat >> "$alacritty_config" <<EOF

# ===== THEME COLORS =====
# Auto-generated by switch-theme.sh

[colors]
primary.background = "$bg"
primary.foreground = "$fg"

[colors.cursor]
text   = "$cursor"
cursor = "$cursor"

[colors.normal]
black   = "$n_black"
red     = "$n_red"
green   = "$n_green"
yellow  = "$n_yellow"
blue    = "$n_blue"
magenta = "$n_magenta"
cyan    = "$n_cyan"
white   = "$n_white"

[colors.bright]
black   = "$b_black"
red     = "$b_red"
green   = "$b_green"
yellow  = "$b_yellow"
blue    = "$b_blue"
magenta = "$b_magenta"
cyan    = "$b_cyan"
white   = "$b_white"

# ===== END THEME COLORS =====
EOF
    fi
    
    echo "→ Applied theme to Alacritty"
}

# Apply theme to tmux
apply_tmux() {
    local theme="$1"
    local bg=$(get_theme_nested "$theme" "i3" "bg")
    local fg=$(get_theme_nested "$theme" "i3" "fg")
    local accent=$(get_theme_nested "$theme" "i3" "accent")
    local urgent=$(get_theme_nested "$theme" "i3" "urgent")

    mkdir -p "$HOME/.config/tmux"
    cat > "$HOME/.config/tmux/theme.conf" <<EOF
# Theme: $theme
set -g status-bg $bg
set -g status-fg $fg
set -g window-status-current-style bg=$accent,fg=$fg
set -g pane-border-style fg=$bg
set -g pane-active-border-style fg=$accent
EOF
    echo "→ Applied theme to tmux"
}

# Apply theme to zsh
apply_zsh() {
    local theme="$1"
    local bg=$(get_theme_nested "$theme" "colors" "background")
    local fg=$(get_theme_nested "$theme" "colors" "foreground")
    local accent=$(get_theme_nested "$theme" "colors" "accent")

    mkdir -p "$HOME/.config/zsh"
    cat > "$HOME/.config/zsh/theme.zsh" <<EOF
# Theme: $theme
export PROMPT_BG="$bg"
export PROMPT_FG="$fg"
export PROMPT_ACCENT="$accent"
EOF
    echo "→ Applied theme to zsh"
}

# Apply theme to starship
apply_starship() {
    local theme="$1"
    # Get colors from starship section, falls back to [colors] automatically
    local accent=$(get_theme_nested "$theme" "starship" "accent")
    local fg=$(get_theme_nested "$theme" "starship" "foreground")
    local bg=$(get_theme_nested "$theme" "starship" "background")
    local urgent=$(get_theme_nested "$theme" "starship" "urgent")

    # Only update the theme values in the user's starship config, preserving the rest
    # This is done by replacing the comment-bounded section
    mkdir -p "$HOME/.config"
    
    # Check if config exists, if not create from default
    if [ ! -f "$HOME/.config/starship.toml" ]; then
        cp "$UP_ROOT/configs/starship.toml" "$HOME/.config/starship.toml" 2>/dev/null || true
    fi
    
    # Use sed to replace just the theme values between markers
    local starship_config="$HOME/.config/starship.toml"
    
    # Create or update the theme section with proper markers
    if grep -q "# ===== THEME COLORS" "$starship_config" 2>/dev/null; then
        # Replace existing theme section
        sed -i "/# ===== THEME COLORS =====/,/# ===== END THEME COLORS =====/c\\
# ===== THEME COLORS =====\\
# Auto-generated by switch-theme.sh\\
\\
[character]\\
success_symbol = \"[➜]($accent)\"\\
error_symbol = \"[✗]($urgent)\"\\
\\
[directory]\\
style = \"bold $accent\"\\
\\
[git_branch]\\
style = \"bold $accent\"\\
\\
# ===== END THEME COLORS =====" "$starship_config"
    else
        # Append theme section
        cat >> "$starship_config" <<EOF

# ===== THEME COLORS =====
# Auto-generated by switch-theme.sh

[character]
success_symbol = "[➜]($accent)"
error_symbol = "[✗]($urgent)"

[directory]
style = "bold $accent"

[git_branch]
style = "bold $accent"

# ===== END THEME COLORS =====
EOF
    fi
    
    echo "→ Applied theme to starship"
}

# Get btop color with smart fallback to standard colors
get_btop_color() {
    local theme="$1"
    local btop_key="$2"
    local fallback_key="$3"
    
    # First check [btop] section for explicit override
    local color=$(get_theme_nested "$theme" "btop" "$btop_key")
    
    # If not found, fall back to standard [colors]
    if [ -z "$color" ]; then
        color=$(get_theme_nested "$theme" "colors" "$fallback_key")
    fi
    
    echo "$color"
}

# Apply theme to btop
apply_btop() {
    local theme="$1"
    
    # Get base colors from [colors] section
    local bg=$(get_theme_nested "$theme" "colors" "background")
    local fg=$(get_theme_nested "$theme" "colors" "foreground")
    local alternate=$(get_theme_nested "$theme" "colors" "alternate")
    local accent=$(get_theme_nested "$theme" "colors" "accent")
    local red=$(get_theme_nested "$theme" "colors" "red")
    local green=$(get_theme_nested "$theme" "colors" "green")
    local yellow=$(get_theme_nested "$theme" "colors" "yellow")
    local blue=$(get_theme_nested "$theme" "colors" "blue")
    local cyan=$(get_theme_nested "$theme" "colors" "cyan")
    local magenta=$(get_theme_nested "$theme" "colors" "magenta")
    local bright_black=$(get_theme_nested "$theme" "colors" "bright_black")
    
    # Set sensible defaults
    bg=${bg:-"#1E1E2E"}
    fg=${fg:-"#CDD6F4"}
    alternate=${alternate:-"#313244"}
    accent=${accent:-"#89B4FA"}
    red=${red:-"#F38BA8"}
    green=${green:-"#A6E3A1"}
    yellow=${yellow:-"#F9E2AF"}
    blue=${blue:-"#89B4FA"}
    cyan=${cyan:-"#94E2D5"}
    magenta=${magenta:-"#F5C2E7"}
    bright_black=${bright_black:-"#45475A"}
    
    # Create btop config directory and themes subdirectory
    mkdir -p "$HOME/.config/btop/themes"
    
    # Remove any existing theme files in the themes directory
    rm -f "$HOME/.config/btop/themes/"*.theme
    
    # Write theme file with CORRECT btop theme key names
    {
        echo "# btop theme: $theme"
        echo "# Auto-generated by switch-theme.sh"
        echo ""
        echo "# Main colors"
        echo "theme[main_bg]=\"${bg}\""
        echo "theme[main_fg]=\"${fg}\""
        echo "theme[title]=\"${accent}\""
        echo "theme[hi_fg]=\"${red}\""
        echo "theme[selected_bg]=\"${accent}\""
        echo "theme[selected_fg]=\"${bg}\""
        echo "theme[inactive_fg]=\"${bright_black}\""
        echo "theme[graph_text]=\"${fg}\""
        echo "theme[proc_misc]=\"${green}\""
        
        echo ""
        echo "# Box outline colors"
        echo "theme[cpu_box]=\"${bright_black}\""
        echo "theme[mem_box]=\"${bright_black}\""
        echo "theme[net_box]=\"${bright_black}\""
        echo "theme[proc_box]=\"${bright_black}\""
        echo "theme[div_line]=\"${bright_black}\""
        
        echo ""
        echo "# Temperature gradient (low -> mid -> high)"
        echo "theme[temp_start]=\"${green}\""
        echo "theme[temp_mid]=\"${yellow}\""
        echo "theme[temp_end]=\"${red}\""
        
        echo ""
        echo "# CPU graph gradient"
        echo "theme[cpu_start]=\"${green}\""
        echo "theme[cpu_mid]=\"${yellow}\""
        echo "theme[cpu_end]=\"${red}\""
        
        echo ""
        echo "# Memory free gradient"
        echo "theme[free_start]=\"${red}\""
        echo "theme[free_mid]=\"${yellow}\""
        echo "theme[free_end]=\"${green}\""
        
        echo ""
        echo "# Memory cached gradient"
        echo "theme[cached_start]=\"${cyan}\""
        echo "theme[cached_mid]=\"${blue}\""
        echo "theme[cached_end]=\"${green}\""
        
        echo ""
        echo "# Memory available gradient"
        echo "theme[available_start]=\"${red}\""
        echo "theme[available_mid]=\"${yellow}\""
        echo "theme[available_end]=\"${green}\""
        
        echo ""
        echo "# Memory used gradient"
        echo "theme[used_start]=\"${green}\""
        echo "theme[used_mid]=\"${yellow}\""
        echo "theme[used_end]=\"${red}\""
        
        echo ""
        echo "# Network download gradient"
        echo "theme[download_start]=\"${green}\""
        echo "theme[download_mid]=\"${cyan}\""
        echo "theme[download_end]=\"${blue}\""
        
        echo ""
        echo "# Network upload gradient"
        echo "theme[upload_start]=\"${red}\""
        echo "theme[upload_mid]=\"${yellow}\""
        echo "theme[upload_end]=\"${green}\""
        
        echo ""
        echo "# Process gradient"
        echo "theme[process_start]=\"${green}\""
        echo "theme[process_mid]=\"${red}\""
        echo "theme[process_end]=\"${red}\""
        
    } > "$HOME/.config/btop/themes/${theme}.theme"

    # Update main btop config - completely rewrite to ensure clean state
    mkdir -p "$HOME/.config/btop"
    cat > "$HOME/.config/btop/btop.conf" <<EOF
# btop config
# Auto-generated by switch-theme.sh
color_theme = "$theme"
EOF
    
    # Signal btop to reload config
    pkill -SIGUSR2 btop 2>/dev/null || true
    
    echo "→ Applied theme to btop"
}

# Apply theme to htop
# Note: htop uses terminal colors from environment, so we just set basic preferences
apply_htop() {
    local theme="$1"
    
    mkdir -p "$HOME/.config/htop"
    
    # htop uses terminal colors, so we just configure basic settings
    # Color schemes are set via the 'color_scheme' setting (0-6 are built-in)
    cat > "$HOME/.config/htop/htoprc" <<EOF
# Theme: $theme
# Auto-generated by switch-theme.sh
# Note: htop uses terminal colors for theming

# Settings
fields=0 48 17 18 38 39 40 2 46 47 49 1
sort_key=46
sort_direction=1
hide_threads=0
hide_kernel_threads=1
hide_userland_threads=0
shadow_other_users=0
show_thread_names=0
show_program_path=1
highlight_base_name=0
highlight_megabytes=1
highlight_threads=1
tree_view=0
header_margin=1
detailed_cpu_time=0
cpu_count_from_zero=0
update_process_names=0
account_guest_in_cpu_meter=0
color_scheme=0
delay=15
left_meters=LeftCPUs2 Memory Swap
left_meter_modes=1 1 1
right_meters=RightCPUs2 Tasks LoadAverage Uptime
right_meter_modes=1 2 2 2
EOF
    echo "→ Applied theme to htop"
}

# Apply theme to nvim
apply_nvim() {
    local theme="$1"
    local nvim_colorscheme=$(get_theme_nested "$theme" "nvim" "colorscheme")

    local options_file="$HOME/.config/nvim/lua/config/options.lua"
    local theme_file="$HOME/.config/nvim/lua/config/theme.lua"

    # Ensure config directory exists
    mkdir -p "$HOME/.config/nvim/lua/config"

    # Ensure options file exists and has theme require
    if [ ! -f "$options_file" ]; then
        cat > "$options_file" <<'OPTS_EOF'
-- LazyVim options override for our XLibre i3 setup
vim.opt.relativenumber = true
vim.opt.tabstop = 2
vim.opt.shiftwidth = 2
vim.g.mapleader = " "

-- Load theme configuration
require("config.theme")
OPTS_EOF
    else
        # Ensure options.lua requires the theme file
        if ! grep -q 'require("config.theme")' "$options_file" 2>/dev/null; then
            echo "" >> "$options_file"
            echo "-- Load theme configuration" >> "$options_file"
            echo 'require("config.theme")' >> "$options_file"
        fi
    fi

    # Create theme commands in separate theme.lua file
    if [ "$nvim_colorscheme" = "custom" ]; then
        # For custom themes, create a full colorscheme file
        # Uses direct highlight setting (no function wrapper) for reliable Neovim 0.9+ loading
        local colors_dir="$HOME/.local/share/nvim/site/colors"
        mkdir -p "$colors_dir"

        local bg=$(get_theme_nested "$theme" "colors" "background")
        local fg=$(get_theme_nested "$theme" "colors" "foreground")
        local accent=$(get_theme_nested "$theme" "colors" "accent")
        local urgent=$(get_theme_nested "$theme" "colors" "urgent")
        local alternate=$(get_theme_nested "$theme" "colors" "alternate")
        local red=$(get_theme_nested "$theme" "colors" "red")
        local green=$(get_theme_nested "$theme" "colors" "green")
        local yellow=$(get_theme_nested "$theme" "colors" "yellow")
        local blue=$(get_theme_nested "$theme" "colors" "blue")
        local magenta=$(get_theme_nested "$theme" "colors" "magenta")
        local cyan=$(get_theme_nested "$theme" "colors" "cyan")
        local white=$(get_theme_nested "$theme" "colors" "white")
        local bright_black=$(get_theme_nested "$theme" "colors" "bright_black")
        local bright_white=$(get_theme_nested "$theme" "colors" "bright_white")
        local bright_red=$(get_theme_nested "$theme" "colors" "bright_red")
        local bright_green=$(get_theme_nested "$theme" "colors" "bright_green")
        local bright_yellow=$(get_theme_nested "$theme" "colors" "bright_yellow")
        local bright_blue=$(get_theme_nested "$theme" "colors" "bright_blue")
        local bright_magenta=$(get_theme_nested "$theme" "colors" "bright_magenta")
        local bright_cyan=$(get_theme_nested "$theme" "colors" "bright_cyan")
        local black=$(get_theme_nested "$theme" "colors" "black")

        cat > "$colors_dir/${theme}.lua" <<COLORSCHEME_EOF
-- Custom colorscheme: $theme
-- Auto-generated by switch-theme.sh
-- Uses direct highlight setting for reliable Neovim 0.9+ compatibility

-- Clean slate
vim.cmd.hi 'clear'
if vim.fn.exists('syntax_on') then
  vim.cmd.syntax 'reset'
end
vim.o.background = 'dark'
vim.g.colors_name = '${theme}'

-- Set highlights directly (no function wrapper needed)
vim.api.nvim_set_hl(0, 'Normal', { bg = '${bg}', fg = '${fg}' })
vim.api.nvim_set_hl(0, 'NormalFloat', { bg = '${bg}', fg = '${fg}' })
vim.api.nvim_set_hl(0, 'NormalNC', { bg = '${bg}', fg = '${fg}' })
vim.api.nvim_set_hl(0, 'Comment', { fg = '${bright_black}', italic = true })
vim.api.nvim_set_hl(0, 'Constant', { fg = '${accent}' })
vim.api.nvim_set_hl(0, 'String', { fg = '${green}' })
vim.api.nvim_set_hl(0, 'Character', { fg = '${green}' })
vim.api.nvim_set_hl(0, 'Number', { fg = '${yellow}' })
vim.api.nvim_set_hl(0, 'Boolean', { fg = '${accent}' })
vim.api.nvim_set_hl(0, 'Float', { fg = '${yellow}' })
vim.api.nvim_set_hl(0, 'Function', { fg = '${accent}' })
vim.api.nvim_set_hl(0, 'Identifier', { fg = '${fg}' })
vim.api.nvim_set_hl(0, 'Statement', { fg = '${urgent}' })
vim.api.nvim_set_hl(0, 'Conditional', { fg = '${urgent}' })
vim.api.nvim_set_hl(0, 'Repeat', { fg = '${urgent}' })
vim.api.nvim_set_hl(0, 'Label', { fg = '${accent}' })
vim.api.nvim_set_hl(0, 'Operator', { fg = '${fg}' })
vim.api.nvim_set_hl(0, 'Keyword', { fg = '${urgent}' })
vim.api.nvim_set_hl(0, 'Exception', { fg = '${urgent}' })
vim.api.nvim_set_hl(0, 'PreProc', { fg = '${urgent}' })
vim.api.nvim_set_hl(0, 'Include', { fg = '${urgent}' })
vim.api.nvim_set_hl(0, 'Define', { fg = '${urgent}' })
vim.api.nvim_set_hl(0, 'Macro', { fg = '${urgent}' })
vim.api.nvim_set_hl(0, 'PreCondit', { fg = '${urgent}' })
vim.api.nvim_set_hl(0, 'Type', { fg = '${accent}' })
vim.api.nvim_set_hl(0, 'StorageClass', { fg = '${accent}' })
vim.api.nvim_set_hl(0, 'Structure', { fg = '${accent}' })
vim.api.nvim_set_hl(0, 'Typedef', { fg = '${accent}' })
vim.api.nvim_set_hl(0, 'Special', { fg = '${accent}' })
vim.api.nvim_set_hl(0, 'SpecialChar', { fg = '${accent}' })
vim.api.nvim_set_hl(0, 'Tag', { fg = '${accent}' })
vim.api.nvim_set_hl(0, 'Delimiter', { fg = '${fg}' })
vim.api.nvim_set_hl(0, 'SpecialComment', { fg = '${alternate}', italic = true })
vim.api.nvim_set_hl(0, 'Debug', { fg = '${accent}' })
vim.api.nvim_set_hl(0, 'Underlined', { underline = true })
vim.api.nvim_set_hl(0, 'Ignore', { fg = '${bright_black}' })
vim.api.nvim_set_hl(0, 'Error', { fg = '${urgent}' })
vim.api.nvim_set_hl(0, 'Todo', { fg = '${urgent}', bold = true })

-- Terminal colors
vim.g.terminal_color_0 = '${black}'
vim.g.terminal_color_1 = '${red}'
vim.g.terminal_color_2 = '${green}'
vim.g.terminal_color_3 = '${yellow}'
vim.g.terminal_color_4 = '${blue}'
vim.g.terminal_color_5 = '${magenta}'
vim.g.terminal_color_6 = '${cyan}'
vim.g.terminal_color_7 = '${white}'
vim.g.terminal_color_8 = '${bright_black}'
vim.g.terminal_color_9 = '${bright_red}'
vim.g.terminal_color_10 = '${bright_green}'
vim.g.terminal_color_11 = '${bright_yellow}'
vim.g.terminal_color_12 = '${bright_blue}'
vim.g.terminal_color_13 = '${bright_magenta}'
vim.g.terminal_color_14 = '${bright_cyan}'
vim.g.terminal_color_15 = '${bright_white}'

-- UI elements
vim.api.nvim_set_hl(0, 'CursorLine', { bg = '${alternate}' })
vim.api.nvim_set_hl(0, 'CursorLineNr', { fg = '${fg}' })
vim.api.nvim_set_hl(0, 'LineNr', { fg = '${alternate}' })
vim.api.nvim_set_hl(0, 'SignColumn', { bg = nil })
vim.api.nvim_set_hl(0, 'Visual', { bg = '${accent}', fg = '${bg}' })
vim.api.nvim_set_hl(0, 'Search', { bg = '${accent}', fg = '${bg}' })
vim.api.nvim_set_hl(0, 'IncSearch', { bg = '${urgent}', fg = '${bg}' })
vim.api.nvim_set_hl(0, 'VisualNOS', { bg = '${accent}', fg = '${bg}' })
vim.api.nvim_set_hl(0, 'StatusLine', { bg = '${alternate}', fg = '${fg}' })
vim.api.nvim_set_hl(0, 'StatusLineNC', { bg = '${alternate}', fg = '${bright_black}' })
vim.api.nvim_set_hl(0, 'VertSplit', { bg = '${alternate}', fg = '${alternate}' })
vim.api.nvim_set_hl(0, 'Pmenu', { bg = '${alternate}', fg = '${fg}' })
vim.api.nvim_set_hl(0, 'PmenuSel', { bg = '${accent}', fg = '${bg}' })
vim.api.nvim_set_hl(0, 'PmenuSbar', { bg = '${alternate}' })
vim.api.nvim_set_hl(0, 'PmenuThumb', { bg = '${bright_black}' })
vim.api.nvim_set_hl(0, 'TabLine', { bg = '${alternate}', fg = '${fg}' })
vim.api.nvim_set_hl(0, 'TabLineSel', { bg = '${accent}', fg = '${bg}' })
vim.api.nvim_set_hl(0, 'TabLineFill', { bg = '${alternate}' })
vim.api.nvim_set_hl(0, 'WildMenu', { bg = '${accent}', fg = '${bg}' })
vim.api.nvim_set_hl(0, 'Folded', { bg = '${alternate}', fg = '${fg}' })
vim.api.nvim_set_hl(0, 'FoldColumn', { bg = '${alternate}', fg = '${fg}' })
vim.api.nvim_set_hl(0, 'DiffAdd', { bg = '${green}', fg = '${bg}' })
vim.api.nvim_set_hl(0, 'DiffChange', { bg = '${yellow}', fg = '${bg}' })
vim.api.nvim_set_hl(0, 'DiffDelete', { bg = '${red}', fg = '${bg}' })
vim.api.nvim_set_hl(0, 'DiffText', { bg = '${blue}', fg = '${bg}' })
vim.api.nvim_set_hl(0, 'Directory', { fg = '${accent}' })
vim.api.nvim_set_hl(0, 'Title', { fg = '${accent}', bold = true })
vim.api.nvim_set_hl(0, 'Question', { fg = '${accent}' })
vim.api.nvim_set_hl(0, 'MoreMsg', { fg = '${accent}' })
vim.api.nvim_set_hl(0, 'ModeMsg', { fg = '${fg}' })
vim.api.nvim_set_hl(0, 'MsgSeparator', { fg = '${accent}' })
vim.api.nvim_set_hl(0, 'MatchParen', { bg = '${alternate}', fg = '${fg}', bold = true })
vim.api.nvim_set_hl(0, 'Cursor', { fg = '${bg}', bg = '${fg}' })
vim.api.nvim_set_hl(0, 'lCursor', { fg = '${bg}', bg = '${fg}' })
vim.api.nvim_set_hl(0, 'CursorIM', { fg = '${bg}', bg = '${fg}' })
COLORSCHEME_EOF

        # Update theme.lua to load the custom colorscheme
        # Live reload is handled by config.theme_watch loaded from init.lua
        {
            echo "-- Theme: $theme (custom)"
            echo "-- Auto-generated by switch-theme.sh"
            echo "-- This file contains theme-specific configuration"
            echo ""
            echo "pcall(vim.cmd.colorscheme, '$theme')"
        } > "$theme_file"
    else
        # For standard colorschemes, apply when config.theme is required by init.lua
        {
            echo "-- Theme: $theme"
            echo "-- Auto-generated by switch-theme.sh"
            echo "-- This file contains theme-specific configuration"
            echo ""
            echo "pcall(vim.cmd.colorscheme, '$nvim_colorscheme')"
        } > "$theme_file"
    fi

    echo "→ Applied theme to nvim"
}

# Generate GTK theme from template
# 
# CRITICAL WORKAROUND: GTK Theme Cache Invalidation
# Problem: GTK applications cache themes by name and won't reload CSS changes
# even when the CSS files are modified. This prevents live theme switching.
# Solution: Generate a unique theme name with timestamp (UpTheme-{theme}-{timestamp})
# each time a theme is applied. This forces GTK to treat it as a completely new
# theme and reload all CSS from scratch, enabling live theme updates without
# restarting applications.
# Trade-off: Old theme directories accumulate, so cleanup_old_themes() removes
# all but the 2 most recent to prevent disk space issues.
generate_gtk_theme() {
    local theme="$1"
    
    # Generate unique theme name with timestamp to force cache invalidation
    # Format: UpTheme-{theme}-{YYYYMMDDHHMMSS}
    local timestamp=$(date +%Y%m%d%H%M%S)
    local theme_name="UpTheme-${theme}-${timestamp}"
    
    # Get template directory
    local template_dir="$UP_ROOT/configs/gtk/theme-template"
    
    # Create theme directory
    local theme_dir="$HOME/.local/share/themes/$theme_name"
    mkdir -p "$theme_dir/gtk-3.0"
    mkdir -p "$theme_dir/gtk-4.0"
    
    # Get colors from theme file
    local background=$(get_theme_nested "$theme" "colors" "background")
    local foreground=$(get_theme_nested "$theme" "colors" "foreground")
    local accent=$(get_theme_nested "$theme" "colors" "accent")
    local urgent=$(get_theme_nested "$theme" "colors" "urgent")
    local alternate=$(get_theme_nested "$theme" "colors" "alternate")
    local hover=$(get_theme_nested "$theme" "colors" "hover")
    local active=$(get_theme_nested "$theme" "colors" "active")
    local blue=$(get_theme_nested "$theme" "colors" "blue")
    local magenta=$(get_theme_nested "$theme" "colors" "magenta")
    local yellow=$(get_theme_nested "$theme" "colors" "yellow")
    local bright_black=$(get_theme_nested "$theme" "colors" "bright_black")
    
    # Generate GTK3 CSS
    if [ -f "$template_dir/gtk-3.0/gtk.css" ]; then
        sed -e "s/{{THEME_NAME}}/$theme_name/g" \
            -e "s/{{THEME_FILE}}/${theme}.toml/g" \
            -e "s/{{background}}/$background/g" \
            -e "s/{{foreground}}/$foreground/g" \
            -e "s/{{accent}}/$accent/g" \
            -e "s/{{urgent}}/$urgent/g" \
            -e "s/{{alternate}}/$alternate/g" \
            -e "s/{{hover}}/$hover/g" \
            -e "s/{{active}}/$active/g" \
            -e "s/{{blue}}/$blue/g" \
            -e "s/{{magenta}}/$magenta/g" \
            -e "s/{{yellow}}/$yellow/g" \
            -e "s/{{bright_black}}/$bright_black/g" \
            "$template_dir/gtk-3.0/gtk.css" > "$theme_dir/gtk-3.0/gtk.css"
    fi
    
    # Generate GTK4 CSS
    if [ -f "$template_dir/gtk-4.0/gtk.css" ]; then
        sed -e "s/{{THEME_NAME}}/$theme_name/g" \
            -e "s/{{THEME_FILE}}/${theme}.toml/g" \
            -e "s/{{background}}/$background/g" \
            -e "s/{{foreground}}/$foreground/g" \
            -e "s/{{accent}}/$accent/g" \
            -e "s/{{urgent}}/$urgent/g" \
            -e "s/{{alternate}}/$alternate/g" \
            -e "s/{{hover}}/$hover/g" \
            -e "s/{{active}}/$active/g" \
            -e "s/{{blue}}/$blue/g" \
            -e "s/{{magenta}}/$magenta/g" \
            -e "s/{{yellow}}/$yellow/g" \
            -e "s/{{bright_black}}/$bright_black/g" \
            "$template_dir/gtk-4.0/gtk.css" > "$theme_dir/gtk-4.0/gtk.css"
    fi
    
    # Generate index.theme
    if [ -f "$template_dir/index.theme" ]; then
        sed -e "s/{{THEME_NAME}}/$theme_name/g" \
            -e "s/{{THEME_FILE}}/${theme}.toml/g" \
            "$template_dir/index.theme" > "$theme_dir/index.theme"
    fi
    
    echo "$theme_name"
}

# Configure xsettingsd for GTK applications
# This is the primary mechanism for live theme updates in GTK apps
apply_xsettings() {
    local theme_name="$1"
    
    mkdir -p "$HOME/.config/xsettingsd"
    cat > "$HOME/.config/xsettingsd/xsettingsd.conf" << EOF
# Auto-generated by switch-theme.sh
Net/ThemeName "$theme_name"
Net/IconThemeName "Papirus-Dark"
Xft/Antialias 1
Xft/HintStyle "hintfull"
Xft/Hinting 1
Xft/RGBA "rgb"
EOF

    ensure_xsettingsd_running
    
    echo "→ Configured XSETTINGS"
}

# Clean up old generated theme directories (keeps 2 most recent)
cleanup_old_themes() {
    local current_name="$1"
    local themes_dir="$HOME/.local/share/themes"
    
    # List all UpTheme directories sorted by modification time (newest first)
    # Keep the 2 most recent (current + one previous), delete the rest
    local count=0
    for dir in $(ls -td "$themes_dir"/UpTheme-* 2>/dev/null || true); do
        if [ -d "$dir" ]; then
            local basename=$(basename "$dir")
            count=$((count + 1))
            if [ $count -gt 2 ]; then
                rm -rf "$dir" 2>/dev/null || true
            fi
        fi
    done
}

# Signal running GTK applications to reload their theme
# 
# WORKAROUND: GTK apps don't automatically detect theme changes
# We use multiple signaling methods for maximum compatibility:
# - SIGUSR1: Standard signal for many GTK apps to reload CSS
# - gsettings: Triggers proper GTK notification system
# - xsettingsd: X11 broadcast mechanism for theme changes
# Note: Some apps (like Thunar) watch the theme directory directly
# and don't need signals - in fact, signals can kill them, so
# we explicitly avoid signaling those apps.
signal_gtk_apps() {
    if ! have_cmd pkill; then
        return
    fi
    
    # Send SIGUSR1 to common GTK file managers and apps
    # SIGUSR1 typically forces GTK apps to reload CSS/theme
    local gtk_apps="nautilus nemo pcmanfm geany mousepad gedit \
                    gnome-calculator gnome-system-monitor \
                    gthumb eog firefox libreoffice"
    
    for app in $gtk_apps; do
        pkill -SIGUSR1 -x "$app" 2>/dev/null || true
    done
    
    # Also try SIGUSR2 for apps that use that signal
    # pkill -SIGUSR2 -x "thunar" 2>/dev/null || true
    # NOTE: thunar is watching the theme name; pkill
    # cannot be used (it kills the app).
}

# Refresh GTK theme for running applications (live reload without restart)
# Uses multiple mechanisms to force GTK apps to reload:
# 1. Theme name rotation (forces cache invalidation)
# 2. gsettings (triggers proper GTK notifications)
# 3. xsettingsd (X11 broadcast)
# 4. Direct app signaling
refresh_gtk_theme() {
    local theme_name="$1"
    local theme_dir="$HOME/.local/share/themes/$theme_name"
    
    # Touch CSS files to update modification time
    touch "$theme_dir/gtk-3.0/gtk.css" 2>/dev/null || true
    touch "$theme_dir/gtk-4.0/gtk.css" 2>/dev/null || true
    touch "$theme_dir/index.theme" 2>/dev/null || true
    
    # Update xsettingsd config
    local xsettingsd_conf="$HOME/.config/xsettingsd/xsettingsd.conf"
    if [ -f "$xsettingsd_conf" ]; then
        sed -i "s/^Net\/ThemeName.*/Net\/ThemeName \"$theme_name\"/" "$xsettingsd_conf"
        # Signal xsettingsd to reload and broadcast changes
        if have_cmd pkill; then
            pkill -HUP xsettingsd 2>/dev/null || true
            # Small delay to let xsettingsd process the change
            sleep 0.1
        fi
    fi
    
    # Also set via gsettings for modern GTK apps
    if is_graphical_session && have_cmd gsettings; then
        gsettings set org.gnome.desktop.interface gtk-theme "$theme_name" 2>/dev/null || true
        gsettings set org.gnome.desktop.interface color-scheme "prefer-dark" 2>/dev/null || true
    fi
    
    # Signal running GTK apps to reload
    signal_gtk_apps
}

# Apply theme to GTK (Thunar and other GTK apps)
apply_gtk() {
    local theme="$1"
    
    # Check if theme specifies a pre-built GTK theme
    local gtk_theme_name=$(get_theme_nested "$theme" "gtk" "theme_name")
    local gtk_package=$(get_theme_nested "$theme" "gtk" "package")
    
    local theme_name=""
    
    if [ -n "$gtk_package" ] && [ "$gtk_package" != "# No external package - generated from colors" ]; then
        # Pre-built theme - check if installed
        local theme_dir="$HOME/.local/share/themes/$gtk_theme_name"
        local system_theme_dir="/usr/share/themes/$gtk_theme_name"
        
        if [ -d "$theme_dir" ] || [ -d "$system_theme_dir" ]; then
            # Pre-built theme installed - use it directly
            theme_name="$gtk_theme_name"
            set_gsettings_value "org.gnome.desktop.interface" "gtk-theme" "$gtk_theme_name"
            set_gsettings_value "org.gnome.desktop.interface" "color-scheme" "prefer-dark"
            echo "→ Applied pre-built GTK theme: $gtk_theme_name"
        else
            # Theme not installed, generate from colors with unique timestamp
            echo "⚠ Pre-built theme '$gtk_theme_name' not found, generating from colors..."
            theme_name=$(generate_gtk_theme "$theme")
            set_gsettings_value "org.gnome.desktop.interface" "gtk-theme" "$theme_name"
            echo "→ Generated and applied GTK theme: $theme_name"
        fi
    else
        # Generate theme from colors with unique timestamp-based name
        # This ensures GTK apps always reload colors (no caching)
        theme_name=$(generate_gtk_theme "$theme")
        set_gsettings_value "org.gnome.desktop.interface" "gtk-theme" "$theme_name"
        echo "→ Generated and applied GTK theme: $theme_name"
    fi
    
    # Also set via GTK settings file for applications that read it
    mkdir -p "$HOME/.config/gtk-3.0"
    cat > "$HOME/.config/gtk-3.0/settings.ini" <<EOF
[Settings]
gtk-theme-name = $theme_name
gtk-application-prefer-dark-theme = true
EOF

    # Also create gtk-4.0 settings for GTK4 applications
    mkdir -p "$HOME/.config/gtk-4.0"
    cat > "$HOME/.config/gtk-4.0/settings.ini" <<EOF
[Settings]
gtk-theme-name = $theme_name
gtk-application-prefer-dark-theme = true
EOF

    # Configure xsettingsd for live theme updates
    apply_xsettings "$theme_name"

    # Refresh running GTK applications to apply new theme without restart
    refresh_gtk_theme "$theme_name"
    
    # Clean up old generated theme directories (keep current + previous)
    cleanup_old_themes "$theme_name"
}

# Apply theme background using feh
apply_background() {
    local theme="$1"
    local current=""
    if [ -f "$HOME/.config/up-background" ]; then
        current=$(tr -d '\n' < "$HOME/.config/up-background")
    fi

    # --no-reload is the desktop-agent files-only pass. Wallpaper is session
    # state (picker / random / first live theme apply). Never touch it here.
    if [ "$NO_RELOAD" = true ]; then
        echo "→ Leaving wallpaper (--no-reload)"
        return 0
    fi

    local bg_path=""
    if wallpaper_is_for_theme "$current" "$theme"; then
        bg_path="$current"
        echo "→ Keeping selected background: $bg_path"
    else
        bg_path=$(find_background "$theme")
    fi

    if [ -n "$bg_path" ] && [ -f "$bg_path" ]; then
        if is_graphical_session && have_cmd feh; then
            feh --bg-fill --no-fehbg "$bg_path" 2>/dev/null || true
        fi
        # Save background path for restoration on login
        echo "$bg_path" > "$HOME/.config/up-background"
        echo "→ Set background: $bg_path"
        if [ -x "$UP_ROOT/configs/scripts/session-curtain.sh" ]; then
            "$UP_ROOT/configs/scripts/session-curtain.sh" prepare "$bg_path" || true
        fi
    else
        echo "→ No background found for theme"
    fi
}

# Apply theme to LightDM greeter
apply_lightdm() {
    local theme="$1"

    # Write to theme.conf in conf.d directory
    # File is owned by root:up with 664 permissions
    # Users in the 'up' group can write to it without sudo
    # lightdm-gtk-greeter reads from /etc/lightdm/lightdm-gtk-greeter.conf.d/*.conf
    local theme_conf="/etc/lightdm/lightdm-gtk-greeter.conf.d/theme.conf"
    local greeter_conf="/etc/lightdm/lightdm-gtk-greeter.conf"

    if [ ! -w "$theme_conf" ] && [ ! -w "$greeter_conf" ]; then
        if [ ! -d /usr/share/backgrounds/up ] || [ ! -w /usr/share/backgrounds/up ]; then
            echo "→ Cannot update LightDM background (need write to greeter conf or /usr/share/backgrounds/up)"
            return 0
        fi
    fi

    # Get GTK theme name (generated or pre-built)
    local gtk_theme_name=$(get_theme_nested "$theme" "gtk" "theme_name")
    local gtk_package=$(get_theme_nested "$theme" "gtk" "package")

    # Use materia-gtk-theme for greeter (always installed)
    local greeter_theme="Materia"
    if [ -n "$gtk_package" ] && [ "$gtk_package" != "# No external package - generated from colors" ]; then
        # Pre-built theme specified
        if [ -d "/usr/share/themes/$gtk_theme_name" ]; then
            greeter_theme="$gtk_theme_name"
        fi
    fi

    # Prefer the user's last-chosen wallpaper, then the theme tree
    local bg_path=""
    if [ -f "$HOME/.config/up-background" ]; then
        bg_path=$(tr -d '\n' <"$HOME/.config/up-background")
    fi
    if [ -z "$bg_path" ] || [ ! -f "$bg_path" ]; then
        bg_path=$(find_background "$theme")
    fi
    if [ -z "$bg_path" ] || [ ! -f "$bg_path" ]; then
        bg_path="/usr/share/backgrounds/archlinux/geowaves.png"
    fi

    if [ -w "$theme_conf" ] || [ ! -e "$theme_conf" ]; then
        mkdir -p "$(dirname "$theme_conf")" 2>/dev/null || true
        cat > "$theme_conf" << EOF
# LightDM GTK Greeter Theme Configuration
# Auto-generated by up-switch-theme — do not edit manually

[greeter]
theme-name = $greeter_theme
background = $bg_path
EOF
    fi

    # Greeter reads the main conf file, not conf.d. Also install a
    # world-readable copy so the lightdm user can open the image.
    set_lightdm_background "$bg_path"

    echo "→ Applied theme to LightDM greeter ($bg_path)"
}

# Interactive theme selection
select_theme() {
    # Check for themes directory
    if [ ! -d "$THEMES_DIR" ]; then
        echo "Error: themes directory not found at $THEMES_DIR"
        exit 1
    fi

    # Get current theme
    current=""
    if [ -f "$STATE_FILE" ]; then
        current=$(cat "$STATE_FILE")
    fi

    # Build theme list for rofi
    shopt -s nullglob
    theme_files=("$THEMES_DIR"/*.toml)
    shopt -u nullglob
    theme_list=""
    for file in "${theme_files[@]}"; do
        theme=$(basename "$file" .toml)
        # Add checkmark indicator for current theme
        if [ "$theme" = "$current" ]; then
            theme_list="$theme_list✓ $theme\n"
        else
            theme_list="$theme_list  $theme\n"
        fi
    done
    theme_list=$(echo "$theme_list" | sort)

    # Check if any themes were found
    if [ -z "$theme_list" ]; then
        echo "Error: No theme files found in $THEMES_DIR"
        exit 1
    fi

    # Show rofi picker
    selected=$(echo -e "$theme_list" | rofi -dmenu -p "Select Theme" -selected-row 0 -kb-cancel Escape)

    if [ -z "$selected" ]; then
        # Return empty and exit code 1 to signal cancellation
        # Do NOT echo anything - main() will handle the cancellation
        return 1
    fi

    # Remove the indicator prefix (checkmark or spaces) to get just the theme name
    selected=$(echo "$selected" | sed 's/^[* ✓]* *//')

    echo "$selected"
}

# Validate theme exists
validate_theme() {
    local theme="$1"
    local themes_dir="${THEMES_DIR:-$(get_themes_dir)}"

    if [ ! -f "$themes_dir/${theme}.toml" ]; then
        echo "Error: Theme '$theme' not found in $themes_dir"
        echo "Available themes:"
        find "$themes_dir" -name "*.toml" -exec basename {} .toml \; | sort
        return 1
    fi
    return 0
}

# Main
main() {
    if [ "$INTERACTIVE" = true ]; then
        # Interactive mode - show rofi picker
        selected=$(select_theme) || {
            # select_theme returned non-zero (user cancelled)
            echo "Theme selection cancelled. No changes made."
            exit 0
        }
        echo "Applying theme: $selected"
    else
        # Non-interactive mode - validate and use specified theme
        if ! validate_theme "$TARGET_THEME"; then
            exit 1
        fi
        selected="$TARGET_THEME"
    fi

    # Apply themes to all apps (only writes theme.conf files)
    apply_i3 "$selected"
    apply_polybar "$selected"
    apply_picom "$selected"
    apply_rofi "$selected"
    apply_alacritty "$selected"
    apply_tmux "$selected"
    apply_zsh "$selected"
    apply_starship "$selected"
    apply_btop "$selected"
    apply_htop "$selected"
    apply_nvim "$selected"
    apply_gtk "$selected"
    apply_background "$selected"
    apply_lightdm "$selected"

# Function to update theme in config file (no-op if already set — avoids watcher loops)
update_config_theme() {
    local theme="$1"
    local existing=""
    # Create config directory if it doesn't exist
    mkdir -p "$(dirname "$USER_CONFIG")"

    # Create config file if it doesn't exist
    if [ ! -f "$USER_CONFIG" ]; then
        touch "$USER_CONFIG"
    fi

    if grep -qE '^[[:space:]]*theme[[:space:]]*=' "$USER_CONFIG" 2>/dev/null; then
        existing=$(grep -E '^[[:space:]]*theme[[:space:]]*=' "$USER_CONFIG" | head -1 \
            | sed 's/.*= *//' | tr -d ' "'"'"'')
        if [ "$existing" = "$theme" ]; then
            return 0
        fi
        sed -i "s/^[[:space:]]*theme[[:space:]]*=.*/theme = \"$theme\"/" "$USER_CONFIG"
    else
        # Add theme field if it doesn't exist
        echo "" >> "$USER_CONFIG"
        echo "# Current theme (auto-detected from applied theme)" >> "$USER_CONFIG"
        echo "theme = \"$theme\"" >> "$USER_CONFIG"
    fi
}

# Save current theme to both state file and config file
if [ ! -f "$STATE_FILE" ] || [ "$(tr -d '[:space:]' < "$STATE_FILE" 2>/dev/null)" != "$selected" ]; then
    echo "$selected" > "$STATE_FILE"
fi
update_config_theme "$selected"

# Desktop process refresh (install vs live session):
#   Install/chroot/migrations/up-update --home → files only or inert reload attempts
#   Live graphical session → queue refresh via desktop-agent
#   Fallback → best-effort i3/polybar if present
use_desktop_queue() {
    # Explicit files-only
    [ "$NO_RELOAD" = true ] && return 1
    # Caller forced inline (config-sync, theme-utils, install helpers)
    [ -n "${UP_DESKTOP_INLINE:-}" ] && return 1
    # Installer / packaging markers
    [ -n "${UP_INSTALL:-}" ] && return 1
    [ -f /run/up-installing ] && return 1
    [ -f /etc/up-installing ] && return 1
    # Applying into another user's HOME — agent belongs to the current session only
    [ -n "${HOME_OVERRIDE:-}" ] && return 1
    # No graphical session (chroot, TTY, SSH without X)
    if [ -z "${DISPLAY:-}" ] && [ -z "${WAYLAND_DISPLAY:-}" ]; then
        return 1
    fi
    # Running inside a chroot (install setup.sh)
    if [ -e /proc/1/root ] && [ -e / ]; then
        local root_id proc_id
        root_id=$(stat -c '%d:%i' / 2>/dev/null || true)
        proc_id=$(stat -c '%d:%i' /proc/1/root 2>/dev/null || true)
        if [ -n "$root_id" ] && [ -n "$proc_id" ] && [ "$root_id" != "$proc_id" ]; then
            return 1
        fi
    fi
    [ -x "${UP_ROOT}/configs/scripts/desktop-request.sh" ] || return 1
    return 0
}

if [ "$NO_RELOAD" = true ]; then
    echo "→ Theme files written (no desktop reload; --no-reload)"
elif [ -n "${HOME_OVERRIDE:-}" ] || [ -n "${UP_INSTALL:-}" ] \
    || [ -n "${UP_DESKTOP_INLINE:-}" ] \
    || [ -f /run/up-installing ] || [ -f /etc/up-installing ] \
    || { [ -z "${DISPLAY:-}" ] && [ -z "${WAYLAND_DISPLAY:-}" ]; }; then
    echo "→ Theme files written (offline/install path; no live desktop reload)"
elif is_graphical_session; then
    # Do not wait on desktop-agent. A queued refresh + wait was hanging
    # ~60s with no bar restart. i3 reload then kill+exec polybar here.
    reload_i3_if_running || true
    wait_for_i3_ipc || true
    restart_polybar_once || true
    echo "→ Reloaded i3 and restarted polybar"
else
    echo "→ Theme files written (no graphical session)"
fi

own_written_home_files
echo "✅ Theme '$selected' applied!"
}

# If we ran as root into another user's HOME (up-update --home), files from
# mktemp/mv stay root:600 and the session cannot start polybar.
own_written_home_files() {
    [ "$(id -u)" -eq 0 ] || return 0
    [ -n "${HOME:-}" ] && [ -d "$HOME" ] || return 0
    local owner
    owner=$(stat -c '%U:%G' "$HOME" 2>/dev/null || true)
    [ -n "$owner" ] || return 0
    case "$owner" in
        root:*) return 0 ;;
    esac
    local p
    for p in \
        "$HOME/.config/polybar" \
        "$HOME/.config/i3/theme.conf" \
        "$HOME/.config/i3/config" \
        "$HOME/.config/up" \
        "$HOME/.config/up-theme" \
        "$HOME/.config/up-background" \
        "$HOME/.config/picom" \
        "$HOME/.config/rofi" \
        "$HOME/.config/alacritty" \
        "$HOME/.config/dunst" \
        "$HOME/.config/btop" \
        "$HOME/.config/gtk-3.0" \
        "$HOME/.config/starship.toml"
    do
        [ -e "$p" ] || continue
        chown -R "$owner" "$p" 2>/dev/null || true
    done
    if [ -f "$HOME/.config/polybar/config.ini" ]; then
        chmod 644 "$HOME/.config/polybar/config.ini" 2>/dev/null || true
    fi
    if [ -f "$HOME/.config/polybar/launch.sh" ]; then
        chmod 755 "$HOME/.config/polybar/launch.sh" 2>/dev/null || true
    fi
}

main "$@"
