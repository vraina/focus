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

sudo mkdir -p /Library/PrivilegedHelperTools "$ROOT/inbox" "$ROOT/vault/sprints" "$ROOT/vault/pending"
sudo install -m 755 -o root -g wheel build/focussprint-vaultd "$HELPER"
sudo chown -R root:wheel "$ROOT"
sudo chmod 755 "$ROOT" "$ROOT/vault" "$ROOT/vault/sprints" "$ROOT/vault/pending"
sudo chmod 1777 "$ROOT/inbox"

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
echo "  1. Make sure the teen's Mac login is a Standard account (System Settings > Users & Groups)."
echo "  2. Log in as the teen, open YoungWonks Focus, and grant Screen Recording when asked."
echo "  3. In Parent settings, paste the Atlas connection string and save."
