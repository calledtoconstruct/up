# Installation UX Improvements

## Status: ✅ COMPLETE

All improvements have been implemented and verified.

**Files Modified:**
- `install.sh` - Responsive layout, dynamic progress, cancellation handler
- `configs/scripts/input-watcher.sh` - Disk UX, hostname suggestions, timezone picker, interrupt handler
- `configs/scripts/package-groups.sh` - Sub-progress updates during package installation
- `docs/DEVELOPMENT.md` - Documentation of new features

**Implementation Date:** 2026-03-29

---

## Overview
Improve the installation experience through responsive tmux layout, better disk selection UX, smart hostname suggestions, accurate progress tracking, cancellation handling, and timezone picker.

---

## 1. Responsive Tmux Layout

### Prerequisites
- None (pure shell scripting changes)

### Implementation Details

**File:** `install.sh` — `launch_tmux()` function

**Requirements:**
- Title pane: Fixed height (4 rows), shows static branding
- Phase pane: Responsive, fills available vertical space
- Progress pane: Responsive, fills remaining horizontal space
- Input pane: Fixed height when collecting input, shrinks to 3-5 lines after completion

**Implementation Approach:**

```bash
# Get terminal dimensions
TERM_COLS=$(tput cols)
TERM_ROWS=$(tput lines)

# Calculate pane sizes
TITLE_HEIGHT=4
INPUT_HEIGHT=20  # During input collection
INPUT_HEIGHT_DONE=3  # After input collection
PROGRESS_HEIGHT=$((TERM_ROWS - TITLE_HEIGHT - INPUT_HEIGHT))

# Launch with calculated sizes
tmux new-session -d -s "$TMUX_SESSION" -x "$TERM_COLS" -y "$TERM_ROWS" ...
tmux split-window -t "$TMUX_SESSION:0" -v -l "$PROGRESS_HEIGHT" ...
```

**Dynamic Resize After Input Collection:**
- Monitor `input-watcher.sh` completion via state file
- When `input_complete.txt` appears, resize input pane to 3 lines
- Expand progress pane to fill reclaimed space

```bash
# In a background monitor script:
while true; do
    if [ -f "$STATE_DIR/input_complete.txt" ]; then
        tmux resize-pane -t "$TMUX_SESSION:0.2" -y 3
        break
    fi
    sleep 2
done
```

**Minimum Terminal Size Check:**
```bash
MIN_COLS=80
MIN_ROWS=30

if [ "$(tput cols)" -lt "$MIN_COLS" ] || [ "$(tput lines)" -lt "$MIN_ROWS" ]; then
    echo "Warning: Terminal too small. Minimum size: ${MIN_COLS}x${MIN_ROWS}"
    echo "Current size: $(tput cols)x$(tput lines)"
    echo "Press Enter to continue or Ctrl+C to cancel..."
    read -r
fi
```

---

## 2. Disk Selection UX

### Prerequisites
- None

### Implementation Details

**File:** `configs/scripts/input-watcher.sh` — `show_disks()` and `collect_disk_and_partition()` functions

**Current State:** Raw `lsblk` output

**Target State:** Formatted table with disk type, size, model, and recommendation

**Implementation:**

