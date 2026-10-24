#!/bin/bash
# Installs (or updates) the root charging daemon. Run with sudo (the app does this for you).
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
LABEL=com.basitanwer.plateau.helper
BIN=/Library/PrivilegedHelperTools/$LABEL
PLIST=/Library/LaunchDaemons/$LABEL.plist
DIR="/Library/Application Support/Plateau"
# The menu bar app runs as the logged-in user and writes the limit; only that user may change it.
OWNER="${SUDO_USER:-$(stat -f %Su /dev/console)}"

# Stop any running copy and wait until launchd has really torn it down, or bootstrap can fail.
launchctl bootout "system/$LABEL" 2>/dev/null || true
for _ in $(seq 1 50); do
    launchctl print "system/$LABEL" >/dev/null 2>&1 || break
    sleep 0.1
done

mkdir -p /Library/PrivilegedHelperTools "$DIR"
chown root:wheel "$DIR"
chmod 755 "$DIR"
install -m 755 -o root -g wheel "$HERE/plateau-helper" "$BIN"
LIMIT="$DIR/limit"
[ -f "$LIMIT" ] && [ ! -L "$LIMIT" ] || { rm -f "$LIMIT"; echo 80 > "$LIMIT"; }
chown "$OWNER" "$LIMIT"
chmod 644 "$LIMIT"

cat > "$PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>$LABEL</string>
    <key>ProgramArguments</key><array><string>$BIN</string><string>daemon</string></array>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key><true/>
    <key>StandardOutPath</key><string>/var/log/plateau.log</string>
    <key>StandardErrorPath</key><string>/var/log/plateau.log</string>
</dict>
</plist>
PLIST
chown root:wheel "$PLIST"
chmod 644 "$PLIST"
launchctl bootstrap system "$PLIST"
