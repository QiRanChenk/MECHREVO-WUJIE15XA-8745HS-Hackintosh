#!/bin/bash
# Install the GPU clock cap as a LaunchDaemon. Run with sudo from this directory.
set -e
cd "$(dirname "$0")"
mkdir -p /usr/local/libexec
install -m 755 -o root -g wheel gpuclk.sh /usr/local/libexec/gpuclk.sh
install -m 644 -o root -g wheel local.gpuclk.plist /Library/LaunchDaemons/local.gpuclk.plist
launchctl bootstrap system /Library/LaunchDaemons/local.gpuclk.plist
echo "installed; log: /var/log/gpuclk.log"