```bash
show_disks() {
    echo -e "${CYAN}Available Disks:${NC}"
    echo ""
    printf "${YELLOW}%-12s %-8s %-10s %-20s %-10s${NC}\n" "DEVICE" "TYPE" "SIZE" "MODEL" "RECOMMENDED"
    printf "%-12s %-8s %-10s %-20s %-10s\n" "------" "----" "----" "-----" "-----------"
    
    local recommended_disk=""
    local max_size=0
    
    while IFS= read -r line; do
        local name=$(echo "$line" | awk '{print $1}')
        local size=$(echo "$line" | awk '{print $2}')
        local model=$(echo "$line" | awk '{$1=$2=""; print $0}' | xargs)
        local rota=$(echo "$line" | awk '{print $NF}')
        local type="HDD"
        [ "$rota" = "0" ] && type="SSD"
        
        # Convert size to bytes for comparison
        local size_bytes=$(blockdev --getsize64 "/dev/$name" 2>/dev/null || echo 0)
        local size_gb=$((size_bytes / 1024 / 1024 / 1024))
        
        # Track largest disk for recommendation
        if [ "$size_bytes" -gt "$max_size" ]; then
            max_size="$size_bytes"
            recommended_disk="/dev/$name"
        fi
        
        # Color code: SSD in green, HDD in yellow, small disk in red
        local color="$NC"
        local rec=""
        if [ "$type" = "SSD" ]; then
            color="$GREEN"
        elif [ "$size_gb" -lt 20 ]; then
            color="$RED"
        fi
        
        printf "${color}%-12s %-8s %-10s %-20s %-10s${NC}\n" \
            "/dev/$name" "$type" "$size" "$model" "$rec"
    done < <(lsblk -d -o NAME,SIZE,MODEL,ROTA 2>/dev/null | awk 'NR>1')
    
    echo ""
    echo -e "${GREEN}★ Recommended: $recommended_disk (largest disk)${NC}"
}
```

**Partition Preview:**
Show what will happen to the selected disk before confirmation:

```bash
show_partition_preview() {
    local disk="$1"
    local choice="$2"
    local disk_size_gb="$3"
    
    echo ""
    echo -e "${RED}⚠️  WARNING: This will COMPLETELY WIPE the selected disk!${NC}"
    echo -e "${RED}   All data on $disk (${disk_size_gb}GB) will be permanently lost!${NC}"
    echo ""
    
    case "$choice" in
        1)
            echo -e "${YELLOW}Partition Layout (Standard):${NC}"
            echo -e "${YELLOW}┌─────────────────────────────────────────────────────┐${NC}"
            echo -e "${YELLOW}│ EFI (512MB) │${GREEN} Root (${disk_size_gb}GB ext4)${YELLOW}                  │${NC}"
            echo -e "${YELLOW}└─────────────────────────────────────────────────────┘${NC}"
            ;;
        2)
            local ram_kb=$(grep MemTotal /proc/meminfo | awk '{print $2}')
            local ram_gb=$((ram_kb / 1024 / 1024))
            local swap_gb=$((ram_gb > 32 ? 32 : (ram_gb < 2 ? 2 : ram_gb)))
            local root_gb=$((disk_size_gb - swap_gb - 1))
            
            echo -e "${YELLOW}Partition Layout (Standard + Swap):${NC}"
            echo -e "${YELLOW}┌──────────┬──────────────┬──────────────────────────┐${NC}"
            echo -e "${YELLOW}│ EFI      │ Swap         │${GREEN} Root${YELLOW}                    │${NC}"
            echo -e "${YELLOW}│ 512MB    │ ${swap_gb}GB         │ ${root_gb}GB ext4              │${NC}"
            echo -e "${YELLOW}└──────────┴──────────────┴──────────────────────────┘${NC}"
            ;;
    esac
    
    echo ""
    echo -e "${CYAN}Current partitions on $disk:${NC}"
    lsblk "$disk" 2>/dev/null || echo "No existing partitions"
}
```

---

## 3. Hostname Suggestions

### Prerequisites
- None

### Implementation Details

**File:** `configs/scripts/input-watcher.sh` — hostname collection section

**Implementation:**

