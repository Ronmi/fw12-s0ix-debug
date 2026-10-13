#!/usr/bin/env python3
"""Compute byte offsets of GNVS fields from a decompiled DSDT.

Usage: gnvs_offsets.py DSDT.dsl [NAME ...]
Prints the GNVS base address, then offset/width/physical address of each NAME
(default: the variables used in the s0ix investigation). Fails loudly if the
accumulated field size does not match the OperationRegion size.
"""
import re
import sys

path = sys.argv[1]
want = set(sys.argv[2:]) or {'OSYS', 'STD3', 'SD2P', 'SDP1', 'SD2R', 'SDR1', 'PEP0'}
lines = open(path, encoding='latin1').read().splitlines()

start = next(i for i, l in enumerate(lines) if 'OperationRegion (GNVS' in l)
m = re.search(r'OperationRegion \(GNVS, SystemMemory, (0x[0-9A-Fa-f]+), (0x[0-9A-Fa-f]+)\)', lines[start])
base, size = int(m.group(1), 16), int(m.group(2), 16)
print(f"GNVS base=0x{base:X} size=0x{size:X}")

bit = 0
for l in lines[start + 1:]:
    s = l.split('//')[0].strip()
    if not s or s.startswith('Field (GNVS') or s == '{':
        continue
    if s == '}':
        break
    m = re.match(r'Offset \((0x[0-9A-Fa-f]+|\d+)\)', s)
    if m:
        bit = int(m.group(1), 0) * 8
        continue
    m = re.match(r'(\w*)\s*,\s*(\d+)\s*,?$', s)
    if not m:
        sys.exit(f"unparsed field line: {s}")
    name, width = m.group(1), int(m.group(2))
    if name in want:
        print(f"{name:5} off=0x{bit // 8:X} bit={bit % 8} width={width} phys=0x{base + bit // 8:X}")
    bit += width

if bit // 8 != size:
    sys.exit(f"field layout ends at 0x{bit // 8:X}, expected 0x{size:X}: parser is wrong")
