#!/bin/bash
# Unattended Up install for the Arch ISO (and VM CI). Does not use tmux.
# NEVER run this on a development host that is not the install target.
set -euo pipefail

export UP_UNATTENDED=1

if [ ! -d /run/archiso ] && [ "${UP_ALLOW_UNATTENDED:-}" != "1" ]; then
    echo "ERROR: refusing to run outside the Arch live ISO (/run/archiso missing)." >&2
    echo "This script partitions a disk. In QEMU the guest ISO has /run/archiso." >&2
    echo "Override only if you mean to wipe the target: UP_ALLOW_UNATTENDED=1" >&2
    exit 1
fi

export UP_ROOT="${UP_ROOT:-/root/up}"
cd "$UP_ROOT"

STATE_DIR="/tmp/up-state"
LOG_FILE="/var/log/up/install.log"

ANSWERS=""
VM_TEST=0
SSH_PUBKEY=""
DISK_OVERRIDE=""

usage() {
    cat <<'EOF'
Usage: install-unattended.sh --answers FILE [--vm-test] [--ssh-pubkey FILE] [--disk /dev/vda]

Writes installer answers and runs bootstrap.sh (which chroots into setup.sh).
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --answers) ANSWERS="$2"; shift 2 ;;
        --vm-test) VM_TEST=1; shift ;;
        --ssh-pubkey) SSH_PUBKEY="$2"; shift 2 ;;
        --disk) DISK_OVERRIDE="$2"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Unknown option: $1" >&2; usage; exit 1 ;;
    esac
done

if [ -z "$ANSWERS" ] || [ ! -f "$ANSWERS" ]; then
    echo "ERROR: --answers FILE is required" >&2
    exit 1
fi

if [ ! -f "$UP_ROOT/bootstrap.sh" ]; then
    echo "ERROR: bootstrap.sh not found under $UP_ROOT" >&2
    exit 1
fi

# shellcheck source=configs/scripts/state-utils.sh
source "$UP_ROOT/configs/scripts/package-groups.sh"
# shellcheck source=configs/scripts/state-utils.sh
source "$UP_ROOT/configs/scripts/state-utils.sh"

answer_get() {
    local key="$1"
    local def="${2:-}"
    local line
    line=$(grep -E "^${key}=" "$ANSWERS" | tail -1 || true)
    if [ -z "$line" ]; then
        printf '%s' "$def"
        return
    fi
    printf '%s' "${line#*=}"
}

resolve_disk() {
    local want
    want=$(answer_get disk auto)
    if [ -n "$DISK_OVERRIDE" ]; then
        printf '%s' "$DISK_OVERRIDE"
        return
    fi
    if [ -n "$want" ] && [ "$want" != "auto" ] && [ -b "$want" ]; then
        printf '%s' "$want"
        return
    fi
    local d
    for d in /dev/vda /dev/sda /dev/nvme0n1 /dev/xvda; do
        if [ -b "$d" ]; then
            printf '%s' "$d"
            return
        fi
    done
    echo "ERROR: no install disk found" >&2
    lsblk -d -o NAME,SIZE,TYPE || true
    exit 1
}

USERNAME=$(answer_get username tester)
PASSWORD=$(answer_get password testervm1)
HOSTNAME=$(answer_get hostname up-vmtest)
TIMEZONE=$(answer_get timezone UTC)
FULLNAME=$(answer_get fullname "Up Tester")
BOOT_MODE=$(answer_get boot_mode uefi)
TABLE=$(answer_get partition_table_type gpt)
PCHOICE=$(answer_get partition_choice 1)
DISK=$(resolve_disk)

rm -rf "${STATE_DIR:?}/"*
mkdir -p "$STATE_DIR" "$(dirname "$LOG_FILE")"
echo "=== Up unattended install $(date -Iseconds) ===" > "$LOG_FILE"
echo "30" > "$STATE_DIR/progress_total.txt"
echo "0" > "$STATE_DIR/progress_current.txt"
echo "Unattended" > "$STATE_DIR/status.txt"

write_answer "disk" "$DISK"
write_answer "boot_mode" "$BOOT_MODE"
write_answer "partition_table_type" "$TABLE"
write_answer "partition_choice" "$PCHOICE"
write_answer "confirm_partition" "yes"
write_answer "confirm_custom" "yes"
write_answer "hostname" "$HOSTNAME"
write_answer "timezone" "$TIMEZONE"
write_answer "username" "$USERNAME"
write_answer "fullname" "$FULLNAME"
write_answer "password_${USERNAME}" "$PASSWORD"
write_answer "password_root" "$PASSWORD"
write_answer "nvidia_drivers" "$(answer_get nvidia_drivers no)"
write_answer "ssh_setup" "$(answer_get ssh_setup yes)"
write_answer "ssh_key_type" "$(answer_get ssh_key_type ed25519)"
write_answer "ssh_passphrase" ""

