#!/bin/bash
# Builds build/YoungWonksFocus.pkg: the installer a parent downloads and runs on their child's Mac.
#
# With nothing set it makes an unsigned package, good for your own Macs (right-click > Open to get past Gatekeeper).
# For a package other families can simply double-click, set all three (needs a paid Apple Developer account):
#   DEVELOPER_ID_APP="Developer ID Application: Your Name (TEAMID)"
#   DEVELOPER_ID_INSTALLER="Developer ID Installer: Your Name (TEAMID)"
#   NOTARY_PROFILE=<name saved with: xcrun notarytool store-credentials>
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION="${VERSION:-0.2.0}"
scripts/bundle.sh release

STAGE="build/pkgroot"; SCRIPTS="build/pkgscripts"
rm -rf "$STAGE" "$SCRIPTS" build/YoungWonksFocus.pkg
mkdir -p "$STAGE/Applications" "$STAGE/Library/PrivilegedHelperTools" "$STAGE/Library/LaunchDaemons" "$STAGE/Library/LaunchAgents" "$SCRIPTS"
cp -R "build/YoungWonks Focus.app" "$STAGE/Applications/"
cp build/focussprint-vaultd "$STAGE/Library/PrivilegedHelperTools/com.focussprint.vaultd"

cat > "$STAGE/Library/LaunchDaemons/com.focussprint.vaultd.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>com.focussprint.vaultd</string>
    <key>ProgramArguments</key><array><string>/Library/PrivilegedHelperTools/com.focussprint.vaultd</string></array>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key><true/>
    <key>StandardOutPath</key><string>/var/log/focussprint-vaultd.log</string>
    <key>StandardErrorPath</key><string>/var/log/focussprint-vaultd.log</string>
</dict>
</plist>
PLIST
cat > "$STAGE/Library/LaunchAgents/com.focussprint.app.plist" <<'PLIST'
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
PLIST

# Runs as root after the files are in place. An existing link to a parent account is left alone on upgrade.
cat > "$SCRIPTS/postinstall" <<'POST'
#!/bin/bash
ROOT="/Library/Application Support/FocusSprint"
# Only the two drop folders are made here. The helper creates each Mac login's own area, closed to other logins.
mkdir -p "$ROOT/inbox" "$ROOT/requests" "$ROOT/users"
chown root:wheel "$ROOT" "$ROOT/inbox" "$ROOT/requests" "$ROOT/users"
chown -R root:wheel "/Applications/YoungWonks Focus.app" /Library/PrivilegedHelperTools/com.focussprint.vaultd
chmod 755 "$ROOT" "$ROOT/users"
chmod 1777 "$ROOT/inbox" "$ROOT/requests"
chmod 755 /Library/PrivilegedHelperTools/com.focussprint.vaultd
chmod 644 /Library/LaunchDaemons/com.focussprint.vaultd.plist /Library/LaunchAgents/com.focussprint.app.plist
launchctl bootout system/com.focussprint.vaultd 2>/dev/null || true
launchctl bootstrap system /Library/LaunchDaemons/com.focussprint.vaultd.plist
# Start the app for whoever is logged in now; at every later login it starts by itself.
CONSOLE_UID=$(stat -f %u /dev/console)
if [ "$CONSOLE_UID" != "0" ]; then
    launchctl bootout "gui/$CONSOLE_UID/com.focussprint.app" 2>/dev/null || true
    launchctl bootstrap "gui/$CONSOLE_UID" /Library/LaunchAgents/com.focussprint.app.plist 2>/dev/null || true
fi
exit 0
POST
chmod +x "$SCRIPTS/postinstall"

SIGN=()
[ -n "${DEVELOPER_ID_INSTALLER:-}" ] && SIGN=(--sign "$DEVELOPER_ID_INSTALLER" --timestamp)
pkgbuild --root "$STAGE" --scripts "$SCRIPTS" --identifier com.focussprint.pkg --version "$VERSION" \
         --install-location / --ownership recommended --filter '/\._[^/]*$' --filter '\.DS_Store$' ${SIGN[@]+"${SIGN[@]}"} build/YoungWonksFocus.pkg

if [ -n "${NOTARY_PROFILE:-}" ] && [ -n "${DEVELOPER_ID_INSTALLER:-}" ]; then
    xcrun notarytool submit build/YoungWonksFocus.pkg --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple build/YoungWonksFocus.pkg
    echo "Notarised: build/YoungWonksFocus.pkg can be downloaded and opened on any Mac."
else
    echo "Built build/YoungWonksFocus.pkg (not notarised: other people's Macs will warn before opening it)."
fi
