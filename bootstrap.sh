#!/bin/bash
set -euo pipefail

# UP_ROOT environment variable must be set by calling script
if [ -z "${UP_ROOT:-}" ]; then
    echo "ERROR: UP_ROOT environment variable not set"
    exit 1
fi

# Export for child scripts
export UP_ROOT

source "$UP_ROOT/configs/scripts/logging.sh"
source "$UP_ROOT/configs/scripts/error-handling.sh"
source "$UP_ROOT/configs/scripts/colors.sh"
source "$UP_ROOT/configs/scripts/package-groups.sh"
source "$UP_ROOT/configs/scripts/detect-boot-mode.sh"
source "$UP_ROOT/configs/scripts/state-utils.sh"
source "$UP_ROOT/configs/scripts/partition-utils.sh"

# Initialize error handling before setting up traps
initialize_error_handling

# State Management for Host/Chroot Communication
#
# CRITICAL WORKAROUND: Host/Chroot Filesystem Isolation
# Problem: During installation, we run bootstrap.sh on the host (Arch ISO) and
# setup.sh inside a chroot environment. These are completely isolated filesystems
# - the chroot can't see /tmp/up-state from the host, and the host can't see
# files created inside the chroot.
#
# Solution: Use bind mounts to create shared directories that both environments
# can access. The host creates the directories first, then bind mounts them
# into the chroot's filesystem. This allows:
# - Input collection (host) → Installation state (chroot)
# - Progress updates (chroot) → TUI display (host)
# - Log sharing (both directions)
#
# STATE_DIR: Where the host stores state files (/tmp/up-state)
# CHROOT_STATE_DIR: Where the chroot sees the same files (/mnt/up-state)
# LOG_DIR: Shared log directory (/var/log/up)
# CHROOT_LOG_DIR: Where the chroot sees logs (/mnt/var/log/up)
STATE_DIR="/tmp/up-state"
CHROOT_STATE_DIR="/mnt/up-state"
LOG_DIR="/var/log/up"
CHROOT_LOG_DIR="/mnt/var/log/up"

# Create directories on host first - required for bind mount to work
# The bind mount will fail if the source directory doesn't exist
mkdir -p "$STATE_DIR"
chmod -R 755 "$STATE_DIR"
mkdir -p "$LOG_DIR"
chmod -R 755 "$LOG_DIR"

update_phase 1 "Welcome & Repo"
# Progress total is owned by install.sh state; read or fall back
PROGRESS_TOTAL=$(state_get "progress_total.txt")
PROGRESS_TOTAL="${PROGRESS_TOTAL:-30}"
update_progress 0 "$PROGRESS_TOTAL" "Initializing..."

# cleanup_partitions is provided by partition-utils.sh (never source bootstrap for cleanup)

# Install prerequisites and navigate to repository
update_progress 1 "$PROGRESS_TOTAL" "Installing prerequisites..."
run_and_log pacman -Sy --noconfirm --needed --quiet git gptfdisk

REPO_DIR="/root/up"
cd "$REPO_DIR"
log_info "Welcome to Up Linux installation!"

# Disk selection and validation.
# Input pane commits disk/boot_mode/partition_table/partition_choice/confirm
# atomically only after the user confirms — so we never consume a partial
# selection, and "back" in the UI cannot strand bootstrap waiting forever.
update_phase 2 "Disk Selection"
update_progress 2 "$PROGRESS_TOTAL" "Waiting for disk selection..."

# Show available disks in the log (UI also shows them in the input pane)
disk_list=$(lsblk -d -o NAME,MODEL,SIZE,ROTA 2>/dev/null |
            sed 's/ROTA/TYPE/' |
            sed 's/1$/HDD/' |
            sed 's/0$/SSD/' ||
            echo "Disk listing not available")
log_info "Available disks:"
echo "$disk_list" | while read -r line; do log_info "  $line"; done

