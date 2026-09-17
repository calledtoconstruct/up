#!/bin/bash
set -euo pipefail

# UP_ROOT must be set by calling script
if [ -z "${UP_ROOT:-}" ]; then
    echo "ERROR: UP_ROOT environment variable not set"
    exit 1
fi
export UP_ROOT

source "$UP_ROOT/configs/scripts/logging.sh"
source "$UP_ROOT/configs/scripts/error-handling.sh"
source "$UP_ROOT/configs/scripts/colors.sh"
source "$UP_ROOT/configs/scripts/package-groups.sh"
source "$UP_ROOT/configs/scripts/theme-utils.sh"
source "$UP_ROOT/configs/scripts/state-utils.sh"

initialize_error_handling

# State directory bind-mounted from host for input sharing
STATE_DIR="/up-state"

# Progress total written by install.sh (shared via bind mount)
PROGRESS_TOTAL=$(state_get "progress_total.txt")
PROGRESS_TOTAL="${PROGRESS_TOTAL:-30}"

log_info "=== Up Setup (Chroot) ==="

update_phase 6 "Base Config (Hostname/Time/Locale)"
update_progress 11 "$PROGRESS_TOTAL" "Configuring hostname..."
HOSTNAME=$(read_input "hostname" "dev-laptop")
echo "$HOSTNAME" >/etc/hostname
log_info "Hostname set to: $HOSTNAME"

update_progress 12 "$PROGRESS_TOTAL" "Configuring timezone..."
TIMEZONE=$(read_input "timezone" "America/New_York")
if [ -f "/usr/share/zoneinfo/$TIMEZONE" ]; then
  ln -sf "/usr/share/zoneinfo/$TIMEZONE" /etc/localtime
  run_and_log hwclock --systohc || true
else
  log_info "Invalid timezone, using UTC"
  ln -sf "/usr/share/zoneinfo/UTC" /etc/localtime
  run_and_log hwclock --systohc || true
fi

update_progress 13 "$PROGRESS_TOTAL" "Configuring locale..."
echo "en_US.UTF-8 UTF-8" >>/etc/locale.gen
run_and_log locale-gen || true
echo "LANG=en_US.UTF-8" >/etc/locale.conf

mkdir -p /var/log
chmod 755 /var/log

update_phase 7 "User Account & Passwords"
update_progress 14 "$PROGRESS_TOTAL" "Creating user account..."
FULLNAME=$(read_input "fullname" "User")
USERNAME=$(read_input "username" "user")

# Create 'up' group for theme switching without sudo
groupadd -f up
useradd -m -G wheel,up,audio,video,storage -c "$FULLNAME" "$USERNAME"

# Set password via state file (avoids logging sensitive data)
set_password_via_state() {
  local account="$1"
  local password=$(read_input "password_${account}" "" "true")
  
  if echo "$account:$password" | chpasswd 2>/dev/null; then
    log_info "✅ Password set for $account"
  else
    log_info "❌ Password setting failed for $account"
    log_info "  Set manually with: sudo passwd $account"
  fi
}

set_password_via_state "$USERNAME"
set_password_via_state "root"

echo "%wheel ALL=(ALL) ALL" >/etc/sudoers.d/wheel
if ! grep -q '@includedir /etc/sudoers.d' /etc/sudoers 2>/dev/null; then
    echo '@includedir /etc/sudoers.d' >> /etc/sudoers
fi

update_phase 8 "XLibre Repo Setup"
update_progress 15 "$PROGRESS_TOTAL" "Adding XLibre repository..."

# Display stack selection: prefer XLibre; fall back to stock xorg-server on failure
DISPLAY_STACK="xlibre"
# Old x11libre.net mirror + key were retired 2026-08-12.
# Current: https://xlibre-arch.github.io/  key B97F7C613F359424
XLIBRE_KEY_ID="B97F7C613F359424"
XLIBRE_KEY_URL="https://xlibre-arch.github.io/xlibre-archlinux.asc"
XLIBRE_KEY_FILE="$UP_ROOT/configs/keys/xlibre-archlinux.asc"

