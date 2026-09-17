#!/bin/bash
# Firewall Setup — configure UFW with sensible defaults
# Called by setup.sh after package installation (optional, non-fatal if ufw missing)

# Note: Do NOT set options here when sourced

setup_firewall() {
    if ! command -v ufw >/dev/null 2>&1; then
        if declare -f log_warning >/dev/null 2>&1; then
            log_warning "ufw not installed — skipping firewall setup"
        fi
        return 1
    fi

    if declare -f log_info >/dev/null 2>&1; then
        log_info "Configuring UFW firewall..."
    fi

    # Default policies
    ufw --force default deny incoming >/dev/null 2>&1 || true
    ufw --force default allow outgoing >/dev/null 2>&1 || true

    # Allow SSH (so remote recovery remains possible)
    ufw allow OpenSSH >/dev/null 2>&1 || ufw allow 22/tcp >/dev/null 2>&1 || true

    # LocalSend LAN discovery + transfers (TCP/UDP 53317)
    ufw allow 53317/tcp comment 'LocalSend' >/dev/null 2>&1 || true
    ufw allow 53317/udp comment 'LocalSend' >/dev/null 2>&1 || true

    # Enable firewall and on boot
    ufw --force enable >/dev/null 2>&1 || true
    systemctl enable ufw >/dev/null 2>&1 || true

    if declare -f log_info >/dev/null 2>&1; then
        log_info "Firewall configured: deny in / allow out / SSH + LocalSend (53317) allowed"
    fi
    return 0
}

# Allow direct execution
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    setup_firewall
fi
