#!/bin/bash
# Input collector for installation
# Collects all required inputs and writes to state files for bootstrap.sh

set -euo pipefail

STATE_DIR="/tmp/up-state"
SCRIPT_DIR="$(dirname "$0")"
source "$SCRIPT_DIR/colors.sh"
source "$SCRIPT_DIR/detect-boot-mode.sh"
source "$SCRIPT_DIR/partition-utils.sh"
source "$SCRIPT_DIR/state-utils.sh"

# Validation functions
validate_username() {
    [[ "$1" =~ ^[a-z][a-z0-9_-]*$ ]] && [ ${#1} -le 32 ]
}

validate_hostname() {
    [[ "$1" =~ ^[a-zA-Z0-9-]+$ ]] && [ ${#1} -le 63 ]
}

validate_timezone() {
    [[ -f "/usr/share/zoneinfo/$1" ]]
}

# Detect hardware for hostname suggestion
detect_hostname_suggestion() {
    local suggestion="up-computer"
    
    if [ -d /sys/class/dmi/id ]; then
        local chassis=$(cat /sys/class/dmi/id/chassis_type 2>/dev/null || echo "0")
        local product=$(cat /sys/class/dmi/id/product_name 2>/dev/null || echo "")
        
        case "$chassis" in
            8|9|10|11|12|13|14|30|31|32) suggestion="up-laptop" ;;
            3|4|5|6|7|15|16) suggestion="up-desktop" ;;
        esac
        
        if [ -n "$product" ]; then
            local sanitized=$(echo "$product" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/-/g' | sed 's/--*/-/g' | head -c 20)
            [[ ! "$sanitized" =~ ^(system|product|to-be-filled) ]] && suggestion="up-$sanitized"
        fi
    fi
    
    echo "$suggestion"
}

# Fuzzy match timezone
fuzzy_match_timezone() {
    local input="$1"
    local input_lower=$(echo "$input" | tr '[:upper:]' '[:lower:]')
    
    [[ -f "/usr/share/zoneinfo/$input" ]] && echo "$input" && return 0
    
    local match=$(find /usr/share/zoneinfo -type f 2>/dev/null | grep -i "$input_lower" | grep -v "^/usr/share/zoneinfo/right/" | grep -v "^/usr/share/zoneinfo/Etc/" | head -1)
    [[ -n "$match" ]] && echo "${match#/usr/share/zoneinfo/}" && return 0
    
    match=$(find /usr/share/zoneinfo -type f -name "*${input}*" 2>/dev/null | head -1)
    [[ -n "$match" ]] && echo "${match#/usr/share/zoneinfo/}" && return 0
    
    return 1
}

# Display available disks in formatted table
show_disks() {
    echo -e "${CYAN}Available Disks:${NC}"
    printf "${YELLOW}%-12s %-8s %-10s %-20s${NC}\n" "DEVICE" "TYPE" "SIZE" "MODEL"
    
    local recommended_disk="" max_size=0
    
    while IFS= read -r line; do
        local name=$(echo "$line" | awk '{print $1}')
        local size=$(echo "$line" | awk '{print $2}')
        local model=$(echo "$line" | awk '{$1=$2=""; print $0}' | xargs)
        local rota=$(echo "$line" | awk '{print $NF}')
        local type="HDD"
        [ "$rota" = "0" ] && type="SSD"
        
        local size_bytes=$(blockdev --getsize64 "/dev/$name" 2>/dev/null || echo 0)
        [ "$size_bytes" -gt "$max_size" ] && max_size="$size_bytes" && recommended_disk="/dev/$name"
        
        local color="$NC"
        [ "$type" = "SSD" ] && color="$GREEN"
        [ "$type" = "HDD" ] && color="$YELLOW"
        
        printf "${color}%-12s %-8s %-10s %-20s${NC}\n" "/dev/$name" "$type" "$size" "$model"
    done < <(lsblk -d -o NAME,SIZE,MODEL,ROTA 2>/dev/null | awk 'NR>1')
    
    echo -e "${GREEN}★ Recommended: $recommended_disk (largest)${NC}"
}

# Show partition preview with visual layout
show_partition_preview() {
    local disk="$1" choice="$2" disk_size_gb="$3" boot_mode="${4:-uefi}" partition_table_type="${5:-gpt}"
    
    # Calculate partition sizes using shared functions
    local ram_gb=$(get_ram_gb)
    local swap_gb=$(calculate_swap_size)
    local root_gb=$(calculate_root_size "$disk_size_gb" "$swap_gb")
    
    echo ""
    echo -e "${RED}⚠️  WARNING: This will COMPLETELY WIPE the selected disk!${NC}"
    echo -e "${RED}   All data on $disk (${disk_size_gb}GB) will be permanently lost!${NC}"
    echo ""
    
    # Show boot mode and partition table info
    echo -e "${CYAN}Boot Mode: ${YELLOW}$boot_mode${NC}"
    [ "$boot_mode" = "bios" ] && echo -e "${CYAN}Partition Table: ${YELLOW}$partition_table_type${NC}"
    echo ""
    
    case "$choice" in
        1)  # Standard (No Swap)
            if [ "$boot_mode" = "uefi" ]; then
                echo -e "${YELLOW}Partition Layout (Standard - UEFI):${NC}"
                echo -e "${YELLOW}┌─────────────────────────────────────────────────────┐${NC}"
                echo -e "${YELLOW}│ EFI (512MB) │${GREEN} Root (${disk_size_gb}GB ext4)${YELLOW}                  │${NC}"
                echo -e "${YELLOW}└─────────────────────────────────────────────────────┘${NC}"
            elif [ "$partition_table_type" = "gpt" ]; then
                echo -e "${YELLOW}Partition Layout (Standard - BIOS/GPT):${NC}"
                echo -e "${YELLOW}┌─────────┬────────────────────────────────────────────┐${NC}"
                echo -e "${YELLOW}│ BIOS    │${GREEN} Root (${disk_size_gb}GB ext4)${YELLOW}                        │${NC}"
                echo -e "${YELLOW}│ 1MB     │                                              │${NC}"
                echo -e "${YELLOW}└─────────┴────────────────────────────────────────────┘${NC}"
            else
                echo -e "${YELLOW}Partition Layout (Standard - BIOS/MBR):${NC}"
                echo -e "${YELLOW}┌─────────────────────────────────────────────────────┐${NC}"
                echo -e "${YELLOW}│ Boot (512MB) │${GREEN} Root (${disk_size_gb}GB ext4)${YELLOW}                  │${NC}"
                echo -e "${YELLOW}└─────────────────────────────────────────────────────┘${NC}"
            fi
            ;;
        2)  # Standard + Swap
            if [ "$boot_mode" = "uefi" ]; then
                echo -e "${YELLOW}Partition Layout (Standard + Swap - UEFI):${NC}"
                echo -e "${YELLOW}┌──────────┬──────────────┬──────────────────────────┐${NC}"
                echo -e "${YELLOW}│ EFI      │ Swap         │${GREEN} Root${YELLOW}                    │${NC}"
                echo -e "${YELLOW}│ 512MB    │ ${swap_gb}GB         │ ${root_gb}GB ext4              │${NC}"
                echo -e "${YELLOW}└──────────┴──────────────┴──────────────────────────┘${NC}"
            elif [ "$partition_table_type" = "gpt" ]; then
                echo -e "${YELLOW}Partition Layout (Standard + Swap - BIOS/GPT):${NC}"
                echo -e "${YELLOW}┌─────────┬──────────────┬──────────────────────────┐${NC}"
                echo -e "${YELLOW}│ BIOS    │ Swap         │${GREEN} Root${YELLOW}                    │${NC}"
                echo -e "${YELLOW}│ 1MB     │ ${swap_gb}GB         │ ${root_gb}GB ext4              │${NC}"
                echo -e "${YELLOW}└─────────┴──────────────┴──────────────────────────┘${NC}"
            else
                echo -e "${YELLOW}Partition Layout (Standard + Swap - BIOS/MBR):${NC}"
                echo -e "${YELLOW}┌──────────┬──────────────┬──────────────────────────┐${NC}"
                echo -e "${YELLOW}│ Boot     │ Swap         │${GREEN} Root${YELLOW}                    │${NC}"
                echo -e "${YELLOW}│ 512MB    │ ${swap_gb}GB         │ ${root_gb}GB ext4              │${NC}"
                echo -e "${YELLOW}└──────────┴──────────────┴──────────────────────────┘${NC}"
            fi
            ;;
    esac
    
    echo ""
    echo -e "${CYAN}Current partitions on $disk:${NC}"
    lsblk "$disk" 2>/dev/null || echo "No existing partitions"
}

# Dynamic timezone picker with regional grouping
select_timezone() {
    echo -e "${CYAN}Select your timezone:${NC}" >&2
    echo "" >&2
    
    # Query all timezones from system (timedatectl is always available on Arch ISO)
    local all_tz_output
    all_tz_output=$(timedatectl list-timezones 2>/dev/null)
    
    if [ -z "$all_tz_output" ]; then
        echo -e "${RED}Could not query timezones. Using UTC.${NC}" >&2
        echo "UTC"
        return
    fi
    
    while true; do
        # Extract unique regions from timezone list
        # Filter: must have '/' delimiter, exclude technical/deprecated regions
        local regions
        regions=$(echo "$all_tz_output" | grep '/' | cut -d'/' -f1 | sort -u | grep -v -E '^(Etc|Factory|Kwajalein|Navajo|CST|EST|HST|MST|PST|YST|NZT|GMT|WET|MET|CET|EET|WST|JST|SST)$')
        
        # Build region array
        local region_array=()
        while IFS= read -r region; do
            # Skip empty lines
            [ -z "$region" ] && continue
            region_array+=("$region")
        done <<< "$regions"
        
        local num_regions=${#region_array[@]}
        
        # Show regions menu in 3 columns
        echo -e "${CYAN}Select a region:${NC}" >&2
        echo "" >&2
        
        local num_cols=3
        local items_per_col=$(( (num_regions + num_cols - 1) / num_cols ))
        
        for ((row=0; row<items_per_col; row++)); do
            for ((col=0; col<num_cols; col++)); do
                local idx=$((row + col * items_per_col))
                if [ "$idx" -lt "$num_regions" ]; then
                    local region="${region_array[$idx]}"
                    local count
                    count=$(echo "$all_tz_output" | grep "^${region}/" | wc -l)
                    printf "${YELLOW}%2d)${NC} %-18s(%d) " "$((idx+1))" "$region" "$count" >&2
                fi
            done
            echo "" >&2
        done
        
        echo "" >&2
        echo -n "Select region (1-$num_regions): " >&2
        read -r region_selection
        
        # Validate region selection
        if [ "$region_selection" -ge 1 ] && [ "$region_selection" -le "$num_regions" ] 2>/dev/null; then
            local selected_region="${region_array[$((region_selection - 1))]}"
            
            # Show timezones in selected region
            echo "" >&2
            echo -e "${CYAN}Timezones in ${selected_region}:${NC}" >&2
            echo "" >&2
            
            local region_tzs
            region_tzs=$(echo "$all_tz_output" | grep "^${selected_region}/")
            
            # Build timezone array
            local tz_array=()
            while IFS= read -r tz; do
                tz_array+=("$tz")
            done <<< "$region_tzs"
            
            local num_tzs=${#tz_array[@]}
            
            # Show timezones in 2 columns
            local num_cols_tz=2
            local items_per_col_tz=$(( (num_tzs + num_cols_tz - 1) / num_cols_tz ))
            
            for ((row=0; row<items_per_col_tz; row++)); do
                for ((col=0; col<num_cols_tz; col++)); do
                    local idx=$((row + col * items_per_col_tz))
                    if [ "$idx" -lt "$num_tzs" ]; then
                        local tz="${tz_array[$idx]}"
                        local city="${tz#*/}"
                        printf "${YELLOW}%3d)${NC} %-35s" "$((idx+1))" "$city" >&2
                    fi
                done
                echo "" >&2
            done
            
            echo "" >&2
            printf "${YELLOW}%3d)${NC} ${RED}Back to region selection${NC}\n" "0" >&2
            echo "" >&2
            echo -n "Select timezone (0-$num_tzs): " >&2
            read -r tz_selection
            
            # Handle back option
            if [ "$tz_selection" -eq 0 ] 2>/dev/null; then
                echo "" >&2
                continue
            fi
            
            # Validate timezone selection
            if [ "$tz_selection" -ge 1 ] && [ "$tz_selection" -le "$num_tzs" ] 2>/dev/null; then
                local selected_tz="${tz_array[$((tz_selection - 1))]}"
                echo "$selected_tz"
                return
            else
                echo -e "${RED}Invalid selection. Using UTC.${NC}" >&2
                echo "UTC"
                return
            fi
        else
            echo -e "${RED}Invalid selection. Using UTC.${NC}" >&2
            echo "UTC"
            return
        fi
    done
}

# Handle Ctrl+C interruption
handle_interrupt() {
    echo ""
    echo -e "${RED}⚠️  Installation interrupted!${NC}"
    echo ""
    echo -e "${YELLOW}What would you like to do?${NC}"
    echo -e "${YELLOW}  continue - Resume installation${NC}"
    echo -e "${YELLOW}  cancel   - Cancel and cleanup (unmount drives, etc.)${NC}"
    echo -n "> "
    read -r choice
    
    case "$choice" in
        [Cc][Oo][Nn][Tt][Ii][Nn][Uu][Ee]|[Cc])
            echo -e "${GREEN}Resuming installation...${NC}"
            return
            ;;
        [Cc][Aa][Nn][Cc][Ee][Ll]|*)
            echo -e "${RED}Cancelling installation and cleaning up...${NC}"
            echo "cancelled" > "$STATE_DIR/install_cancelled.txt"
            
            # Simplified cleanup using recursive unmount
            umount --recursive /mnt 2>/dev/null || true
            swapoff -a 2>/dev/null || true
            partprobe "$DISK" 2>/dev/null || true
            
            echo -e "${GREEN}Cleanup complete.${NC}"
            exit 1
            ;;
    esac
}

# Set up interrupt handler
trap 'handle_interrupt' SIGINT SIGTERM

# Collect disk and partition selection (can be restarted).
# CRITICAL: Do NOT write state answers until the user confirms "yes".
# Writing early lets bootstrap consume disk/boot_mode/etc. while the user is
# still navigating (or going "back"), which leaves the process stuck waiting
# for answers the input pane will never re-send.
collect_disk_and_partition() {
    # Get available disks to temp file
    lsblk -d -o NAME 2>/dev/null | awk 'NR>1 {print $1}' > /tmp/up-available-disks.tmp
    lsblk -d -o NAME,SIZE -b 2>/dev/null | awk 'NR>1 {print $1, $2}' | sort -k2 -nr | head -1 | awk '{print "/dev/"$1}' > /tmp/up-default-disk.tmp

    # Read default disk from file
    local default_disk=""
    if [ -s /tmp/up-default-disk.tmp ]; then
        default_disk=$(cat /tmp/up-default-disk.tmp)
    fi

    # Show disks
    show_disks
    echo ""

    local disk=""
    while true; do
        echo -e "${YELLOW}Enter disk path (e.g. /dev/nvme0n1, /dev/sda, /dev/vda) [default: $default_disk]:${NC}"
        echo -e "${YELLOW}Available disks shown above. Use the NAME column (e.g. sda, nvme0n1):${NC}"
        echo -n "> "

        # Plain read from stdin - no redirection
        read -r disk

        [ -z "$disk" ] && disk="$default_disk"

        # Normalize input
        local disk_name
        if [[ "$disk" =~ ^/dev/ ]]; then
            disk_name="${disk#/dev/}"
        else
            disk_name="$disk"
            disk="/dev/$disk"
        fi

        # Check if disk name is in available disks list and is a block device
        if grep -q "^${disk_name}$" /tmp/up-available-disks.tmp 2>/dev/null && [ -b "$disk" ]; then
            break
        else
            echo -e "${RED}Invalid disk '$disk'. Please enter a valid disk name from the list above.${NC}"
            echo -e "${YELLOW}You entered: '$disk_name'${NC}"
        fi
    done

    # Boot mode detection and user override (after disk is selected)
    local detected_mode
    detected_mode=$(detect_boot_mode)
    echo ""
    echo -e "${CYAN}Detected boot mode: ${YELLOW}$detected_mode${NC}"
    
    local override_mode
    if [ "$detected_mode" = "uefi" ]; then
        override_mode="bios"
    else
        override_mode="uefi"
    fi
    
    echo -e "${YELLOW}Override detected mode?${NC}"
    echo -e "${YELLOW}1) Continue with $detected_mode (recommended)${NC}"
    echo -e "${YELLOW}2) Override with $override_mode${NC}"
    echo -n "> "
    read -r boot_mode_choice
    
    local boot_mode
    if [ "$boot_mode_choice" = "2" ]; then
        boot_mode="$override_mode"
    else
        boot_mode="$detected_mode"
    fi
    echo -e "${CYAN}Using boot mode: $boot_mode${NC}"
    
    # For BIOS systems, determine partition table type based on disk size
    local two_tb_bytes=$((2 * 1024 * 1024 * 1024 * 1024))
    local disk_size_bytes
    disk_size_bytes=$(blockdev --getsize64 "$disk" 2>/dev/null || echo 0)
    local disk_size_gb=$((disk_size_bytes / 1024 / 1024 / 1024))
    local partition_table_type="gpt"
    
    if [ "$boot_mode" = "bios" ]; then
        if [ "$disk_size_bytes" -gt "$two_tb_bytes" ]; then
            # Disk is larger than 2TB - prompt user
            echo ""
            echo -e "${RED}⚠️  Disk Size Warning: Your disk (${disk_size_gb}GB) is larger than 2TB.${NC}"
            echo -e "${RED}MBR partition tables only support up to 2TB.${NC}"
            echo ""
            echo -e "${YELLOW}Select partition table type:${NC}"
            echo -e "${YELLOW}1) Use GPT (supports full disk, but may not boot on older BIOS)${NC}"
            echo -e "${YELLOW}2) Use MBR (only first 2TB will be usable)${NC}"
            echo -n "> "
            read -r partition_table_choice
            
            if [ "$partition_table_choice" = "1" ]; then
                partition_table_type="gpt"
            else
                partition_table_type="mbr"
            fi
        else
            # Disk ≤2TB - use MBR automatically
            partition_table_type="mbr"
        fi
        echo -e "${CYAN}Partition table type: $partition_table_type${NC}"
    else
        # UEFI always uses GPT
        partition_table_type="gpt"
    fi

    # Partitioning choice
    echo ""
    local partition_choice
    while true; do
        echo -e "${YELLOW}Select partitioning:${NC}"
        echo -e "${YELLOW}1. Standard (EFI + Root) - Automatic partitioning${NC}"
        echo -e "${YELLOW}2. Standard + Swap - Automatic partitioning with swap${NC}"
        echo -e "${YELLOW}Enter choice (1-2):${NC}"
        echo -n "> "
        read -r partition_choice

        case "$partition_choice" in
            [1-2]) break ;;
            *) echo -e "${RED}Invalid choice. Please enter 1 or 2.${NC}" ;;
        esac
    done

    # Get disk size for preview
    if [ -b "$disk" ]; then
        disk_size_bytes=$(blockdev --getsize64 "$disk" 2>/dev/null || echo 0)
        disk_size_gb=$((disk_size_bytes / 1024 / 1024 / 1024))
    else
        disk_size_gb="unknown"
    fi

    # Show partition preview with boot mode and partition table info
    show_partition_preview "$disk" "$partition_choice" "$disk_size_gb" "$boot_mode" "$partition_table_type"

    # Get confirmation with options
    echo ""
    local confirm
    while true; do
        echo -e "${YELLOW}What would you like to do?${NC}"
        echo -e "${YELLOW}  yes/proceed - Continue with this partitioning (ERASES ALL DATA)${NC}"
        echo -e "${YELLOW}  disk/back   - Go back to disk selection${NC}"
        echo -e "${YELLOW}  no/abort    - Cancel installation${NC}"
        echo -n "> "
        read -r confirm

        case "$confirm" in
            [Yy][Ee][Ss]|[Yy]|[Pp][Rr][Oo][Cc][Ee][Ee][Dd])
                # Atomic commit: publish the full disk config only after confirmation.
                # Order matches bootstrap read order; durable answers survive re-reads.
                write_answer "disk" "$disk"
                write_answer "boot_mode" "$boot_mode"
                write_answer "partition_table_type" "$partition_table_type"
                write_answer "partition_choice" "$partition_choice"
                write_answer "confirm_partition" "yes"
                write_answer "confirm_custom" "yes"
                return 0
                ;;
            [Dd][Ii][Ss][Kk]|[Bb][Aa][Cc][Kk])
                echo -e "${CYAN}Going back to disk selection...${NC}"
                # Do NOT write empty/partial state files — bootstrap must keep
                # waiting until a confirmed selection is committed.
                return 1
                ;;
            [Nn][Oo]|[Nn]|[Aa][Bb][Oo][Rr][Tt])
                echo -e "${RED}Installation cancelled by user.${NC}"
                echo "cancelled" > "$STATE_DIR/install_cancelled.txt"
                exit 1
                ;;
            *)
                echo -e "${RED}Please choose: yes/proceed, disk/back, or no/abort.${NC}"
                ;;
        esac
    done
}

