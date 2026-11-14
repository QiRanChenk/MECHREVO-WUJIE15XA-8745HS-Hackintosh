#!/bin/bash
# Install the CPPC service (root LaunchDaemon). Run on the Hackintosh: sudo ./install.sh
# Needs PhxCPPC.kext (nullarc PR 21, https://github.com/luuumi-dev/nullarc/pull/21) injected by OpenCore.
# The mode is chosen in the powerbar menu (tools/powerbar) or by hand:
#   echo auto > /Users/Shared/cppc/mode        EPP 128 on AC power, 192 on battery
#   echo "epp 160" > /Users/Shared/cppc/mode   fixed, 0 = performance ... 255 = power saving
set -e
cd "$(dirname "$0")"
[ "$(id -u)" = 0 ] || { echo "run with sudo"; exit 1; }
install -m 755 -o root -g wheel cppcd.sh /usr/local/libexec/cppcd.sh
install -m 644 -o root -g wheel local.cppcd.plist /Library/LaunchDaemons/local.cppcd.plist
launchctl bootout system/local.cppcd 2>/dev/null || true
launchctl bootstrap system /Library/LaunchDaemons/local.cppcd.plist
sleep 3; echo "status: $(cat /Users/Shared/cppc/status 2>/dev/null)"