setup_xlibre_repo() {
  run_and_log pacman-key --init || return 1
  run_and_log pacman-key --populate archlinux || return 1

  local keytmp
  keytmp=$(mktemp)
  if [ -f "$XLIBRE_KEY_FILE" ]; then
    cp "$XLIBRE_KEY_FILE" "$keytmp"
  elif ! curl -fsSL "$XLIBRE_KEY_URL" -o "$keytmp"; then
    rm -f "$keytmp"
    # Last resort: keyservers (often blocked on live ISOs)
    if ! run_and_log pacman-key --keyserver hkps://keyserver.ubuntu.com --recv-keys "$XLIBRE_KEY_ID"; then
      return 1
    fi
    keytmp=""
  fi
  if [ -n "$keytmp" ]; then
    if ! run_and_log pacman-key --add "$keytmp"; then
      rm -f "$keytmp"
      return 1
    fi
    rm -f "$keytmp"
  fi
  run_and_log pacman-key --finger "$XLIBRE_KEY_ID" || true
  if ! run_and_log pacman-key --lsign-key "$XLIBRE_KEY_ID"; then
    return 1
  fi

  # Drop retired [xlibre] / stale [xlibre-stable] blocks, then add current.
  if grep -qE '^\[xlibre(-stable)?\]' /etc/pacman.conf 2>/dev/null; then
    sed -i '/^\[xlibre\]/,/^Server = /d;/^\[xlibre-stable\]/,/^Server = /d' /etc/pacman.conf 2>/dev/null || true
  fi
  cat <<EOF >>/etc/pacman.conf

[xlibre-stable]
Server = https://packages.xlibre.net/arch/stable/\$arch
SigLevel = Required DatabaseOptional
EOF

  if ! run_and_log pacman -Sy --noconfirm; then
    return 1
  fi
  return 0
}

xlibre_ok=false
xlibre_attempt=0
while [ $xlibre_attempt -lt 3 ]; do
  xlibre_attempt=$((xlibre_attempt + 1))
  log_info "XLibre repository setup attempt $xlibre_attempt/3..."
  if setup_xlibre_repo; then
    xlibre_ok=true
    break
  fi
  log_warning "XLibre repo/key setup failed (attempt $xlibre_attempt)"
  if [ $xlibre_attempt -lt 3 ]; then
    # Offer retry via TUI when available
    if declare -f prompt_on_error >/dev/null 2>&1; then
      resp=$(prompt_on_error "XLibre repository setup failed (network/key). Retry?" "retry_continue_exit")
      case "$resp" in
        retry) continue ;;
        exit)
          echo "cancelled" > "$STATE_DIR/install_cancelled.txt"
          exit 1
          ;;
        *) break ;;
      esac
    else
      sleep 2
    fi
  fi
done

if [ "$xlibre_ok" = false ]; then
  log_warning "XLibre unavailable — falling back to stock xorg-server"
  DISPLAY_STACK="xorg"
  # Remove xlibre repo block if partially added
  if grep -qE '^\[xlibre(-stable)?\]' /etc/pacman.conf 2>/dev/null; then
    sed -i '/^\[xlibre\]/,/^Server = /d;/^\[xlibre-stable\]/,/^Server = /d' /etc/pacman.conf 2>/dev/null || true
  fi
fi
echo "DISPLAY_STACK=$DISPLAY_STACK" > /root/up/.display-stack
log_info "Display stack: $DISPLAY_STACK"

update_phase 9 "Essential Packages"
update_progress 16 "$PROGRESS_TOTAL" "Checking NVIDIA driver selection..."
NVIDIA_PKGS=""
nvidia_choice=$(read_input "nvidia_drivers" "no")
if [[ "$nvidia_choice" =~ ^[Yy][Ee][Ss]$ ]]; then
  # nvidia-open is Turing+ (GTX 16 / RTX). 2010–2018 cards need proprietary nvidia.
  nvidia_kmod="nvidia"
  nvidia_lspci=$(lspci 2>/dev/null | grep -iE 'VGA|3D' | grep -i nvidia || true)
  if echo "$nvidia_lspci" | grep -qiE 'RTX|GTX 16|TU1|GA1|AD1|GB2'; then
    nvidia_kmod="nvidia-open"
  fi
  NVIDIA_PKGS="$nvidia_kmod nvidia-utils nvidia-settings"
  log_info "NVIDIA driver package: $nvidia_kmod"
  echo 'blacklist nouveau' >/etc/modprobe.d/blacklist-nouveau.conf
  echo 'options nouveau modeset=0' >>/etc/modprobe.d/blacklist-nouveau.conf
