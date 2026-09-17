#!/bin/bash
# Keybinding Utilities
# Parses keybindings.toml with user override support
# Generates i3 config bindings and help text
#
# Note: Do NOT set shell options here — this file is sourced by setup/update scripts.

# Keybinding file locations (require UP_ROOT)
BASE_KEYBINDINGS="${UP_ROOT:-/usr/local/share/up}/configs/keybindings.toml"
USER_OVERRIDES="${HOME:-/root}/.config/up/keybindings-overrides.toml"

# Get merged keybinding content (base + user overrides)
# User overrides take precedence over base config
get_merged_keybindings() {
    if [ ! -f "$BASE_KEYBINDINGS" ]; then
        echo "# ERROR: Base keybindings file not found: $BASE_KEYBINDINGS"
        return 1
    fi
    
    # Start with base config
    cat "$BASE_KEYBINDINGS"
    
    # Append user overrides if file exists
    if [ -f "$USER_OVERRIDES" ]; then
        echo ""
        echo "# === USER OVERRIDES ==="
        echo "# These override the base keybindings above"
        cat "$USER_OVERRIDES"
    fi
}

# Get a variable value from keybindings config
# Usage: get_kb_var "mod"
get_kb_var() {
    local var_name="$1"
    get_merged_keybindings | awk -v var="$var_name" '
    /^\[variables\]/ { in_vars=1; next }
    /^\[/ { in_vars=0 }
    in_vars && $0 ~ "^" var " = " {
        gsub(/^.*= *"/, "")
        gsub(/".*$/, "")
        print
        exit
    }
    '
}

# Generate i3 keybindings from TOML config
# Outputs bindsym lines for i3 config
# Usage: generate_i3_keybindings [section_filter]
generate_i3_keybindings() {
    local filter="${1:-}"
    
    if [ ! -f "$BASE_KEYBINDINGS" ]; then
        echo "# ERROR: Keybindings file not found"
        return 1
    fi
    
    # Get variables
    local mod=$(get_kb_var "mod")
    local term=$(get_kb_var "term")
    local menu=$(get_kb_var "menu")
    local browser=$(get_kb_var "browser")

    # Default mod if missing from config
    [ -n "$mod" ] || mod="Mod4"
    
    get_merged_keybindings | awk -v mod="$mod" -v term="$term" -v menu="$menu" -v browser="$browser" -v filter="$filter" '
    BEGIN {
        current_section = ""
        in_section = 0
    }

    # Extract a double-quoted TOML string value, honoring backslash escapes.
    # Sets global _extracted; returns 1 on success.
    function extract_quoted(line, key,    re, start, s, i, c, out) {
        re = key "[[:space:]]*=[[:space:]]*\""
        if (!match(line, re)) return 0
        start = RSTART + RLENGTH
        s = substr(line, start)
        out = ""
        for (i = 1; i <= length(s); i++) {
            c = substr(s, i, 1)
            if (c == "\\") {
                if (i < length(s)) {
                    out = out substr(s, i + 1, 1)
                    i++
                }
            } else if (c == "\"") {
                _extracted = out
                return 1
            } else {
                out = out c
            }
        }
        return 0
    }

    # Convert human-friendly key chord to i3 bindsym syntax:
    #   Super -> Mod4 (or $mod value), Alt -> Mod1
    #   Space -> space, ";" -> semicolon
    #   Single letters -> lowercase (i3 expects Mod4+Shift+a, not ...+A)
    function normalize_key(key,    n, parts, i, p, out, sep) {
        n = split(key, parts, "+")
        out = ""
        sep = ""
        for (i = 1; i <= n; i++) {
            p = parts[i]
            if (p == "Super")      p = mod
            else if (p == "Alt")   p = "Mod1"
            else if (p == "Space") p = "space"
            else if (p == ";")     p = "semicolon"
            else if (p ~ /^[A-Za-z]$/) p = tolower(p)
            out = out sep p
            sep = "+"
        }
        return out
    }

    # i3 built-in commands (no exec wrapper)
    function is_i3_command(cmd) {
        return cmd ~ /^(focus|move|split|layout|fullscreen|floating|workspace|mode|restart|reload|kill|sticky|resize|mark|unmark|title_format|border|nop)([[:space:]]|$)/
    }
    
    # Track sections
    /^\[variables\]/ { in_section = 0; next }
    /^\[([a-z_]+)\]/ {
        gsub(/^\[/, "")
        gsub(/\].*$/, "")
        current_section = $0
        # If filter specified, only process matching section
        if (filter == "" || current_section == filter) {
            in_section = 1
        } else {
            in_section = 0
        }
        next
    }
    
    # Skip if not in a section we want
    !in_section { next }
    
    # Parse keybinding line: "key" = { mode = "...", desc = "...", command = "..." }
    /^"[^"]+"[[:space:]]*=/ {
        # Extract key (first quoted field on the line)
        key = $1
        gsub(/"/, "", key)
        key = normalize_key(key)
        
        # Extract mode (optional)
        mode = ""
        if (extract_quoted($0, "mode")) {
            mode = _extracted
        }
        
        # Extract command (handles escaped quotes, e.g. mode \"resize\")
        cmd = ""
        if (extract_quoted($0, "command")) {
            cmd = _extracted
        }
        
        # Skip empty commands (disabled keybindings)
        if (cmd == "") next
        
        # Substitute variables
        gsub(/\$mod/, mod, cmd)
        gsub(/\$term/, term, cmd)
        gsub(/\$menu/, menu, cmd)
        gsub(/\$browser/, browser, cmd)
        
        # Generate bindsym based on command type
        if (mode != "") {
            # Mode-specific binding (MODE|name|bindsym ... for later assembly)
            # Use | delimiter so commands containing colons stay intact
            printf "MODE|%s|bindsym %s %s\n", mode, key, cmd
        } else if (is_i3_command(cmd)) {
            # i3 internal command (no exec needed)
            printf "bindsym %s %s\n", key, cmd
        } else {
            # External command — --no-startup-id avoids i3 startup notifications
            printf "bindsym %s exec --no-startup-id %s\n", key, cmd
        }
    }
    ' | {
        # Group mode bindings after regular ones; keep stable order within groups
        regular_tmp=$(mktemp)
        mode_tmp=$(mktemp)
        while IFS= read -r line || [ -n "$line" ]; do
            case "$line" in
                MODE\|*) printf '%s\n' "$line" >> "$mode_tmp" ;;
                *)       printf '%s\n' "$line" >> "$regular_tmp" ;;
            esac
        done
        cat "$regular_tmp"
        if [ -s "$mode_tmp" ]; then
            sort -t'|' -k2,2 "$mode_tmp" | awk -F'|' '
            BEGIN { current_mode = ""; in_mode = 0 }
            {
                mode = $2
                # Reconstruct binding: fields 3..NF joined by | (normally just field 3)
                binding = $3
                for (i = 4; i <= NF; i++) binding = binding "|" $i

                if (mode != current_mode) {
                    if (in_mode) print "}"
                    print "mode \"" mode "\" {"
                    current_mode = mode
                    in_mode = 1
                }
                print "    " binding
            }
            END { if (in_mode) print "}" }
            '
        fi
        rm -f "$regular_tmp" "$mode_tmp"
    }
}

