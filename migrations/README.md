# Migrations

`up-update` runs every `migrations/*.sh` that does not yet have a matching
`/var/lib/up/migrations/<name>.done` marker. New installs get the current
tree from `setup.sh`. Migrations still run there; they must be no-ops when
the tree is already current.

## Adding one

1. Name it `NNN-short-name.sh` (next unused number, three digits).
2. Make it idempotent. Safe to re-run if the `.done` file is missing.
3. Do not assume a TTY. `up-update` may run from the system menu.
4. On success the updater writes the `.done` file. Do not write it yourself
   unless you are testing by hand.

```bash
#!/bin/bash
set -euo pipefail
echo "=== Migration NNN: what it does ==="
UP_ROOT="${UP_ROOT:-/usr/local/share/up}"
# ...
```
