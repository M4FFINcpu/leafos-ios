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
KEYBOARD="${KEYBOARD:-gb}"                 # keyboard layout: gb, us, es, fr, de, it, pt, latam...
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
udev
kmod
iproute2
isc-dhcp-client
iputils-ping
curl
systemd-timesyncd
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

# ---- Networking: make sure the VM always gets online ----------------------------------
mkdir -p "$INC/etc/NetworkManager/conf.d" "$INC/etc/NetworkManager/system-connections" \
         "$INC/usr/local/sbin" "$INC/etc/systemd/system" config/hooks/normal

# NetworkManager manages every network card (ignore /etc/network/interfaces)
cat > "$INC/etc/NetworkManager/conf.d/10-leafos.conf" <<'EOF'
[main]
plugins=keyfile
dns=default

[ifupdown]
managed=true

[keyfile]
unmanaged-devices=none
EOF

# A wired connection that works on any network card (VirtualBox NAT, bridged, real PCs)
cat > "$INC/etc/NetworkManager/system-connections/Wired.nmconnection" <<'EOF'
[connection]
id=Wired
type=ethernet
autoconnect=true
autoconnect-priority=10

[ipv4]
method=auto

[ipv6]
method=auto
EOF
chmod 600 "$INC/etc/NetworkManager/system-connections/Wired.nmconnection"

# Fallback: if there's still no connection after boot, use DHCP directly and fix DNS
cat > "$INC/usr/local/sbin/leafos-netfix" <<'EOF'
#!/bin/sh
# Leaf OS network fallback
[ "$1" = "now" ] || sleep 12
for attempt in 1 2 3; do
    if ip -4 route show default | grep -q default; then break; fi
    for dev in $(ls /sys/class/net); do
        [ "$dev" = "lo" ] && continue
        ip link set "$dev" up 2>/dev/null
        if ! ip -4 addr show dev "$dev" | grep -q "inet "; then
            timeout 25 dhclient -1 "$dev" >/dev/null 2>&1 || true
        fi
    done
    sleep 5
done
if ! grep -q '^nameserver' /etc/resolv.conf 2>/dev/null; then
    rm -f /etc/resolv.conf
    printf 'nameserver 10.0.2.3\nnameserver 1.1.1.1\nnameserver 8.8.8.8\n' > /etc/resolv.conf
fi
exit 0
EOF
chmod 755 "$INC/usr/local/sbin/leafos-netfix"

cat > "$INC/etc/systemd/system/leafos-netfix.service" <<'EOF'
[Unit]
Description=Leaf OS network fallback
After=NetworkManager.service network.target
Wants=network.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/leafos-netfix

[Install]
WantedBy=multi-user.target
EOF

cat > config/hooks/normal/0100-leafos-services.hook.chroot <<'EOF'
#!/bin/sh
systemctl enable NetworkManager.service || true
systemctl enable leafos-netfix.service || true
systemctl enable systemd-timesyncd.service || true
EOF
chmod 755 config/hooks/normal/0100-leafos-services.hook.chroot

# ---- Local server: serves Leaf OS, power buttons, network check ------------------------
cat > "$INC/opt/leafos/server.py" <<'EOF'
#!/usr/bin/env python3
"""Leaf OS ISO edition: serves the desktop on http://127.0.0.1:8080, handles the
Shut down / Reboot buttons and the Terminal's netstatus / netfix commands."""
import functools
import http.server
import subprocess

ROOT = "/opt/leafos"
CHECKS = [
    ("network cards", ["ip", "-br", "link"]),
    ("addresses", ["ip", "-4", "-br", "addr"]),
    ("routes", ["ip", "route"]),
    ("dns servers", ["cat", "/etc/resolv.conf"]),
    ("networkmanager", ["nmcli", "-t", "-f", "DEVICE,TYPE,STATE,CONNECTION", "device"]),
    ("dns lookup", ["getent", "hosts", "api.open-meteo.com"]),
    ("https test", ["curl", "-sS", "-m", "8", "-o", "/dev/null", "-w", "HTTP %{http_code}\n", "https://api.open-meteo.com/v1/forecast?latitude=40&longitude=-3&current=temperature_2m"]),
]


