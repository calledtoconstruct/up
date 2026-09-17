#!/bin/bash
# Standard + Swap partition configuration: EFI + Swap + Root
# Sets: EFI_PART, ROOT_PART, SWAP_TYPE, SWAP_PART, SWAP_SIZE_GB
# Requires: DISK - set by bootstrap.sh
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

log_info "Creating EFI partition (512MB)..."
if ! sgdisk -n 1:0:+512M -t 1:EF00 "$DISK" >/dev/null 2>&1; then
    log_error "Failed to create EFI partition on $DISK"
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

sgdisk -c 1:"EFI System" "$DISK" >/dev/null 2>&1 || true
sgdisk -c 2:"Linux Swap" "$DISK" >/dev/null 2>&1 || true
sgdisk -c 3:"Linux Root" "$DISK" >/dev/null 2>&1 || true

EFI_PART=$(partition_device "$DISK" 1)
SWAP_PART=$(partition_device "$DISK" 2)
ROOT_PART=$(partition_device "$DISK" 3)

if ! wait_for_partitions "$DISK" "$EFI_PART" "$SWAP_PART" "$ROOT_PART"; then
    log_error "Partition devices did not appear after GPT+swap layout on $DISK"
    exit 1
fi

SWAP_TYPE="partition"
log_info "GPT partitions created: efi=$EFI_PART, swap=$SWAP_PART, root=$ROOT_PART"
