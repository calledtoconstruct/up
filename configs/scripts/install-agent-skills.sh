#!/bin/bash
# Symlink shipped skills into the directories coding harnesses search.
# Safe to run repeatedly. HOME and UP_ROOT must be set (or defaulted).
set -euo pipefail

export UP_ROOT="${UP_ROOT:-/usr/local/share/up}"
HOME_DIR="${HOME:-}"

while [ $# -gt 0 ]; do
    case "$1" in
        --home)
            HOME_DIR="${2:-}"
            shift 2
            ;;
        *)
            echo "Usage: $0 [--home DIR]" >&2
            exit 2
            ;;
    esac
done

if [ -z "$HOME_DIR" ]; then
    echo "install-agent-skills: HOME not set" >&2
    exit 1
fi

src="$UP_ROOT/default/agents/skills"
if [ ! -d "$src" ]; then
    echo "install-agent-skills: no skills at $src" >&2
    exit 0
fi

link_into() {
    local dest="$1"
    mkdir -p "$dest"
    local skill name
    for skill in "$src"/*/; do
        [ -d "$skill" ] || continue
        name=$(basename "$skill")
        ln -sfn "$src/$name" "$dest/$name"
    done
}

link_into "$HOME_DIR/.agents/skills"
link_into "$HOME_DIR/.claude/skills"
link_into "$HOME_DIR/.codex/skills"
link_into "$HOME_DIR/.pi/agent/skills"
link_into "$HOME_DIR/.gemini/config/skills"
link_into "$HOME_DIR/.hermes/skills"

if [ -d "$HOME_DIR/.hermes/profiles" ]; then
    for profile in "$HOME_DIR/.hermes/profiles"/*/; do
        [ -d "$profile" ] || continue
        link_into "$profile/skills"
    done
fi
