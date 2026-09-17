#!/bin/bash
# Host-safe: --invoke style/Background/Select must pass --image through.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

mkdir -p "$tmp/bin" "$tmp/configs/scripts"
cp "$ROOT/configs/scripts/system-menu.sh" "$tmp/configs/scripts/"
cp "$ROOT/configs/scripts/rofi-menu.sh" "$tmp/configs/scripts/"
cp "$ROOT/configs/scripts/menu-addons.sh" "$tmp/configs/scripts/"

cat > "$tmp/bin/up-select-desktop-image" <<'EOF'
#!/bin/bash
printf '%s\n' "$@" >"${UP_INVOKE_LOG:?}"
exit 0
EOF
chmod +x "$tmp/bin/up-select-desktop-image"

export UP_ROOT="$tmp"
export UP_INVOKE_LOG="$tmp/args.txt"
export DISPLAY="${DISPLAY:-:0}"
export UP_ADDONS_DIR="$tmp/no-addons"

bash "$tmp/configs/scripts/system-menu.sh" --invoke style/Background/Select -- --image /tmp/fake-bg.jpg
rc=$?
if [ "$rc" -ne 0 ]; then
    echo "FAIL invoke exit $rc"
    exit 1
fi
if [ ! -f "$UP_INVOKE_LOG" ]; then
    echo "FAIL up-select-desktop-image was not run"
    exit 1
fi
got=$(tr '\n' ' ' <"$UP_INVOKE_LOG")
if ! grep -q -- '--image' "$UP_INVOKE_LOG"; then
    echo "FAIL --image not passed; args were: $got"
    exit 1
fi
if ! grep -qx -- '/tmp/fake-bg.jpg' "$UP_INVOKE_LOG" && ! grep -q -- '/tmp/fake-bg.jpg' "$UP_INVOKE_LOG"; then
    echo "FAIL image path not passed; args were: $got"
    exit 1
fi
echo "menu-invoke-image: OK ($got)"