```bash
# Detect hardware type from DMI
detect_hostname_suggestion() {
    local suggestion="up-computer"
    
    # Try to detect if laptop or desktop
    if [ -d /sys/class/dmi/id ]; then
        local chassis=$(cat /sys/class/dmi/id/chassis_type 2>/dev/null || echo "0")
        local product=$(cat /sys/class/dmi/id/product_name 2>/dev/null || echo "")
        
        # Chassis types: 8-14 = laptop/portable, 3-7 = desktop
        case "$chassis" in
            8|9|10|11|12|13|14|30|31|32)
                suggestion="up-laptop"
                ;;
            3|4|5|6|7|15|16)
                suggestion="up-desktop"
                ;;
            *)
                suggestion="up-computer"
                ;;
        esac
        
        # Optionally include product name (sanitized)
        if [ -n "$product" ]; then
            local sanitized=$(echo "$product" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/-/g' | sed 's/--*/-/g' | head -c 20)
            # Don't use product name if it's too generic
            if [[ ! "$sanitized" =~ ^(system|product|to-be-filled) ]]; then
                suggestion="up-$sanitized"
            fi
        fi
    fi
    
    echo "$suggestion"
}

# In collect_all_inputs():
local default_hostname=$(detect_hostname_suggestion)

echo -e "${YELLOW}Enter hostname (e.g., $default_hostname, dev-laptop, workstation):${NC}"
echo -e "${YELLOW}Default: $default_hostname${NC}"
```

---

## 4. Dynamic Progress Calculation

### Prerequisites
- Package counts must be available from `package-groups.sh`

### Implementation Details

**File:** `install.sh` and `setup.sh`

**Current:** Hardcoded `echo "15" > "$STATE_DIR/progress_total.txt"`

**Target:** Dynamic calculation based on actual package batches

**Implementation Approach:**

```bash
# In install.sh - calculate after sourcing package-groups.sh
calculate_total_steps() {
    # Base installation steps (disk, format, mount, pacstrap, etc.)
    local base_steps=11  # Steps 1-11 in bootstrap.sh
    
    # Count package batches (not individual packages, since they install in batches)
    local essential_batches=1    # All essential in one batch
    local system_batches=1       # All system in one batch
    local shell_batches=1        # Shell tools in one batch
    local cosmetic_batches=1     # Cosmetic in one batch
    local aur_batches=$(echo "$AUR_PACKAGES" | wc -w)  # AUR packages individually
    
    # Config deployment steps
    local config_steps=3  # Deploy configs, GRUB, services
    
    # Total
    local total=$((base_steps + essential_batches + system_batches + shell_batches + cosmetic_batches + aur_batches + config_steps))
    
    echo "$total"
}

TOTAL_STEPS=$(calculate_total_steps)
echo "$TOTAL_STEPS" > "$STATE_DIR/progress_total.txt"
```

**Sub-progress for Long Operations:**

```bash
# In package-groups.sh - install_packages_with_fallback()
# Show sub-progress during batch installation
install_packages_with_fallback() {
    local packages="$1"
    local type="$2"
    local package_list=($packages)
    local total=${#package_list[@]}
    local current=0
    
    for package in $packages; do
        current=$((current + 1))
        # Update status with sub-progress
        update_progress "$current_step" "$total_steps" "Installing $type: $current/$total - $package"
        install_single_package "$package" "$type"
    done
}
```

---

## 5. Installation Cancellation (Ctrl+C Handler)

### Prerequisites
- Cleanup function already exists in `bootstrap.sh`

### Implementation Details

**Files:** `install.sh`, `configs/scripts/input-watcher.sh`

**Implementation:**

```bash
# In install.sh - add trap before launching tmux
cleanup_and_exit() {
    echo ""
    echo "Installation cancelled by user."
    
    # Kill tmux session
    tmux kill-session -t "$TMUX_SESSION" 2>/dev/null || true
    
    # Run cleanup (unmount partitions, etc.)
    if [ -f "$UP_ROOT/bootstrap.sh" ]; then
        source "$UP_ROOT/configs/scripts/error-handling.sh" 2>/dev/null || true
        cleanup_partitions "$DISK" 2>/dev/null || true
    fi
    
    # Clean up state
    rm -rf "$STATE_DIR" 2>/dev/null || true
    
    echo "Cleanup complete. You can restart the installation with: ./install.sh"
    exit 1
}

# Set trap for Ctrl+C
trap cleanup_and_exit SIGINT SIGTERM

# In input-watcher.sh - add confirmation before cancellation
trap 'handle_interrupt' SIGINT SIGTERM

handle_interrupt() {
    echo ""
    echo -e "${RED}Installation interrupted!${NC}"
    echo ""
    echo -e "${YELLOW}What would you like to do?${NC}"
    echo -e "${YELLOW}  continue - Resume installation${NC}"
    echo -e "${YELLOW}  cancel   - Cancel and cleanup${NC}"
    echo -n "> "
    read -r choice
    
    case "$choice" in
        [Cc][Oo][Nn][Tt][Ii][Nn][Uu][Ee]|[Cc])
            echo -e "${GREEN}Resuming installation...${NC}"
            return
            ;;
        [Cc][Aa][Nn][Cc][Ee][Ll]|*)
            echo -e "${RED}Cancelling installation...${NC}"
            echo "cancelled" > "$STATE_DIR/install_cancelled.txt"
            exit 1
            ;;
    esac
}
```

