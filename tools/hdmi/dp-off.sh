#!/bin/bash
# dp-off.sh: switch the USB-C DisplayPort output off (video stream, link, transmitter, OTG1). dp-on.sh lights it again.
cd "$(dirname "$0")"; P=/Users/Shared/gpu/phxctl/phxctl
./dmubboot run plan_dp_off1.txt >/dev/null 2>&1
./dmubboot dpoff >/dev/null 2>&1          # sink to D3 when it is still there, transmitter DISABLE
./dmubboot run plan_dp_off2.txt >/dev/null 2>&1
$P wreg 0x36b8 0x10080001 >/dev/null      # GPINT: only stream 0 active
echo "DP off: BE_EN $($P regs 0x5772 | awk '/^0x/{print $2}')"
