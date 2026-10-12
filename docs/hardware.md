# Hardware identification: the SIL6250 fingerprint sensor

## TL;DR

The sensor is **not** a Goodix GXFP5130. It is a **Silead GSL6150r touch ASIC +
HDSC HC32F460 MCU** module, branded **Petaic**, exposed to the OS as the ACPI
device `SIL6250`.

It is **not** on USB, PCIe, or normal SPI. It lives behind the Embedded
Controller (EC), reached through an **EC-arbitrated shared-memory mailbox**.

## Why Linux sees nothing

On Windows the fingerprint reader works. On Linux:

- `lsusb` shows no fingerprint device (it is not USB)
- `fprintd-list` prints `No devices available`
- no SPI or I2C device matches

That is the classic symptom of this sensor family: the hardware is present and
enumerated in ACPI, but no Linux driver binds it.

## The ACPI evidence (DSDT)

The device lives under the ACPI node `\_SB_.SPBA`. Two sibling sensors share
this node, switched at runtime by an EC field named `HWEP`:

```asl
Device (SPBA)
{
    Name (_HID, "GXFP5130")      // Goodix sibling (fallback)
    Name (_CID, "GXFP5130")
    Method (_INI, 0, NotSerialized)
    {
        If ((HWEP == 0x02))      // EC reports which sensor is fitted
        {
            _HID = "SIL6250"     // the Petaic/Silead part on this unit
            _CID = "SIL6250"
        }
    }
    Method (_STA, 0, NotSerialized)
    {
        If ((HFTE && HWEP)) { Return (0x0F) } Else { Return (Zero) }
    }
    Method (_CRS, 0, Serialized) { /* see below */ }
}
```

On the AMD MateBook D 14 (Ryzen 7 H 255), the live HID is `SIL6250` and
`_STA` returns `0x0F` (present + enabled).

> **Correction from the field:** an earlier community repo labelled SIL6250 as
> "a Goodix GXFP5130 variant". That is wrong. GXFP5130 is the *sibling* sensor on
> the *same* ACPI node; SIL6250 is the Silead/Petaic part. They share the outer
> mailbox transport but use different inner command framing.

## The _CRS resources

`_CRS` hands out exactly four resources, and they are the entire hardware
contract:

```asl
Memory32Fixed (ReadWrite, 0xFEEC3000, 0x00001000)  // 4 KB mailbox window
GpioInt (Level, ActiveHigh, ExclusiveAndWake, ...)  // EC -> host "RX ready"
GpioIo  (Exclusive, ..., IoRestrictionOutputOnly)   // output strobe #1
GpioIo  (Exclusive, ..., IoRestrictionOutputOnly)   // output strobe #2
```

| Resource | Meaning |
|----------|---------|
| `Memory32Fixed` 0xFEEC3000 (4 KB) | the mailbox window (dual-port RAM) |
| `GpioInt` | EC→host interrupt, "response ready" |
| `GpioIo` #1 | `write_done` strobe |
| `GpioIo` #2 | `read_done` strobe |

The two output GPIOs are **handshake strobes**, not power/chip-select. Driving
them does not power anything; the EC owns power.

### AMD vs Intel address

| Platform | Mailbox address |
|----------|-----------------|
| **AMD** MateBook D 14 (Ryzen 7 H 255) | `0xFEEC3000` |
| Intel MateBook X Pro 2024 | `0xFE800000` |

The kernel driver reads the address from ACPI `_CRS` at runtime
(`platform_get_resource`), so **the same driver works on both** — the address
difference does not matter.

## How to confirm on your own machine

1. Disassemble the DSDT (see `kernel-probe/README.md` for the exact commands)
2. `grep -n SIL6250 dsdt.dsl` and read the `_CRS`
3. Load `probe_mailbox.ko` and check `FPST == 0xAA` (sensor physically fitted)

The `FPST` register (offset `0x16` in the EC ERAM region) is the ground
truth: `0xAA` means the fingerprint sensor is fitted and the EC sees it.
