#!/bin/bash
# BIOS + MBR partition configuration: Boot + Root (no swap partition)
# For legacy BIOS systems with disks ≤2TB
# Sets: BOOT_PART, ROOT_PART, SWAP_PART
# Requires: DISK, SWAP_TYPE - set by bootstrap.sh
# Requires: partition-utils.sh sourced

SWAP_PART=""

log_info "Wiping disk $DISK and creating MBR partition table..."
if ! printf 'label: dos\n' | sfdisk "$DISK" >/dev/null 2>&1; then
    log_error "Failed to wipe disk $DISK"
    exit 1
fi

log_info "Creating boot partition (512MB) and root partition..."
if ! printf 'label: dos\n,512M,L,*\n,,L\n' | sfdisk "$DISK" >/dev/null 2>&1; then
    log_error "Failed to create partitions on $DISK"
    exit 1
fi

BOOT_PART=$(partition_device "$DISK" 1)
ROOT_PART=$(partition_device "$DISK" 2)

if ! wait_for_partitions "$DISK" "$BOOT_PART" "$ROOT_PART"; then
    log_error "Partition devices did not appear after MBR layout on $DISK"
    exit 1
fi

log_info "MBR partitions created: boot=$BOOT_PART, root=$ROOT_PART"

EFI_PART=""
