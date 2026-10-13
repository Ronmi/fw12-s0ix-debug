#!/bin/bash
# Usage: snap6.sh pre|post -- trace ACPI D-state decisions during suspend via kprobes
OUT=/tmp/claude-1000/-home-ronmi-tmp/99917a6a-df60-4e4b-92f7-9b5c276ff529/scratchpad/snap6-$1.txt
D=/sys/kernel/debug/pmc_core
T=/sys/kernel/tracing
{
date '+%F %T'
if [ "$1" = pre ]; then
  echo 1 > /sys/power/pm_debug_messages
  echo 1 > /sys/module/intel_pmc_core/parameters/warn_on_s0ix_failures
  echo 'file drivers/pci/pci-driver.c +p' > /sys/kernel/debug/dynamic_debug/control
  echo 0 > $T/tracing_on
  echo > $T/trace
  echo 'p:s0w/sleepst acpi_pm_device_sleep_state dev=+0(+0(%di)):string dmax=%dx:s32' >> $T/kprobe_events || echo "probe entry FAILED"
  echo 'r:s0w/sleepst_ret acpi_pm_device_sleep_state ret=$retval:s32' >> $T/kprobe_events || echo "probe return FAILED"
  echo 1 > $T/events/s0w/enable
  echo 1 > $T/tracing_on
  echo "kprobe_events:"; cat $T/kprobe_events
fi
echo "charge_now=$(cat /sys/class/power_supply/BAT1/charge_now) ac=$(cat /sys/class/power_supply/ACAD/online)"
echo "slp_s0=$(cat $D/slp_s0_residency_usec)"
grep -E 'C6|C10' $D/package_cstate_show
if [ "$1" = post ]; then
  echo "=== trace"
  grep -v '^#' $T/trace | sed -E 's/^ +//' | awk '{$1="";$2="";$3="";print}' | head -80
  echo 0 > $T/events/s0w/enable
  echo '-:s0w/sleepst' >> $T/kprobe_events; echo '-:s0w/sleepst_ret' >> $T/kprobe_events
  echo "=== PCI PM during last suspend"
  dmesg | awk '/PM: suspend entry/{buf=""} {buf=buf"\n"$0} END{print buf}' | grep -E 'pcieport|nvme 0000|did not enter'
fi
} > $OUT 2>&1
chown 1000:1000 $OUT
echo "saved $OUT"
