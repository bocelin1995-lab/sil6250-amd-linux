# Architecture: how the whole stack works

```
  GNOME/KDE Settings, PAM (sudo/login)
            |  D-Bus
        open-fprintd          <- fprintd drop-in replacement (this repo vendors it)
            |  io.github.uunicorn.Fprint.Device
        sil6250d              <- Rust daemon (upstream sil6250-linux)
            | uses
      sil6250 (Rust library)  <- mailbox framing + TLS-PSK + capture + matcher
            | /dev/sil6250 (mmap + ioctl)
        sil6250.ko            <- C kernel resource broker (upstream sil6250-linux)
            | ACPI platform device "SIL6250"
      hardware: EC mailbox window + GPIO strobes + IRQ
```

## Layer by layer

### 1. Hardware + EC mailbox

The CPU cannot talk to the sensor chip directly. Every command goes through the
Embedded Controller over a doorbell protocol:

```
lock (host-side critical section)
  write request packet -> window +0x000
  pulse write_done strobe
  wait for GpioInt                 (EC -> host: response ready)
  read response packet(s) <- window +0x200
  pulse read_done strobe
  verify checksum
unlock
```

The window is split: **TX at offset 0x000**, **RX at offset 0x200**, MMIO
accesses are 8-byte (qword) aligned.

> Reading the window outside an EC-granted transaction returns garbage; writes
> do not stick. This is why "just mmap and poke" does not work.

### 2. sil6250.ko (kernel resource broker)

A minimal C ACPI platform driver with **no protocol knowledge**. It only:

- binds `SIL6250` (and `GXFP5130`)
- ioremaps the mailbox window from `_CRS`
- resolves the two `GpioIo` strobes + one `GpioInt`
- exposes `/dev/sil6250` with `mmap` (window) + 2 ioctls (strobes, IRQ wait)

### 3. sil6250 (Rust library)

All the real work: mailbox framing, the TLS-PSK secure channel, the
`0x11 -> 0x37 -> 0x38` capture loop, and the host-side matcher.

### 4. sil6250d (Rust daemon)

Implements the `io.github.uunicorn.Fprint.Device` D-Bus interface and
registers with open-fprintd. Enroll/verify/identify run as async D-Bus calls.

### 5. open-fprintd (drop-in fprintd replacement)

Standard `pam_fprintd.so` talks to fprintd over the D-Bus name
`net.reactivated.Fprint`. open-fprintd owns that name and forwards to
out-of-tree backends over `io.github.uunicorn.Fprint`. This lets a standalone
driver work **without patching libfprint**.

## The sensor is Match-on-Host

The sensor streams **raw 64×80 images** and does **no matching itself**. The
host must do everything, including the matcher. The patch is 3.2×4 mm — too
small for classical minutiae, so the matcher is a local-feature keypoint +
descriptor + geometric-verification algorithm (SIFT-class), clean-room
reimplemented.

Single-frame matching on this sensor is intrinsically marginal (~30% FRR is the
ceiling, and the original Windows matcher hits it too). The stack reaches usable
accuracy with a quality gate, multi-frame verify, and an enroll-diversity gate
(15 distinct frames).
