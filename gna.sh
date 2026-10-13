#!/bin/bash
# Show PM capability of GNA/crashlog; if GNA has PM cap, measure idle package C-states before/after putting it in D3hot
D=/sys/kernel/debug/pmc_core
for d in 00:08.0 00:0a.0; do echo "=== $d"; lspci -vv -s $d | grep -E 'Capabilities|Flags|Status: D'; done
measure() { a=$(cat $D/package_cstate_show); sleep 15; b=$(cat $D/package_cstate_show); paste <(echo "$a") <(echo "$b") | awk -F'[:\t]' '{printf "%-12s delta=%d\n",$1,$4-$2}'; }
if lspci -vv -s 00:08.0 | grep -q 'Power Management'; then
  echo "=== idle 15s, GNA D0"; measure
  setpci -s 00:08.0 CAP_PM+4.w=0003:0003; sleep 1
  echo "GNA power_state=$(cat /sys/bus/pci/devices/0000:00:08.0/power_state)"
  echo "=== idle 15s, GNA D3hot"; measure
fi
