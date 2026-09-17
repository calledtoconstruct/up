# Security & System Setup

## Overview
Add firewall configuration and SSH key setup during installation.

---

## 1. Firewall Configuration During Installation

### Prerequisites
- `ufw` (Uncomplicated Firewall) package must be installed

### Implementation Details

**Package Addition:**

Add `ufw` to essential or system packages in `configs/scripts/package-groups.sh`:

```bash
SYSTEM_PACKAGES="
    ... existing packages ...
    ufw
    ...
"
```

**New File:** `configs/scripts/setup-firewall.sh`

**Purpose:** Configure UFW firewall during installation.

```bash
#!/bin/bash
# Firewall Setup
# Configures UFW firewall during installation
# Called by setup.sh after package installation

set -euo pipefail

UP_ROOT="${UP_ROOT:-/usr/local/share/up}"

# Source logging if available
if [ -f "$UP_ROOT/configs/scripts/logging.sh" ]; then
    source "$UP_ROOT/configs/scripts/logging.sh"
fi

setup_firewall() {
    log_message "Configuring firewall..."
    
    # Enable UFW
    ufw --force enable
    
    # Default policies
    ufw default deny incoming
    ufw default allow outgoing
    
    # Allow common services
    ufw allow ssh          # SSH (port 22)
    ufw allow 80/tcp       # HTTP
    ufw allow 443/tcp      # HTTPS
    
    # Allow local network discovery (for LocalSend, etc.)
    ufw allow from 192.168.0.0/16
    ufw allow from 10.0.0.0/8
    ufw allow from 172.16.0.0/12
    
    # Enable firewall on boot
    systemctl enable ufw
    
    log_message "Firewall configured"
    log_message "  - Default deny incoming"
    log_message "  - Default allow outgoing"
    log_message "  - SSH, HTTP, HTTPS allowed"
    log_message "  - Local network allowed"
}

setup_firewall
```

**Integration in `setup.sh`:**

Add after package installation, before config deployment:

```bash
# In setup.sh - after AUR packages section
update_progress 25 30 "Configuring firewall..."
source "$UP_ROOT/configs/scripts/setup-firewall.sh"
```

**User Notification:**

After installation, show firewall status:

```bash
log_message "Firewall status:"
ufw status verbose >> "$LOG_FILE" 2>/dev/null || true
```

---

## 2. SSH Key Setup During Installation

### Prerequisites
- `openssh` package (already in essential packages)

### Implementation Details

**File:** `configs/scripts/input-watcher.sh` — Add SSH key prompt

**New Prompt in `collect_all_inputs()`:**

```bash
# SSH Key Setup
echo ""
echo -e "${YELLOW}Would you like to set up SSH keys?${NC}"
echo -e "${YELLOW}  This allows secure remote access to your system.${NC}"
echo -e "${YELLOW}  (yes/no) [default: no]:${NC}"
echo -n "> "
read -r setup_ssh

if [[ "$setup_ssh" =~ ^[Yy][Ee][Ss]$ ]]; then
    echo "yes" > "$STATE_DIR/setup_ssh.input"
    
    # SSH key type selection
    echo ""
    echo -e "${YELLOW}Select SSH key type:${NC}"
    echo -e "${YELLOW}  1. ed25519 (recommended, modern, secure)${NC}"
    echo -e "${YELLOW}  2. rsa (legacy, compatible with older systems)${NC}"
    echo -e "${YELLOW}Enter choice (1-2) [default: 1]:${NC}"
    echo -n "> "
    read -r ssh_key_type
    
    case "$ssh_key_type" in
        2) echo "rsa" > "$STATE_DIR/ssh_key_type.input" ;;
        *) echo "ed25519" > "$STATE_DIR/ssh_key_type.input" ;;
    esac
    
    # Key size for RSA
    if [ "$ssh_key_type" = "2" ]; then
        echo ""
        echo -e "${YELLOW}RSA key size (bits):${NC}"
        echo -e "${YELLOW}  1. 2048 (faster, less secure)${NC}"
        echo -e "${YELLOW}  2. 4096 (slower, more secure) [recommended]${NC}"
        echo -e "${YELLOW}Enter choice (1-2) [default: 2]:${NC}"
        echo -n "> "
        read -r rsa_size
        
        case "$rsa_size" in
            1) echo "2048" > "$STATE_DIR/ssh_key_size.input" ;;
            *) echo "4096" > "$STATE_DIR/ssh_key_size.input" ;;
        esac
    fi
    
    # Optional passphrase
    echo ""
    echo -e "${YELLOW}Set a passphrase for your SSH key?${NC}"
    echo -e "${YELLOW}  (recommended for security, leave empty for no passphrase)${NC}"
    echo -n "> "
    stty -echo
    read -r ssh_passphrase
    stty echo
    echo ""
    
    if [ -n "$ssh_passphrase" ]; then
        echo "$ssh_passphrase" > "$STATE_DIR/ssh_passphrase.input"
    fi
else
    echo "no" > "$STATE_DIR/setup_ssh.input"
fi
```

