#!/bin/bash
# hdmid: keeps the external display ports and PhxAMDFB's extra heads in step with the monitors.
# Two ports: the HDMI port, and DisplayPort on the USB-C port (DP alt mode, e.g. a USB-C -> HDMI adapter).
#   phxfb2=1 alone: one monitor at a time (both ports use display pipe 1 and head 1); the port that has a monitor
#                   first keeps the head until its monitor goes.
#   with phxfb3=1:  a monitor on each. The HDMI port keeps pipe 1 / head 1, the USB-C port gets pipe 2 / head 2. This
#                   script then runs twice, once per port (the second copy is started with the argument "dp"); every
#                   register sequence is done under a lock, since both go through the one DMUB mailbox.
#   monitor plugged in (HPD) and the port dark   -> read the EDID, hdmi-on.sh / dp-on.sh, fb1cfg online
#   monitor gone                                 -> fb1cfg offline, hdmi-off.sh / dp-off.sh
#   macOS put the display to sleep for 6 s       -> port off (the monitor goes to standby); lit again on wake
# After a wake from hibernation the port is dark again (the display block was reset): same path as a plug.
# The state comes from the kext (sysctl debug.phxfb1_hw / _power), so polling does not wake the GPU.
# (The 780M's clock cap follows the monitor too: the cppcd service raises it while the port is lit.)
# LaunchDaemon local.hdmid; log /var/log/hdmid.log; `touch /Users/Shared/gpu/hdmi/off` pauses it.
D=/Users/Shared/gpu/hdmi; cd $D || exit 1
[ -z "$1" ] && [ "$(stat -f %z /var/log/hdmid.log 2>/dev/null || echo 0)" -gt 1048576 ] && mv /var/log/hdmid.log /var/log/hdmid.log.old   # at each start
exec >>/var/log/hdmid.log 2>&1
# FIX: the port this copy looks after ("" = both, sharing head 1). HEAD: its framebuffer head. X: suffix of its files.
FIX=""; HEAD=1; X=""; TAG=""
if [ "$1" = dp ]; then FIX=dp; HEAD=2; X=-dp; TAG="[dp] "
else
  rmdir /tmp/hdmid.lock 2>/dev/null
  for i in $(seq 1 120); do hw=$(sysctl -n debug.phxfb1_hw 2>/dev/null); [ -n "$hw" ] && [ "$hw" -ge 0 ] && break; sleep 2; done
  pkill -f "hdmid.sh dp" 2>/dev/null      # a copy left from before a restart
  if [ $(( ${hw:-0} & 128 )) != 0 ]; then FIX=hdmi; "$0" dp & fi
fi
export FB_HEAD=$HEAD
say() { echo "$(date '+%F %T') $TAG$*"; }
# one register sequence at a time (a lock older than a minute is a leftover)
lock() { local i=0; until mkdir /tmp/hdmid.lock 2>/dev/null; do i=$(( i + 1 )); [ $i -gt 600 ] && rmdir /tmp/hdmid.lock 2>/dev/null; sleep 0.1; done; }
unlock() { rmdir /tmp/hdmid.lock 2>/dev/null; }
# a bring-up is running, or the GPU is still in its power-on state after a wake from hibernation (GRBM_STATUS 0)
# (at boot the accelerator's heads are armed once the bring-up is over: the check on nvaccel_heads_piped below; waiting
# for phxboot's last line cost another minute and a half)
busy() { pgrep -qf 'phxwake.sh|full.sh|bringup5.sh' ||
         [ "$(/Users/Shared/gpu/phxctl/phxctl regs 0x2004 | awk '/^0x/{print $2}')" = 0x00000000 ]; }
