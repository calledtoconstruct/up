#!/bin/bash
# Flameshot 13+ asks the screenshot portal. i3/X11 has no portal backend,
# so capture fails unless useX11LegacyScreenshot=true is set.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

fail=0
ok() { printf 'OK  %s\n' "$1"; }
bad() { printf 'FAIL %s\n' "$1"; fail=1; }

script="$ROOT/configs/scripts/screenshot.sh"
if [ -x "$script" ]; then
    ok "screenshot.sh is executable"
else
    bad "screenshot.sh missing or not executable"
fi

# Fresh home
HOME="$tmp/fresh" "$script" --ensure-config
ini="$tmp/fresh/.config/flameshot/flameshot.ini"
if grep -qx 'useX11LegacyScreenshot=true' "$ini" 2>/dev/null \
    && grep -qx '\[General\]' "$ini"; then
    ok "seeds legacy X11 capture on a new config"
else
    bad "did not seed flameshot.ini"
    cat "$ini" 2>/dev/null || true
fi

# Existing config: flip false, keep other keys, do not duplicate the section
home="$tmp/existing"
mkdir -p "$home/.config/flameshot"
cat >"$home/.config/flameshot/flameshot.ini" <<'EOF'
[General]
showHelp=false
useX11LegacyScreenshot=false
savePath=/tmp/shots

[Shortcuts]
TYPE_COPY=Ctrl+C
EOF
HOME="$home" "$script" --ensure-config
ini="$home/.config/flameshot/flameshot.ini"
if grep -qx 'useX11LegacyScreenshot=true' "$ini" \
    && grep -qx 'showHelp=false' "$ini" \
    && grep -qx 'savePath=/tmp/shots' "$ini" \
    && grep -qx 'TYPE_COPY=Ctrl+C' "$ini" \
    && [ "$(grep -c '^\[General\]' "$ini")" -eq 1 ] \
    && ! grep -q 'useX11LegacyScreenshot=false' "$ini"; then
    ok "enables legacy capture without dropping other settings"
else
    bad "existing flameshot.ini was not patched cleanly"
    cat "$ini" || true
fi

# No [General] section yet
home="$tmp/nosection"
mkdir -p "$home/.config/flameshot"
printf '%s\n' '[Shortcuts]' 'TYPE_SAVE=Ctrl+S' >"$home/.config/flameshot/flameshot.ini"
HOME="$home" "$script" --ensure-config
ini="$home/.config/flameshot/flameshot.ini"
if grep -qx '\[General\]' "$ini" && grep -qx 'useX11LegacyScreenshot=true' "$ini" \
    && grep -qx 'TYPE_SAVE=Ctrl+S' "$ini"; then
    ok "adds [General] when the file has other sections only"
else
    bad "failed to add [General]"
    cat "$ini" || true
fi

if [ "$fail" -ne 0 ]; then
    echo "screenshot-legacy: FAIL"
    exit 1
fi
echo "screenshot-legacy: OK"
