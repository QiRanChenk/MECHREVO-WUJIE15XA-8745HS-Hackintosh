#!/bin/bash
# cppcd: keeps AMD CPPC (PhxCPPC.kext, nullarc PR 21) enabled with the energy-performance preference the user chose.
# Runs as root (LaunchDaemon local.cppcd). The choice is one line in /Users/Shared/cppc/mode, written by powerbar:
#   auto        EPP 128 on AC power, 192 on battery (default)
#   epp <0-255> fixed EPP: 0 = performance ... 255 = power saving
# The request MSRs reset on a hibernation wake and the kext keeps nothing itself, so the setting is written again every
# 30 s as well as on every change. What was applied goes to /Users/Shared/cppc/status.
D=/Users/Shared/cppc; mkdir -p $D; chmod 777 $D
AC_EPP=128; BATT_EPP=192
for i in $(seq 1 60); do sysctl -n debug.phx_cppc_supported >/dev/null 2>&1 && break; sleep 2; done
[ "$(sysctl -n debug.phx_cppc_supported 2>/dev/null)" = 1 ] || { echo "no PhxCPPC" > $D/status; exit 0; }
last=""; n=0; src=""
while :; do
    m=auto; v=; [ -r $D/mode ] && read -r m v < $D/mode
    # the power source every third round, the mode file every round: a choice in the menu applies within a second
    if [ $((n % 3)) = 0 ] || [ -z "$src" ]; then src=batt; pmset -g ps | head -1 | grep -q "AC Power" && src=ac; fi
    case "$m" in
        epp) case "$v" in ''|*[!0-9]*) epp=$AC_EPP ;; *) epp=$v; [ "$epp" -gt 255 ] && epp=255 ;; esac; mode="epp" ;;
        *)   mode=auto; [ $src = ac ] && epp=$AC_EPP || epp=$BATT_EPP ;;
    esac
    if [ "$epp" != "$last" ] || [ $n -ge 30 ]; then
        sysctl -w debug.phx_cppc_enable=1 >/dev/null 2>&1
        sysctl -w debug.phx_cppc_max=-2 debug.phx_cppc_min=-2 debug.phx_cppc_epp=$epp >/dev/null 2>&1
        sysctl -w debug.phx_cppc_apply=1 >/dev/null 2>&1
        echo "$mode $epp $src" > $D/status.tmp && mv $D/status.tmp $D/status; chmod 644 $D/status
        last=$epp; n=0
    fi
    n=$((n + 1)); sleep 1
done