# Extract largest available disk as default (used only if answer is empty)
default_disk=""
if [ "$disk_list" != "Disk listing not available" ]; then
    disk_sizes_bytes=$(lsblk -d -o NAME,SIZE -b 2>/dev/null | awk 'NR>1 {print $1, $2}' 2>/dev/null || echo "")
    if [ -n "$disk_sizes_bytes" ]; then
        default_disk=$(echo "$disk_sizes_bytes" | sort -k2 -nr | head -1 | awk '{print "/dev/"$1}' 2>/dev/null || echo "")
    fi
fi

while true; do
    update_progress 2 "$PROGRESS_TOTAL" "Waiting for disk selection..."
    DISK=$(read_input "disk" "$default_disk")
    # Normalize path (strip accidental whitespace/CR; ensure /dev/ prefix)
    DISK="${DISK//$'\r'/}"
    DISK="${DISK#"${DISK%%[![:space:]]*}"}"
    DISK="${DISK%"${DISK##*[![:space:]]}"}"
    if [ -n "$DISK" ] && [[ ! "$DISK" =~ ^/dev/ ]]; then
        DISK="/dev/${DISK#/dev/}"
    fi

    if [ -z "$DISK" ]; then
        log_info "Disk selection cancelled or empty."
        request_reprompt "disk" "Disk path was empty. Please select a disk."
        continue
    fi

    # Validate disk exists as a block device
    if [ ! -b "$DISK" ]; then
        log_info "ERROR: '$DISK' is not a valid block device."
        # Helpful diagnostics when the path looks right but -b fails
        log_info "  lsblk: $(lsblk -d -n -o NAME,TYPE,SIZE "$DISK" 2>&1 || true)"
        log_info "  stat:  $(stat -c '%F %n' "$DISK" 2>&1 || true)"
        request_reprompt "disk" "'$DISK' is not a valid block device. Please select again."
        # Also clear dependent answers so a full re-confirm is required
        clear_answer "boot_mode"
        clear_answer "partition_table_type"
        clear_answer "partition_choice"
        clear_answer "confirm_partition"
        continue
    fi

    disk_size_bytes=$(blockdev --getsize64 "$DISK" 2>/dev/null || echo 0)
    DISK_SIZE_BYTES=$disk_size_bytes
    DISK_SIZE_GB=$((disk_size_bytes / 1024 / 1024 / 1024))
    log_info "Selected disk: $DISK (${DISK_SIZE_GB}GB)"

    # Set up error trap for cleanup after DISK is set
    trap 'cleanup_partitions "$DISK"' ERR

    update_progress 2 "$PROGRESS_TOTAL" "Waiting for boot/partition options..."
    BOOT_MODE=$(read_input "boot_mode" "uefi")
    PARTITION_TABLE_TYPE=$(read_input "partition_table_type" "gpt")

    update_progress 3 "$PROGRESS_TOTAL" "Configuring partitioning for $DISK (${DISK_SIZE_GB}GB)..."

    PARTITION_CHOICE=$(read_input "partition_choice")

    case "$PARTITION_CHOICE" in
        1|2)
            break
            ;;
        *)
            log_info "ERROR: Invalid partition choice '$PARTITION_CHOICE'"
            request_reprompt "partition_choice" "Invalid partition choice. Please select 1 or 2."
            clear_answer "confirm_partition"
            # Re-read only partition_choice (disk/boot still valid)
            continue
            ;;
    esac
done

# Verify user confirmed partitioning (committed with the rest of disk config)
update_progress 3 "$PROGRESS_TOTAL" "Waiting for partition confirmation..."
CONFIRM_PARTITION=$(read_input "confirm_partition")
if [ "$CONFIRM_PARTITION" != "yes" ]; then
    log_info "Partitioning not confirmed (got: ${CONFIRM_PARTITION:-empty}). Cancelling."
    echo "cancelled" > "$STATE_DIR/install_cancelled.txt"
    exit 1
fi

