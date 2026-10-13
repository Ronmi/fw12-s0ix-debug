#!/bin/bash
# Usage: snap4.sh pre|post -- suspend test with PCI PM debug and unbound CPU devices on runtime PM auto
OUT=/tmp/claude-1000/-home-ronmi-tmp/99917a6a-df60-4e4b-92f7-9b5c276ff529/scratchpad/snap4-$1.txt
D=/sys/kernel/debug/pmc_core
{
date '+%F %T'
if [ "$1" = pre ]; then
  echo disabled > /sys/bus/pci/devices/0000:00:06.0/power/wakeup
  echo 1 > /sys/power/pm_debug_messages
  echo 1 > /sys/module/intel_pmc_core/parameters/warn_on_s0ix_failures
  echo 'file drivers/pci/pci-driver.c +p' > /sys/kernel/debug/dynamic_debug/control
  echo 'file drivers/pci/pci.c +p' > /sys/kernel/debug/dynamic_debug/control
  for d in 00:08.0 00:0a.0; do echo auto > /sys/bus/pci/devices/0000:$d/power/control; done
  sleep 5
fi
for d in 00:04.0 00:06.0 00:08.0 00:0a.0 01:00.0; do p=/sys/bus/pci/devices/0000:$d; echo "$d control=$(cat $p/power/control) status=$(cat $p/power/runtime_status) state=$(cat $p/power_state) wakeup=$(cat $p/power/wakeup)"; done
echo "charge_now=$(cat /sys/class/power_supply/BAT1/charge_now) ac=$(cat /sys/class/power_supply/ACAD/online)"
echo "slp_s0=$(cat $D/slp_s0_residency_usec) total_hw_sleep=$(cat /sys/power/suspend_stats/total_hw_sleep)"
cat $D/substate_residencies
cat $D/package_cstate_show
if [ "$1" = post ]; then
  echo "=== PCI PM during last suspend"
  dmesg | awk '/PM: suspend entry/{buf=""} {buf=buf"\n"$0} END{print buf}' | grep -E 'PCI PM: (Suspend power state|Skipped)|PM: suspend entry|did not enter|wakeup from'
fi
} > $OUT 2>&1
chown 1000:1000 $OUT
echo "saved $OUT"
