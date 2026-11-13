#!/bin/bash
# Install the wake service (run with sudo on the Hackintosh, from this directory).
set -e
cd "$(dirname "$0")"
clang -O2 -o /tmp/phxwaked phxwaked.c -framework IOKit -framework CoreFoundation
install -m 755 -o root -g wheel /tmp/phxwaked /usr/local/libexec/phxwaked
install -m 755 -o root -g wheel phxwake.sh /usr/local/libexec/phxwake.sh
install -m 644 -o root -g wheel local.phxwake.plist /Library/LaunchDaemons/local.phxwake.plist
launchctl bootout system/local.phxwake 2>/dev/null || true
launchctl bootstrap system /Library/LaunchDaemons/local.phxwake.plist
echo "installed; log: /var/log/phxwake.log"
