#!/bin/bash
# dp-off.sh: switch the USB-C DisplayPort output off (video stream, link, transmitter, OTG1). dp-on.sh lights it again.
# PIPE=2: the output on display pipe 2 (phxfb3), which also gives back pipe 2's DPP clock DTO bit.
cd "$(dirname "$0")"; P=/Users/Shared/gpu/phxctl/phxctl
T=plan_dp; [ "${PIPE:-1}" = 2 ] && T=plan_dp2
./dmubboot run ${T}_off1.txt >/dev/null 2>&1
./dmubboot dpoff >/dev/null 2>&1          # sink to D3 when it is still there, transmitter DISABLE
./dmubboot run ${T}_off2.txt >/dev/null 2>&1
[ "${PIPE:-1}" = 2 ] && $P wreg 0x176 $(printf 0x%x $(( $($P regs 0x176 | awk '/^0x/{print $2}') & ~0x100 ))) >/dev/null
./streams.sh                              # GPINT: the streams still running
echo "DP off: BE_EN $($P regs 0x5772 | awk '/^0x/{print $2}')"
