#!/bin/bash
# Cap 780M GFX clock: nullarc leaves it pinned at 2600 MHz (~25 W extra). SMU msg 0x1B SetSoftMaxGfxClk.
exec >>/var/log/gpuclk.log 2>&1
echo "== $(date "+%F %T") gpuclk"
[ -e /Users/Shared/gpu/phxboot-off ] && { echo "GPU off, skip"; exit 0; }
for i in $(seq 1 300); do ioreg -rc NMXAccel -d0 | grep -q NMXAccel && break; sleep 1; done
ioreg -rc NMXAccel -d0 | grep -q NMXAccel || { echo "no NMXAccel"; exit 0; }
sleep 15
/Users/Shared/gpu/phxctl/phxctl smu 0x1b 800 | tail -1
/Users/Shared/gpu/phxctl/phxctl smu 0x17 0 | tail -1
