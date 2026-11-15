#!/bin/bash
# cppcd: keeps AMD CPPC (PhxCPPC.kext, nullarc PR 21) enabled with the energy-performance preference the user chose.
# Runs as root (LaunchDaemon local.cppcd). The choice is one line in /Users/Shared/cppc/mode, written by powerbar:
#   auto        EPP 128 on AC power, 192 on battery (default)
#   epp <0-255> fixed EPP: 0 = performance ... 255 = power saving
# The request MSRs reset on a hibernation wake and the kext keeps nothing itself, so the setting is written again
# after every wake (noticed as a jump of the wall clock between two rounds) as well as on every change. It is NOT
# rewritten periodically: the write stops every CPU for a moment (mp_rendezvous), and one landing in the middle of a
# sleep transition is the suspect for a reset on the way into hibernation (2026-11-14). What was applied goes to /Users/Shared/cppc/status.
D=/Users/Shared/cppc; mkdir -p $D; chmod 777 $D
AC_EPP=128; BATT_EPP=192
for i in $(seq 1 60); do sysctl -n debug.phx_cppc_supported >/dev/null 2>&1 && break; sleep 2; done
[ "$(sysctl -n debug.phx_cppc_supported 2>/dev/null)" = 1 ] || { echo "no PhxCPPC" > $D/status; exit 0; }
# Two more settings ride on this service because they need root as well:
#   /Users/Shared/cppc/lid     "awake" = closing the lid does not sleep (pmset disablesleep 1); anything else = it does
#   /Users/Shared/cppc/gfxoff-off   present = leave GFXOFF alone; absent = keep debug.phx_pm_gfxoff at 1 (the kext's
#                              sysctl does not survive a reboot)
#   /Users/Shared/cppc/gpu     the 780M's clock cap (SMU SetSoftMaxGfxClk): "auto" = 800 MHz on the panel alone, 1600 MHz
#                              while an external monitor is lit (two 2.5K displays stutter at 800), 2000 MHz with one on
#                              each port (HDMI and USB-C); or a number
#                              800-2600 (2600 = what the firmware allows without a cap; higher caps cost idle power).
#                              Written again 45 s and 120 s after the start and after a wake: the boot and wake scripts
#                              set their own value first. What is in force goes to /Users/Shared/cppc/gpu-status.
# The keyboard backlight (EC RAM 0x078c bits 5-7 = level 0..4, written with bit 4 set; WujieSleepPolicy's sysctls):
#   - its level is kept in /Users/Shared/cppc/kbd and put back at boot and after a wake (the firmware lights it again);
#   - off while the lid is closed, back when it opens. WujieSleepPolicy does this on the clamshell message too, but with
#     "keep running with the lid closed" (pmset disablesleep) the light stayed on (2026-11-15), so it is done here from
#     the lid state as well.
ec() { sysctl -w debug.wujie_ec_addr=1932 >/dev/null 2>&1 || return 1; if [ -n "$1" ]; then sysctl -w debug.wujie_ec_val=$1 >/dev/null 2>&1; else sysctl -n debug.wujie_ec_val 2>/dev/null; fi; }
kbd_set() { ec $(( ($1 << 5) | 0x10 )); }           # level 0..4
kbd_get() { local v; v=$(ec) || return 1; [ -n "$v" ] && [ "$v" -ge 0 ] && echo $(( (v >> 5) & 7 )); }
lid_closed() { ioreg -r -k AppleClamshellState -d1 | grep -q '"AppleClamshellState" = Yes'; }
kbdlast=""; kbdlid=0; kbdboot=1
last=""; n=0; src=""; lidlast=""; prev=""; glast=""; ticks=0
while :; do
    m=auto; v=; [ -r $D/mode ] && read -r m v < $D/mode
    # the power source every third round, the mode file every round: a choice in the menu applies within a second
    if [ $((n % 3)) = 0 ] || [ -z "$src" ]; then src=batt; pmset -g ps | head -1 | grep -q "AC Power" && src=ac; fi
    case "$m" in
        epp) case "$v" in ''|*[!0-9]*) epp=$AC_EPP ;; *) epp=$v; [ "$epp" -gt 255 ] && epp=255 ;; esac; mode="epp" ;;
        *)   mode=auto; [ $src = ac ] && epp=$AC_EPP || epp=$BATT_EPP ;;
    esac
    now=$(date +%s); woke=0
    if [ -n "$prev" ] && [ $((now - prev)) -gt 8 ]; then woke=1; sleep 5; now=$(date +%s); fi
    prev=$now
    if [ "$epp" != "$last" ] || [ $woke = 1 ]; then
        sysctl -w debug.phx_cppc_enable=1 >/dev/null 2>&1
        sysctl -w debug.phx_cppc_max=-2 debug.phx_cppc_min=-2 debug.phx_cppc_epp=$epp >/dev/null 2>&1
        sysctl -w debug.phx_cppc_apply=1 >/dev/null 2>&1
        echo "$mode $epp $src" > $D/status.tmp && mv $D/status.tmp $D/status; chmod 644 $D/status
        last=$epp; n=0
    fi
    g=auto; [ -r $D/gpu ] && read -r g < $D/gpu
    case "$g" in
        ''|*[!0-9]*) gmode=auto; hw=$(sysctl -n debug.phxfb1_hw 2>/dev/null || echo 0); [ "$hw" -lt 0 ] && hw=0
                     cap=800; [ $(( hw & 34 )) != 0 ] && cap=1600; [ $(( hw & 34 )) = 34 ] && cap=2000 ;;
        *) gmode=manual; cap=$g; [ "$cap" -lt 800 ] && cap=800; [ "$cap" -gt 2600 ] && cap=2600 ;;
    esac
    [ $woke = 1 ] && ticks=0
    ticks=$((ticks + 1))
    if [ "$cap" != "$glast" ] || [ $ticks = 45 ] || [ $ticks = 120 ]; then
        if [ "$(sysctl -n debug.nvaccel_iop_ok 2>/dev/null || echo 0)" != 0 ] && /Users/Shared/gpu/phxctl/phxctl smu 0x1b $cap >/dev/null 2>&1; then
            glast=$cap; echo "$gmode $cap" > $D/gpu-status.tmp && mv $D/gpu-status.tmp $D/gpu-status; chmod 644 $D/gpu-status
        fi
    fi
    lid=sleep; [ -r $D/lid ] && read -r lid < $D/lid
    [ "$lid" = awake ] || lid=sleep
    if [ "$lid" != "$lidlast" ]; then
        if [ $lid = awake ]; then pmset -a disablesleep 1 >/dev/null 2>&1; else pmset -a disablesleep 0 >/dev/null 2>&1; fi
        echo "$lid" > $D/lid-status; chmod 644 $D/lid-status; lidlast=$lid
    fi
    # keyboard light: restore once after the start and after every wake, follow the lid every round, remember the
    # level the user picks with Fn every few rounds (while the lid is open)
    if [ $kbdboot = 1 ] || [ $woke = 1 ]; then
        k=$(cat $D/kbd 2>/dev/null); case "$k" in [0-4]) lid_closed || kbd_set $k ;; esac; kbdboot=0; kbdlast=$k
    fi
    if lid_closed; then
        if [ $kbdlid = 0 ]; then kbdlid=1; k=$(kbd_get); [ -n "$k" ] && [ "$k" != 0 ] && kbd_set 0; fi
    elif [ $kbdlid = 1 ]; then
        kbdlid=0; k=$(cat $D/kbd 2>/dev/null); case "$k" in [1-4]) [ "$(kbd_get)" = 0 ] && kbd_set $k ;; esac
    elif [ $((n % 3)) = 1 ]; then
        k=$(kbd_get); if [ -n "$k" ] && [ "$k" != "$kbdlast" ]; then echo $k > $D/kbd; chmod 644 $D/kbd; kbdlast=$k; fi
    fi
    if [ $((n % 10)) = 0 ] && [ ! -e $D/gfxoff-off ] && [ "$(sysctl -n debug.phx_pm_gfxoff 2>/dev/null)" = 0 ] \
       && [ "$(sysctl -n debug.nvaccel_iop_ok 2>/dev/null || echo 0)" != 0 ]; then
        sysctl -w debug.phx_pm_gfxoff=1 >/dev/null 2>&1
    fi
    n=$((n + 1)); sleep 1
done