def run(cmd, timeout=12):
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
        return (r.stdout + r.stderr).strip() or "(no output)"
    except Exception as e:  # noqa: BLE001
        return f"error: {e}"


class LeafHandler(http.server.SimpleHTTPRequestHandler):
    def send_text(self, text, code=200):
        body = text.encode()
        self.send_response(code)
        self.send_header("Content-Type", "text/plain; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path == "/netstatus":
            self.send_text("\n\n".join(f"== {t} ==\n{run(c)}" for t, c in CHECKS))
        else:
            super().do_GET()

    def do_POST(self):
        # The custom header blocks requests coming from other websites
        if self.headers.get("X-Leaf") != "1":
            self.send_text("forbidden", 403)
            return
        if self.path in ("/power/off", "/power/reboot"):
            self.send_text("ok")
            action = "poweroff" if self.path.endswith("off") else "reboot"
            subprocess.Popen(["sudo", "-n", "systemctl", action])
        elif self.path == "/netfix":
            out = run(["sudo", "-n", "systemctl", "restart", "NetworkManager"], 20)
            out += "\n" + run(["sudo", "-n", "/usr/local/sbin/leafos-netfix", "now"], 120)
            self.send_text(out)
        else:
            self.send_text("not found", 404)

    def end_headers(self):
        self.send_header("Cache-Control", "no-store")
        super().end_headers()

    def log_message(self, *args):
        pass


if __name__ == "__main__":
    handler = functools.partial(LeafHandler, directory=ROOT)
    http.server.ThreadingHTTPServer(("127.0.0.1", 8080), handler).serve_forever()
EOF
chmod 755 "$INC/opt/leafos/server.py"

# ---- Leaf OS additions for the ISO edition ---------------------------------------------
cat > "$INC/opt/leafos/iso-extra.js" <<'EOF'
// Leaf OS ISO edition extras (added by build.sh)
(function () {
    if (!(location.hostname === '127.0.0.1' || location.hostname === 'localhost')) return;

    // Chromium inside a VM can wrongly report "offline", so trust the Wi-Fi switch instead
    window.isOsOnline = function () { return Boolean(osSettings.wifi && !osSettings.airplane); };

    async function netstatus() {
        try { return await (await fetch('/netstatus', { cache: 'no-store' })).text(); }
        catch (e) { return 'Could not run the network check: ' + e.message; }
    }

    // Terminal commands: netstatus (show connection details) and netfix (reconnect)
    const baseCmd = window.execCmdExtra;
    window.execCmdExtra = async function (cmd, arg, out, hist) {
        if (cmd === 'netstatus' || cmd === 'ifconfig') {
            out.textContent = 'Checking the network...';
            out.textContent = await netstatus();
            hist.scrollTop = hist.scrollHeight;
            return true;
        }
        if (cmd === 'netfix') {
            out.textContent = 'Reconnecting the network (up to 1 minute)...';
            try {
                const r = await fetch('/netfix', { method: 'POST', headers: { 'X-Leaf': '1' } });
                await r.text();
            } catch (e) { /* ignore */ }
            await refreshLiveNetworkInfo(false);
            out.textContent = liveNet.ip && liveNet.ip !== 'Unavailable'
                ? 'Connected! Public IP: ' + liveNet.ip
                : 'Still offline. Type netstatus and send a photo of the result.';
            hist.scrollTop = hist.scrollHeight;
            return true;
        }
        return baseCmd(cmd, arg, out, hist);
    };

    // A few seconds after start-up, warn if the internet can't be reached
    window.addEventListener('load', () => {
        setTimeout(async () => {
            await refreshLiveNetworkInfo(false);
            if (!liveNet.ip || liveNet.ip === 'Unavailable') {
                showToast('No internet yet. Open Terminal and type netfix (or netstatus for details).', true);
            }
        }, 9000);
    });
})();
EOF
sed -i 's#</body>#<script src="iso-extra.js"></script>\n</body>#' "$INC/opt/leafos/index.html"

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