fi

update_progress 17 "$PROGRESS_TOTAL" "Updating package database..."
run_and_log pacman -Syu --noconfirm || true

# Build essential package list with display stack substitution
ALL_ESSENTIAL="$ESSENTIAL_PACKAGES"
if [ "$DISPLAY_STACK" = "xorg" ]; then
  # Replace XLibre packages with stock Xorg equivalents
  ALL_ESSENTIAL=$(echo "$ALL_ESSENTIAL" | sed \
    -e 's/xlibre-xserver/xorg-server/g' \
    -e 's/xlibre-input-libinput/xf86-input-libinput/g')
  log_info "Using xorg-server + xf86-input-libinput (XLibre fallback)"
fi
if [ -n "$NVIDIA_PKGS" ]; then
  ALL_ESSENTIAL="$ALL_ESSENTIAL $NVIDIA_PKGS"
fi

update_progress 18 "$PROGRESS_TOTAL" "Installing essential packages..."
install_essential_packages "$ALL_ESSENTIAL"

update_phase 10 "System Packages"
update_progress 19 "$PROGRESS_TOTAL" "Installing system packages..."
install_system_packages "$SYSTEM_PACKAGES"

update_phase 11 "Shell & Cosmetic Packages"
update_progress 20 "$PROGRESS_TOTAL" "Installing shell tools..."
install_shell_tools "$SHELL_TOOLS"
check_shell_tools

update_progress 21 "$PROGRESS_TOTAL" "Installing cosmetic packages..."
install_cosmetic_packages "$COSMETIC_PACKAGES"

# SSH key setup (if requested)
SSH_SETUP=$(read_input "ssh_setup" "no")
if [[ "$SSH_SETUP" =~ ^[Yy][Ee][Ss]$ ]]; then
    update_progress 21 "$PROGRESS_TOTAL" "Setting up SSH authentication..."
    SSH_KEY_TYPE=$(read_input "ssh_key_type" "ed25519")
    SSH_PASSPHRASE=$(read_input "ssh_passphrase" "")
    
    log_info "Setting up SSH key authentication..."
    
    mkdir -p "/home/$USERNAME/.ssh"
    chmod 700 "/home/$USERNAME/.ssh"
    
    local_key_path="/home/$USERNAME/.ssh/id_${SSH_KEY_TYPE}"
    local_comment="$USERNAME@$(cat /etc/hostname)"
    # Build argv array — never eval with passphrase
    ssh_keygen_cmd=(ssh-keygen -f "$local_key_path" -C "$local_comment" -q)
    if [ "$SSH_KEY_TYPE" = "ed25519" ]; then
        ssh_keygen_cmd+=(-t ed25519)
    else
        ssh_keygen_cmd+=(-t rsa -b 4096)
    fi
    # -N sets passphrase (empty string = no passphrase)
    ssh_keygen_cmd+=(-N "${SSH_PASSPHRASE}")
    
    if "${ssh_keygen_cmd[@]}" 2>/dev/null; then
        log_info "✅ SSH key generated successfully"
        chown -R "$USERNAME:$USERNAME" "/home/$USERNAME/.ssh"
        if [ -f "${local_key_path}.pub" ]; then
            FINGERPRINT=$(ssh-keygen -lf "${local_key_path}.pub" 2>/dev/null || echo "")
            log_info "Key fingerprint: $FINGERPRINT"
        fi
    else
        log_warning "⚠ SSH key generation failed"
    fi
fi

update_phase 12 "AUR Packages"
update_progress 22 "$PROGRESS_TOTAL" "Installing yay for AUR..."
source "$UP_ROOT/configs/scripts/install-yay.sh"
install_yay

