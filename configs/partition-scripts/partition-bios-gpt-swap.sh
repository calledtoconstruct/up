#!/bin/bash
# BIOS + GPT + Swap partition configuration: BIOS Boot + Swap + Root
# For legacy BIOS systems with disks >2TB and swap partition
# Sets: BIOS_BOOT_PART, SWAP_PART, ROOT_PART
# Requires: DISK, SWAP_TYPE - set by bootstrap.sh
# Requires: partition-utils.sh sourced

RAM_GB=$(get_ram_gb)
SWAP_SIZE_GB=$(calculate_swap_size)
log_info "Calculated swap size: ${SWAP_SIZE_GB}GB (based on ${RAM_GB}GB RAM)"

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

log_info "Creating swap partition (${SWAP_SIZE_GB}GB)..."
if ! sgdisk -n 2:0:+${SWAP_SIZE_GB}G -t 2:8200 "$DISK" >/dev/null 2>&1; then
    log_error "Failed to create swap partition on $DISK"
    exit 1
fi

log_info "Creating root partition..."
if ! sgdisk -n 3:0:0 -t 3:8300 "$DISK" >/dev/null 2>&1; then
    log_error "Failed to create root partition on $DISK"
    exit 1
fi

sgdisk -c 1:"BIOS Boot" "$DISK" >/dev/null 2>&1 || true
sgdisk -c 2:"Linux Swap" "$DISK" >/dev/null 2>&1 || true
sgdisk -c 3:"Linux Root" "$DISK" >/dev/null 2>&1 || true

BIOS_BOOT_PART=$(partition_device "$DISK" 1)
SWAP_PART=$(partition_device "$DISK" 2)
ROOT_PART=$(partition_device "$DISK" 3)

if ! wait_for_partitions "$DISK" "$BIOS_BOOT_PART" "$SWAP_PART" "$ROOT_PART"; then
    log_error "Partition devices did not appear after BIOS/GPT+swap layout on $DISK"
    exit 1
fi

log_info "GPT partitions created: bios_boot=$BIOS_BOOT_PART, swap=$SWAP_PART, root=$ROOT_PART"

EFI_PART=""
BOOT_PART="$BIOS_BOOT_PART"
SWAP_TYPE="partition"