# Generate help text for keybindings
# Usage: generate_help_text [format]
# format: "plain" (default), "rofi", "markdown"
generate_help_text() {
    local format="${1:-plain}"
    
    if [ ! -f "$BASE_KEYBINDINGS" ]; then
        echo "Keybindings file not found"
        return 1
    fi
    
    # Section titles and emojis
    declare -A titles
    titles[basic]="Basic Keybindings"
    titles[media]="Media Keys"
    titles[navigation]="Navigation"
    titles[layout]="Layout Controls"
    titles[workspaces]="Workspaces"
    titles[resize_mode]="Resize Mode"
    titles[launcher]="Application Launcher"
    titles[user_apps]="User Applications"
    titles[system_functions]="System Functions"
    titles[system_menu]="System Menu"
    titles[additional]="Additional"
    
    declare -A emojis
    emojis[basic]="⌨️"
    emojis[media]="🔊"
    emojis[navigation]="🧭"
    emojis[layout]="📐"
    emojis[workspaces]="🖥️"
    emojis[resize_mode]="📏"
    emojis[launcher]="🚀"
    emojis[user_apps]="📱"
    emojis[system_functions]="⚙️"
    emojis[system_menu]="📋"
    emojis[additional]="➕"
    
    # First pass: find maximum key length for rofi format
    local max_key_len=25
    if [ "$format" = "rofi" ]; then
        max_key_len=$(get_merged_keybindings | awk '
        /^\["[a-z_]+"\]/ { next }
        /^"[^"]+"[[:space:]]*=/ {
            key = $1
            gsub(/"/, "", key)
            if (length(key) > max) max = length(key)
        }
        END { print (max > 0 ? max : 25) }
        ')
        # Add padding for alignment
        max_key_len=$((max_key_len + 3))
    fi
    
    # Process each section
    local sections="basic media navigation layout workspaces resize_mode launcher user_apps system_functions system_menu additional"
    
    for section in $sections; do
        local title="${titles[$section]:-$section}"
        local emoji="${emojis[$section]:-}"
        
        case "$format" in
            "rofi")
                echo "<b>$emoji $title</b>"
                ;;
            "markdown")
                echo "### $emoji $title"
                echo ""
                ;;
            *)
                echo "## $emoji $title"
                echo ""
                ;;
        esac
        
        # Extract keybindings for this section
        get_merged_keybindings | awk -v sec="$section" -v format="$format" -v max_len="$max_key_len" '
        BEGIN { in_section = 0; section_hdr = "[" sec "]" }
        index($0, section_hdr) == 1 { in_section = 1; next }
        /^\[/ { in_section = 0 }
        in_section && /^"[^"]+"[[:space:]]*=/ {
            key = $1
            gsub(/"/, "", key)

            desc = ""
            if (match($0, /desc = "/)) {
                s = substr($0, RSTART + RLENGTH)
                # Take until next unescaped quote
                d = ""
                for (i = 1; i <= length(s); i++) {
                    c = substr(s, i, 1)
                    if (c == "\\") {
                        if (i < length(s)) { d = d substr(s, i + 1, 1); i++ }
                    } else if (c == "\"") {
                        break
                    } else {
                        d = d c
                    }
                }
                desc = d
            }

            if (desc != "") {
                if (format == "rofi") {
                    # Use Pango markup with monospace font for alignment
                    printf "<tt>%-" max_len "s</tt>%s\n", key, desc
                } else {
                    printf "  %-25s %s\n", key, desc
                }
            }
        }
        '
        
        echo ""
    done
}