if [ "$YAY_AVAILABLE" = true ]; then
  update_progress 23 "$PROGRESS_TOTAL" "Installing application packages..."
  install_application_packages "$APPLICATION_PACKAGES"
  update_progress 24 "$PROGRESS_TOTAL" "Installing AUR packages..."
  install_aur_packages "$AUR_PACKAGES"
else
  log_info "⚠ yay failed - skipping AUR packages"
  log_info "  Install manually: git clone https://aur.archlinux.org/yay-bin.git && cd yay-bin && makepkg -si"
fi

update_progress 25 "$PROGRESS_TOTAL" "Finalizing installation..."

update_phase 13 "Config Deployment"
update_progress 26 "$PROGRESS_TOTAL" "Deploying configuration..."

if [ ! -d "/home/$USERNAME/.config/nvim" ]; then
  run_and_log git clone https://github.com/LazyVim/starter "/home/$USERNAME/.config/nvim" || true
  rm -rf "/home/$USERNAME/.config/nvim/.git"
fi

mkdir -p /usr/local/share/up
cp -a /root/up/* /usr/local/share/up/ 2>/dev/null || true
cp -a /root/up/.git /usr/local/share/up/ 2>/dev/null || true
# Vendor checkout: chmod +x must not show up as local git dirt
if [ -d /usr/local/share/up/.git ]; then
  git -C /usr/local/share/up config core.fileMode false 2>/dev/null || true
fi

CONFIG_DIR="$UP_ROOT/configs"

# Deploy config as copies. Never symlink live paths into the vendor git
# tree — greeter settings, LightDM, and session files are written at
# runtime and would dirty /usr/local/share/up.
deploy() {
  local src="$1" dst="$2"
  if [ -d "$src" ]; then
    cp -rp "$src" "$dst"
  else
    mkdir -p "$(dirname "$dst")"
    rm -f "$dst" 2>/dev/null || true
    cp -a "$src" "$dst"
  fi
}

# Deploy system config with directory creation
deploy_system() {
  local src="$1" dst="$2"
  mkdir -p "$(dirname "$dst")"
  rm -f "$dst" 2>/dev/null || true
  cp -a "$src" "$dst"
}

deploy "$CONFIG_DIR/i3" "/home/$USERNAME/.config/i3"
deploy "$CONFIG_DIR/polybar" "/home/$USERNAME/.config/polybar"
deploy "$CONFIG_DIR/picom" "/home/$USERNAME/.config/picom"
deploy "$CONFIG_DIR/rofi" "/home/$USERNAME/.config/rofi"
deploy "$CONFIG_DIR/dunst" "/home/$USERNAME/.config/dunst"
deploy "$CONFIG_DIR/alacritty" "/home/$USERNAME/.config/alacritty"
deploy "$CONFIG_DIR/nvim" "/home/$USERNAME/.config/nvim"
deploy "$CONFIG_DIR/tmux" "/home/$USERNAME/.config/tmux"
deploy "$CONFIG_DIR/lightdm/lightdm.conf" "/etc/lightdm/lightdm.conf"
deploy "$CONFIG_DIR/X11/xsessions/i3-up.desktop" "/usr/share/xsessions/i3-up.desktop"
deploy "$CONFIG_DIR/lightdm/lightdm-gtk-greeter.conf" "/etc/lightdm/lightdm-gtk-greeter.conf"

# Generate i3 keybindings (essential for a usable desktop)
# shellcheck disable=SC1091
source "$UP_ROOT/configs/scripts/keybinding-utils.sh"
if ! HOME="/home/$USERNAME" write_i3_keybindings_file "/home/$USERNAME/.config/i3/keybindings.conf"; then
  log_error "Failed to generate i3 keybindings.conf — desktop would be unusable"
  exit 1
fi
log_info "Generated i3 keybindings for $USERNAME"
# Ensure polybar launch script is executable
chmod +x "/home/$USERNAME/.config/polybar/launch.sh" 2>/dev/null || true

# Remove default i3 sessions (we use i3-up.desktop)
rm -f /usr/share/xsessions/i3.desktop 2>/dev/null || true
rm -f /usr/share/xsessions/i3-with-shmconfig.desktop 2>/dev/null || true

# Create LightDM theme config with group-writable permissions
# Users in 'up' group can change themes without sudo
mkdir -p "/etc/lightdm/lightdm-gtk-greeter.conf.d"
install -d -m 775 -o root -g up /usr/share/backgrounds/up
cat > "/etc/lightdm/lightdm-gtk-greeter.conf.d/theme.conf" << 'EOF'
[greeter]
theme-name = Materia
background = /usr/share/backgrounds/archlinux/geowaves.png
EOF
chown root:up "/etc/lightdm/lightdm-gtk-greeter.conf.d/theme.conf"
chmod 664 "/etc/lightdm/lightdm-gtk-greeter.conf.d/theme.conf"
# Greeter reads this file, not conf.d — allow the up group to update background=
if [ -f /etc/lightdm/lightdm-gtk-greeter.conf ]; then
  chown root:up /etc/lightdm/lightdm-gtk-greeter.conf
  chmod 664 /etc/lightdm/lightdm-gtk-greeter.conf
fi

generate_zshrc "$USERNAME"
cp -p "$CONFIG_DIR/starship.toml" "/home/$USERNAME/.config/starship.toml"

# Create user config with hardware-aware compositor defaults
mkdir -p "/home/$USERNAME/.config/up" "/home/$USERNAME/.config/picom"
chmod +x "$UP_ROOT/configs/scripts/detect-compositor-capability.sh" \
         "$UP_ROOT/configs/scripts/apply-compositor-profile.sh" \
         "$UP_ROOT/configs/scripts/seed-user-overrides.sh" 2>/dev/null || true

if [ -x "$UP_ROOT/configs/scripts/seed-user-overrides.sh" ]; then
  HOME="/home/$USERNAME" "$UP_ROOT/configs/scripts/seed-user-overrides.sh" \
    --home "/home/$USERNAME" || true
fi

if [ -x "$UP_ROOT/configs/scripts/install-agent-skills.sh" ]; then
  chmod +x "$UP_ROOT/configs/scripts/install-agent-skills.sh"
  HOME="/home/$USERNAME" "$UP_ROOT/configs/scripts/install-agent-skills.sh" \
    --home "/home/$USERNAME" || true
fi

# Seed config before detection so effects=auto is present
cat > "/home/$USERNAME/.config/up/config" << 'EOF'
# effects: auto | full | lite | safe
# auto = detect GPU/virt/RAM and set fade/blur/dim; other values pin a profile
effects = "auto"
fade = true
blur = true
dim = true
font = "DejaVu Sans Mono"
theme = "aetherweft"
ready_sound = false
EOF

# Materialize fade/blur/dim + picom/capability.conf for this machine
# Install/chroot: never start desktop-agent or polybar (no graphical session yet).
if [ -x "$UP_ROOT/configs/scripts/apply-compositor-profile.sh" ]; then
  HOME="/home/$USERNAME" UP_INSTALL=1 UP_DESKTOP_INLINE=1 \
    "$UP_ROOT/configs/scripts/apply-compositor-profile.sh" --force --no-theme --home "/home/$USERNAME" \
    || log_warn "Compositor capability detection failed; using config defaults"
fi

# Generate default theme files only (desktop-agent applies live reloads after first login)
HOME="/home/$USERNAME" UP_INSTALL=1 UP_DESKTOP_INLINE=1 \
  "$UP_ROOT/configs/scripts/switch-theme.sh" --theme aetherweft --no-reload --home "/home/$USERNAME" \
  || log_warn "Default theme generation failed (non-fatal)"

# Copy desktop files
mkdir -p "/home/$USERNAME/.local/share/applications"
if [ -d "$CONFIG_DIR/local/share/applications" ]; then
  for desktop_file in "$CONFIG_DIR/local/share/applications"/*.desktop; do
    [ -f "$desktop_file" ] && cp -p "$desktop_file" "/home/$USERNAME/.local/share/applications/" 2>/dev/null || true
  done
fi

[ -n "$NVIDIA_PKGS" ] && deploy_system "$CONFIG_DIR/X11/xorg.conf.d/20-nvidia.conf" "/etc/X11/xorg.conf.d/20-nvidia.conf"

chown -R "$USERNAME:$USERNAME" "/home/$USERNAME"
chmod 755 "/home/$USERNAME"

# Create .xprofile for X11 session environment
cat > "/home/$USERNAME/.xprofile" << 'EOF'
#!/bin/sh
export DISPLAY="${DISPLAY:-:0}"
export XDG_SESSION_TYPE="x11"
export XDG_CURRENT_DESKTOP="i3"
export XDG_SESSION_DESKTOP="i3-up"
[ -z "$XAUTHORITY" ] && export XAUTHORITY="$HOME/.Xauthority"
[ -d "/usr/local/share/up/bin" ] && export PATH="/usr/local/share/up/bin:$PATH"
export UP_ROOT="/usr/local/share/up"
[ -f /etc/profile ] && . /etc/profile
[ -f "$HOME/.profile" ] && . "$HOME/.profile"
EOF
chmod 644 "/home/$USERNAME/.xprofile"
chown "$USERNAME:$USERNAME" "/home/$USERNAME/.xprofile"

# Create .xsession that delegates to start-session.sh
cat > "/home/$USERNAME/.xsession" << 'EOF'
#!/bin/sh
exec /usr/local/share/up/configs/scripts/start-session.sh
EOF
chmod 755 "/home/$USERNAME/.xsession"
chown "$USERNAME:$USERNAME" "/home/$USERNAME/.xsession"

mkdir -p /etc/lightdm/lightdm.conf.d
cat > /etc/lightdm/lightdm.conf.d/50-default-i3-session.conf << 'EOF'
[Seat:*]
greeter-session=lightdm-gtk-greeter
user-session=i3-up
session-wrapper=/etc/lightdm/Xsession
EOF

# Set executable permissions on all scripts
find "$UP_ROOT" -type f \( -name "*.sh" -o -path "*/bin/*" \) -exec chmod +x {} \;

chsh -s /usr/bin/zsh "$USERNAME"

# Set UP_ROOT system-wide (login shells)
cat > /etc/profile.d/up-path.sh << 'EOF'
export UP_ROOT="/usr/local/share/up"
export PATH="$UP_ROOT/bin:$PATH"
EOF
chmod 644 /etc/profile.d/up-path.sh

# Symlink up-* into /usr/local/bin so sudo secure_path finds them
# (sudo does not use /etc/profile.d/up-path.sh)
mkdir -p /usr/local/bin
for up_bin in "$UP_ROOT"/bin/up-*; do
  [ -e "$up_bin" ] || continue
  ln -sfn "$up_bin" "/usr/local/bin/$(basename "$up_bin")"
done

if [ -f "$UP_ROOT/configs/sudoers/up-greeter" ]; then
  install -m 440 "$UP_ROOT/configs/sudoers/up-greeter" /etc/sudoers.d/up-greeter
fi

# Customize OS identification
sed -i 's/^NAME=.*/NAME="Up"/' /etc/os-release
sed -i 's/^PRETTY_NAME=.*/PRETTY_NAME="Up"/' /etc/os-release
sed -i 's/^ID=.*/ID=up/' /etc/os-release
sed -i 's/^ID_LIKE=.*/ID_LIKE=arch/' /etc/os-release