online() { ./fb1cfg show 2>/dev/null | grep -q '^online 1'; }
# The mode is the EDID's preferred timing (hdmimode.py); a line like 1920x1080 in $D/mode asks for another one.
E=/tmp/hdmid-edid$X.bin; PD=/tmp/hdmid-plans$X
light() { lock; light1; local r=$?; unlock; return $r; }
light1() {
  if [ $act = dp ]; then
    PIPE=$HEAD ./dp-on.sh $E $PD $(cat $D/mode$X 2>/dev/null) || return 1
    online || ./fb1cfg online $E mode $(cat $PD/mode.txt)
    return
  fi
  for i in 1 2 3; do ./ddcbb edid $E >/dev/null 2>&1 && [ "$(stat -f %z $E 2>/dev/null || echo 0)" -ge 128 ] && break; sleep 1; done
  rm -rf $PD
  if /usr/bin/python3 ./hdmimode.py $E $PD $(cat $D/mode 2>/dev/null); then
    PLANS=$PD ./hdmi-on.sh || return 1
    online || ./fb1cfg online $E mode $(cat $PD/mode.txt)
  else
    say "no plans for this EDID: the fixed 2560x1440"
    ./hdmi-on.sh || return 1
    online || ./fb1cfg online $E 1440p
  fi
}
dark_port() { lock; if [ $act = dp ]; then PIPE=$HEAD ./dp-off.sh; else ./hdmi-off.sh; fi; unlock; }
# DDC/CI: bit-banged on the HDMI port's DDC pads, I2C-over-AUX on the DisplayPort side
vcp() { lock; if [ "$act" = dp ]; then ./dmubboot aux vcp "$@"; else ./ddcbb vcp "$@"; fi; local r=$?; unlock; return $r; }
# The monitor's own brightness and speaker volume (DDC/CI, VCP 0x10 and 0x62): $S/state holds "<brightness> <max>
# <volume> <max>" while a monitor answers, and a number written to $S/brightness or $S/volume (0-100 %, by the
# powerbar menu) is applied. HDMI audio is digital: the Mac's own volume control does not act on it. Checked every half second; the port's
# state every two.
# With a head per port the USB-C port's files carry the suffix -dp (state-dp, brightness-dp, volume-dp), and name /
# name-dp hold the monitor's name from its EDID for the menu.
S=/Users/Shared/hdmi; mkdir -p $S; chmod 777 $S; rm -f $S/state$X $S/brightness$X $S/volume$X $S/name$X
edid_name() { /usr/bin/python3 -c 'import sys
e=open(sys.argv[1],"rb").read()
for o in range(54,126,18):
    if e[o:o+3]==b"\0\0\0" and e[o+3]==0xfc: print(e[o+5:o+18].split(b"\n")[0].decode("ascii","replace").strip())' $E 2>/dev/null | head -1; }
vmax=0; cur=0; amax=0; acur=0       # brightness (VCP 0x10) and speaker volume (VCP 0x62); max 0 = the monitor has no such control
vcp_read() { vcp $1 2>/dev/null | awk '/^vcp 0x[0-9a-f]+ =/{print $4, $6}'; }
put_state() { if [ $vmax -gt 0 ]; then echo "$cur $vmax $acur $amax" > $S/state$X; chmod 644 $S/state$X; else rm -f $S/state$X; fi; }
bright_state() {
  out=$(vcp_read 0x10)
  if [ -n "$out" ]; then cur=${out% *}; vmax=${out#* }; else vmax=0; fi
  out=$(vcp_read 0x62)
  if [ -n "$out" ]; then acur=${out% *}; amax=${out#* }; else amax=0; fi
  put_state
}
# apply <file> <vcp code> <max>: a percentage written by the powerbar menu
apply() {
  [ -f $S/$1$X ] || return 1
  pct=$(tr -dc '0-9' < $S/$1$X | cut -c1-3); rm -f $S/$1$X
  [ -n "$pct" ] && [ "$3" -gt 0 ] || return 1
  [ "$pct" -gt 100 ] && pct=100
  v=$(( (pct * $3 + 50) / 100 ))
  vcp $2 $v >/dev/null 2>&1 || return 1
  hot=100                 # a slider is in use: look again every 0.1 s for the next ten seconds
}
bright_apply() {
  apply brightness 0x10 $vmax && { cur=$v; put_state; }
  apply volume 0x62 $amax && { acur=$v; put_state; }
}
say "hdmid start${FIX:+ (port $FIX, head $HEAD)}"
dark=0; n=0; bs=0; hot=0; act="$FIX"; fails=0; lastfail=0
while :; do
  [ -n "$act" ] && bright_apply
  if [ $hot -gt 0 ]; then hot=$(( hot - 1 )); sleep 0.1; [ $(( hot % 20 )) = 0 ] || continue
  else n=$(( n + 1 )); if [ $(( n % 4 )) != 1 ]; then sleep 0.5; continue; fi; fi
  hw=$(sysctl -n debug.phxfb1_hw 2>/dev/null); pw=$(sysctl -n debug.phxfb${HEAD}_power 2>/dev/null)
  if [ -z "$hw" ] || [ "$hw" -lt 0 ] || [ -e $D/off ]; then sleep 10; continue; fi
  # bits: 0 HDMI monitor, 1 HDMI encoder on, 2 DAL DMUB firmware, 4 DP sink on USB-C, 5 DP encoder on
  fw=$(( (hw >> 2) & 1 ))
  if [ -z "$act" ]; then      # which port owns the head: one that is lit already (the daemon restarted), else one with a monitor
    if [ $fw = 1 ] && [ $(( hw & 2 )) != 0 ]; then act=hdmi; elif [ $fw = 1 ] && [ $(( hw & 32 )) != 0 ]; then act=dp
    elif [ $(( hw & 1 )) != 0 ]; then act=hdmi; elif [ $(( hw & 16 )) != 0 ]; then act=dp
    else online && { say "head online with no monitor: offline"; ./fb1cfg offline >/dev/null; }; sleep 0.5; continue; fi
  fi
  if [ $act = dp ]; then hb=16; lb=32; else hb=1; lb=2; fi
  hpd=$(( (hw & hb) != 0 )); lit=$(( fw == 1 && (hw & lb) != 0 ))
  [ "$pw" = 0 ] && dark=$(( dark + 1 )) || dark=0
  # a monitor may take a few seconds after the link comes up before it answers DDC/CI: up to five tries
  if [ $hpd = 1 ] && [ $lit = 1 ] && [ $dark = 0 ] && [ $vmax = 0 ] && [ $bs -lt 5 ]; then bright_state; bs=$(( bs + 1 )); fi
  # the monitor's name for the menu, also for a port that was lit before this copy started
  if [ $hpd = 1 ] && [ $lit = 1 ] && [ ! -s $S/name$X ]; then
    [ -s $E ] || { lock; if [ $act = dp ]; then ./dmubboot aux edid $E; else ./ddcbb edid $E; fi >/dev/null 2>&1; unlock; }
    edid_name > $S/name$X; chmod 644 $S/name$X
  fi
  if [ $hpd = 1 ] && [ $dark = 0 ] && { [ $lit = 0 ] || ! online; }; then
    # the GPU must be up and WindowServer on the accelerator (boot, or the bring-up after a wake)
    if busy || [ $(( $(sysctl -n debug.nvaccel_heads_piped 2>/dev/null || echo 0) & (1 << HEAD) )) = 0 ]; then sleep 2; continue; fi
    sleep 1; [ $(( $(sysctl -n debug.phxfb1_hw) & hb )) != 0 ] || continue
    # after three failed tries in a row, one try every 30 s (a link that will not train stays so until it is replugged)
    if [ $fails -ge 3 ] && [ $(( $(date +%s) - lastfail )) -lt 30 ]; then sleep 1; continue; fi
    say "monitor on the $act port (hw $hw): lighting"; light; say "-> hw $(sysctl -n debug.phxfb1_hw), $(./fb1cfg show)"
    if online; then fails=0; else fails=$(( fails + 1 )); lastfail=$(date +%s); fi
    bs=0; edid_name > $S/name$X; chmod 644 $S/name$X
  elif [ $hpd = 0 ]; then
    sleep 1; [ $(( $(sysctl -n debug.phxfb1_hw) & hb )) = 0 ] || continue
    if [ $lit = 1 ] || online; then say "monitor gone from the $act port (hw $hw)"; ./fb1cfg offline >/dev/null; dark_port; fi
    rm -f $S/state$X $S/name$X; vmax=0; amax=0; bs=0; act="$FIX"; fails=0
  elif [ $lit = 1 ] && [ $dark = 3 ]; then
    say "display sleep: $act port off"; dark_port
  fi
  sleep 0.5
done
