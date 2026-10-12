# sil6250-amd-linux

[![CI](https://github.com/bocelin1995-lab/sil6250-amd-linux/actions/workflows/ci.yml/badge.svg)](https://github.com/bocelin1995-lab/sil6250-amd-linux/actions)

**Make the SIL6250 fingerprint sensor work on Linux — end to end, with Secure
Boot signing and reboot persistence.**

This repo documents and packages the *complete* journey of getting the Huawei /
WIKO **MateBook D 14 (AMD Ryzen)** fingerprint reader working on Ubuntu/Debian:
hardware identification, the driver stack, MOK signing, PAM integration, and
DKMS persistence. It also ships a diagnostic kernel probe and install scripts.

The actual driver is [AlexDaichendt/sil6250-linux](https://github.com/AlexDaichendt/sil6250-linux)
(Silead GSL6150r + HC32F460, branded *Petaic*). This repo fills in everything
the upstream README leaves out: Ubuntu packaging, **signing with an *enrolled*
MOK** (the #1 silent failure), PAM, and reboot persistence.

---

## TL;DR

The sensor is **not** a Goodix GXFP5130 and is **not** on USB/PCIe/SPI. It is a
**Silead GSL6150r + HDSC HC32F460** module (Petaic) reached through an
**EC-arbitrated shared-memory mailbox** at `0xFEEC3000` (AMD) or
`0xFE800000` (Intel), exposed as ACPI device `SIL6250`.

Install everything, enroll, done:

```sh
sudo ./scripts/install.sh
fprintd-enroll
fprintd-verify -f right-index-finger
```

---

## The story, in one page

1. **Symptom** — Windows fingerprint works; Linux `fprintd-list` says
   "No devices available", `lsusb` shows nothing.

2. **Root cause** — the sensor is an ACPI/EC mailbox device, invisible to every
   USB/SPI/I2C driver. It is *also* not the Goodix chip everyone assumed: the
   ACPI node `\_SB.SPBA` hosts *two* sibling sensors, switched by an EC field
   (`HWEP == 0x02` → `SIL6250`, the Silead/Petaic part).

3. **Fix** — the `sil6250-linux` stack: a C kernel resource broker, a Rust
   library (mailbox framing + TLS-PSK + capture + a clean-room SIFT matcher),
   and a Rust daemon that plugs into `open-fprintd`.

4. **The real gotcha** — Secure Boot. DKMS signs the module with the *shim* key
   by default, which is **not enrolled** in your firmware. The module builds and
   loads fine, then is **rejected on reboot**. This repo configures DKMS to sign
   with your *enrolled* MOK.

5. **Polish** — PAM integration (fingerprint for sudo + GDM login) with a
   safe `sufficient` rule and `timeout=10`, plus DKMS so it survives kernel
   updates.

---

## Repository layout

```
.
├── README.md              ← you are here
├── LICENSE
├── kernel-probe/          ← read-only diagnostic kernel module (ours)
│   ├── probe_mailbox.c
│   ├── Makefile
│   └── README.md
├── scripts/               ← automation (ours)
│   ├── install.sh         ← end-to-end installer
│   └── setup-pam.sh       ← sudo + GDM fingerprint auth
└── docs/                  ← the detailed write-ups (ours)
    ├── hardware.md        ← what the sensor actually is (DSDT evidence)
    ├── architecture.md    ← how the whole stack works
    ├── install.md         ← step-by-step, every command explained
    └── troubleshooting.md ← every failure mode we hit, and the fix
```

## What each piece does

| Path | Purpose |
|------|---------|
| `kernel-probe/probe_mailbox.c` | Diagnostic: read `FPST` (sensor fitted?) and dump the mailbox, so you can confirm hardware before installing anything |
| `scripts/install.sh` | Installs packages, builds open-fprintd + sil6250 stack, signs via your enrolled MOK, installs via DKMS, enables services, sets up PAM |
| `scripts/setup-pam.sh` | Adds the `pam_fprintd.so` rule to sudo + GDM |
| `docs/hardware.md` | The full reverse-engineering story: what SIL6250 is, the DSDT `_CRS`, AMD vs Intel addresses |
| `docs/architecture.md` | Layer-by-layer: EC mailbox → `sil6250.ko` → Rust lib → `sil6250d` → `open-fprintd` |
| `docs/install.md` | Every step, every command, why |
| `docs/troubleshooting.md` | enroll not finishing, verify arg confusion, Secure Boot rejection, etc. |

---

## Quick start

### 1. Confirm your hardware (optional but recommended)

```sh
cd kernel-probe
make
sudo insmod probe_mailbox.ko
sudo dmesg | grep gxfp_probe
# look for: FPST register ... = 0xaa (==0xAA fingerprint present)
sudo rmmod probe_mailbox
```

### 2. Install

```sh
sudo ./scripts/install.sh
```

If Secure Boot is on and you already have an enrolled MOK at `~/MOK.key` +
`~/MOK.crt`, the script uses it automatically. Otherwise it tells you how to
create and enroll one.

### 3. Enroll + verify

```sh
fprintd-enroll                          # press 15 times, vary position
fprintd-verify -f right-index-finger    # expect "verify-match"
```

### 4. (optional) sudo + GDM fingerprint

`scripts/install.sh` runs this by default. Manual:

```sh
sudo ./scripts/setup-pam.sh
sudo -k && sudo true    # test: press finger instead of typing password
```

---

## Supported hardware

- ✅ **WIKO Hi MateBook D 14 (Ryzen 7 H 255)** — AMD, mailbox `0xFEEC3000` — *tested end-to-end by the author*
- Likely **Huawei MateBook D 14 (AMD)** — same board
- Intel MateBook X Pro 2024 — mailbox `0xFE800000` — upstream-verified, same driver

The kernel driver reads the mailbox address from ACPI at runtime, so the AMD vs
Intel address difference does not matter.

---

## Security notes

- `pam_fprintd.so` is used with `sufficient` + `timeout=10`, so fingerprint
  failure **always** falls back to password. You cannot lock yourself out.
- `setup-pam.sh` keeps `.bak` backups and is trivially reversible.
- The kernel probe is strictly **read-only** (ioremap + dump, no writes).

## License

See `LICENSE`. The probe module and scripts are GPL-2.0 (probe links kernel
headers) / MIT (scripts). The driver itself is [LGPL-2.1](https://github.com/AlexDaichendt/sil6250-linux)
and is fetched at install time, not vendored here.

## Credits

- [AlexDaichendt/sil6250-linux](https://github.com/AlexDaichendt/sil6250-linux) — the driver
- [uunicorn/open-fprintd](https://github.com/uunicorn/open-fprintd) — the fprintd drop-in
- [Void755/gxfp_linux_driver](https://github.com/Void755/gxfp_linux_driver) — the Goodix sibling reference
