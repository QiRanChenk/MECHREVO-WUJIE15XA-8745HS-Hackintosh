#!/bin/bash
# Build and register the menu-bar power readout as a login agent (run as the logged-in user, on the Hackintosh).
set -e
cd "$(dirname "$0")"
mkdir -p ~/.local/bin ~/Library/LaunchAgents
swiftc -O -o ~/.local/bin/powerbar powerbar.swift
sed "s|__HOME__|$HOME|g" local.powerbar.plist > ~/Library/LaunchAgents/local.powerbar.plist
launchctl bootout gui/$(id -u)/local.powerbar 2>/dev/null || true
sleep 1    # bootout finishes a moment after it returns; bootstrap right behind it fails with "Bad request"
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/local.powerbar.plist || { sleep 2; launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/local.powerbar.plist; }
