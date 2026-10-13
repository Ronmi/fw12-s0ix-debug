#!/bin/bash
# Read GNVS variables through ACPICA's ioremap mapping using a kprobe @ADDR fetch
T=/sys/kernel/tracing
GNVS=0x448F9018
old_kr=$(cat /proc/sys/kernel/kptr_restrict); echo 1 > /proc/sys/kernel/kptr_restrict
trap "echo $old_kr > /proc/sys/kernel/kptr_restrict" EXIT
line=$(awk -v g=$((GNVS)) '/phys=/{split($1,r,"-"); sz=$2; match($0,/phys=0x[0-9a-f]+/); p=strtonum(substr($0,RSTART+5,RLENGTH-5)); if (p<=g && g+0xD1E<=p+sz-4096) {print; exit}}' /proc/vmallocinfo)
echo "all ACPI maps near GNVS:"; grep -E "phys=0x0000000044[89]" /proc/vmallocinfo
echo "mapping: $line"
[ -z "$line" ] && { echo "GNVS mapping not found"; exit 1; }
vstart=$(echo "$line" | cut -d- -f1)
pstart=$(echo "$line" | grep -o 'phys=0x[0-9a-f]*' | cut -d= -f2)
va() { printf '0x%x' $(( vstart + $1 - pstart )); }
probe="p:gnvs/rd vfs_read osys=@$(va 0x448F9018):x16 std3=@$(va 0x448F9BA8):u8 sd2p=@$(va 0x448F9A00):x32 sdp1=@$(va 0x448F9A04):u8 sd2r=@$(va 0x448F9A05):x32 sdr1=@$(va 0x448F9A09):u8 pep0=@$(va 0x448F9088):u8"
echo "$probe"
echo > $T/trace
echo "$probe" >> $T/kprobe_events || { echo "probe FAILED"; exit 1; }
echo 1 > $T/events/gnvs/enable; echo 1 > $T/tracing_on
cat /etc/hostname >/dev/null; sleep 0.2
echo 0 > $T/events/gnvs/enable
grep -m2 'gnvs\|rd:' $T/trace
echo '-:gnvs/rd' >> $T/kprobe_events
