#!/bin/bash
# Builds build/YoungWonksFocus.pkg: the installer a person downloads and runs on a Mac.
#
# With nothing set it makes an unsigned package, good for your own Macs (right-click > Open to get past Gatekeeper).
# For a package anyone can simply double-click, and that installed Macs will accept as an automatic update, set all
# three (they need a paid Apple Developer account):
#   DEVELOPER_ID_APP="Developer ID Application: Your Name (TEAMID)"
#   DEVELOPER_ID_INSTALLER="Developer ID Installer: Your Name (TEAMID)"
#   NOTARY_PROFILE=<name saved with: xcrun notarytool store-credentials>
set -euo pipefail
cd "$(dirname "$0")/.."
export VERSION="${VERSION:-$(cat VERSION)}"
scripts/bundle.sh release

STAGE="build/pkgroot"; SCRIPTS="build/pkgscripts"; PARTS="build/pkgparts"; OUT="build/YoungWonksFocus.pkg"
rm -rf "$STAGE" "$SCRIPTS" "$PARTS" "$OUT"
mkdir -p "$STAGE/Applications" "$STAGE/Library/PrivilegedHelperTools" "$STAGE/Library/LaunchDaemons" "$STAGE/Library/LaunchAgents" "$SCRIPTS" "$PARTS"
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

# Runs as root after the files are in place, on a first install and on every update.
# A computer's link to its household, and everything already recorded, are left alone.
cat > "$SCRIPTS/postinstall" <<'POST'
#!/bin/bash
ROOT="/Library/Application Support/FocusSprint"
# Only the two drop folders are made here. The helper creates each Mac login's own area, closed to other logins.
mkdir -p "$ROOT/inbox" "$ROOT/requests" "$ROOT/users"
chown root:wheel "$ROOT" "$ROOT/inbox" "$ROOT/requests" "$ROOT/users"
chown -R root:wheel "/Applications/YoungWonks Focus.app" /Library/PrivilegedHelperTools/com.focussprint.vaultd
chmod 755 "$ROOT" "$ROOT/users" /Library/PrivilegedHelperTools/com.focussprint.vaultd
chmod 1777 "$ROOT/inbox" "$ROOT/requests"
chmod 644 /Library/LaunchDaemons/com.focussprint.vaultd.plist /Library/LaunchAgents/com.focussprint.app.plist

# Restart the helper on the new version. During an automatic update the old helper is what asked for this
# install; this script is run by the system's installer service, so stopping the helper does not stop it.
launchctl bootout system/com.focussprint.vaultd 2>/dev/null || true
for i in 1 2 3 4 5 6 7 8 9 10; do launchctl print system/com.focussprint.vaultd >/dev/null 2>&1 || break; sleep 1; done
launchctl bootstrap system /Library/LaunchDaemons/com.focussprint.vaultd.plist 2>/dev/null \
    || { sleep 3; launchctl bootstrap system /Library/LaunchDaemons/com.focussprint.vaultd.plist 2>/dev/null; } \
    || launchctl kickstart -k system/com.focussprint.vaultd 2>/dev/null || true

# Restart the app for everyone logged in right now; at every later login it starts by itself.
for uid in $(ps -axo uid=,comm= | awk '$2 ~ /loginwindow$/ {print $1}' | sort -u); do
    [ "$uid" = "0" ] && continue
    launchctl bootout "gui/$uid/com.focussprint.app" 2>/dev/null || true
    for i in 1 2 3 4 5; do launchctl print "gui/$uid/com.focussprint.app" >/dev/null 2>&1 || break; sleep 1; done
    launchctl bootstrap "gui/$uid" /Library/LaunchAgents/com.focussprint.app.plist 2>/dev/null \
        || launchctl kickstart -k "gui/$uid/com.focussprint.app" 2>/dev/null || true
done
exit 0
POST
chmod +x "$SCRIPTS/postinstall"

# By default the installer "relocates" an app: if another copy with the same identifier is anywhere on the Mac
# (a download, a build folder), it updates that copy and puts nothing in Applications. Always install in place.
pkgbuild --analyze --root "$STAGE" "$PARTS/components.plist" >/dev/null
/usr/libexec/PlistBuddy -c "Set :0:BundleIsRelocatable false" -c "Set :0:BundleIsVersionChecked false" "$PARTS/components.plist"
pkgbuild --root "$STAGE" --component-plist "$PARTS/components.plist" --scripts "$SCRIPTS" --identifier com.focussprint.pkg --version "$VERSION" \
         --install-location / --ownership recommended --filter '\.DS_Store$' "$PARTS/core.pkg" >/dev/null

# The installer's own screens: what it does before, and the two steps left after.
cat > "$PARTS/distribution.xml" <<DIST
<?xml version="1.0" encoding="utf-8"?>
<installer-gui-script minSpecVersion="2">
    <title>YoungWonks Focus</title>
    <welcome file="welcome.html" mime-type="text/html"/>
    <conclusion file="conclusion.html" mime-type="text/html"/>
    <options customize="never" require-scripts="false" hostArchitectures="arm64,x86_64"/>
    <domains enable_localSystem="true" enable_anywhere="false" enable_currentUserHome="false"/>
    <volume-check><allowed-os-versions><os-version min="14.0"/></allowed-os-versions></volume-check>
    <choices-outline><line choice="core"/></choices-outline>
    <choice id="core" visible="false"><pkg-ref id="com.focussprint.pkg"/></choice>
    <pkg-ref id="com.focussprint.pkg" version="$VERSION" onConclusion="none">core.pkg</pkg-ref>
</installer-gui-script>
DIST

SIGN=()
[ -n "${DEVELOPER_ID_INSTALLER:-}" ] && SIGN=(--sign "$DEVELOPER_ID_INSTALLER" --timestamp)
productbuild --distribution "$PARTS/distribution.xml" --package-path "$PARTS" --resources installer \
             ${SIGN[@]+"${SIGN[@]}"} "$OUT" >/dev/null

if [ -n "${NOTARY_PROFILE:-}" ] && [ -n "${DEVELOPER_ID_INSTALLER:-}" ]; then
    xcrun notarytool submit "$OUT" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$OUT"
    spctl --assess --type install -vv "$OUT"
    echo "Built $OUT $VERSION: signed and notarised. It can be downloaded and opened on any Mac."
else
    echo "Built $OUT $VERSION: NOT notarised. Other people's Macs will refuse it, and installed Macs will not accept it as an update."
fi
