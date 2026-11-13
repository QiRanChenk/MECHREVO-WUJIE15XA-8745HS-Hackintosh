#!/bin/bash
P=/Users/Shared/gpu/phxctl/phxctl
smu() { $P wreg 0x1629a 0 >/dev/null; $P wreg 0x16292 $2 >/dev/null; $P wreg 0x16282 $1 >/dev/null; for i in 1 2 3 4 5 6 7 8; do [ "$($P regs 0x1629a | awk '{print $2}')" != 0x00000000 ] && break; done; }
smu 0x0d 0x80; smu 0x0e 0x02521000
for k in $(seq 1 ${1:-5}); do sleep 4; smu 0x0f 7; $P vram 0x2521000 40; done