SWAP_TYPE="none"
SWAP_PART=""
    case "$PARTITION_CHOICE" in
        1)  # Standard (No Swap)
            update_phase 3 "Partitioning"
            update_progress 4 "$PROGRESS_TOTAL" "Creating standard partitions..."
            if [ "$BOOT_MODE" = "uefi" ]; then
                source "$REPO_DIR/configs/partition-scripts/partition-standard.sh"
            elif [ "$PARTITION_TABLE_TYPE" = "gpt" ]; then
                source "$REPO_DIR/configs/partition-scripts/partition-bios-gpt.sh"
            else
                source "$REPO_DIR/configs/partition-scripts/partition-bios-mbr.sh"
            fi
            ;;
        2)  # Standard + Swap
            update_phase 3 "Partitioning"
            update_progress 4 "$PROGRESS_TOTAL" "Creating partitions with swap..."
            RAM_GB=$(get_ram_gb)
            SWAP_SIZE_GB=$(calculate_swap_size)
            log_info "Calculated swap size: ${SWAP_SIZE_GB}GB (based on ${RAM_GB}GB RAM)"
            if [ "$BOOT_MODE" = "uefi" ]; then
                source "$REPO_DIR/configs/partition-scripts/partition-swap.sh"
            elif [ "$PARTITION_TABLE_TYPE" = "gpt" ]; then
                source "$REPO_DIR/configs/partition-scripts/partition-bios-gpt-swap.sh"
            else
                source "$REPO_DIR/configs/partition-scripts/partition-bios-mbr-swap.sh"
            fi
            ;;
    esac

# Installation progress
update_phase 4 "Formatting & Mounting"
update_progress 5 "$PROGRESS_TOTAL" "Formatting partitions..."

# Format partitions based on boot mode
if [ "$BOOT_MODE" = "uefi" ]; then
    log_info "Formatting EFI partition ($EFI_PART) as FAT32..."
    run_and_log mkfs.fat -F32 "$EFI_PART"
else
    if [ -n "${BOOT_PART:-}" ] && [ -n "$BOOT_PART" ]; then
        log_info "Formatting boot partition ($BOOT_PART) as ext4..."
        run_and_log mkfs.ext4 -F "$BOOT_PART"
    fi
fi

log_info "Formatting root partition ($ROOT_PART)..."
run_and_log mkfs.ext4 -F "$ROOT_PART"

if [ "$SWAP_TYPE" = "partition" ] && [ -n "$SWAP_PART" ]; then
    run_and_log mkswap "$SWAP_PART"
    run_and_log swapon "$SWAP_PART"
fi

update_progress 6 "$PROGRESS_TOTAL" "Mounting partitions..."
run_and_log mount "$ROOT_PART" /mnt
run_and_log mkdir -p /mnt/boot

if [ "$BOOT_MODE" = "uefi" ]; then
    log_info "Mounting EFI partition ($EFI_PART) to /mnt/boot..."
    run_and_log mount "$EFI_PART" /mnt/boot
else
    if [ -n "${BOOT_PART:-}" ] && [ -n "$BOOT_PART" ]; then
        log_info "Mounting boot partition ($BOOT_PART) to /mnt/boot..."
        run_and_log mount "$BOOT_PART" /mnt/boot
    fi
fi

# Set up bind mounts for host/chroot communication
log_info "Setting up bind mounts for state and log sharing..."
mkdir -p "$CHROOT_STATE_DIR"
mount --bind "$STATE_DIR" "$CHROOT_STATE_DIR"
mkdir -p "$CHROOT_LOG_DIR"
mount --bind "$LOG_DIR" "$CHROOT_LOG_DIR"



update_phase 5 "Pacstrapping Base"
update_progress 7 "$PROGRESS_TOTAL" "Installing base system..."

