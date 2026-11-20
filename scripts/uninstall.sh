#!/bin/bash
# Removes the app and helper. The vault (recorded sprints) is kept unless you pass --purge.
set -euo pipefail
sudo launchctl bootout system/com.focussprint.vaultd 2>/dev/null || true
sudo rm -f /Library/LaunchAgents/com.focussprint.app.plist /Library/LaunchDaemons/com.focussprint.vaultd.plist /Library/PrivilegedHelperTools/com.focussprint.vaultd
sudo rm -rf "/Applications/YoungWonks Focus.app" /Applications/FocusSprint.app
if [ "${1:-}" = "--purge" ]; then sudo rm -rf "/Library/Application Support/FocusSprint"; fi
echo "Removed."
