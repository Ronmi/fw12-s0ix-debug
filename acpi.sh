#!/bin/bash
# Copy ACPI tables for offline decompilation
D=/tmp/claude-1000/-home-ronmi-tmp/99917a6a-df60-4e4b-92f7-9b5c276ff529/scratchpad/acpi
mkdir -p $D; for t in /sys/firmware/acpi/tables/DSDT /sys/firmware/acpi/tables/SSDT*; do cp $t $D/$(basename $t).dat; done; chown -R 1000:1000 $D