**New File:** `configs/scripts/setup-ssh.sh`

**Purpose:** Generate SSH keys during installation.

```bash
#!/bin/bash
# SSH Key Setup
# Generates SSH keys during installation
# Called by setup.sh after user creation

set -euo pipefail

UP_ROOT="${UP_ROOT:-/usr/local/share/up}"

# Source logging if available
if [ -f "$UP_ROOT/configs/scripts/logging.sh" ]; then
    source "$UP_ROOT/configs/scripts/logging.sh"
fi

setup_ssh_keys() {
    local username="$1"
    local ssh_key_type="${2:-ed25519}"
    local ssh_key_size="${3:-4096}"
    local ssh_passphrase="${4:-}"
    local user_home="/home/$username"
    
    log_message "Setting up SSH keys for $username..."
    
    # Create .ssh directory
    mkdir -p "$user_home/.ssh"
    chmod 700 "$user_home/.ssh"
    chown "$username:$username" "$user_home/.ssh"
    
    # Generate key
    local key_file="$user_home/.ssh/id_$ssh_key_type"
    
    if [ -f "$key_file" ]; then
        log_message "SSH key already exists, skipping generation"
        return 0
    fi
    
    # Build ssh-keygen command
    local cmd="ssh-keygen -t $ssh_key_type"
    
    if [ "$ssh_key_type" = "rsa" ]; then
        cmd="$cmd -b $ssh_key_size"
    fi
    
    cmd="$cmd -f $key_file"
    
    if [ -n "$ssh_passphrase" ]; then
        cmd="$cmd -N '$ssh_passphrase'"
    else
        cmd="$cmd -N ''"
    fi
    
    cmd="$cmd -C '$username@$(hostname)'"
    
    # Generate key as the user (not root)
    if [ -n "${SUDO_USER:-}" ]; then
        runuser -u "$username" -- bash -c "$cmd"
    else
        su - "$username" -c "$cmd"
    fi
    
    # Set permissions
    chmod 600 "$key_file"
    chmod 644 "$key_file.pub"
    chown "$username:$username" "$key_file" "$key_file.pub"
    
    log_message "SSH key generated: $key_file"
    log_message "Public key: $key_file.pub"
    
    # Show public key to user
    log_message "Your public key (add this to GitHub, GitLab, or remote servers):"
    cat "$key_file.pub" >> "${INSTALL_LOG_FILE:-/var/log/up/install.log}" 2>/dev/null || true
    
    # Configure SSH client
    local ssh_config="$user_home/.ssh/config"
    if [ ! -f "$ssh_config" ]; then
        cat > "$ssh_config" << 'EOF'
# SSH Client Configuration
# Generated by Up Linux

Host *
    AddKeysToAgent yes
    IdentitiesOnly yes
EOF
        chmod 600 "$ssh_config"
        chown "$username:$username" "$ssh_config"
        log_message "Created SSH client config"
    fi
}

# Main - called from setup.sh
if [ -n "${1:-}" ]; then
    setup_ssh_keys "$1" "${2:-ed25519}" "${3:-4096}" "${4:-}"
fi
```

**Integration in `setup.sh`:**

Add after user creation and password setup:

```bash
# In setup.sh - after password setup
# SSH Key Setup
if [ -f "$STATE_DIR/setup_ssh.input" ]; then
    ssh_setup=$(cat "$STATE_DIR/setup_ssh.input")
    if [ "$ssh_setup" = "yes" ]; then
        update_progress 15 30 "Setting up SSH keys..."
        ssh_key_type=$(cat "$STATE_DIR/ssh_key_type.input" 2>/dev/null || echo "ed25519")
        ssh_key_size=$(cat "$STATE_DIR/ssh_key_size.input" 2>/dev/null || echo "4096")
        ssh_passphrase=$(cat "$STATE_DIR/ssh_passphrase.input" 2>/dev/null || echo "")
        source "$UP_ROOT/configs/scripts/setup-ssh.sh"
        setup_ssh_keys "$USERNAME" "$ssh_key_type" "$ssh_key_size" "$ssh_passphrase"
    fi
fi
```

---

