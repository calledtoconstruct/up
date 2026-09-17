#!/bin/bash
# Host-safe checks for shipped agent skills and crash prompt wiring.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
fail=0
note() { printf '%s\n' "$*"; }
ok() { note "OK  $1"; }
bad() { note "FAIL $1"; fail=1; }

# --- skill files exist and refuse vendor edits ---
skill="$ROOT/default/agents/skills/up/SKILL.md"
crash="$ROOT/default/agents/skills/diagnose-crash/SKILL.md"
if [ -f "$skill" ]; then
    ok "up skill present"
else
    bad "up skill missing: $skill"
fi
if [ -f "$crash" ]; then
    ok "diagnose-crash skill present"
else
    bad "diagnose-crash skill missing: $crash"
fi

if [ -f "$skill" ]; then
    if grep -q 'Never edit `/usr/local/share/up`' "$skill"; then
        ok "up skill forbids vendor edits"
    else
        bad "up skill does not forbid vendor tree edits"
    fi
    if grep -E 'edit `/usr/local/share/up' "$skill" | grep -v 'Never edit' >/dev/null; then
        bad "up skill still tells the agent to edit the vendor tree"
    else
        ok "up skill has no vendor-edit instruction"
    fi
fi

# --- symlink installer ---
installer="$ROOT/configs/scripts/install-agent-skills.sh"
if [ -x "$installer" ] || [ -f "$installer" ]; then
    tmp=$(mktemp -d)
    trap 'rm -rf "$tmp"' EXIT
    HOME="$tmp" UP_ROOT="$ROOT" bash "$installer"
    if [ -L "$tmp/.agents/skills/up" ] && [ "$(readlink "$tmp/.agents/skills/up")" = "$ROOT/default/agents/skills/up" ]; then
        ok "symlink ~/.agents/skills/up"
    else
        bad "symlink ~/.agents/skills/up not created"
    fi
    if [ -L "$tmp/.claude/skills/up" ]; then
        ok "symlink ~/.claude/skills/up"
    else
        bad "symlink ~/.claude/skills/up not created"
    fi
    if [ -L "$tmp/.agents/skills/diagnose-crash" ]; then
        ok "symlink diagnose-crash"
    else
        bad "symlink diagnose-crash not created"
    fi
else
    bad "install-agent-skills.sh missing"
fi

# --- crash helper dry-run ---
crash_bin="$ROOT/bin/up-agent-crash"
if [ -x "$crash_bin" ] || [ -f "$crash_bin" ]; then
    out=$(UP_ROOT="$ROOT" bash "$crash_bin" --dry-run 4242 2>&1) || true
    if printf '%s\n' "$out" | grep -q 'diagnose-crash'; then
        ok "up-agent-crash --dry-run names diagnose-crash"
    else
        bad "up-agent-crash --dry-run did not mention diagnose-crash"
        note "$out"
    fi
    if printf '%s\n' "$out" | grep -q '4242'; then
        ok "up-agent-crash --dry-run includes PID"
    else
        bad "up-agent-crash --dry-run missing PID"
    fi
else
    bad "bin/up-agent-crash missing"
fi

if [ "$fail" -ne 0 ]; then
    note "agent-skills: FAIL"
    exit 1
fi
note "agent-skills: OK"
