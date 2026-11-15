#!/bin/bash
# hdmi-on.sh: light the HDMI port of the WUJIE15XA under macOS at 2560x1440@60, 8 bpc. The second display pipe scans
# the buffer of PhxAMDFB's second head (VRAM offset 0x6000000, boot-arg phxfb2=1), which macOS draws once
# `fb1cfg online <edid>` has reported the monitor; MIRROR=1 scans the panel's own frame buffer instead (a mirror of
# its top 1440 lines, no kext support needed). Run as root after the desktop is up (phxboot done). Needs phxdebug=1. Recipe that first produced a picture on 2026-11-15 (see NEXT.md):
#   1. DAL DMUB firmware through the PSP + start (dmubboot start)   2. transmitter B and PLL1 off (as Linux at init)
#   3. pixel clock, OTG1, DIG1, transmitter on (plan_signal)        4. plane on pipe 1 (plan_plane) + FMT for 8 bpc
#   5. DC_GENERICA, generic packet control 6, DIO FIFO resync (DENTIST rewrite), stream mask to the firmware
cd "$(dirname "$0")"; P=/Users/Shared/gpu/phxctl/phxctl; L=/Users/Shared/dmubboot.log
echo "=== $(date '+%F %T') hdmi-on" >> $L
hpd=$($P regs 0x53dc | awk '/^0x/{print $2}'); [ $(( hpd & 0x10 )) -ne 0 ] || { echo "no monitor on HDMI (HPD 0x53dc = $hpd)"; exit 1; }
if [ "$($P regs 0x36a3 | awk '/^0x/{print $2}')" != 0x00000003 ] || [ "$($P regs 0x36a4 | awk '/^0x/{print $2}')" != 0x08006500 ]; then
  $P loadfw dcn_3_1_4_dmcub.bin 256 350368 51 0x900000 2>&1 | grep loadfw >> $L
  ./dmubboot start vbios.bin >/dev/null 2>&1 || { echo "DMUB did not start"; exit 2; }
fi
# PLANS=<dir>: the plans hdmimode.py generated for the monitor's mode (signal.txt, plane.txt, audio.txt)
SIG=plan_signal.txt; PL=plan_plane6.txt; AUD=plan_audio.txt
[ "${MIRROR:-0}" = 1 ] && PL=plan_plane.txt
[ -n "${PLANS:-}" ] && [ -f "$PLANS/plane.txt" ] && { SIG=$PLANS/signal.txt; PL=$PLANS/plane.txt; AUD=$PLANS/audio.txt; }
for p in plan_init_off.txt $AUD $SIG $PL plan_fmt8.txt; do ./dmubboot run $p >/dev/null 2>&1 || { echo "$p failed"; exit 3; }; done
$P wreg 0x5d28 0x80 >/dev/null; $P wreg 0x565c 0 >/dev/null
$P wreg 0x124 $($P regs 0x124 | awk '/^0x/{print $2}') >/dev/null      # dccg314_trigger_dio_fifo_resync
$P wreg 0x36b8 0x10080003 >/dev/null                                    # GPINT: streams 0 and 1 active
[ -n "${PLANS:-}" ] && [ -f "$PLANS/audio_on.txt" ] && ./dmubboot run $PLANS/audio_on.txt >/dev/null 2>&1    # audio endpoint on
echo "HDMI on: BE_EN $($P regs 0x5672 | awk '/^0x/{print $2}') FE $($P regs 0x564b | awk '/^0x/{print $2}') FIFO $($P regs 0x5652 | awk '/^0x/{print $2}')" | tee -a $L