# Show keybindings in rofi menu
show_rofi_keybindings() {
    generate_help_text "rofi" | rofi -dmenu -i -p "Keybindings" -markup-rows -width 80 -lines 25 -kb-cancel Escape
}

# Show full keybindings in terminal
show_terminal_keybindings() {
    generate_help_text "plain" | less -R
}

# Write generated keybindings to the user's i3 config include file.
# Usage: write_i3_keybindings_file [output_path]
# Default output: $HOME/.config/i3/keybindings.conf
write_i3_keybindings_file() {
    local out="${1:-$HOME/.config/i3/keybindings.conf}"
    local tmp
    mkdir -p "$(dirname "$out")"

    tmp=$(mktemp)
    {
        echo "# Auto-generated by keybinding-utils.sh — do not edit"
        echo "# Source: $BASE_KEYBINDINGS"
        echo "# Overrides: $USER_OVERRIDES"
        echo ""
        generate_i3_keybindings
    } > "$tmp"

    if [ ! -s "$tmp" ] || ! grep -q '^bindsym ' "$tmp"; then
        rm -f "$tmp"
        echo "ERROR: Failed to generate i3 keybindings (no bindsym lines)" >&2
        return 1
    fi

    mv "$tmp" "$out"
    return 0
}

# Export functions
export -f get_merged_keybindings
export -f get_kb_var
export -f generate_i3_keybindings
export -f generate_help_text
export -f show_rofi_keybindings
export -f show_terminal_keybindings
export -f write_i3_keybindings_file