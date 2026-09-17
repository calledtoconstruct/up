#!/usr/bin/env bash
# Boot and runtime tunables that do not drop features.
# Safe to run from setup.sh (chroot) and from up-update if invoked by a future migration.
#
#   - GRUB menu timeout 2s (menu still interruptible)
#   - Do not block graphical.target on a live network
#   - Cap journald disk use
#   - SSD weekly TRIM
#   - Swap reclaim suited to zram vs disk swap

set -euo pipefail

log() {
    printf '%s\n' "$*"
}

# --- GRUB: keep the menu, wait less ------------------------------------------

grub_default=/etc/default/grub
grub_changed=false

if [ -f "$grub_default" ]; then
    if grep -qE '^GRUB_TIMEOUT=' "$grub_default"; then
        if ! grep -qE '^GRUB_TIMEOUT=2[[:space:]]*$' "$grub_default"; then
            sed -i 's/^GRUB_TIMEOUT=.*/GRUB_TIMEOUT=2/' "$grub_default"
            grub_changed=true
        fi
    else
        printf '\nGRUB_TIMEOUT=2\n' >>"$grub_default"
        grub_changed=true
    fi

    if grep -qE '^GRUB_TIMEOUT_STYLE=' "$grub_default"; then
        if ! grep -qE '^GRUB_TIMEOUT_STYLE=menu[[:space:]]*$' "$grub_default"; then
            sed -i 's/^GRUB_TIMEOUT_STYLE=.*/GRUB_TIMEOUT_STYLE=menu/' "$grub_default"
            grub_changed=true
        fi
    else
        printf 'GRUB_TIMEOUT_STYLE=menu\n' >>"$grub_default"
        grub_changed=true
    fi
    log "→ GRUB timeout=2 (menu kept)"
fi

if [ "$grub_changed" = true ] && [ -f /boot/grub/grub.cfg ] && command -v grub-mkconfig >/dev/null 2>&1; then
    grub-mkconfig -o /boot/grub/grub.cfg >/dev/null 2>&1 || \
        log "⚠ grub-mkconfig failed; reboot will use previous grub.cfg until it is regenerated"
fi

# --- Do not stall LightDM on DHCP --------------------------------------------

# Mask so NetworkManager cannot pull wait-online back in via Wants=.
# NM still connects in the background; nothing requires a link before the greeter.
mkdir -p /etc/systemd/system
for unit in NetworkManager-wait-online.service systemd-networkd-wait-online.service; do
    ln -sfn /dev/null "/etc/systemd/system/$unit"
done
log "→ Masked *-wait-online (graphical.target no longer waits for a network)"

# --- journald: persist logs, cap growth --------------------------------------

mkdir -p /etc/systemd/journald.conf.d
cat >/etc/systemd/journald.conf.d/50-up.conf <<'EOF'
[Journal]
Storage=persistent
Compress=yes
SystemMaxUse=200M
RuntimeMaxUse=50M
MaxRetentionSec=2week
EOF
log "→ journald capped at 200M / 2 weeks"

# --- weekly TRIM (no-op on disks that do not support it) ---------------------

mkdir -p /etc/systemd/system/timers.target.wants
if [ -f /usr/lib/systemd/system/fstrim.timer ]; then
    ln -sfn /usr/lib/systemd/system/fstrim.timer \
        /etc/systemd/system/timers.target.wants/fstrim.timer
    log "→ Enabled fstrim.timer"
fi

# --- reclaim: zram likes high swappiness; disk swap does not -----------------

use_zram=false
if [ "${SWAP_TYPE:-}" = "zram" ] \
    || [ -f /etc/systemd/system/zram-setup.service ] \
    || [ -f /usr/lib/systemd/system/zram-setup.service ]; then
    use_zram=true
fi

mkdir -p /etc/sysctl.d
if [ "$use_zram" = true ]; then
    cat >/etc/sysctl.d/99-up.conf <<'EOF'
# zram: compress early, skip extra swap-page clustering
vm.swappiness = 180
vm.page-cluster = 0
vm.vfs_cache_pressure = 50
EOF
    log "→ sysctl: zram reclaim (swappiness=180)"
else
    cat >/etc/sysctl.d/99-up.conf <<'EOF'
# Disk swap: keep working set in RAM
vm.swappiness = 10
vm.vfs_cache_pressure = 50
EOF
    log "→ sysctl: disk-swap reclaim (swappiness=10)"
fi

if [ -d /proc/sys ] && command -v sysctl >/dev/null 2>&1; then
    sysctl --system >/dev/null 2>&1 || true
fi

exit 0
