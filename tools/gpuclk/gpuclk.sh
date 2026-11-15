#!/bin/bash
# Cap 780M GFX clock: nullarc leaves it pinned at 2600 MHz (~25 W extra). SMU msg 0x1B SetSoftMaxGfxClk.
exec >>/var/log/gpuclk.log 2>&1
echo "== $(date "+%F %T") gpuclk"
[ -e /Users/Shared/gpu/phxboot-off ] && { echo "GPU off, skip"; exit 0; }
for i in $(seq 1 300); do ioreg -rc NMXAccel -d0 | grep -q NMXAccel && break; sleep 1; done
ioreg -rc NMXAccel -d0 | grep -q NMXAccel || { echo "no NMXAccel"; exit 0; }
sleep 15
# 800 MHz on the panel alone; with a monitor lit on the HDMI port (hdmid) two displays need more
CAP=800; [ $(( $(sysctl -n debug.phxfb1_hw 2>/dev/null || echo 0) & 2 )) = 2 ] && CAP=$(cat /Users/Shared/gpu/hdmi/gfxclk 2>/dev/null || echo 1600)
/Users/Shared/gpu/phxctl/phxctl smu 0x1b $CAP | tail -1
/Users/Shared/gpu/phxctl/phxctl smu 0x17 0 | tail -1
# Enable GFX clock gating (nullarc leaves every override set; ~2 W idle). Skip with /Users/Shared/gpu/gpucg-off.
if [ -x /usr/local/libexec/gpucg.sh ] && [ ! -e /Users/Shared/gpu/gpucg-off ]; then
  /usr/local/libexec/gpucg.sh all
fi
