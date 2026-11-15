#!/bin/bash
# hdmi-off.sh: switch the HDMI port off (plane blanked, transmitter, OTG1 and its PLL off). hdmi-on.sh lights it again.
cd "$(dirname "$0")"; P=/Users/Shared/gpu/phxctl/phxctl
./dmubboot run plan_off.txt >/dev/null 2>&1 || { echo "plan_off failed"; exit 3; }
$P wreg 0x36b8 0x10080001 >/dev/null     # GPINT: only stream 0 active
echo "HDMI off: BE_EN $($P regs 0x5672 | awk '/^0x/{print $2}')"
