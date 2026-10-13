#!/bin/bash
# Read STD3 (GNVS byte at 0x448F9BA8) and surrounding bytes
dd if=/dev/mem bs=1 skip=$((0x448F9BA0)) count=16 2>&1 | od -An -tx1
