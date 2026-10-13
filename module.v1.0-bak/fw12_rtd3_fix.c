// SPDX-License-Identifier: GPL-2.0
/*
 * fw12_rtd3_fix - enable RTD3 (D3cold) on the NVMe root port of the
 * Framework Laptop 12 (13th Gen Intel Core) so that s2idle can reach S0ix.
 *
 * BIOS 03.07 sets the GNVS variable STD3 to 1, and PEG0._INI copies it into
 * \_SB.PC00.PEG0.RD3C. With RD3C != 2 the firmware:
 *   - returns D0 from PEG0._S0W, so Linux keeps the root port in D0 during
 *     s2idle, and
 *   - makes PEG0.GPRS return 0, so the PXP power resource _OFF/_ON are no-ops.
 * The CPU package then never goes below PC3 and S0ix is never entered.
 *
 * This module installs a tiny helper method (\_SB.PC00.PEG0.FXRD, see
 * rd3c_method.asl) and calls it to set RD3C to 2, which enables the
 * firmware's own RTD3 path. The original value is restored on unload.
 */

#define pr_fmt(fmt) KBUILD_MODNAME ": " fmt

#include <linux/acpi.h>
#include <linux/dmi.h>
#include <linux/module.h>

#include "rd3c_method.h"

#define PEG0_PATH	"\\_SB.PC00.PEG0"
#define RD3C_PATH	PEG0_PATH ".RD3C"
#define PNVM_PATH	PEG0_PATH ".PEGP.PNVM"
#define FXRD_PATH	PEG0_PATH ".FXRD"
#define SD2P_PATH	"\\SD2P"	/* SSD power enable GPIO pad */
#define SD2R_PATH	"\\SD2R"	/* SSD reset (PERST#) GPIO pad */

#define RD3C_RTD3	2

static bool force;
module_param(force, bool, 0444);
MODULE_PARM_DESC(force, "Apply even if the DMI vendor/product does not match");

static const struct dmi_system_id fw12_dmi_table[] = {
	{
		.matches = {
			DMI_MATCH(DMI_SYS_VENDOR, "Framework"),
			DMI_MATCH(DMI_PRODUCT_NAME, "Laptop 12 (13th Gen Intel Core)"),
		},
	},
	{ }
};
MODULE_DEVICE_TABLE(dmi, fw12_dmi_table);

static u64 orig_rd3c;
static bool rd3c_changed;

static int read_int(const char *path, u64 *val)
{
	acpi_status status;

	status = acpi_evaluate_integer(NULL, (acpi_string)path, NULL, val);
	if (ACPI_FAILURE(status)) {
		pr_info("cannot evaluate %s: %s\n", path,
			acpi_format_exception(status));
		return -ENODEV;
	}
	return 0;
}

static int set_rd3c(u64 value)
{
	union acpi_object arg = {
		.integer = { .type = ACPI_TYPE_INTEGER, .value = value },
	};
	struct acpi_object_list args = { .count = 1, .pointer = &arg };
	acpi_status status;
	u64 result;

	status = acpi_evaluate_integer(NULL, FXRD_PATH, &args, &result);
	if (ACPI_FAILURE(status)) {
		pr_err("cannot evaluate %s: %s\n", FXRD_PATH,
		       acpi_format_exception(status));
		return -EIO;
	}
	if (result != value) {
		pr_err("RD3C is %llu after setting it to %llu\n", result, value);
		return -EIO;
	}
	return 0;
}

static int __init fw12_rtd3_fix_init(void)
{
	u64 pnvm, sd2p, sd2r;
	acpi_status status;
	int ret;

	if (!dmi_check_system(fw12_dmi_table) && !force) {
		pr_info("not a Framework Laptop 12 (13th Gen), use force=1 to override\n");
		return -ENODEV;
	}

	ret = read_int(RD3C_PATH, &orig_rd3c);
	if (ret)
		return ret;
	if (orig_rd3c == RD3C_RTD3) {
		pr_info("RD3C is already %d, nothing to do\n", RD3C_RTD3);
		return 0;
	}

	/* Only NVMe: the firmware applies STD3 to RD3C only for NVMe/AHCI. */
	ret = read_int(PNVM_PATH, &pnvm);
	if (ret)
		return ret;
	if (!pnvm) {
		pr_info("device below PEG0 is not NVMe, leaving RD3C untouched\n");
		return -ENODEV;
	}

	/*
	 * The PXP power resource toggles these GPIO pads without any sanity
	 * check, so refuse to enable RTD3 if the BIOS did not configure them.
	 */
	ret = read_int(SD2P_PATH, &sd2p);
	if (!ret)
		ret = read_int(SD2R_PATH, &sd2r);
	if (ret)
		return ret;
	if (!sd2p || !sd2r) {
		pr_info("SSD power/reset GPIOs not configured (SD2P=0x%llx SD2R=0x%llx), leaving RD3C untouched\n",
			sd2p, sd2r);
		return -ENODEV;
	}

	status = acpi_install_method(rd3c_method_aml);
	if (ACPI_FAILURE(status)) {
		pr_err("cannot install %s: %s\n", FXRD_PATH,
		       acpi_format_exception(status));
		return -EIO;
	}

	ret = set_rd3c(RD3C_RTD3);
	if (ret)
		return ret;

	rd3c_changed = true;
	pr_info("RD3C %llu -> %d, NVMe root port RTD3 enabled (SD2P=0x%llx SD2R=0x%llx)\n",
		orig_rd3c, RD3C_RTD3, sd2p, sd2r);
	return 0;
}

static void __exit fw12_rtd3_fix_exit(void)
{
	if (!rd3c_changed)
		return;

	if (!set_rd3c(orig_rd3c))
		pr_info("RD3C restored to %llu\n", orig_rd3c);
}

module_init(fw12_rtd3_fix_init);
module_exit(fw12_rtd3_fix_exit);

MODULE_DESCRIPTION("Enable NVMe root port RTD3 on Framework Laptop 12 (13th Gen Intel) for S0ix");
MODULE_LICENSE("GPL");
