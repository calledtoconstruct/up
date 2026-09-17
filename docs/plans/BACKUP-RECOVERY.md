# Backup & Recovery

## Overview
Add system snapshot capability after installation, user data backup/restore commands, and automatic backup before updates.

---

## 1. System Snapshot After Installation

### Prerequisites
- `timeshift` package (for BTRFS snapshots) OR `rsync` package (for filesystem snapshots)

### Implementation Details

**Package Addition:**

Add backup tools to system packages in `configs/scripts/package-groups.sh`:

```bash
SYSTEM_PACKAGES="
    ... existing packages ...
    rsync
    ...
"
```

**Note:** `timeshift` requires BTRFS filesystem. Since the installer supports ext4, we'll use `rsync`-based snapshots for broad compatibility.

**New File:** `configs/scripts/setup-snapshot.sh`

**Purpose:** Create initial system snapshot after installation.

```bash
#!/bin/bash
# System Snapshot Setup
# Creates initial system snapshot after installation
# Called by setup.sh after all configuration is complete

set -euo pipefail

UP_ROOT="${UP_ROOT:-/usr/local/share/up}"
SNAPSHOT_DIR="/var/lib/up/snapshots"

# Source logging if available
if [ -f "$UP_ROOT/configs/scripts/logging.sh" ]; then
    source "$UP_ROOT/configs/scripts/logging.sh"
fi

create_initial_snapshot() {
    log_message "Creating initial system snapshot..."
    
    mkdir -p "$SNAPSHOT_DIR"
    
    local snapshot_name="initial-install-$(date +%Y%m%d-%H%M%S)"
    local snapshot_path="$SNAPSHOT_DIR/$snapshot_name"
    
    # Create snapshot using rsync
    # Exclude virtual filesystems, temporary files, and package cache
    rsync -aAXv / "$snapshot_path" \
        --exclude={"/dev/*","/proc/*","/sys/*","/tmp/*","/run/*","/mnt/*","/media/*","/var/cache/pacman/pkg/*","/var/lib/up/snapshots/*","/home/*/.cache/*"} \
        2>&1 | tail -5 >> "${INSTALL_LOG_FILE:-/var/log/up/install.log}" || true
    
    # Create snapshot metadata
    cat > "$snapshot_path/.snapshot-info" << EOF
name=$snapshot_name
type=initial-install
date=$(date -Iseconds)
hostname=$(hostname)
kernel=$(uname -r)
description=Initial system snapshot created after Up Linux installation
EOF
    
    log_message "Initial snapshot created: $snapshot_path"
    log_message "Snapshot size: $(du -sh "$snapshot_path" 2>/dev/null | cut -f1)"
}

create_initial_snapshot
```

**Integration in `setup.sh`:**

Add after all configuration is complete, before final cleanup:

```bash
# In setup.sh - after migrations
update_progress 28 30 "Creating system snapshot..."
source "$UP_ROOT/configs/scripts/setup-snapshot.sh"
```

---

## 2. Backup & Restore Commands

### Prerequisites
- `rsync` package (already in system packages)

### Implementation Details

**New File:** `bin/up-backup`

**Purpose:** Backup user data and system configuration.

