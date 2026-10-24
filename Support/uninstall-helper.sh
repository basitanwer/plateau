#!/bin/bash
# Removes the daemon and restores normal charging. Run with sudo.
set -u
LABEL=com.basitanwer.plateau.helper
BIN=/Library/PrivilegedHelperTools/$LABEL
launchctl bootout "system/$LABEL" 2>/dev/null
# The daemon leaves the charge state alone when stopped (so shutdown doesn't charge to 100%),
# so turn charging back on explicitly.
[ -x "$BIN" ] && "$BIN" charge on
rm -f "/Library/LaunchDaemons/$LABEL.plist" "$BIN"
rm -rf "/Library/Application Support/Plateau"
echo "Uninstalled. Charging is back to normal."
