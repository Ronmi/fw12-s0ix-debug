/*
 * Helper control method loaded at runtime by fw12_rtd3_fix.ko via
 * acpi_load_table(). Sets \_SB.PC00.PEG0.RD3C to Arg0 and returns the
 * resulting value. RD3C == 2 enables the BIOS's own RTD3 (D3cold) path for
 * the NVMe root port (PEG0._S0W, PEG0.GPRS, power resource PXP _ON/_OFF).
 *
 * acpi_install_method() is not used because Linux 7.2 leaves
 * parser_state.aml_end uninitialized there and it fails with
 * AE_BAD_PARAMETER (fixed upstream in ACPICA 19429ef91, release 20260930).
 */
DefinitionBlock ("", "SSDT", 2, "FW12FX", "RD3CFIX", 0x00000002)
{
    External (\_SB.PC00.PEG0, DeviceObj)
    External (\_SB.PC00.PEG0.RD3C, IntObj)

    Scope (\_SB.PC00.PEG0)
    {
        Method (FXRD, 1, Serialized)
        {
            RD3C = Arg0
            Return (RD3C)
        }
    }
}