```bash
#!/bin/bash
# Up Backup
# Backup user data and system configuration
# Usage: up-backup [options]

set -euo pipefail

UP_ROOT="${UP_ROOT:-/usr/local/share/up}"
BACKUP_DIR="${BACKUP_DIR:-/var/backups/up}"
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
BACKUP_NAME="up-backup-$TIMESTAMP"

# Default backup targets
USER_DATA=(
    "$HOME/.config"
    "$HOME/.local/share/applications"
    "$HOME/Documents"
    "$HOME/Downloads"
    "$HOME/Pictures"
    "$HOME/Music"
    "$HOME/Videos"
    "$HOME/projects"
)

SYSTEM_CONFIG=(
    "/etc/fstab"
    "/etc/hostname"
    "/etc/locale.conf"
    "/etc/hosts"
    "/etc/pacman.conf"
    "/etc/pacman.d/mirrorlist"
    "/etc/systemd"
    "/etc/NetworkManager"
)

# Parse arguments
BACKUP_TYPE="full"
DESTINATION=""

while [[ $# -gt 0 ]]; do
    case $1 in
        --user-only)
            BACKUP_TYPE="user"
            shift
            ;;
        --system-only)
            BACKUP_TYPE="system"
            shift
            ;;
        --destination|-d)
            DESTINATION="$2"
            shift 2
            ;;
        --help|-h)
            echo "Usage: up-backup [options]"
            echo ""
            echo "Options:"
            echo "  --user-only      Backup user data only"
            echo "  --system-only    Backup system config only"
            echo "  --destination -d Set backup destination"
            echo "  --help -h        Show this help"
            echo ""
            echo "Default destination: $BACKUP_DIR"
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
done

# Set destination
if [ -n "$DESTINATION" ]; then
    BACKUP_DIR="$DESTINATION"
fi

mkdir -p "$BACKUP_DIR"

echo "Creating backup: $BACKUP_NAME"
echo "Type: $BACKUP_TYPE"
echo "Destination: $BACKUP_DIR"
echo ""

# Backup user data
backup_user_data() {
    echo "Backing up user data..."
    
    local user_backup="$BACKUP_DIR/$BACKUP_NAME/user-data"
    mkdir -p "$user_backup"
    
    for dir in "${USER_DATA[@]}"; do
        if [ -d "$dir" ]; then
            echo "  - $dir"
            rsync -a "$dir" "$user_backup/" 2>/dev/null || true
        fi
    done
    
    echo "User data backup complete"
}

# Backup system configuration
backup_system_config() {
    echo "Backing up system configuration..."
    
    local system_backup="$BACKUP_DIR/$BACKUP_NAME/system-config"
    mkdir -p "$system_backup"
    
    for item in "${SYSTEM_CONFIG[@]}"; do
        if [ -e "$item" ]; then
            echo "  - $item"
            if [ -d "$item" ]; then
                rsync -a "$item" "$system_backup/" 2>/dev/null || true
            else
                cp -p "$item" "$system_backup/" 2>/dev/null || true
            fi
        fi
    done
    
    # Save installed packages list
    pacman -Qqe > "$system_backup/installed-packages.txt" 2>/dev/null || true
    pacman -Qqm > "$system_backup/aur-packages.txt" 2>/dev/null || true
    
    echo "System config backup complete"
}

# Create backup
case "$BACKUP_TYPE" in
    full)
        backup_user_data
        backup_system_config
        ;;
    user)
        backup_user_data
        ;;
    system)
        backup_system_config
        ;;
esac

# Create backup metadata
cat > "$BACKUP_DIR/$BACKUP_NAME/.backup-info" << EOF
name=$BACKUP_NAME
type=$BACKUP_TYPE
date=$(date -Iseconds)
hostname=$(hostname)
user=$(whoami)
EOF

# Compress backup
echo ""
echo "Compressing backup..."
tar -czf "$BACKUP_DIR/$BACKUP_NAME.tar.gz" -C "$BACKUP_DIR" "$BACKUP_NAME" 2>/dev/null || true

# Remove uncompressed directory
rm -rf "$BACKUP_DIR/$BACKUP_NAME"

echo ""
echo "Backup complete: $BACKUP_DIR/$BACKUP_NAME.tar.gz"
echo "Size: $(du -sh "$BACKUP_DIR/$BACKUP_NAME.tar.gz" 2>/dev/null | cut -f1)"
```

**New File:** `bin/up-restore`

**Purpose:** Restore user data and system configuration from backup.

```bash
#!/bin/bash
# Up Restore
# Restore user data and system configuration from backup
# Usage: up-restore <backup-file>

set -euo pipefail

UP_ROOT="${UP_ROOT:-/usr/local/share/up}"

# Parse arguments
BACKUP_FILE="$1"

if [ -z "$BACKUP_FILE" ]; then
    echo "Usage: up-restore <backup-file>"
    echo ""
    echo "Available backups:"
    ls -lh /var/backups/up/*.tar.gz 2>/dev/null || echo "No backups found"
    exit 1
fi

if [ ! -f "$BACKUP_FILE" ]; then
    echo "Error: Backup file not found: $BACKUP_FILE"
    exit 1
fi

echo "Restoring from: $BACKUP_FILE"
echo ""

# Extract backup
TEMP_DIR=$(mktemp -d)
tar -xzf "$BACKUP_FILE" -C "$TEMP_DIR" 2>/dev/null || {
    echo "Error: Failed to extract backup"
    rm -rf "$TEMP_DIR"
    exit 1
}

BACKUP_NAME=$(ls "$TEMP_DIR")
BACKUP_PATH="$TEMP_DIR/$BACKUP_NAME"

# Read backup info
if [ -f "$BACKUP_PATH/.backup-info" ]; then
    source "$BACKUP_PATH/.backup-info"
    echo "Backup type: $type"
    echo "Backup date: $date"
    echo ""
fi

# Restore user data
restore_user_data() {
    if [ -d "$BACKUP_PATH/user-data" ]; then
        echo "Restoring user data..."
        
        for dir in "$BACKUP_PATH/user-data"/*; do
            if [ -d "$dir" ]; then
                local dirname=$(basename "$dir")
                echo "  - ~/$dirname"
                rsync -a "$dir/" "$HOME/$dirname/" 2>/dev/null || true
            fi
        done
        
        chown -R "$(whoami):$(whoami)" "$HOME" 2>/dev/null || true
        echo "User data restored"
    fi
}

# Restore system config
restore_system_config() {
    if [ -d "$BACKUP_PATH/system-config" ]; then
        echo "Restoring system configuration..."
        echo "  (requires root privileges)"
        
        sudo rsync -a "$BACKUP_PATH/system-config/" /etc/ 2>/dev/null || true
        
        echo "System config restored"
    fi
}

# Confirm restore
echo "This will restore files from the backup."
echo "Existing files may be overwritten."
echo ""
read -p "Continue? (yes/no): " confirm

if [ "$confirm" != "yes" ]; then
    echo "Restore cancelled"
    rm -rf "$TEMP_DIR"
    exit 0
fi

# Perform restore
case "$type" in
    full)
        restore_user_data
        restore_system_config
        ;;
    user)
        restore_user_data
        ;;
    system)
        restore_system_config
        ;;
esac

# Cleanup
rm -rf "$TEMP_DIR"

echo ""
echo "Restore complete!"
echo "You may need to restart your session for changes to take effect."
```

