#!/bin/bash
# BIOS + GPT partition configuration: BIOS Boot + Root (no swap partition)
# For legacy BIOS systems with disks >2TB
# Sets: BIOS_BOOT_PART, ROOT_PART, SWAP_PART
# Requires: DISK, SWAP_TYPE - set by bootstrap.sh
# Requires: partition-utils.sh sourced

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

log_info "Creating BIOS boot partition (1MB)..."
if ! sgdisk -n 1:0:+1M -t 1:EF02 "$DISK" >/dev/null 2>&1; then
    log_error "Failed to create BIOS boot partition on $DISK"
    exit 1
fi

log_info "Creating root partition..."
if ! sgdisk -n 2:0:0 -t 2:8300 "$DISK" >/dev/null 2>&1; then
    log_error "Failed to create root partition on $DISK"
    exit 1
fi

sgdisk -c 1:"BIOS Boot" "$DISK" >/dev/null 2>&1 || true
sgdisk -c 2:"Linux Root" "$DISK" >/dev/null 2>&1 || true

BIOS_BOOT_PART=$(partition_device "$DISK" 1)
ROOT_PART=$(partition_device "$DISK" 2)

if ! wait_for_partitions "$DISK" "$BIOS_BOOT_PART" "$ROOT_PART"; then
    log_error "Partition devices did not appear after BIOS/GPT layout on $DISK"
    exit 1
fi

log_info "GPT partitions created: bios_boot=$BIOS_BOOT_PART, root=$ROOT_PART"

EFI_PART=""
BOOT_PART="$BIOS_BOOT_PART"
