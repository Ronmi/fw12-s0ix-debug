#!/bin/bash
# Usage: snap9.sh pre|post -- suspend test with fw12_rtd3_fix module (no ACPI table override)
OUT=/tmp/claude-1000/-home-ronmi-tmp/99917a6a-df60-4e4b-92f7-9b5c276ff529/scratchpad/snap9-$1.txt
D=/sys/kernel/debug/pmc_core
T=/sys/kernel/tracing
{
date '+%F %T'
if [ "$1" = pre ]; then
  echo "cmdline: $(cat /proc/cmdline)"
  echo "=== ACPI override (should be none)"; dmesg | grep -iE "table upgrade" | head -3
  echo "=== module"; lsmod | grep fw12; dmesg | grep fw12_rtd3_fix
  echo "SSDT4 OEM rev: 0x$(dd if=/sys/firmware/acpi/tables/SSDT4 bs=1 skip=24 count=4 2>/dev/null | od -An -tx4 | tr -d ' ')"
  echo "nvme simple suspend: $(dmesg | grep -c 'simple suspend')"
  echo "usb mass storage: $(lsusb -t | grep -c Mass)"
  echo 1 > /sys/power/pm_debug_messages
  echo 1 > /sys/module/intel_pmc_core/parameters/warn_on_s0ix_failures
  echo 'file drivers/pci/pci-driver.c +p' > /sys/kernel/debug/dynamic_debug/control
  echo 0 > $T/tracing_on; echo > $T/trace
  echo 'p:s0w/sleepst acpi_pm_device_sleep_state dev=+0(+0(%di)):string dmax=%dx:s32' >> $T/kprobe_events || echo "probe entry FAILED"
  echo 'r:s0w/sleepst_ret acpi_pm_device_sleep_state ret=$retval:s32' >> $T/kprobe_events || echo "probe return FAILED"
  echo 1 > $T/events/s0w/enable; echo 1 > $T/tracing_on
fi
echo "charge_now=$(cat /sys/class/power_supply/BAT1/charge_now) ac=$(cat /sys/class/power_supply/ACAD/online)"
echo "slp_s0=$(cat $D/slp_s0_residency_usec) total_hw_sleep=$(cat /sys/power/suspend_stats/total_hw_sleep) last_hw_sleep=$(cat /sys/power/suspend_stats/last_hw_sleep)"
cat $D/substate_residencies
cat $D/package_cstate_show
if [ "$1" = post ]; then
  echo "=== ACPI D-state decisions (00:06.0 / 01:00.0)"
  grep -A1 -E 'dev="0000:0(0:06|1:00)\.0"' $T/trace | grep -v '^--' | sed -E 's/^ +//' | awk '{$1="";$2="";$3="";print}' | head -12
  echo 0 > $T/events/s0w/enable
  echo '-:s0w/sleepst' >> $T/kprobe_events; echo '-:s0w/sleepst_ret' >> $T/kprobe_events
  echo "=== last suspend"
  dmesg | awk '/PM: suspend entry/{buf=""} {buf=buf"\n"$0} END{print buf}' | grep -E 'PCI PM: (Suspend power state|Skipped)|nvme|did not enter|wakeup from|Package C|PM: suspend|error|fail' | grep -v 'save config\|restore config'
fi
} > $OUT 2>&1
chown 1000:1000 $OUT
echo "saved $OUT"
