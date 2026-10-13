# Framework Laptop 12 (13th Gen Intel): s2idle never reaches S0ix on Linux because BIOS sets STD3=1, keeping the NVMe root port (PEG0) in D0

This report and debug process are AI-aided. I have no deep understanding of ACPI/BIOS/firmware/Linux kernel. Related code and debug helpers, including the workaround kernel module, are on GitHub at https://github.com/Ronmi/fw12-s0ix-debug (written in Traditional Chinese). The module is a proof of concept for this report, not a recommended fix; use it at your own risk.

## Summary

On the Framework Laptop 12 (13th Gen Intel Core), s2idle on Linux **never reaches S0ix**: the CPU package never goes deeper than PC3, and the battery drains about 3–5 %/hour while suspended (about 30 % overnight).

The cause is in the firmware's ACPI tables. The GNVS variable **`STD3` is 1** (Storage D3 enabled, but not RTD3). `\_SB.PC00.PEG0._INI` copies it into `PEG0.RD3C`, and with `RD3C != 2`:

- `PEG0._S0W` returns **0 (D0)**, so the OS must keep the CPU PCIe root port of the NVMe SSD (00:06.0) in D0 during s2idle, and
- `PEG0.GPRS` returns 0, so the `PXP` power resource `_OFF`/`_ON` are no-ops.

When `RD3C` is forced to 2 at runtime, everything else stays the same and the firmware's own RTD3 path works perfectly. The root port and the SSD go to D3cold, the package reaches PC10, the system spends **99.8 % of suspend time in S0i3.0**, and drain drops to about **1 %/hour**. Resume is reliable.

## System

| Item | Value |
|---|---|
| Model | Framework Laptop 12 (13th Gen Intel Core), board FRAPMACP05 rev A5 |
| CPU | Intel Core i5-1334U (Raptor Lake-U) |
| BIOS | **03.07** (02/10/2026), **03.08** (08/20/2026) and **03.09** — all affected |
| SSD | Kingston NV3 2230 (SNV3SM31T0, SM2268XT2, DRAM-less, HMB), firmware SDX01100 |
| OS | Debian 13, Linux 7.1.13 (backports) and 7.2.6 |
| Sleep mode | `s2idle` (default; `deep` is also offered) |

## Symptoms

- `/sys/kernel/debug/pmc_core/slp_s0_residency_usec` and the S0i2.0/S0i3.0 substate residencies stay at **0** after every suspend.
- With `intel_pmc_core.warn_on_s0ix_failures=1`, the kernel reports `CPU did not enter Package C10!!!` on every resume. Package C6–C10 counters stay at 0, and only PC2/PC3 increase.
- There are no spurious wakeups; the only wake event is the lid (EC GPE, IRQ 9).
- Intel's S0ixSelftestTool reports: *"Your system achieved PC3 residency, but no PC8 residency during S2idle"*. It also reports that `pcieport 0000:00:06.0` stays in **D0** (`PCI PM: Skipped`) and that its link is only in L1, not L1.1/L1.2.

## Analysis

### Firmware logic (from SSDT "SaSsdt" and SSDT "ADL-P-M", BIOS 03.08)

`SSDT SaSsdt` (rev 0x3000), `\_SB.PC00.PEG0._INI`:

```asl
If ((\_SB.PC00.PEG0.PEGP.PNVM () || \_SB.PC00.PEG0.PEGP.PAHC ()))
{
    \_SB.PC00.PEG0.RD3C = \STD3
}
```

`SSDT ADL-P-M`, `\_SB.PC00.PEG0`:

```asl
Method (_S0W, 0, NotSerialized)
{
    If (CondRefOf (RD3C)) { If ((RD3C == 0x02)) { Return (0x04) } }
    Return (Zero)                                   // D0
}

Method (GPRS, 0, NotSerialized)                     // gate used by PXP._ON/_OFF
{
    ...
    If (CondRefOf (RD3C)) { If ((RD3C != 0x02)) { Return (Zero) } }
    ...
    Return (One)
}
```

`\_SB.PC00.PEG0.PEGP._S0W` similarly returns 3 (D3hot) instead of 4 when `RD3C != 2`.