# Main input collection - plain stdin, no fancy redirection
collect_all_inputs() {
    clear
    echo -e "${BLUE}========================================${NC}"
    echo -e "${CYAN}  Up Linux Input Collection${NC}"
    echo -e "${BLUE}========================================${NC}"
    echo ""
    echo "Please provide the following information for your Up Linux installation:"
    echo ""

    # Allow restarting disk/partition selection
    while ! collect_disk_and_partition; do
        clear
        echo -e "${BLUE}========================================${NC}"
        echo -e "${CYAN}  Up Linux Input Collection${NC}"
        echo -e "${BLUE}========================================${NC}"
        echo ""
        echo "Please provide the following information for your Up Linux installation:"
        echo ""
    done

    # Hostname with smart suggestion
    echo ""
    local hostname
    local default_hostname=$(detect_hostname_suggestion)
    while true; do
        echo -e "${YELLOW}Enter hostname (e.g., $default_hostname, dev-laptop, workstation):${NC}"
        echo -e "${YELLOW}Default: $default_hostname${NC}"
        echo -n "> "
        read -r hostname

        [ -z "$hostname" ] && hostname="$default_hostname"

        if validate_hostname "$hostname"; then
            write_answer "hostname" "$hostname"
            break
        else
            echo -e "${RED}Invalid hostname. Use only letters, numbers, and hyphens.${NC}"
        fi
    done

    # Timezone with picker
    echo ""
    local timezone
    while true; do
        timezone=$(select_timezone)
        
        if validate_timezone "$timezone"; then
            write_answer "timezone" "$timezone"
            break
        else
            echo -e "${RED}Invalid timezone '$timezone'. Please try again.${NC}"
        fi
    done

    # Username
    echo ""
    local username
    while true; do
        echo -e "${YELLOW}Enter username (lowercase letters and numbers only, max 32 chars):${NC}"
        echo -n "> "
        read -r username

        if validate_username "$username"; then
            write_answer "username" "$username"
            break
        else
            echo -e "${RED}Invalid username. Must start with lowercase letter, contain only lowercase/numbers/underscore/hyphen.${NC}"
        fi
    done

    # Full name
    echo ""
    echo -e "${YELLOW}Enter your full name:${NC}"
    echo -n "> "
    read -r fullname
    write_answer "fullname" "$fullname"

    # User password
    echo ""
    local user_password
    while true; do
        echo -e "${YELLOW}Enter password for user account (minimum 8 characters):${NC}"
        echo -n "> "
        stty -echo
        read -r user_password
        stty echo
        echo ""
        
        echo -e "${YELLOW}Confirm user password:${NC}"
        echo -n "> "
        stty -echo
        read -r confirm_password
        stty echo
        echo ""

        if [ "$user_password" = "$confirm_password" ]; then
            write_answer "password_$username" "$user_password"
            write_answer "password_confirm_$username" "$confirm_password"
            break
        else
            echo -e "${RED}Passwords don't match. Please try again.${NC}"
        fi
    done

    # Root password
    echo ""
    while true; do
        echo -e "${YELLOW}Enter password for root (administrator) account (minimum 8 characters):${NC}"
        echo -n "> "
        stty -echo
        read -r root_password
        stty echo
        echo ""
        
        echo -e "${YELLOW}Confirm root password:${NC}"
        echo -n "> "
        stty -echo
        read -r confirm_root
        stty echo
        echo ""

        if [ "$root_password" = "$confirm_root" ]; then
            write_answer "password_root" "$root_password"
            write_answer "password_confirm_root" "$confirm_root"
            break
        else
            echo -e "${RED}Passwords don't match. Please try again.${NC}"
        fi
    done

    # SSH key setup (optional)
    echo ""
    echo -e "${YELLOW}Would you like to set up SSH key authentication? (yes/no):${NC}"
    echo -e "${YELLOW}This allows secure remote access to your system.${NC}"
    echo -n "> "
    read -r ssh_choice
    
    if [[ "$ssh_choice" =~ ^[Yy][Ee][Ss]$ ]]; then
        write_answer "ssh_setup" "yes"
        
        # Ask for key type
        echo ""
        echo -e "${YELLOW}Select SSH key type:${NC}"
        echo -e "${YELLOW}1) ED25519 (recommended, faster, more secure)${NC}"
        echo -e "${YELLOW}2) RSA 4096-bit (compatible with older systems)${NC}"
        echo -n "> "
        read -r ssh_key_type
        
        if [ "$ssh_key_type" = "1" ] || [ -z "$ssh_key_type" ]; then
            write_answer "ssh_key_type" "ed25519"
        else
            write_answer "ssh_key_type" "rsa"
        fi
        
        # Prompt for passphrase directly (simplified flow)
        echo ""
        while true; do
            echo -e "${YELLOW}Enter passphrase for SSH key (leave empty for no passphrase):${NC}"
            echo -n "> "
            stty -echo
            read -r ssh_passphrase
            stty echo
            echo ""
            
            if [ -z "$ssh_passphrase" ]; then
                echo -e "${YELLOW}No passphrase will be used.${NC}"
                write_answer "ssh_passphrase" ""
                break
            fi
            
            echo -e "${YELLOW}Confirm passphrase:${NC}"
            echo -n "> "
            stty -echo
            read -r ssh_passphrase_confirm
            stty echo
            echo ""
            
            if [ "$ssh_passphrase" = "$ssh_passphrase_confirm" ]; then
                write_answer "ssh_passphrase" "$ssh_passphrase"
                break
            else
                echo -e "${RED}Passphrases don't match. Please try again.${NC}"
            fi
        done
    else
        write_answer "ssh_setup" "no"
    fi

    # NVIDIA check
    echo ""
    if lspci | grep -E "VGA|3D" | grep -i nvidia > /dev/null; then
        echo -e "${YELLOW}NVIDIA GPU detected.${NC}"
        echo -e "${YELLOW}Install proprietary NVIDIA drivers? (yes/no):${NC}"
        echo -n "> "
        read -r nvidia_choice
        write_answer "nvidia_drivers" "$nvidia_choice"
    else
        write_answer "nvidia_drivers" "no"
    fi

    # Signal that input collection is complete
    echo "complete" > "$STATE_DIR/input_complete.txt"
    echo "input_complete" > "$STATE_DIR/pane_state.txt"

    echo ""
    echo -e "${GREEN}All input collected! Installation will now proceed...${NC}"
    echo -e "${CYAN}You can monitor progress in the other panes.${NC}"
}

