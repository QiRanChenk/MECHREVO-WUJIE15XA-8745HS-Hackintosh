#!/bin/bash
# Run on the Hackintosh (sudo). Builds the tools and installs the HDMI daemon (root LaunchDaemon local.hdmid) with its
# files in /Users/Shared/gpu/hdmi. Before running, put next to this script:
#   dcn_3_1_4_dmcub.bin   from linux-firmware (amdgpu/dcn_3_1_4_dmcub.bin)
#   vbios.bin             this machine's video BIOS (under Linux: /sys/kernel/debug/dri/0/amdgpu_vbios)
set -e
cd "$(dirname "$0")"
for f in dcn_3_1_4_dmcub.bin vbios.bin; do [ -f $f ] || { echo "missing $f (see the header of this script)"; exit 1; }; done
clang -arch x86_64 -O2 -o dmubboot dmubboot.c -framework IOKit -framework CoreFoundation
clang -arch x86_64 -O2 -o ddcbb ddcbb.c -framework IOKit -framework CoreFoundation
clang -arch x86_64 -O2 -o fb1cfg fb1cfg.c
D=/Users/Shared/gpu/hdmi; mkdir -p $D
for f in dmubboot ddcbb fb1cfg hdmi-on.sh hdmi-off.sh dp-on.sh dp-off.sh streams.sh hdmid.sh hdmimode.py; do install -m 755 -o root -g wheel $f $D/$f; done
for f in plan_*.txt dcn_3_1_4_dmcub.bin vbios.bin; do install -m 644 -o root -g wheel $f $D/; done
install -m 644 -o root -g wheel local.hdmid.plist /Library/LaunchDaemons/local.hdmid.plist
launchctl bootout system/local.hdmid 2>/dev/null || true
launchctl bootstrap system /Library/LaunchDaemons/local.hdmid.plist
echo "installed; log: /var/log/hdmid.log"
