#!/bin/bash
# Runs on the Arch live ISO inside the VM. Do not run on the host.
set -euo pipefail

echo "=== Up VM guest ISO bootstrap ==="

for iface in /sys/class/net/*; do
    name=$(basename "$iface")
    [ "$name" = "lo" ] && continue
    ip link set "$name" up || true
done
systemctl start systemd-networkd 2>/dev/null || true
systemctl start systemd-resolved 2>/dev/null || true
systemctl start dhcpcd 2>/dev/null || true
dhcpcd 2>/dev/null || true

ok=0
for _ in $(seq 1 30); do
    if ping -c 1 -W 2 archlinux.org >/dev/null 2>&1 || ping -c 1 -W 2 1.1.1.1 >/dev/null 2>&1; then
        ok=1
        break
    fi
    sleep 2
done
if [ "$ok" != "1" ]; then
    echo "WARNING: network not ready; pacstrap may fail"
    ip -br a || true
fi

mkdir -p /upsrc /upwork
modprobe 9p 9pnet 9pnet_virtio 2>/dev/null || true
if ! mountpoint -q /upsrc; then
    mount -t 9p -o trans=virtio,version=9p2000.L,ro upsrc /upsrc
fi
if ! mountpoint -q /upwork; then
    mount -t 9p -o trans=virtio,version=9p2000.L upwork /upwork || true
fi

rm -rf /root/up
mkdir -p /root/up
# The 9p tree includes tests/vm/work/*.qcow2 (multi-GB). Copying that onto
# the live ISO tmpfs OOMs a 4G guest. Only the installer sources are needed.
tar -C /upsrc --exclude='tests/vm/work' --exclude='.git' --exclude='*.qcow2' \
    -cf - . | tar -C /root/up -xf -
chmod +x /root/up/install-unattended.sh /root/up/bootstrap.sh /root/up/setup.sh

PUBKEY=""
if [ -f /upwork/id_ed25519.pub ]; then
    PUBKEY="--ssh-pubkey /upwork/id_ed25519.pub"
fi
ANSWERS="/root/up/tests/vm/fixtures/uefi-virtio.conf"
if [ -f /upwork/answers.conf ]; then
    ANSWERS="/upwork/answers.conf"
fi

export UP_ROOT=/root/up
export UP_UNATTENDED=1
# shellcheck disable=SC2086
if /root/up/install-unattended.sh --answers "$ANSWERS" --vm-test $PUBKEY; then
    echo "UNATTENDED_INSTALL_OK" | tee /upwork/install-result.txt
    exit 0
else
    echo "UNATTENDED_INSTALL_FAIL" | tee /upwork/install-result.txt
    exit 1
fi
