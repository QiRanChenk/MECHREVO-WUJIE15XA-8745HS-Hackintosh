#!/bin/bash
# dp-on.sh <edid.bin> [plans dir] [WxH[@Hz]]: light a DisplayPort sink on the USB-C port (DP alt mode; e.g. a USB-C ->
# HDMI adapter) on display pipe 1, scanning the buffer of PhxAMDFB's second head. Same idea as hdmi-on.sh plus what
# DP needs, all done by dmubboot: AUX (DPCD, EDID) and link training. As Linux does, the link is trained once to
# learn what it carries (lanes, rate), the mode is chosen within that, and the link is trained again for real after
# the stream attributes are set. Run as root; needs phxdebug=1. Leaves <plans dir>/mode.txt for `fb1cfg online`.
# PIPE=2 in the environment: display pipe 2 and PhxAMDFB's third head (phxfb3=1), so that HDMI keeps pipe 1. The audio
# then stays with HDMI while HDMI is lit (both would need the one audio endpoint and DTO the HD-audio driver plays to).
cd "$(dirname "$0")"; P=/Users/Shared/gpu/phxctl/phxctl; L=/Users/Shared/dmubboot.log
E=${1:-/tmp/dp-edid.bin}; PD=${2:-/tmp/dp-plans}; WANT=${3:-}
echo "=== $(date '+%F %T') dp-on" >> $L
./dmubboot aux hpd >/dev/null 2>&1 || { echo "no DP sink on the USB-C port"; exit 1; }
if [ "$($P regs 0x36a3 | awk '/^0x/{print $2}')" != 0x00000003 ] || [ "$($P regs 0x36a4 | awk '/^0x/{print $2}')" != 0x08006500 ]; then
  $P loadfw dcn_3_1_4_dmcub.bin 256 350368 51 0x900000 2>&1 | grep loadfw >> $L
  ./dmubboot start vbios.bin >/dev/null 2>&1 || { echo "DMUB did not start"; exit 2; }
fi
for i in 1 2 3; do ./dmubboot aux edid $E >/dev/null 2>&1 && break; sleep 1; done
link=$(./dmubboot dptrain 2>/dev/null | awk '/^link [0-9]/{print $2, $3}')
[ -n "$link" ] || { echo "link training failed"; ./dmubboot dpoff >/dev/null 2>&1; exit 4; }
./dmubboot dpoff >/dev/null 2>&1
rm -rf $PD
PIPE=${PIPE:-1}; T=plan_dp; FMT=plan_fmt8.txt; [ $PIPE = 2 ] && { T=plan_dp2; FMT=plan_fmt8_2.txt; }
if /usr/bin/python3 ./hdmimode.py $E $PD $WANT --dp $link --pipe $PIPE; then PRE=$PD/dp_pre.txt; POST=$PD/dp_post.txt; PL=$PD/dp_plane.txt
else echo "no plans for this EDID: the fixed 2560x1440@60"; PRE=${T}_pre.txt; POST=${T}_post.txt; PL=${T}_plane.txt; mkdir -p $PD; echo "2560 1440 244800 2720 2608 2640 1500 1443 1448 0" > $PD/mode.txt; fi
if [ $PIPE = 2 ] && [ $(( $($P regs 0x5081 | awk '/^0x/{print $2}') & 1 )) = 1 ]; then rm -f $PD/dp_audio.txt $PD/dp_audio_on.txt; fi
./dmubboot run $PRE >/dev/null 2>&1 || { echo "$PRE failed"; exit 3; }
[ -f $PD/dp_audio.txt ] && ./dmubboot run $PD/dp_audio.txt >/dev/null 2>&1
./dmubboot dptrain $link 2>/dev/null | grep -E "LINK UP|failed" 
[ $(( $($P regs 0x57c8 | awk '/^0x/{print $2}') & 0x10 )) = 16 ] || { echo "link not up"; exit 4; }
for p in $POST $PL $FMT; do ./dmubboot run $p >/dev/null 2>&1 || { echo "$p failed"; exit 3; }; done
$P wreg 0x124 $($P regs 0x124 | awk '/^0x/{print $2}') >/dev/null      # DIO FIFO resync
./streams.sh                                                            # GPINT: the streams that run
[ -f $PD/dp_audio_on.txt ] && ./dmubboot run $PD/dp_audio_on.txt >/dev/null 2>&1
echo "DP on (pipe $PIPE): link $link, video $($P regs 0x57cc | awk '/^0x/{print $2}'), sink $(./dmubboot aux rd 0x202 4 | tail -1)" | tee -a $L
