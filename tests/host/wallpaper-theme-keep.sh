#!/bin/bash
# A wallpaper already in a theme's tree must count as belonging to that theme.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

mkdir -p "$tmp/configs/backgrounds/bloom-shadow/dark" \
         "$tmp/configs/backgrounds/bloom-shadow/light" \
         "$tmp/configs/backgrounds/aetherweft/dark"
: >"$tmp/configs/backgrounds/bloom-shadow/dark/001.jpg"
: >"$tmp/configs/backgrounds/bloom-shadow/light/002.jpg"
: >"$tmp/configs/backgrounds/aetherweft/dark/001.jpg"

export UP_ROOT="$tmp"
# shellcheck source=../../configs/scripts/theme-utils.sh
source "$ROOT/configs/scripts/theme-utils.sh"

fail=0
if wallpaper_is_for_theme "$tmp/configs/backgrounds/bloom-shadow/light/002.jpg" bloom-shadow; then
    echo "OK  bloom-shadow light/002 belongs"
else
    echo "FAIL bloom-shadow light/002 should belong"
    fail=1
fi
if wallpaper_is_for_theme "$tmp/configs/backgrounds/aetherweft/dark/001.jpg" bloom-shadow; then
    echo "FAIL aetherweft image should not belong to bloom-shadow"
    fail=1
else
    echo "OK  aetherweft image does not belong"
fi
if wallpaper_is_for_theme "$tmp/missing.jpg" bloom-shadow; then
    echo "FAIL missing file should not belong"
    fail=1
else
    echo "OK  missing file does not belong"
fi

if [ "$fail" -ne 0 ]; then
    echo "wallpaper-theme-keep: FAIL"
    exit 1
fi
echo "wallpaper-theme-keep: OK"
