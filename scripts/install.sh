#!/usr/bin/env bash
# install.sh — install the SIL6250 fingerprint stack on Ubuntu/Debian
#
# What it does (see docs/install.md for the full explanation):
#   1. installs system packages (dkms, rust, dev libs)
#   2. builds + installs open-fprintd (fprintd drop-in)
#   3. builds + installs the sil6250 kernel module + daemon
#   4. copies your enrolled MOK key for signing (if present)
#   5. configures DKMS to sign with that key
#   6. installs the module via DKMS (persists across reboots)
#   7. enables the systemd services
#
# Optional env:
#   MOK_KEY  path to an ENROLLED MOK private key (default: ~/MOK.key)
#   MOK_CRT  path to the matching cert           (default: ~/MOK.crt)
#   SKIP_PAM  set to 1 to skip PAM integration
#
# Run:  sudo ./install.sh
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
    echo "Run as root: sudo $0" >&2
    exit 1
fi

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MOK_KEY="${MOK_KEY:-$HOME/MOK.key}"
MOK_CRT="${MOK_CRT:-$HOME/MOK.crt}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!!\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31mxx\033[0m %s\n' "$*" >&2; exit 1; }

# ---- 1. system packages -----------------------------------------------------
log "Installing system packages"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq \
    dkms rustc cargo libssl-dev libdbus-1-dev libmbedtls-dev \
    git make gcc acpica-tools python3-dbus python3-gi

# ---- 2. open-fprintd --------------------------------------------------------
log "Building + installing open-fprintd"
git clone --depth 1 https://github.com/uunicorn/open-fprintd.git "$WORK/open-fprintd"
(
    cd "$WORK/open-fprintd"
    ./setup.py install --force --install-layout deb --prefix=/usr --root=/
)

# ---- 3. sil6250 kernel module + daemon --------------------------------------
log "Building + installing sil6250 kernel module + daemon"
git clone --depth 1 https://github.com/AlexDaichendt/sil6250-linux.git "$WORK/sil6250-linux"
(
    cd "$WORK/sil6250-linux"
    make -C kernel -j"$(nproc)"
    cargo build --locked --release -p sil6250d

    install -Dm755 target/release/sil6250d /usr/local/bin/sil6250d
    install -Dm644 sil6250d/io.github.uunicorn.Fprint.conf \
        /etc/dbus-1/system.d/io.github.uunicorn.Fprint.conf
    install -Dm644 kernel/69-sil6250.rules /etc/udev/rules.d/69-sil6250.rules
    install -Dm644 sil6250d/sil6250d.service /etc/systemd/system/sil6250d.service
)
install -Dm644 "$WORK/open-fprintd/debian/open-fprintd.service" \
    /etc/systemd/system/open-fprintd.service

# ---- 4. MOK key for signing -------------------------------------------------
log "Preparing MOK signing key"
if [ -f "$MOK_KEY" ] && [ -f "$MOK_CRT" ]; then
    install -m600 "$MOK_KEY" /var/lib/dkms/mok.key
    install -m644 "$MOK_CRT" /var/lib/dkms/mok.pub
    log "Using existing MOK: $MOK_CRT"
else
    warn "No MOK key at $MOK_KEY / $MOK_CRT"
    warn "If Secure Boot is on, the module must be signed by an ENROLLED key."
    warn "Either:"
    warn "  1. put your enrolled key at ~/MOK.key + ~/MOK.crt and re-run, or"
    warn "  2. create+enroll one now (needs a reboot):"
    warn "       openssl req -new -x509 -newkey rsa:2048 -keyout MOK.key \\"
    warn "         -outform DER -out MOK.crt -nodes -days 36500 -subj /CN=you/"
    warn "       sudo mokutil --import MOK.crt   # then reboot + enroll"
fi

# ---- 5. DKMS signing config -------------------------------------------------
log "Configuring DKMS to use the enrolled MOK"
mkdir -p /etc/dkms/framework.conf.d
cat > /etc/dkms/framework.conf.d/99-sil6250-signing.conf <<EOF
mok_signing_key="/var/lib/dkms/mok.key"
mok_certificate="/var/lib/dkms/mok.pub"
EOF

# ---- 6. DKMS install --------------------------------------------------------
log "Installing module via DKMS"
VER="0.1.0"
rm -rf "/usr/src/sil6250-$VER"
cp -r "$WORK/sil6250-linux/kernel" "/usr/src/sil6250-$VER"
(cd "/usr/src/sil6250-$VER" && make clean)
dkms remove "sil6250/$VER" --all 2>/dev/null || true
dkms add "sil6250/$VER"
dkms build "sil6250/$VER"
dkms install "sil6250/$VER"

# ---- 7. services ------------------------------------------------------------
log "Enabling services"
udevadm control --reload
systemctl daemon-reload
systemctl reload dbus 2>/dev/null || true
systemctl enable open-fprintd sil6250d
systemctl restart open-fprintd sil6250d

# ---- 8. PAM (optional) ------------------------------------------------------
if [ "${SKIP_PAM:-0}" != "1" ]; then
    log "Setting up PAM integration (sudo + GDM)"
    bash "$HERE/setup-pam.sh"
fi

log "Done."
log "Enroll a finger:   fprintd-enroll"
log "Verify:            fprintd-verify -f right-index-finger"