cat >/etc/issue <<'EOF'
Up \r (\l)

EOF

sed -i 's/^GRUB_DISTRIBUTOR=.*/GRUB_DISTRIBUTOR="Up"/' /etc/default/grub
grep -q '^GRUB_DISTRIBUTOR=' /etc/default/grub || echo 'GRUB_DISTRIBUTOR="Up"' >>/etc/default/grub

# Boot/runtime tunables (GRUB timeout, wait-online, journald, TRIM, swappiness)
# Must run before grub-mkconfig so the 2s timeout lands in grub.cfg.
[ -f /root/up/.swap-config ] && source /root/up/.swap-config
if [ -x "$UP_ROOT/configs/scripts/tune-system.sh" ]; then
  "$UP_ROOT/configs/scripts/tune-system.sh" || log_warning "System runtime tuning skipped"
fi

update_phase 14 "GRUB & Services"
update_progress 27 "$PROGRESS_TOTAL" "Installing GRUB bootloader..."

BOOT_MODE="uefi"
PARTITION_TABLE_TYPE="gpt"
[ -f /root/up/.boot-config ] && source /root/up/.boot-config

# Install GRUB based on boot mode — essential: do not swallow failures
if [ "$BOOT_MODE" = "uefi" ]; then
    if ! run_and_log grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=GRUB; then
        log_error "GRUB EFI install failed — system may be unbootable"
        exit 1
    fi
