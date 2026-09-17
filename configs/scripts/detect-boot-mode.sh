#!/bin/bash
# Boot Mode Detection Script for Up Linux Installer
# Detects whether the system is booting in UEFI or Legacy BIOS mode
#
# Usage:
#   source detect-boot-mode.sh
#   mode=$(detect_boot_mode)
#   echo "Boot mode: $mode"  # Outputs: "uefi" or "bios"

detect_boot_mode() {
    # Check if EFI variables are available
    # /sys/firmware/efi/efivars exists on UEFI systems
    if [ -d /sys/firmware/efi/efivars ]; then
        echo "uefi"
    else
        echo "bios"
    fi
}

# Export the function for use in other scripts
export -f detect_boot_mode