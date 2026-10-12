// SPDX-License-Identifier: GPL-2.0
/*
 * probe_mailbox.c — SIL6250 fingerprint sensor diagnostic probe
 *
 * The SIL6250 fingerprint sensor (Silead GSL6150r + HDSC HC32F460, branded
 * "Petaic") is NOT on USB, PCIe, or normal SPI. It is reached through an
 * EC-arbitrated shared-memory mailbox:
 *
 *   - a 4 KB MMIO mailbox window (Memory32Fixed in ACPI _CRS)
 *   - the Embedded Controller's ERAM region, which contains a FPST
 *     (FingerPrint STatus) register that reports whether a fingerprint
 *     sensor is physically fitted.
 *
 * This module exists to answer two diagnostic questions WITHOUT needing the
 * full driver stack:
 *
 *   1. Is the sensor physically present?   (read FPST from EC ERAM)
 *   2. What is the mailbox layout?          (dump the 4 KB window)
 *
 * It is READ-ONLY: it ioremaps two physical ranges and prints their contents
 * to the kernel log. It performs no writes and no GPIO handshakes, so it is
 * safe to load on any machine that has these two ACPI regions.
 *
 * Build:      make
 * Load:       sudo insmod probe_mailbox.ko
 * Read dump:  sudo dmesg | grep gxfp_probe
 * Unload:     sudo rmmod probe_mailbox
 *
 * The default addresses below match the AMD Huawei/WIKO MateBook D 14
 * (Ryzen 7 H 255). On the Intel MateBook X Pro 2024 the mailbox is at
 * 0xFE800000 instead. Override at load time with:
 *
 *     sudo insmod probe_mailbox.ko mbx_phys=0xFE800000
 *
 * You can discover YOUR machine's addresses from the disassembled DSDT:
 * the SIL6250 device's _CRS contains a Memory32Fixed resource (the mailbox)
 * and the EC device (PNP0C09) has an OperationRegion (the ERAM).
 */
#include <linux/module.h>
#include <linux/kernel.h>
#include <linux/init.h>
#include <linux/io.h>
#include <linux/minmax.h>

/* EC ERAM base: the EC's SystemMemory operation region. The FPST register
 * lives at offset 0x16 inside it. */
static unsigned long eram_phys = 0xFEEC2300UL;
module_param(eram_phys, ulong, 0444);
MODULE_PARM_DESC(eram_phys, "EC ERAM physical base address");

/* Mailbox window base + size (from SIL6250 _CRS Memory32Fixed). */
static unsigned long mbx_phys = 0xFEEC3000UL;
module_param(mbx_phys, ulong, 0444);
MODULE_PARM_DESC(mbx_phys, "Fingerprint mailbox physical base address");

#define ERAM_SIZE  0x100   /* EC ERAM operation region size */
#define MBX_SIZE   0x1000  /* mailbox window size (4 KB) */
#define FPST_OFF   0x16    /* offset of the FPST status register in ERAM */

static void __iomem *eram;
static void __iomem *mbx;

/* Print a memory region as 16-byte hex rows. */
static void dump_region(const char *name, void __iomem *v, size_t len)
{
	size_t i;
	pr_info("gxfp_probe: === %s (%zu bytes) ===\n", name, len);
	for (i = 0; i < len; i += 16) {
		u8 buf[16];
		size_t n = min_t(size_t, 16, len - i);
		int j;
		memcpy_fromio(buf, v + i, n);
		pr_info("  %04zx:", i);
		for (j = 0; j < (int)n; j++)
			pr_cont(" %02x", buf[j]);
		pr_cont("\n");
	}
}

static int __init probe_init(void)
{
	u8 fpst;

	pr_info("gxfp_probe: init\n");
	pr_info("gxfp_probe: eram_phys=0x%lx mbx_phys=0x%lx\n",
		eram_phys, mbx_phys);

	eram = ioremap(eram_phys, ERAM_SIZE);
	if (!eram) {
		pr_err("gxfp_probe: ioremap ERAM failed\n");
		return -ENOMEM;
	}

	mbx = ioremap(mbx_phys, MBX_SIZE);
	if (!mbx) {
		pr_err("gxfp_probe: ioremap MBX failed\n");
		iounmap(eram);
		return -ENOMEM;
	}

	fpst = readb(eram + FPST_OFF);
	pr_info("gxfp_probe: FPST register (ERAM+0x%02x) = 0x%02x %s\n",
		FPST_OFF, fpst,
		fpst == 0xAA ? "(==0xAA fingerprint present)"
			      : "(!=0xAA, no fingerprint fitted)");

	dump_region("EC ERAM", eram, ERAM_SIZE);
	dump_region("MAILBOX", mbx, MBX_SIZE);

	return 0;
}

static void __exit probe_exit(void)
{
	pr_info("gxfp_probe: exit\n");
	if (eram)
		iounmap(eram);
	if (mbx)
		iounmap(mbx);
}

module_init(probe_init);
module_exit(probe_exit);

MODULE_LICENSE("GPL");
MODULE_DESCRIPTION("SIL6250 fingerprint mailbox diagnostic probe");
MODULE_AUTHOR("Rouyuan");
