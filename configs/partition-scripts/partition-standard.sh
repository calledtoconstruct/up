#!/bin/bash
# Standard partition configuration: EFI + Root (no swap partition)
# Sets: EFI_PART, ROOT_PART, SWAP_PART
# Requires: DISK, SWAP_TYPE (file, zram, or none) - set by bootstrap.sh
# Requires: partition-utils.sh sourced (partition_device, wait_for_partitions)

SWAP_PART=""

log_info "Wiping disk $DISK and creating GPT partition table..."
if ! sgdisk -Z "$DISK" >/dev/null 2>&1; then
    log_error "Failed to wipe disk $DISK"
    exit 1
fi
if ! sgdisk -o "$DISK" >/dev/null 2>&1; then
    log_error "Failed to create GPT partition table on $DISK"
    exit 1
fi

log_info "Creating EFI partition (512MB)..."
if ! sgdisk -n 1:0:+512M -t 1:EF00 "$DISK" >/dev/null 2>&1; then
    log_error "Failed to create EFI partition on $DISK"
    exit 1
fi

log_info "Creating root partition..."
if ! sgdisk -n 2:0:0 -t 2:8300 "$DISK" >/dev/null 2>&1; then
    log_error "Failed to create root partition on $DISK"
    exit 1
fi

sgdisk -c 1:"EFI System" "$DISK" >/dev/null 2>&1 || true
sgdisk -c 2:"Linux Root" "$DISK" >/dev/null 2>&1 || true

EFI_PART=$(partition_device "$DISK" 1)
ROOT_PART=$(partition_device "$DISK" 2)

if ! wait_for_partitions "$DISK" "$EFI_PART" "$ROOT_PART"; then
    log_error "Partition devices did not appear after GPT layout on $DISK"
    exit 1
fi

log_info "GPT partitions created: efi=$EFI_PART, root=$ROOT_PART"
