#!/bin/bash
# streams.sh: tell the DMUB firmware which display pipes carry a stream (GPINT 8, IDLE_OPT_NOTIFY_STREAM_MASK). As in
# Linux's get_stream_mask() the bit is the pipe index: 1 = the panel (pipe 0), 2 = HDMI (pipe 1), 4 = DisplayPort on
# pipe 2. With a bit missing the firmware treats that pipe as idle (DisplayPort alone on pipe 2 with mask 3 stayed black).
P=/Users/Shared/gpu/phxctl/phxctl
r() { $P regs $1 | awk '/^0x/{print $2}'; }
m=$(( 1 | ($(r 0x5081) & 1) << 1 | ($(r 0x5101) & 1) << 2 ))
$P wreg 0x36b8 $(printf 0x%x $(( 0x10080000 | m ))) >/dev/null