echo "Unattended answers: disk=$DISK user=$USERNAME host=$HOSTNAME mode=$BOOT_MODE"
echo "Starting bootstrap (this takes a long time)..."

if ! UP_ROOT="$UP_ROOT" UP_UNATTENDED=1 "$UP_ROOT/bootstrap.sh"; then
    echo "UNATTENDED_INSTALL_FAIL"
    exit 1
fi

if [ ! -f "$STATE_DIR/install_complete.txt" ]; then
    echo "ERROR: bootstrap finished without install_complete.txt" >&2
    echo "UNATTENDED_INSTALL_FAIL"
    exit 1
fi

apply_vm_test_hooks() {
    local root="${1:-/mnt}"
    if [ ! -d "$root/etc" ]; then
        echo "WARNING: $root is not an installed root; skip VM hooks"
        return 0
    fi

    echo "Applying VM test hooks in $root..."
    arch-chroot "$root" pacman -S --noconfirm --needed openssh xdotool || true

    mkdir -p "$root/etc/ssh/sshd_config.d"
    cat > "$root/etc/ssh/sshd_config.d/50-up-vm-test.conf" <<'EOF'
PasswordAuthentication yes
PubkeyAuthentication yes
PermitRootLogin yes
EOF

    if [ -n "$SSH_PUBKEY" ] && [ -f "$SSH_PUBKEY" ]; then
        local home="$root/home/$USERNAME"
        mkdir -p "$home/.ssh" "$root/root/.ssh"
        cat "$SSH_PUBKEY" >> "$home/.ssh/authorized_keys"
        cat "$SSH_PUBKEY" >> "$root/root/.ssh/authorized_keys"
        chmod 700 "$home/.ssh" "$root/root/.ssh"
        chmod 600 "$home/.ssh/authorized_keys" "$root/root/.ssh/authorized_keys"
        arch-chroot "$root" chown -R "$USERNAME:$USERNAME" "/home/$USERNAME/.ssh" || true
    fi

    ln -sf /usr/lib/systemd/system/sshd.service \
        "$root/etc/systemd/system/multi-user.target.wants/sshd.service" 2>/dev/null || true
    arch-chroot "$root" systemctl enable sshd.service 2>/dev/null || true

    mkdir -p "$root/etc/lightdm/lightdm.conf.d"
    cat > "$root/etc/lightdm/lightdm.conf.d/60-up-vm-autologin.conf" <<EOF
[Seat:*]
autologin-user=$USERNAME
autologin-user-timeout=0
user-session=i3-up
EOF
    arch-chroot "$root" groupadd -f -r autologin || true
    arch-chroot "$root" gpasswd -a "$USERNAME" autologin || true

    mkdir -p "$root/etc/sudoers.d"
    # Lexically last in sudoers.d so it wins over %wheel ALL=(ALL) ALL.
    cat > "$root/etc/sudoers.d/zz-up-vm-test" <<EOF
$USERNAME ALL=(ALL) NOPASSWD: ALL
EOF
    chmod 440 "$root/etc/sudoers.d/zz-up-vm-test"

    mkdir -p "$root/var/lib/up"
    echo "VM_TEST=1 USER=$USERNAME" > "$root/var/lib/up/vm-test"

    # Alacritty needs a GL context. QEMU -display none has none unless we
    # force Mesa software rendering for the graphical session.
    local home="$root/home/$USERNAME"
    mkdir -p "$home"
    cat >> "$home/.xprofile" <<'EOF'
export LIBGL_ALWAYS_SOFTWARE=1
export GALLIUM_DRIVER=llvmpipe
export WINIT_UNIX_BACKEND=x11
EOF
    mkdir -p "$root/etc/environment.d"
    cat > "$root/etc/environment.d/50-up-vm-gl.conf" <<'EOF'
LIBGL_ALWAYS_SOFTWARE=1
GALLIUM_DRIVER=llvmpipe
EOF
    arch-chroot "$root" chown "$USERNAME:$USERNAME" "/home/$USERNAME/.xprofile" || true
    arch-chroot "$root" pacman -S --noconfirm --needed mesa || true
}

if [ "$VM_TEST" = "1" ]; then
    apply_vm_test_hooks /mnt
fi

echo "UNATTENDED_INSTALL_OK"
exit 0
