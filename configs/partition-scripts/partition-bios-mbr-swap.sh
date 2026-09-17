#!/bin/bash
# BIOS + MBR + Swap partition configuration: Boot + Swap + Root
# For legacy BIOS systems with disks ≤2TB and swap partition
# Sets: BOOT_PART, SWAP_PART, ROOT_PART
# Requires: DISK, SWAP_TYPE - set by bootstrap.sh
# Requires: partition-utils.sh sourced

RAM_GB=$(get_ram_gb)
SWAP_SIZE_GB=$(calculate_swap_size)
log_info "Calculated swap size: ${SWAP_SIZE_GB}GB (based on ${RAM_GB}GB RAM)"

log_info "Wiping disk $DISK and creating MBR partition table..."
if ! printf 'label: dos\n' | sfdisk "$DISK" >/dev/null 2>&1; then
    log_error "Failed to wipe disk $DISK"
    exit 1
fi

log_info "Creating boot (512MB), swap (${SWAP_SIZE_GB}GB), and root partitions..."
if ! printf "label: dos\n,512M,L,*\n,${SWAP_SIZE_GB}G,S\n,,L\n" | sfdisk "$DISK" >/dev/null 2>&1; then
    log_error "Failed to create partitions on $DISK"
    exit 1
fi

BOOT_PART=$(partition_device "$DISK" 1)
SWAP_PART=$(partition_device "$DISK" 2)
ROOT_PART=$(partition_device "$DISK" 3)

if ! wait_for_partitions "$DISK" "$BOOT_PART" "$SWAP_PART" "$ROOT_PART"; then
    log_error "Partition devices did not appear after MBR+swap layout on $DISK"
    exit 1
fi

log_info "MBR partitions created: boot=$BOOT_PART, swap=$SWAP_PART, root=$ROOT_PART"

EFI_PART=""
SWAP_TYPE="partition"
