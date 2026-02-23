#!/bin/bash
# =============================================================================
# prepare-image.sh — Jetson Nano image preparation script
# Cleans personal data, sets up first-boot hooks, then shuts down.
# Run as root: sudo bash prepare-image.sh
# =============================================================================

set -e

# ── Colour helpers ────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

# ── Root check ────────────────────────────────────────────────────────────────
[[ $EUID -ne 0 ]] && error "Please run as root: sudo bash $0"

echo ""
echo "============================================="
echo "  Jetson Nano — Community Image Prep Script  "
echo "============================================="
echo ""
warn "This will WIPE personal data and SHUT DOWN the system."
read -rp "Are you sure you want to continue? [yes/N] " confirm
[[ "$confirm" != "yes" ]] && { info "Aborted."; exit 0; }

# ─────────────────────────────────────────────────────────────────────────────
# 1. NetworkManager connections
# ─────────────────────────────────────────────────────────────────────────────
info "Removing NetworkManager connections..."
rm -f  /etc/NetworkManager/system-connections/*
rm -rf /var/lib/NetworkManager/*

info "Removing wpa_supplicant configs..."
rm -f  /etc/wpa_supplicant/wpa_supplicant.conf
rm -rf /etc/wpa_supplicant/*

# ─────────────────────────────────────────────────────────────────────────────
# 2. Shell histories — wiped once at the end (step 8), skipped here
# ─────────────────────────────────────────────────────────────────────────────

# ─────────────────────────────────────────────────────────────────────────────
# 3. Journals and logs
# ─────────────────────────────────────────────────────────────────────────────
info "Rotating and vacuuming systemd journal..."
journalctl --rotate      2>/dev/null || true
journalctl --vacuum-time=1s 2>/dev/null || true

info "Truncating log files..."
find /var/log -type f -exec truncate -s 0 {} \;

# ─────────────────────────────────────────────────────────────────────────────
# 4. SSH host keys + first-boot regeneration unit
# ─────────────────────────────────────────────────────────────────────────────
info "Removing SSH host keys..."
rm -f /etc/ssh/ssh_host_*

info "Installing regen-ssh-hostkeys.service..."
cat > /etc/systemd/system/regen-ssh-hostkeys.service <<'EOF'
[Unit]
Description=Regenerate SSH host keys if missing
Before=ssh.service
ConditionPathExists=!/etc/ssh/ssh_host_ed25519_key

[Service]
Type=oneshot
ExecStart=/usr/bin/ssh-keygen -A

[Install]
WantedBy=multi-user.target
EOF
systemctl enable regen-ssh-hostkeys.service
info "regen-ssh-hostkeys.service enabled."

# ─────────────────────────────────────────────────────────────────────────────
# 5. Root filesystem auto-expand on first boot
# ─────────────────────────────────────────────────────────────────────────────
info "Installing expand-rootfs.service..."
cat > /etc/systemd/system/expand-rootfs.service <<'EOF'
[Unit]
Description=Expand root partition and filesystem to fill SD card
# Run after the filesystem is mounted but before user services start
After=local-fs.target
Before=multi-user.target
# Skip if already done (sentinel file written by ExecStart)
ConditionPathExists=!/var/lib/.expand-rootfs-done

[Service]
Type=oneshot
# growpart exits 1 if partition already fills the disk — treat that as ok
ExecStart=/bin/bash -c '\
    growpart /dev/mmcblk0 1 || true && \
    resize2fs /dev/mmcblk0p1 && \
    touch /var/lib/.expand-rootfs-done'
# Give it time — resize2fs on a large card can take a moment
TimeoutSec=120
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
systemctl enable expand-rootfs.service
info "expand-rootfs.service enabled."

# ─────────────────────────────────────────────────────────────────────────────
# 6. Machine ID
# ─────────────────────────────────────────────────────────────────────────────
info "Resetting machine-id..."
truncate -s 0 /etc/machine-id
rm -f /var/lib/dbus/machine-id

# ─────────────────────────────────────────────────────────────────────────────
# 7. APT caches + temp files
# ─────────────────────────────────────────────────────────────────────────────
info "Cleaning apt caches..."
apt-get clean
rm -rf /var/lib/apt/lists/*

info "Cleaning temp files and thumbnails..."
rm -rf /tmp/* /var/tmp/*
find /home -maxdepth 3 -path "*/.cache/thumbnails/*" -type f -delete
find /home -maxdepth 2 \( \
    -name ".sudo_as_admin_successful" \
    -o -name ".lesshst" \
\) -delete

# ─────────────────────────────────────────────────────────────────────────────
# 8. Shell history — single wipe at the very end
#    Covers root + all home users, then nukes the current session too
# ─────────────────────────────────────────────────────────────────────────────
info "Wiping shell histories..."
rm -f /root/.bash_history /root/.zsh_history
find /home -maxdepth 2 \( -name ".bash_history" -o -name ".zsh_history" \) -type f -delete
# Kill current in-memory history and prevent it being written on exit
history -c 2>/dev/null || true
export HISTSIZE=0 HISTFILESIZE=0
unset HISTFILE

# ─────────────────────────────────────────────────────────────────────────────
# 9. Sync and shut down
# ─────────────────────────────────────────────────────────────────────────────
echo ""
info "All done. Syncing filesystems and shutting down in 5 seconds..."
echo "  → After shutdown: dd the image, shrink it, compress with xz."
echo ""
sleep 5
sync
shutdown now
