# kernel-probe — SIL6250 diagnostic tool

`probe_mailbox.ko` is a **read-only** kernel module that answers two questions
without needing the full driver stack:

1. **Is a fingerprint sensor physically fitted?**
   Reads the EC's `FPST` register (offset `0x16` in the EC ERAM region).
   `0xAA` = sensor present, anything else = no sensor.

2. **What does the mailbox window look like?**
   Dumps the 4 KB mailbox (`Memory32Fixed` from the SIL6250 ACPI `_CRS`).

## Build & run

```sh
make
sudo insmod probe_mailbox.ko
sudo dmesg | grep gxfp_probe
sudo rmmod probe_mailbox
```

## Overriding addresses

Defaults target the **AMD** MateBook D 14 (`0xFEEC3000` mailbox). The Intel
MateBook X Pro 2024 uses `0xFE800000`:

```sh
sudo insmod probe_mailbox.ko mbx_phys=0xFE800000
```

Find your own addresses from the disassembled DSDT (see `../docs/hardware.md`):
the SIL6250 device `_CRS` → `Memory32Fixed` = mailbox; the EC (`PNP0C09`)
device's `OperationRegion` = ERAM.

## How to disassemble your DSDT

```sh
sudo apt install acpica-tools
sudo acpidump -o acpi.bin
acpixtract -a acpi.bin
iasl -d dsdt.dat
grep -n SIL6250 dsdt.dsl
```
