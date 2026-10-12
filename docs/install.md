# Install guide

Step-by-step for a **Debian/Ubuntu** machine (tested on Ubuntu 26.04).

> The actual driver is [AlexDaichendt/sil6250-linux](https://github.com/AlexDaichendt/sil6250-linux).
> This repo provides the missing glue that the upstream README leaves as an
> exercise: Ubuntu packaging, Secure Boot signing with an *enrolled* MOK, PAM
> integration, and DKMS persistence. The script `scripts/install.sh` automates
> all of it.

## Prerequisites

- kernel headers for your running kernel: `linux-headers-$(uname -r)`
- build tools: `gcc make git`
- Rust toolchain: `rustc cargo` (Ubuntu: `sudo apt install rustc cargo`)
- `libssl-dev libdbus-1-dev libmbedtls-dev`

## Quick install (automated)

```sh
sudo ./scripts/install.sh
```

Then enroll a finger:

```sh
fprintd-enroll
```

And verify:

```sh
fprintd-verify -f right-index-finger
```

## What the script does, step by step

### 1. Install system packages

```sh
sudo apt install -y dkms rustc cargo libssl-dev libdbus-1-dev libmbedtls-dev acpica-tools
```

### 2. Build + install open-fprintd (the fprintd drop-in)

```sh
git clone https://github.com/uunicorn/open-fprintd.git
cd open-fprintd
sudo ./setup.py install --force --install-layout deb --prefix=/usr --root=/
```

This installs `/usr/lib/open-fprintd/open-fprintd` and a D-Bus service file
for `net.reactivated.Fprint`. It needs `python3-dbus` + `python3-gi`
(usually preinstalled).

### 3. Build + install the sil6250 kernel module + daemon

```sh
git clone https://github.com/AlexDaichendt/sil6250-linux.git
cd sil6250-linux
make -C kernel
cargo build --locked --release -p sil6250d
sudo install -Dm755 target/release/sil6250d /usr/local/bin/sil6250d
sudo install -Dm644 sil6250d/io.github.uunicorn.Fprint.conf /etc/dbus-1/system.d/
sudo install -Dm644 kernel/69-sil6250.rules /etc/udev/rules.d/
sudo install -Dm644 sil6250d/sil6250d.service /etc/systemd/system/
sudo install -Dm644 /path/to/open-fprintd/debian/open-fprintd.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now open-fprintd sil6250d
```

### 4. Secure Boot: sign the module with an ENROLLED MOK

This is the part that silently breaks most people (see
`docs/troubleshooting.md` — DKMS signs with a key that is *not enrolled* by
default). The rule:

> The module must be signed by a MOK whose public half is enrolled in firmware.
> If the key is not enrolled, the module loads fine at build time but is
> **rejected on the next boot** under Secure Boot.

```sh
# If you already have an enrolled MOK (e.g. from a previous driver fix):
sudo cp ~/MOK.key  /var/lib/dkms/mok.key
sudo cp ~/MOK.crt  /var/lib/dkms/mok.pub
sudo chmod 600 /var/lib/dkms/mok.key
sudo chmod 644 /var/lib/dkms/mok.pub

# If you do not have one yet, create + enroll it (one-time, needs a reboot):
openssl req -new -x509 -newkey rsa:2048 -keyout MOK.key -outform DER   -out MOK.crt -nodes -days 36500 -subj "/CN=your-name/"
sudo mokutil --import MOK.crt        # then reboot, complete MOK enrollment
```

### 5. Configure DKMS to use the enrolled key

```sh
cat | sudo tee /etc/dkms/framework.conf.d/99-sil6250-signing.conf <<EOF
mok_signing_key="/var/lib/dkms/mok.key"
mok_certificate="/var/lib/dkms/mok.pub"
EOF
```

Without this, Ubuntu DKMS uses `/var/lib/shim-signed/mok/MOK.priv`, which is
the *shim* key — not your enrolled MOK — and the module will be rejected at
boot.

### 6. Install the module via DKMS (persists across reboots + kernel updates)

```sh
sudo cp -r sil6250-linux/kernel /usr/src/sil6250-0.1.0
cd /usr/src/sil6250-0.1.0 && sudo make clean
sudo dkms add sil6250/0.1.0
sudo dkms build sil6250/0.1.0
sudo dkms install sil6250/0.1.0
```

Verify the signature is from your enrolled key:

```sh
modinfo /lib/modules/$(uname -r)/updates/dkms/sil6250.ko.zst | grep signer
# expect: signer: <your-MOK-name>
```

### 7. PAM integration (sudo + GDM login)

Add one line to `/etc/pam.d/sudo` and `/etc/pam.d/gdm-password`, right
before `@include common-auth`:

```
auth    sufficient    pam_fprintd.so timeout=10
```

- `sufficient` = fingerprint success grants access; failure/timeout falls
  through to password (you can never lock yourself out).
- `timeout=10` = wait 10 s for a finger before falling back (otherwise you
  wait 30+ s).

`scripts/setup-pam.sh` does this and keeps `.bak` backups.

## After a reboot

DKMS + the `modules.alias` entry (`acpi*:SIL6250:*`) mean the module
auto-loads when the ACPI device appears. No manual `insmod` needed.
