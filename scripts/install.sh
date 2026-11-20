#!/bin/bash
# One-time setup, run by a parent from an Administrator account:  scripts/install.sh
# Installs the app for all users and the root-owned vault helper.
set -euo pipefail
cd "$(dirname "$0")/.."
if [ "$(id -u)" = "0" ]; then echo "Run this as your normal admin user, not with sudo. It asks for the password itself."; exit 1; fi
scripts/bundle.sh release

ROOT="/Library/Application Support/FocusSprint"
HELPER="/Library/PrivilegedHelperTools/com.focussprint.vaultd"
PLIST="/Library/LaunchDaemons/com.focussprint.vaultd.plist"

echo "Installing (administrator password required)…"
sudo -v
sudo rm -rf "/Applications/YoungWonks Focus.app" /Applications/FocusSprint.app
sudo cp -R "build/YoungWonks Focus.app" "/Applications/YoungWonks Focus.app"
sudo chown -R root:wheel "/Applications/YoungWonks Focus.app"

# Only the two drop folders are made here. The helper creates each Mac login's own area, closed to other logins.
sudo mkdir -p /Library/PrivilegedHelperTools "$ROOT/inbox" "$ROOT/requests" "$ROOT/users"
sudo install -m 755 -o root -g wheel build/focussprint-vaultd "$HELPER"
sudo chown root:wheel "$ROOT" "$ROOT/inbox" "$ROOT/requests" "$ROOT/users"
sudo chmod 755 "$ROOT" "$ROOT/users"
sudo chmod 1777 "$ROOT/inbox" "$ROOT/requests"

sudo tee "$PLIST" >/dev/null <<PLISTEOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>com.focussprint.vaultd</string>
    <key>ProgramArguments</key><array><string>$HELPER</string></array>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key><true/>
    <key>StandardOutPath</key><string>/var/log/focussprint-vaultd.log</string>
    <key>StandardErrorPath</key><string>/var/log/focussprint-vaultd.log</string>
</dict>
</plist>
PLISTEOF
sudo chown root:wheel "$PLIST"
sudo chmod 644 "$PLIST"
# Start the app at login for every user and restart it if it is quit, so the day is always tracked.
AGENT="/Library/LaunchAgents/com.focussprint.app.plist"
sudo tee "$AGENT" >/dev/null <<AGENTEOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>com.focussprint.app</string>
    <key>ProgramArguments</key><array><string>/Applications/YoungWonks Focus.app/Contents/MacOS/FocusSprint</string></array>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key><true/>
    <key>LimitLoadToSessionType</key><string>Aqua</string>
    <key>AssociatedBundleIdentifiers</key><string>com.focussprint.app</string>
</dict>
</plist>
AGENTEOF
sudo chown root:wheel "$AGENT"
sudo chmod 644 "$AGENT"

sudo launchctl bootout system/com.focussprint.vaultd 2>/dev/null || true
sudo launchctl bootstrap system "$PLIST"

echo
echo "Done. Next:"
echo "  1. On the website, open Computers and get a code. Open the app in any login here and type it under Account."
echo "  2. Each other Mac login on this computer: assign it on the website, or let a kid pick their profile in the app."
echo "  3. Make sure each kid's Mac login is a Standard account (System Settings > Users & Groups)."
echo "  4. In each login, grant Screen Recording when the app asks."