---

## 3. Automatic Backup Before Updates

### Prerequisites
- Backup commands (above)

### Implementation Details

**File:** `update.sh` — Add backup before applying changes

**Implementation:**

```bash
# In update.sh - at the beginning, before git pull
echo "Creating backup before update..."
BACKUP_DIR="/var/backups/up"
mkdir -p "$BACKUP_DIR"
TIMESTAMP=$(date +%Y%m%d-%H%M%S)

# Backup current configs
if [ -d "$UP_ROOT/configs" ]; then
    echo "Backing up current configuration..."
    cp -a "$UP_ROOT/configs" "$BACKUP_DIR/configs-backup-$TIMESTAMP" 2>/dev/null || true
fi

# Backup user configs for all users
for user_home in /home/*; do
    if [ -d "$user_home" ] && [ -f "$user_home/.bashrc" ]; then
        username=$(basename "$user_home")
        echo "Backing up configs for $username..."
        
        # Backup specific config files
        for config_file in "${CONFIG_FILES[@]}"; do
            SRC="$user_home/.config/$config_file"
            if [ -f "$SRC" ]; then
                DST="$BACKUP_DIR/$username-$config_file-$TIMESTAMP"
                mkdir -p "$(dirname "$DST")"
                cp -p "$SRC" "$DST" 2>/dev/null || true
            fi
        done
    fi
done

echo "Backup complete. Proceeding with update..."
```

**Restore on Failed Update:**

```bash
# In update.sh - if update fails
restore_from_backup() {
    echo "Update failed. Restoring from backup..."
    
    # Restore system configs
    if [ -d "$BACKUP_DIR/configs-backup-$TIMESTAMP" ]; then
        cp -a "$BACKUP_DIR/configs-backup-$TIMESTAMP/"* "$UP_ROOT/configs/" 2>/dev/null || true
    fi
    
    # Restore user configs
    for user_home in /home/*; do
        if [ -d "$user_home" ] && [ -f "$user_home/.bashrc" ]; then
            username=$(basename "$user_home")
            
            for config_file in "${CONFIG_FILES[@]}"; do
                BACKUP="$BACKUP_DIR/$username-$config_file-$TIMESTAMP"
                if [ -f "$BACKUP" ]; then
                    DST="$user_home/.config/$config_file"
                    mkdir -p "$(dirname "$DST")"
                    cp -p "$BACKUP" "$DST" 2>/dev/null || true
                    chown "$username:$username" "$DST" 2>/dev/null || true
                fi
            done
        fi
    done
    
    echo "Restore complete. Please check your system and try again."
}
```

---

## 4. Backup Scheduling (Optional)

### Prerequisites
- Backup commands (above)

### Implementation Details

**New File:** `configs/scripts/backup-scheduler.sh`

**Purpose:** Set up automatic daily/weekly backups via systemd timer.

```bash
#!/bin/bash
# Backup Scheduler
# Set up automatic backups via systemd timer
# Usage: up-backup-scheduler [enable|disable|status]

set -euo pipefail

ACTION="${1:-status}"

case "$ACTION" in
    enable)
        echo "Enabling automatic daily backups..."
        
        # Create systemd service
        cat > /etc/systemd/system/up-backup.service << 'EOF'
[Unit]
Description=Up Linux Backup
After=network.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/up-backup --user-only
User=root
EOF

        # Create systemd timer
        cat > /etc/systemd/system/up-backup.timer << 'EOF'
[Unit]
Description=Daily Up Linux Backup

[Timer]
OnCalendar=daily
Persistent=true

[Install]
WantedBy=timers.target
EOF

        systemctl daemon-reload
        systemctl enable up-backup.timer
        systemctl start up-backup.timer
        
        echo "Automatic daily backups enabled"
        ;;
        
    disable)
        echo "Disabling automatic backups..."
        systemctl disable up-backup.timer 2>/dev/null || true
        systemctl stop up-backup.timer 2>/dev/null || true
        echo "Automatic backups disabled"
        ;;
        
    status)
        echo "Backup scheduler status:"
        systemctl status up-backup.timer 2>/dev/null || echo "  Not configured"
        echo ""
        echo "Next backup:"
        systemctl list-timers up-backup.timer 2>/dev/null || echo "  N/A"
        ;;
        
    *)
        echo "Usage: up-backup-scheduler [enable|disable|status]"
        exit 1
        ;;
esac
```

---

