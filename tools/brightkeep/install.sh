#!/bin/bash
# Build and install brightkeep as a per-user LaunchAgent (run as the desktop user, not root).
set -e
cd "$(dirname "$0")"
swiftc -O -target x86_64-apple-macosx12.0 brightkeep.swift -o brightkeep
codesign -s - -f brightkeep
mkdir -p ~/.local/bin ~/Library/LaunchAgents
install -m 755 brightkeep ~/.local/bin/brightkeep
sed "s#__HOME__#$HOME#" local.brightkeep.plist > ~/Library/LaunchAgents/local.brightkeep.plist
launchctl bootout gui/$(id -u)/local.brightkeep 2>/dev/null || true
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/local.brightkeep.plist
echo installed
