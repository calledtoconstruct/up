---
name: diagnose-crash
description: >
  Diagnose why a program crashed on this machine from a systemd-coredump core dump.
  Use when a process segfaulted, aborted, or dumped core, when asked why an app
  crashed or disappeared, or when a "Process crashed:" notification is acted on.
  Triggers: crash, segfault, SIGSEGV, SIGABRT, core dump, coredumpctl.
---

# Diagnosing a crash

Work from evidence. Do not invent a story.

## Facts

`coredumpctl info <pid>` is the start. Note the **command line**. `coredumpctl list` shows whether this is a one-off.

## Boring causes first

`free -h` and the journal for OOM kills. An OOM kill is not a bug in the process.

## Timeline

Compare the crash timestamp to filesystem mtimes, the journal around that moment, and recent `up-update` / pacman activity.

## The core

Thread stacks besides frame 0 show work in flight. Third-party in-process code (file-manager plugins, browser extensions, out-of-tree drivers) is worth flagging only with evidence.

Symbolize on Arch:

```bash
core=$(mktemp -t crash-XXXXXX.core)
trap 'rm -f "$core"' EXIT
coredumpctl dump <pid> --output="$core"
DEBUGINFOD_URLS="https://debuginfod.archlinux.org" \
  gdb -q <executable> "$core" \
  -batch -ex 'set debuginfod enabled on' -ex 'bt'
```

A core is a copy of process memory. Write it only under `mktemp` and delete it when done.

Unresolved frames: say so. Do not invent function names.

## Report

1. What crashed, and what it was doing.
2. What the evidence proves vs what you infer.
3. Whether user data was lost (check trash).
4. Whether it is likely to recur.

Diagnosis reads. It does not fix, tidy, or reconfigure. Delete the core you extracted.

## Mute notifications for this program

Only if the user asks:

```bash
up-crash-mute '<program>'
up-crash-mute '<program>' off
up-crash-mute
```

Prefer the `binary:` path from the facts. A process name is truncated to 15 characters.

## If it is an Up bug

Most crashes are upstream of the app, not Up. Up's sphere is i3 session scripts, polybar launch, picom profiles, LightDM greeter, `up-*` tools, and `/usr/local/share/up`. If the cause really sits there, gather `up version` (or `/usr/local/share/up/version`) and `/var/log/up/install-report.txt` if present, then ask the user before filing anything.
