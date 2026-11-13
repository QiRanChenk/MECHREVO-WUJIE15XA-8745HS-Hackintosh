#!/bin/bash
# tcc-grant.sh <App.app> [service...]: grant TCC services (default Camera, Microphone) to an app by writing the
# logged-in user's TCC database directly.
#
# Why: this machine boots with AMFI disabled for the GPU driver (amfi=0x80 amfi_get_out_of_my_way=0x1). tccd then logs
# "Policy disallows prompt" and denies third-party apps without ever showing the permission dialog, so nothing can be
# allowed from System Settings either.
#
# Run ON the Hackintosh as the logged-in user (no sudo). Requires SIP disabled. A backup of TCC.db is written next to
# it first. To revoke: System Settings > Privacy & Security, or delete the row.
set -euo pipefail
APP=${1:?usage: tcc-grant.sh /Applications/Foo.app [kTCCServiceCamera kTCCServiceMicrophone ...]}; shift || true
SVCS=("$@"); [ ${#SVCS[@]} -gt 0 ] || SVCS=(kTCCServiceCamera kTCCServiceMicrophone)
DB="$HOME/Library/Application Support/com.apple.TCC/TCC.db"
ID=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$APP/Contents/Info.plist")
REQ=$(codesign -d -r- "$APP" 2>&1 | sed -n 's/^designated => //p')
[ -n "$REQ" ] || { echo "no designated requirement for $APP"; exit 1; }
T=$(mktemp); echo "$REQ" | csreq -r- -b "$T"; HEX=$(xxd -p "$T" | tr -d '\n'); rm -f "$T"
cp "$DB" "$DB.bak-$(date +%Y%m%d-%H%M%S)"
for S in "${SVCS[@]}"; do
  sqlite3 "$DB" "INSERT OR REPLACE INTO access (service, client, client_type, auth_value, auth_reason, auth_version, csreq, flags) VALUES ('$S', '$ID', 0, 2, 3, 1, X'$HEX', 0);"
  echo "granted $S to $ID"
done
killall tccd 2>/dev/null || true