else
    # DISK must come from .boot-config written by bootstrap
    if [ -z "${DISK:-}" ]; then
        log_error "DISK not set for BIOS GRUB install (missing .boot-config?)"
        exit 1
    fi
    if ! run_and_log grub-install --target=i386-pc --boot-directory=/boot "$DISK"; then
        log_error "GRUB BIOS install failed on $DISK — system may be unbootable"
        exit 1
    fi
fi

# Generate GRUB configuration
if ! run_and_log grub-mkconfig -o /boot/grub/grub.cfg; then
    log_error "grub-mkconfig failed — system may be unbootable"
    exit 1
fi

if [ ! -f "/boot/grub/grub.cfg" ]; then
    log_error "GRUB config missing after mkconfig"
    exit 1
fi

# Update boot message
sed -i 's/Loading Linux/Loading Up/g' /boot/grub/grub.cfg

systemctl daemon-reload
enable_service_safe dbus
enable_service_safe NetworkManager

[ -f /root/up/.swap-config ] && source /root/up/.swap-config
[ "$SWAP_TYPE" = "zram" ] && enable_service_safe zram-setup.service

mkdir -p /etc/NetworkManager/conf.d
cat >/etc/NetworkManager/conf.d/dns.conf <<'EOF'
[main]
dns=systemd-resolved
EOF

