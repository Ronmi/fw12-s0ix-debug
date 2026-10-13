#!/bin/bash
# Usage: snap3.sh pre|post -- suspend test with NVMe root port (00:06.0) wakeup disabled
OUT=/tmp/claude-1000/-home-ronmi-tmp/99917a6a-df60-4e4b-92f7-9b5c276ff529/scratchpad/snap3-$1.txt
D=/sys/kernel/debug/pmc_core
P=/sys/bus/pci/devices/0000:00:06.0
{
date '+%F %T'
if [ "$1" = pre ]; then
  echo disabled > $P/power/wakeup
  echo 1 > /sys/power/pm_debug_messages
  echo 1 > /sys/module/intel_pmc_core/parameters/warn_on_s0ix_failures
fi
echo "00:06.0 wakeup=$(cat $P/power/wakeup)"
echo "charge_now=$(cat /sys/class/power_supply/BAT1/charge_now) ac=$(cat /sys/class/power_supply/ACAD/online)"
echo "slp_s0=$(cat $D/slp_s0_residency_usec) total_hw_sleep=$(cat /sys/power/suspend_stats/total_hw_sleep) last_hw_sleep=$(cat /sys/power/suspend_stats/last_hw_sleep)"
cat $D/substate_residencies
cat $D/package_cstate_show
if [ "$1" = post ]; then
  echo "=== kernel log"
  journalctl -k --since "-1h" --no-pager | grep -iE 'PM: suspend (entry|exit)|0000:00:06\.0|nvme|wakeup from|did not enter|Package C|SLP_S0|failed|error' | grep -v 'PCI PM: Suspend power state: D3hot' | tail -60
  journalctl -k --since "-1h" --no-pager | grep -E 'nvme 0000:01:00.0: PCI PM|pcieport 0000:00:06.0: PCI PM' | tail -4
fi
} > $OUT 2>&1
chown 1000:1000 $OUT
echo "saved $OUT"
