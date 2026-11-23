#!/bin/bash
# =============================================================================
#  Leaf OS 3.0 ISO builder
#  Builds a bootable live ISO (Debian 12 + Chromium kiosk) that starts straight
#  into the Leaf OS desktop with working internet.
#
#  Run inside a Debian 12 container (works on Linux, Windows and macOS):
#     docker run --rm --privileged -v "$PWD":/build -w /build debian:bookworm bash ./build.sh
#  Result: out/leafos-3.0-amd64.iso
# =============================================================================
set -euo pipefail

# ---- settings you can change ------------------------------------------------
KEYBOARD="${KEYBOARD:-es}"                 # keyboard layout: es, us, gb, fr, de, it, pt, latam...
TIMEZONE="${TIMEZONE:-Europe/Madrid}"      # time zone
LOCALE="${LOCALE:-en_US.UTF-8}"            # system language
SCREEN="${SCREEN:-1280x800}"               # preferred screen size inside the VM
# -----------------------------------------------------------------------------

ROOT="$(cd "$(dirname "$0")" && pwd)"
export DEBIAN_FRONTEND=noninteractive

echo "==> Installing live-build"
apt-get update
apt-get install -y --no-install-recommends live-build debootstrap ca-certificates cpio xz-utils

rm -rf "$ROOT/work" "$ROOT/out"
mkdir -p "$ROOT/work" "$ROOT/out"
cd "$ROOT/work"

echo "==> Configuring the live system"
lb config \
  --mode debian \
  --distribution bookworm \
  --architectures amd64 \
  --archive-areas "main" \
  --binary-images iso-hybrid \
  --debian-installer none \
  --memtest none \
  --apt-recommends false \
  --firmware-binary false \
  --firmware-chroot false \
  --iso-application "Leaf OS 3.0" \
  --iso-publisher "Leaf OS" \
  --iso-volume "LEAFOS_3_0" \
  --bootappend-live "boot=live components quiet splash hostname=leafos username=leaf user-fullname=Leaf locales=${LOCALE} keyboard-layouts=${KEYBOARD} timezone=${TIMEZONE}"

# ---- packages -----------------------------------------------------------------
mkdir -p config/package-lists
cat > config/package-lists/leafos.list.chroot <<'EOF'
live-boot
live-config
live-config-systemd
systemd-sysv
libpam-systemd
user-setup
sudo
dbus
dbus-x11
xserver-xorg-core
xserver-xorg-legacy
xserver-xorg-input-libinput
xserver-xorg-video-vmware
xserver-xorg-video-vesa
xserver-xorg-video-fbdev
xinit
x11-xserver-utils
xkb-data
openbox
chromium
fonts-dejavu-core
fonts-liberation2
fonts-noto-color-emoji
python3
network-manager
ca-certificates
pulseaudio
alsa-utils
locales
keyboard-configuration
console-setup
tzdata
EOF

# ---- Leaf OS files ----------------------------------------------------------------
INC=config/includes.chroot
mkdir -p "$INC/opt/leafos" "$INC/etc/skel" "$INC/etc/chromium/policies/managed"
cp "$ROOT/leafos/index.html" "$INC/opt/leafos/index.html"
cp "$ROOT/leafos/server.py"  "$INC/opt/leafos/server.py"
chmod 755 "$INC/opt/leafos/server.py"

# Log in automatically on the first console and start the graphical session
cat > "$INC/etc/skel/.bash_profile" <<'EOF'
if [ -z "${DISPLAY:-}" ] && [ "$(tty)" = "/dev/tty1" ]; then
    exec startx -- -nolisten tcp > "$HOME/.leafos-x.log" 2>&1
fi
EOF

# The graphical session: Leaf OS full screen, restarted automatically if closed
cat > "$INC/etc/skel/.xinitrc" <<EOF
#!/bin/sh
xset s off -dpms s noblank 2>/dev/null
OUT=\$(xrandr 2>/dev/null | awk '/ connected/{print \$1; exit}')
[ -n "\$OUT" ] && xrandr --output "\$OUT" --mode ${SCREEN} 2>/dev/null
openbox &
python3 /opt/leafos/server.py &
sleep 1
while true; do
    chromium --kiosk --app=http://127.0.0.1:8080/index.html \\
        --user-data-dir="\$HOME/.leafos-browser" \\
        --no-first-run --noerrdialogs --disable-infobars \\
        --disable-session-crashed-bubble --disable-translate \\
        --password-store=basic --autoplay-policy=no-user-gesture-required \\
        --check-for-update-interval=31536000 --overscroll-history-navigation=0 \\
        --disable-pinch --disable-features=Translate,MediaRouter --disable-gpu
    sleep 1
done
EOF
chmod 755 "$INC/etc/skel/.xinitrc"

# Quiet, private browser defaults
cat > "$INC/etc/chromium/policies/managed/leafos.json" <<'EOF'
{
  "BrowserSignin": 0,
  "SyncDisabled": true,
  "PasswordManagerEnabled": false,
  "TranslateEnabled": false,
  "MetricsReportingEnabled": false,
  "PromotionalTabsEnabled": false,
  "DefaultBrowserSettingEnabled": false,
  "BackgroundModeEnabled": false
}
EOF

# ---- boot menu: Leaf OS branding and a 5 second auto-start ----------------------------
if [ -d /usr/share/live/build/bootloaders/isolinux ]; then
    mkdir -p config/bootloaders
    cp -r /usr/share/live/build/bootloaders/isolinux config/bootloaders/
    grep -rl "Live system" config/bootloaders 2>/dev/null | xargs -r sed -i 's/Live system/Leaf OS 3.0/g' || true
    grep -rl "^timeout" config/bootloaders 2>/dev/null | xargs -r sed -i 's/^timeout .*/timeout 50/' || true
fi

echo "==> Building the ISO (this takes 15-30 minutes)"
lb build

ISO=$(ls -1 ./*.iso | head -n1)
mv "$ISO" "$ROOT/out/leafos-3.0-amd64.iso"
ls -lh "$ROOT/out/"
echo "==> Done: out/leafos-3.0-amd64.iso"