---

## 6. Timezone Picker

### Prerequisites
- None

### Implementation Details

**File:** `configs/scripts/input-watcher.sh`

**Implementation:**

```bash
# Simplified timezone picker with common timezones
select_timezone() {
    echo -e "${CYAN}Select your timezone:${NC}"
    echo ""
    
    # Common timezones grouped by region
    local -a timezones=(
        "America/New_York"
        "America/Chicago"
        "America/Denver"
        "America/Los_Angeles"
        "America/Anchorage"
        "Pacific/Honolulu"
        "Europe/London"
        "Europe/Paris"
        "Europe/Berlin"
        "Europe/Moscow"
        "Asia/Tokyo"
        "Asia/Shanghai"
        "Asia/Kolkata"
        "Asia/Dubai"
        "Australia/Sydney"
        "Pacific/Auckland"
    )
    
    local i=1
    for tz in "${timezones[@]}"; do
        printf "${YELLOW}%2d)${NC} %s\n" "$i" "$tz"
        i=$((i + 1))
    done
    echo ""
    printf "${YELLOW}%2d)${NC} %s\n" "$i" "Enter custom timezone"
    
    echo ""
    echo -n "Select option (1-$i): "
    read -r selection
    
    if [ "$selection" -eq "$i" ] 2>/dev/null; then
        # Custom timezone entry
        echo -n "Enter timezone (e.g., America/New_York): "
        read -r timezone
        if validate_timezone "$timezone"; then
            echo "$timezone"
        else
            echo -e "${RED}Invalid timezone. Trying fuzzy match...${NC}"
            local matched=$(fuzzy_match_timezone "$timezone")
            if [ -n "$matched" ]; then
                echo -e "${GREEN}Matched to: $matched${NC}"
                echo "$matched"
            else
                echo -e "${RED}Could not match timezone. Using UTC.${NC}"
                echo "UTC"
            fi
        fi
    elif [ "$selection" -ge 1 ] && [ "$selection" -lt "$i" ] 2>/dev/null; then
        echo "${timezones[$((selection - 1))]}"
    else
        echo -e "${RED}Invalid selection. Using UTC.${NC}"
        echo "UTC"
    fi
}

# Fuzzy match timezone
fuzzy_match_timezone() {
    local input="$1"
    local input_lower=$(echo "$input" | tr '[:upper:]' '[:lower:]')
    
    # Try exact match first
    if [ -f "/usr/share/zoneinfo/$input" ]; then
        echo "$input"
        return 0
    fi
    
    # Try partial match
    local match=$(find /usr/share/zoneinfo -type f 2>/dev/null | \
        grep -i "$input_lower" | \
        grep -v "^/usr/share/zoneinfo/right/" | \
        grep -v "^/usr/share/zoneinfo/Etc/" | \
        head -1)
    
    if [ -n "$match" ]; then
        echo "${match#/usr/share/zoneinfo/}"
        return 0
    fi
    
    # Try city name match
    match=$(find /usr/share/zoneinfo -type f -name "*${input}*" 2>/dev/null | head -1)
    if [ -n "$match" ]; then
        echo "${match#/usr/share/zoneinfo/}"
        return 0
    fi
    
    return 1
}

validate_timezone() {
    local timezone="$1"
    [ -f "/usr/share/zoneinfo/$timezone" ]
}
```

---

