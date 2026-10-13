#!/bin/bash
# Usage: snap7.sh pre|post -- suspend test with nvme.noacpi=1 (host-managed NVMe suspend)
OUT=/tmp/claude-1000/-home-ronmi-tmp/99917a6a-df60-4e4b-92f7-9b5c276ff529/scratchpad/snap7-$1.txt
D=/sys/kernel/debug/pmc_core
{
date '+%F %T'
if [ "$1" = pre ]; then
  echo 1 > /sys/power/pm_debug_messages
  echo 1 > /sys/module/intel_pmc_core/parameters/warn_on_s0ix_failures
  echo 'file drivers/pci/pci-driver.c +p' > /sys/kernel/debug/dynamic_debug/control
  echo "nvme.noacpi=$(cat /sys/module/nvme/parameters/noacpi)"
  echo "simple suspend msgs: $(dmesg | grep -c 'simple suspend')"
  echo "usb mass storage: $(lsusb -t | grep -c Mass)"
fi
echo "charge_now=$(cat /sys/class/power_supply/BAT1/charge_now) ac=$(cat /sys/class/power_supply/ACAD/online)"
echo "slp_s0=$(cat $D/slp_s0_residency_usec) total_hw_sleep=$(cat /sys/power/suspend_stats/total_hw_sleep)"
cat $D/substate_residencies
cat $D/package_cstate_show
if [ "$1" = post ]; then
  echo "=== last suspend"
  dmesg | awk '/PM: suspend entry/{buf=""} {buf=buf"\n"$0} END{print buf}' | grep -E 'PCI PM: (Suspend power state|Skipped)|nvme|did not enter|wakeup from|Package C|SLP_S0|PM: suspend' | grep -v 'save config\|restore config'
fi
} > $OUT 2>&1
chown 1000:1000 $OUT
echo "saved $OUT"
