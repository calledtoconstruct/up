#!/bin/bash
# Partition Calculation Utilities
# Shared functions for partition size calculations
#
# This file provides a single source of truth for partition size calculations,
# ensuring consistency between the installation preview (input-watcher.sh)
# and the actual partitioning (bootstrap.sh and partition scripts).
#
# The swap size formula is designed for hibernation support:
# - RAM < 2GB: 2GB swap (minimum for hibernation)
# - RAM 2-32GB: swap = RAM (full hibernation support)
# - RAM > 32GB: 32GB swap (diminishing returns, save disk space)

# Guard against multiple sourcing
# If this file is sourced multiple times, skip re-execution
if [ -n "${PARTITION_UTILS_LOADED:-}" ]; then
    return 0
fi
PARTITION_UTILS_LOADED=1

# Calculate swap size based on RAM
# Returns swap size in GB
# Formula: RAM < 2GB → 2GB, RAM > 32GB → 32GB, else = RAM
calculate_swap_size() {
    local ram_kb=$(grep MemTotal /proc/meminfo | awk '{print $2}')
    local ram_gb=$((ram_kb / 1024 / 1024))
    echo $((ram_gb > 32 ? 32 : (ram_gb < 2 ? 2 : ram_gb)))
}

# Calculate RAM size in GB
get_ram_gb() {
    local ram_kb=$(grep MemTotal /proc/meminfo | awk '{print $2}')
    echo $((ram_kb / 1024 / 1024))
}

# Calculate root partition size
# Takes disk size (GB) and swap size (GB) as arguments
# Subtracts 1GB for EFI/BIOS boot partition
calculate_root_size() {
    local disk_gb="$1"
    local swap_gb="$2"
    echo $((disk_gb - swap_gb - 1))
}

# Get all partition sizes as variables
# Usage: eval "$(get_partition_sizes <disk_size_gb>)"
# Sets: SWAP_SIZE, ROOT_SIZE, RAM_GB
get_partition_sizes() {
    local disk_gb="$1"
    local ram_gb=$(get_ram_gb)
    local swap_gb=$((ram_gb > 32 ? 32 : (ram_gb < 2 ? 2 : ram_gb)))
    local root_gb=$((disk_gb - swap_gb - 1))
    
    echo "RAM_GB=$ram_gb"
    echo "SWAP_SIZE=$swap_gb"
    echo "ROOT_SIZE=$root_gb"
}

# Build a partition device path for a disk and partition number.
# Disks that use a "p" separator (nvme, mmcblk, loop, nbd, md): /dev/nvme0n1p1
# Classic SCSI/SATA/virtio names: /dev/sda1, /dev/vda1
# Usage: part=$(partition_device "$DISK" 1)
partition_device() {
    local disk="$1"
    local num="$2"
    local base
    base=$(basename "$disk")

    case "$base" in
        nvme*|mmcblk*|loop*|nbd*|md*)
            echo "${disk}p${num}"
            ;;
        *)
            echo "${disk}${num}"
            ;;
    esac
}

# Wait for kernel partition nodes after partitioning, then assert they exist.
# Usage: wait_for_partitions "$DISK" "/dev/sda1" "/dev/sda2"
wait_for_partitions() {
    local disk="$1"
    shift
    local parts=("$@")
    local part
    local attempts=0
    local max_attempts=20

    # Refresh kernel partition table
    partprobe "$disk" 2>/dev/null || true
    sleep 1

    while [ $attempts -lt $max_attempts ]; do
        local all_present=true
        for part in "${parts[@]}"; do
            if [ ! -b "$part" ]; then
                all_present=false
                break
            fi
        done
        if $all_present; then
            return 0
        fi
        sleep 0.5
        attempts=$((attempts + 1))
        partprobe "$disk" 2>/dev/null || true
    done

    for part in "${parts[@]}"; do
        if [ ! -b "$part" ]; then
            if declare -f log_error >/dev/null 2>&1; then
                log_error "Partition device not found after partitioning: $part"
            else
                echo "ERROR: Partition device not found after partitioning: $part" >&2
            fi
            return 1
        fi
    done
    return 0
}

# Cleanup partitions and bind mounts after a failed/cancelled install.
# Safe to call from traps; does not re-enter bootstrap/setup.
# Usage: cleanup_partitions [disk]
cleanup_partitions() {
    local disk="${1:-${DISK:-}}"
    local chroot_state="${CHROOT_STATE_DIR:-/mnt/up-state}"
    local chroot_log="${CHROOT_LOG_DIR:-/mnt/var/log/up}"

    if mountpoint -q "$chroot_state" 2>/dev/null; then
        umount "$chroot_state" 2>/dev/null || true
    fi
    if mountpoint -q "$chroot_log" 2>/dev/null; then
        umount "$chroot_log" 2>/dev/null || true
    fi

    # Recursive unmount of install target
    if mountpoint -q /mnt 2>/dev/null; then
        umount --recursive /mnt 2>/dev/null || true
    fi
    for mount_point in /mnt/boot/efi /mnt/boot /mnt; do
        if mountpoint -q "$mount_point" 2>/dev/null; then
            umount -R "$mount_point" 2>/dev/null || true
        fi
    done

    if [ -n "$disk" ]; then
        for swap_dev in $(swapon --show=NAME --noheadings 2>/dev/null); do
            if [[ "$swap_dev" == "$disk"* ]]; then
                swapoff "$swap_dev" 2>/dev/null || true
            fi
        done
        partprobe "$disk" 2>/dev/null || true
        if declare -f log_info >/dev/null 2>&1; then
            log_info "Cleanup complete for $disk"
        fi
    else
        swapoff -a 2>/dev/null || true
    fi
}

# Export functions for use in other scripts
export -f calculate_swap_size
export -f get_ram_gb
export -f calculate_root_size
export -f get_partition_sizes
export -f partition_device
export -f wait_for_partitions
export -f cleanup_partitions