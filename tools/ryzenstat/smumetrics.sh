#!/bin/bash
# Fetch the PMFW metrics table (TABLE_SMU_METRICS) into a scratch VRAM page and dump it. Run as root.
P=/Users/Shared/gpu/phxctl/phxctl
smu() { $P wreg 0x1629a 0 >/dev/null; $P wreg 0x16292 $2 >/dev/null; $P wreg 0x16282 $1 >/dev/null; for i in 1 2 3 4 5 6 7 8; do [ "$($P regs 0x1629a | awk '{print $2}')" != 0x00000000 ] && break; done; }
smu 0x0d 0x80; smu 0x0e 0x02521000
sleep ${1:-0}
smu 0x0f 7
$P vram 0x2521000 40
