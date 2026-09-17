#!/bin/bash
# Compatibility wrapper — prefer: up-update
# Kept so existing docs/scripts calling ./update.sh continue to work.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"

# Prefer sibling bin/ when invoked from a git checkout or install tree
if [ -f "$HERE/bin/up-update" ]; then
    export UP_ROOT="${UP_ROOT:-$HERE}"
    exec bash "$HERE/bin/up-update" "$@"
fi

export UP_ROOT="${UP_ROOT:-/usr/local/share/up}"
if [ -f "$UP_ROOT/bin/up-update" ]; then
    exec bash "$UP_ROOT/bin/up-update" "$@"
fi

# Last resort: /usr/local/bin symlink (sudo secure_path)
if [ -f /usr/local/bin/up-update ]; then
    exec bash /usr/local/bin/up-update "$@"
fi

echo "Error: up-update not found." >&2
echo "  looked in: $HERE/bin/up-update" >&2
echo "             $UP_ROOT/bin/up-update" >&2
echo "             /usr/local/bin/up-update" >&2
exit 1