Since `STD3 != 0`, `PEGP._DSD` still exposes `StorageD3Enable = 1`, so Linux puts the SSD into D3hot ("simple suspend"). However, the root port is not allowed below D0. On Linux, for S0 the `_S0W` limit is applied whenever the device has `_PRW`, regardless of the user's wakeup setting.

### Runtime values (read from GNVS at 0x448F9018 on BIOS 03.08)

| Variable | Value | Meaning |
|---|---|---|
| `OSYS` | 0x07DF | sanity check (Windows 2015 `_OSI`) |
| `STD3` | **1** | Storage D3 only, not RTD3 |
| `SD2P` / `SDP1` | 0x0908000E / 1 | SSD power-enable GPIO pad, active high |
| `SD2R` / `SDR1` | 0x090C0014 / 0 | SSD reset (PERST#) GPIO pad, active low |
| `PEP0` | 100 | power-on delay (ms) |

The RTD3 GPIOs **are configured**, so the hardware path is clearly wired. Only the `STD3` value keeps it disabled.

### Kernel trace confirming the D-state decision

A kprobe on `acpi_pm_device_sleep_state()` during suspend (stock BIOS tables):

```
dev="0000:00:06.0"  ret=0     # root port: firmware allows D0 only
dev="0000:01:00.0"  ret=3     # NVMe: D3hot only
```

With `RD3C = 2`:

```
dev="0000:00:06.0"  ret=4     # D3cold
dev="0000:01:00.0"  ret=4     # D3cold
pcieport 0000:00:06.0: PCI PM: Suspend power state: D3cold
nvme 0000:01:00.0: PCI PM: Suspend power state: D3cold
```

## Measurements

All runs are on battery with the dock unplugged and the lid closed. The drain figures include the few minutes the system was awake around each suspend.

| Configuration | Suspend time | S0i3.0 residency | Package C10 | Drain |
|---|---|---|---|---|
| Stock BIOS 03.07 | ~15 min | 0 | 0 | 72 mAh in 18 min (≈ 5 %/h) |
| Stock BIOS 03.08 | ~39 min | 0 | 0 | 87 mAh in 40 min (≈ 3 %/h) |
| Stock + `nvme.noacpi=1` (SSD kept in D0/APST) | ~64 min | 0 | 0 (PC2 only) | 288 mAh in 66 min (≈ 6 %/h) |
| **`RD3C = 2`** via SSDT override (initrd) | ~51 min | **3021 s (99.8 %)** | 3024 s | 33 mAh in 51 min (≈ 0.9 %/h) |
| **`RD3C = 2`** via runtime method (no table replaced) | ~37 min | **2243 s (99.8 %)** | 2245 s | 32 mAh in 38 min (≈ 1.2 %/h, microSD card inserted) |

Battery: 4303 mAh full charge.

Things that were ruled out along the way, with no change in package C-state:

- External display or dock
- microSD expansion card (USB on the TCSS xHCI)
- GNA (00:08.0) left in D0
- Disabling wakeup on the root port
- Package C-state limit (MSR 0xE2 allows PC10)
- GPU RC6 (OK)
- `ltr_ignore_all_suspend` (already on)

## Workaround currently in use

A small out-of-tree kernel module loads a tiny SSDT (via `acpi_load_table()`) that adds `\_SB.PC00.PEG0.FXRD`, a method that sets `RD3C`, and calls it with `2` at boot. It only acts on a Framework Laptop 12 (13th Gen) (DMI check), when `PEGP.PNVM()` is true, and when `SD2P`/`SD2R` are non-zero. No firmware tables are replaced. (v1.0 used `acpi_install_method()`, which fails with `AE_BAD_PARAMETER` on Linux 7.2 due to an ACPICA regression fixed upstream in ACPICA 19429ef91.)

This works, but it is clearly something the BIOS should handle.

Although this looks like a firmware bug, `STD3=1` may be intentional (e.g. to avoid resume issues with certain SSDs). If so, a BIOS option to enable Storage RTD3 (`STD3=2`) would be appreciated.