# Wait for installation to complete while serving mid-install prompts on this TTY.
# Must stay in the foreground so read prompts work (background jobs steal/lose stdin).
wait_for_installation() {
    while [ ! -f "$STATE_DIR/install_complete.txt" ] && [ ! -f "$STATE_DIR/install_cancelled.txt" ]; do
        serve_pending_prompts_once
        sleep 1
    done
}

# Single pass of mid-install interactive events (errors, pacstrap, reprompts)
serve_pending_prompts_once() {
    local current_state
    current_state=$(cat "$STATE_DIR/pane_state.txt" 2>/dev/null || echo "input_pending")

    # Only process interactive events after initial collection
    if [ "$current_state" != "input_complete" ] && [ "$current_state" != "error_pending" ]; then
        return 0
    fi

    # Bootstrap asked to re-collect a specific field
    local reprompt_file
    for reprompt_file in "$STATE_DIR"/*.reprompt; do
        [ -f "$reprompt_file" ] || continue
        local rtype
        rtype=$(basename "$reprompt_file" .reprompt)
        handle_reprompt "$rtype"
    done

    # Pacstrap failure (separate from generic install_error)
    if [ -f "$STATE_DIR/pacstrap_failed.txt" ] && [ ! -f "$STATE_DIR/pacstrap_retry.answer" ] && [ ! -f "$STATE_DIR/pacstrap_retry.input" ]; then
        handle_pacstrap_failure
    fi

    # Only prompt once per error: skip if a response is already staged
    if [ -f "$STATE_DIR/install_error.txt" ] \
        && [ ! -f "$STATE_DIR/error_response.answer" ] \
        && [ ! -f "$STATE_DIR/error_response.input" ]; then
        # Transition to error_pending state - pane resize handled by install.sh state machine
        echo "error_pending" > "$STATE_DIR/pane_state.txt"

        local error_msg
        error_msg=$(cat "$STATE_DIR/install_error.txt")
        local options
        options=$(cat "$STATE_DIR/error_options.txt" 2>/dev/null || echo "retry_continue_exit")

        echo ""
        echo -e "${RED}⚠️  Installation Error${NC}"
        echo -e "${RED}$error_msg${NC}"

        if [ -f "$STATE_DIR/failed_packages.txt" ]; then
            echo ""
            echo -e "${YELLOW}Failed packages:${NC}"
            while IFS= read -r pkg; do
                echo -e "  ${RED}- $pkg${NC}"
            done < "$STATE_DIR/failed_packages.txt"
        fi

        clear_answer "error_response"
        local user_choice=""
        while true; do
            echo ""
            echo -e "${YELLOW}What would you like to do?${NC}"

            case "$options" in
                "retry_continue_exit")
                    echo -e "${YELLOW}  retry    - Retry failed packages only${NC}"
                    echo -e "${YELLOW}  continue - Skip failed packages and continue${NC}"
                    echo -e "${YELLOW}  exit     - Cancel installation${NC}"
                    ;;
                "retry_exit")
                    echo -e "${YELLOW}  retry - Retry this step${NC}"
                    echo -e "${YELLOW}  exit  - Cancel installation${NC}"
                    ;;
                "continue_exit")
                    echo -e "${YELLOW}  continue - Skip this step and continue${NC}"
                    echo -e "${YELLOW}  exit     - Cancel installation${NC}"
                    ;;
            esac

            echo -n "> "
            read -r user_choice

            case "$user_choice" in
                [Rr][Ee][Tt][Rr][Yy]|[Rr])
                    write_answer "error_response" "retry"
                    break
                    ;;
                [Cc][Oo][Nn][Tt][Ii][Nn][Uu][Ee]|[Cc])
                    if [[ "$options" == *"continue"* ]]; then
                        write_answer "error_response" "continue"
                        break
                    else
                        echo -e "${RED}Invalid option. Please try again.${NC}"
                    fi
                    ;;
                [Ee][Xx][Ii][Tt]|[Ee])
                    write_answer "error_response" "exit"
                    break
                    ;;
                *)
                    echo -e "${RED}'$user_choice' is not recognized. Please enter a valid option.${NC}"
                    ;;
            esac
        done

        echo "input_complete" > "$STATE_DIR/pane_state.txt"
    fi
}

# Show welcome wizard and handle reboot/exit
show_welcome() {
    echo ""
    echo -e "${GREEN}🎉 Installation Complete! 🎉${NC}"
    echo -e "${CYAN}Welcome to Up Linux!${NC}"
    echo ""
    echo -e "${YELLOW}Your system has been successfully installed and configured.${NC}"
    echo -e "${YELLOW}All packages, themes, and settings are ready to use.${NC}"
    echo ""

    local choice
    while true; do
        echo -e "${YELLOW}What would you like to do?${NC}"
        echo -e "${YELLOW}  reboot - Restart your computer to boot into Up Linux${NC}"
        echo -e "${YELLOW}  exit   - Exit the installer (you can manually reboot later)${NC}"
        echo -n "> "
        read -r choice

        case "$choice" in
            [Rr][Ee][Bb][Oo][Oo][Tt])
                echo -e "${CYAN}Rebooting system...${NC}"
                sleep 1
                reboot
                break
                ;;
            [Ee][Xx][Ii][Tt])
                echo -e "${CYAN}Exiting installer...${NC}"
                echo -e "${YELLOW}You can manually reboot with: reboot${NC}"
                tmux detach
                exit 0
                ;;
            *)
                echo -e "${RED}Please enter 'reboot' or 'exit'.${NC}"
                ;;
        esac
    done
}

# Handle mid-install reprompts from bootstrap (validation failure, etc.)
handle_reprompt() {
    local input_type="$1"
    local message
    message=$(cat "$STATE_DIR/${input_type}.reprompt" 2>/dev/null || echo "Please re-enter $input_type")

    echo ""
    echo -e "${YELLOW}⚠️  $message${NC}"
    echo "error_pending" > "$STATE_DIR/pane_state.txt"

    case "$input_type" in
        disk|boot_mode|partition_table_type|partition_choice|confirm_partition)
            # Full disk flow again; commits answers only on yes
            while ! collect_disk_and_partition; do
                :
            done
            ;;
        pacstrap_retry)
            echo -e "${YELLOW}Pacstrap failed. Retry? (retry/exit):${NC}"
            echo -n "> "
            local choice
            read -r choice
            case "$choice" in
                [Rr][Ee][Tt][Rr][Yy]|[Rr]) write_answer "pacstrap_retry" "retry" ;;
                *) write_answer "pacstrap_retry" "exit" ;;
            esac
            rm -f "$STATE_DIR/pacstrap_failed.txt"
            ;;
        *)
            echo -e "${YELLOW}Enter value for ${input_type}:${NC}"
            echo -n "> "
            local value
            read -r value
            write_answer "$input_type" "$value"
            ;;
    esac

    rm -f "$STATE_DIR/${input_type}.reprompt"
    echo "input_complete" > "$STATE_DIR/pane_state.txt"
}

# Handle pacstrap failure prompt (bootstrap writes pacstrap_failed.txt)
handle_pacstrap_failure() {
    echo ""
    echo -e "${RED}⚠️  Pacstrap failed${NC}"
    local msg
    msg=$(cat "$STATE_DIR/pacstrap_failed.txt" 2>/dev/null || echo "Network or mirror issue during base install.")
    echo -e "${RED}$msg${NC}"
    echo ""
    echo -e "${YELLOW}What would you like to do?${NC}"
    echo -e "${YELLOW}  retry - Try pacstrap again${NC}"
    echo -e "${YELLOW}  exit  - Cancel installation${NC}"
    echo -n "> "

    echo "error_pending" > "$STATE_DIR/pane_state.txt"
    clear_answer "pacstrap_retry"

    local choice
    while true; do
        read -r choice
        case "$choice" in
            [Rr][Ee][Tt][Rr][Yy]|[Rr])
                write_answer "pacstrap_retry" "retry"
                break
                ;;
            [Ee][Xx][Ii][Tt]|[Ee])
                write_answer "pacstrap_retry" "exit"
                break
                ;;
            *)
                echo -e "${RED}Please enter 'retry' or 'exit'.${NC}"
                echo -n "> "
                ;;
        esac
    done

    echo "input_complete" > "$STATE_DIR/pane_state.txt"
}

# Main flow
collect_all_inputs
wait_for_installation
show_welcome
