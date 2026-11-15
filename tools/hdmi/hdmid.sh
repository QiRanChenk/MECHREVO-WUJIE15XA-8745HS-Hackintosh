#!/bin/bash
# hdmid: keeps the HDMI port and PhxAMDFB's second head (boot-arg phxfb2=1) in step with the monitor.
#   monitor plugged in (HPD) and the port dark   -> hdmi-on.sh, read the EDID (ddcbb), fb1cfg online
#   monitor gone                                 -> fb1cfg offline, hdmi-off.sh
#   macOS put the display to sleep for 6 s       -> hdmi-off.sh (the monitor goes to standby); lit again on wake
# After a wake from hibernation the port is dark again (the display block was reset): same path as a plug.
# The state comes from the kext (sysctl debug.phxfb1_hw / _power), so polling does not wake the GPU.
# LaunchDaemon local.hdmid; log /var/log/hdmid.log; `touch /Users/Shared/gpu/hdmi/off` pauses it.
D=/Users/Shared/gpu/hdmi; cd $D || exit 1
exec >>/var/log/hdmid.log 2>&1
say() { echo "$(date '+%F %T') $*"; }
# a bring-up is running, or the GPU is still in its power-on state after a wake from hibernation (GRBM_STATUS 0)
# (at boot the accelerator's heads are armed once the bring-up is over: the check on nvaccel_heads_piped below; waiting
# for phxboot's last line cost another minute and a half)
busy() { pgrep -qf 'phxwake.sh|full.sh|bringup5.sh' ||
         [ "$(/Users/Shared/gpu/phxctl/phxctl regs 0x2004 | awk '/^0x/{print $2}')" = 0x00000000 ]; }
online() { ./fb1cfg show 2>/dev/null | grep -q '^online 1'; }
# The mode is the EDID's preferred timing (hdmimode.py); a line like 1920x1080 in $D/mode asks for another one.
light() {
  for i in 1 2 3; do ./ddcbb edid /tmp/hdmid-edid.bin >/dev/null 2>&1 && [ "$(stat -f %z /tmp/hdmid-edid.bin 2>/dev/null || echo 0)" -ge 128 ] && break; sleep 1; done
  rm -rf /tmp/hdmid-plans
  if /usr/bin/python3 ./hdmimode.py /tmp/hdmid-edid.bin /tmp/hdmid-plans $(cat $D/mode 2>/dev/null); then
    PLANS=/tmp/hdmid-plans ./hdmi-on.sh || return 1
    online || ./fb1cfg online /tmp/hdmid-edid.bin mode $(cat /tmp/hdmid-plans/mode.txt)
  else
    say "no plans for this EDID: the fixed 2560x1440"
    ./hdmi-on.sh || return 1
    online || ./fb1cfg online /tmp/hdmid-edid.bin 1440p
  fi
}
# The monitor's own brightness (DDC/CI, VCP 0x10): $S/state holds "<value> <max>" while a monitor answers, and a
# number written to $S/brightness (0-100 %, by the powerbar menu) is applied. Checked every half second; the port's
# state every two.
S=/Users/Shared/hdmi; mkdir -p $S; chmod 777 $S; rm -f $S/state $S/brightness
vmax=0
bright_state() {
  out=$(./ddcbb vcp 0x10 2>/dev/null | awk '/^vcp 0x10 =/{print $4, $6}')
  if [ -n "$out" ]; then echo "$out" > $S/state; chmod 644 $S/state; vmax=${out#* }; else rm -f $S/state; vmax=0; fi
}
bright_apply() {
  [ -f $S/brightness ] || return
  pct=$(tr -dc '0-9' < $S/brightness | cut -c1-3); rm -f $S/brightness
  [ -n "$pct" ] && [ "$vmax" -gt 0 ] || return
  [ "$pct" -gt 100 ] && pct=100
  v=$(( (pct * vmax + 50) / 100 ))
  ./ddcbb vcp 0x10 $v >/dev/null 2>&1 && echo "$v $vmax" > $S/state
  hot=100                 # the slider is in use: look again every 0.1 s for the next ten seconds
}
say "hdmid start"
dark=0; n=0; bs=0; hot=0
while :; do
  bright_apply
  if [ $hot -gt 0 ]; then hot=$(( hot - 1 )); sleep 0.1; [ $(( hot % 20 )) = 0 ] || continue
  else n=$(( n + 1 )); if [ $(( n % 4 )) != 1 ]; then sleep 0.5; continue; fi; fi
  hw=$(sysctl -n debug.phxfb1_hw 2>/dev/null); pw=$(sysctl -n debug.phxfb1_power 2>/dev/null)
  if [ -z "$hw" ] || [ "$hw" -lt 0 ] || [ -e $D/off ]; then sleep 10; continue; fi
  hpd=$(( hw & 1 )); lit=$(( (hw & 6) == 6 ))
  [ "$pw" = 0 ] && dark=$(( dark + 1 )) || dark=0
  # a monitor may take a few seconds after the link comes up before it answers DDC/CI: up to five tries
  if [ $hpd = 1 ] && [ $lit = 1 ] && [ $dark = 0 ] && [ $vmax = 0 ] && [ $bs -lt 5 ]; then bright_state; bs=$(( bs + 1 )); fi
  if [ $hpd = 1 ] && [ $dark = 0 ] && { [ $lit = 0 ] || ! online; }; then
    # the GPU must be up and WindowServer on the accelerator (boot, or the bring-up after a wake)
    if busy || [ $(( $(sysctl -n debug.nvaccel_heads_piped 2>/dev/null || echo 0) & 2 )) = 0 ]; then sleep 2; continue; fi
    sleep 1; [ $(( $(sysctl -n debug.phxfb1_hw) & 1 )) = 1 ] || continue
    say "monitor on the HDMI port (hw $hw): lighting"; light; say "-> hw $(sysctl -n debug.phxfb1_hw), $(./fb1cfg show)"
    bs=0
  elif [ $hpd = 0 ] && { [ $lit = 1 ] || online; }; then
    sleep 1; [ $(( $(sysctl -n debug.phxfb1_hw) & 1 )) = 0 ] || continue
    say "monitor gone (hw $hw)"; ./fb1cfg offline >/dev/null; ./hdmi-off.sh; rm -f $S/state; vmax=0; bs=0
  elif [ $lit = 1 ] && [ $dark = 3 ]; then
    say "display sleep: port off"; ./hdmi-off.sh
  fi
  sleep 0.5
done
