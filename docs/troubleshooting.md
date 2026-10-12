# Troubleshooting

## enroll prints "enroll-stage-passed" forever

Not a hang. `ENROLL_STAGES` is **15**, and each pass is a distinct frame. You
must:

- keep pressing until it prints `enroll-completed`
- vary finger position/angle each press — identical presses are rejected as
  "redundant" (NCC similarity gate) and do not count

Pressing Ctrl+C shows `enroll error: cancelled` — that just means you stopped
early.

## fprintd-verify: "PermissionDenied" or "No fingers enrolled"

`fprintd-verify` positional arg is the **username**, not the finger. The
finger name goes after `-f`:

```sh
# WRONG: treats "right-index-finger" as a username
fprintd-verify right-index-finger

# RIGHT
fprintd-verify -f right-index-finger
# or just (auto-selects the only enrolled finger)
fprintd-verify
```

- As a normal user, the wrong form → `PermissionDenied` (username mismatch)
- As root (`sudo`), the wrong form → `No fingers enrolled` (root has none)

## Module loads now but is rejected after reboot

Secure Boot signature problem. Check:

```sh
sudo dmesg | grep -i "rejected\|lockdown\|signature"
mokutil --sb-state
```

The classic cause: **DKMS signed with the shim key, not your enrolled MOK**.
`/var/lib/shim-signed/mok/MOK.priv` is the shim's key; unless you enrolled
*that* key, the module is rejected. Fix in
`/etc/dkms/framework.conf.d/99-sil6250-signing.conf` (see install guide).

## "No devices available" from fprintd-list

- Is `sil6250` loaded? `lsmod | grep sil6250`
- Does `/dev/sil6250` exist? `ls -la /dev/sil6250`
- Is the daemon running? `systemctl status sil6250d open-fprintd`
- Is the sensor actually fitted? Load `probe_mailbox.ko` and check
  `FPST == 0xAA`.

## Sensor works in Windows but not Linux

Expected — see `docs/hardware.md`. The sensor is not USB/PCIe/SPI; it is an
EC mailbox device. `lsusb` will never show it.