# Pacstrap with error handling and retry
while true; do
    if run_pacstrap_with_progress -K /mnt base linux linux-firmware networkmanager git sudo base-devel; then
        log_info "Pacstrap completed successfully"
        break
    fi
    
    # Pacstrap failed - notify input watcher and wait for a fresh response
    log_error "Pacstrap failed - possibly due to network issues"
    clear_answer "pacstrap_retry"
    state_set "pacstrap_failed.txt" "Pacstrap failed - possibly due to network issues. Check your connection and try again."
    
    retry=$(read_input "pacstrap_retry")
    
    if [ "$retry" = "retry" ]; then
        log_info "Retrying pacstrap..."
        rm -f "$STATE_DIR/pacstrap_failed.txt"
        clear_answer "pacstrap_retry"
        continue
    else
        log_info "User chose to exit. Exiting..."
        echo "cancelled" > "$STATE_DIR/install_cancelled.txt"
        cleanup_partitions "$DISK"
        exit 1
    fi
done

update_progress 8 "$PROGRESS_TOTAL" "Generating fstab..."
FSTAB_OUTPUT=$(genfstab -U /mnt 2>&1) || true
echo "$FSTAB_OUTPUT" >> /mnt/etc/fstab
log_info "$FSTAB_OUTPUT"

update_progress 9 "$PROGRESS_TOTAL" "Configuring swap..."

if [ "$SWAP_TYPE" = "file" ]; then
    run_and_log dd if=/dev/zero of=/mnt/swapfile bs=1M count=4096 status=progress
    run_and_log chmod 600 /mnt/swapfile
    run_and_log mkswap /mnt/swapfile
    echo '/swapfile none swap sw 0 0' >> /mnt/etc/fstab
fi

if [ "$SWAP_TYPE" = "zram" ]; then
    cat > /mnt/etc/systemd/system/zram-setup.service << 'EOF'
[Unit]
Description=Setup zram swap
After=local-fs.target

[Service]
Type=oneshot
ExecStart=/usr/bin/bash -c 'echo lz4 > /sys/block/zram0/comp_algorithm'
ExecStart=/usr/bin/bash -c 'echo 2G > /sys/block/zram0/disksize'
ExecStart=/usr/bin/mkswap /dev/zram0
ExecStart=/usr/bin/swapon /dev/zram0 -p 100

[Install]
WantedBy=multi-user.target
EOF
    mkdir -p /mnt/etc/modprobe.d
    echo "options zram num_devices=1" > /mnt/etc/modprobe.d/zram.conf
fi

update_progress 10 "$PROGRESS_TOTAL" "Copying files..."
mkdir -p /mnt/root/up
cp -a . /mnt/root/up/

echo "SWAP_TYPE=$SWAP_TYPE" > /mnt/root/up/.swap-config

# Save boot configuration for setup.sh (chroot environment)
cat > /mnt/root/up/.boot-config <<EOF
BOOT_MODE=$BOOT_MODE
PARTITION_TABLE_TYPE=$PARTITION_TABLE_TYPE
DISK=$DISK
EOF

# Save bootstrap state for welcome wizard
echo "BOOTSTRAP_PACKAGE_COUNT=$BOOTSTRAP_PACKAGE_COUNT" > /mnt/root/up/.bootstrap-state

# Verify setup.sh exists and is executable
if [ ! -f "/mnt/root/up/setup.sh" ]; then
    log_error "setup.sh not found in chroot!"
    exit 1
fi
if [ ! -x "/mnt/root/up/setup.sh" ]; then
    chmod +x /mnt/root/up/setup.sh
fi

update_progress 11 "$PROGRESS_TOTAL" "Base installation complete!"
log_info "Handing off to setup.sh..."
sleep 1

# Run setup.sh in chroot with UP_ROOT environment variable
UP_ROOT=/root/up arch-chroot /mnt /root/up/setup.sh

# Signal completion and cleanup bind mounts
echo "complete" > "$STATE_DIR/install_complete.txt"
umount "$CHROOT_STATE_DIR" 2>/dev/null || true
umount "$CHROOT_LOG_DIR" 2>/dev/null || true

echo ""
print_success "Installation complete! Check the input pane for reboot options."
echo ""
