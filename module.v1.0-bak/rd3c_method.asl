/*
 * Helper control method installed at runtime by fw12_rtd3_fix.ko via
 * acpi_install_method(). Sets \_SB.PC00.PEG0.RD3C to Arg0 and returns the
 * resulting value. RD3C == 2 enables the BIOS's own RTD3 (D3cold) path for
 * the NVMe root port (PEG0._S0W, PEG0.GPRS, power resource PXP _ON/_OFF).
 *
 * acpi_install_method() requires the first AML opcode after the table
 * header to be a Method, so no External() is declared here.
 */
DefinitionBlock ("", "SSDT", 2, "FW12FX", "RD3CFIX", 0x00000001)
{
    Method (\_SB.PC00.PEG0.FXRD, 1, Serialized)
    {
        \_SB.PC00.PEG0.RD3C = Arg0
        Return (\_SB.PC00.PEG0.RD3C)
    }
}