enable_service_safe systemd-resolved
enable_service_safe pipewire --user
enable_service_safe pipewire-pulse --user
enable_service_safe wireplumber --user
enable_service_safe lightdm

# Firewall defaults (non-fatal)
# shellcheck disable=SC1091
source "$UP_ROOT/configs/scripts/setup-firewall.sh"
setup_firewall || log_warning "Firewall setup skipped or failed"

save_failed_services
save_installation_state

# Human-readable install report for first boot
{
  echo "=== Up Linux Installation Report ==="
  echo "Date: $(date -Iseconds)"
  echo "Hostname: $(cat /etc/hostname 2>/dev/null || echo unknown)"
  echo "User: ${USERNAME:-unknown}"
  echo "Display stack: ${DISPLAY_STACK:-unknown}"
  [ -f /root/up/.boot-config ] && cat /root/up/.boot-config
  echo ""
  if [ -f /var/log/up/install-state.sh ]; then
    echo "--- Package state ---"
    cat /var/log/up/install-state.sh
  fi
  if [ -f /var/log/up/failed-services.sh ]; then
    echo "--- Service state ---"
    cat /var/log/up/failed-services.sh
  fi
  echo ""
  echo "Log: /var/log/up/install.log"
  echo "Next: log in via LightDM, then run up-quickstart"
} > /var/log/up/install-report.txt
log_info "Install report written to /var/log/up/install-report.txt"

update_phase 15 "Welcome to Up Linux"
update_progress "$PROGRESS_TOTAL" "$PROGRESS_TOTAL" "Installation complete!"

MIG_STATE_DIR="/var/lib/up/migrations"
mkdir -p "$MIG_STATE_DIR"

# Run migrations (non-blocking - failures don't stop setup)
for mig in $UP_ROOT/migrations/*.sh; do
  [ -f "$mig" ] || continue
  mig_num=$(basename "$mig" .sh)
  DONE_FILE="$MIG_STATE_DIR/${mig_num}.done"
  
  [ -f "$DONE_FILE" ] && continue
  
  if bash "$mig"; then
    touch "$DONE_FILE"
  else
    log_info "⚠ Migration $mig_num failed"
  fi
done

save_failed_services
save_installation_state
