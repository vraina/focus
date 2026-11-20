#!/bin/bash
# Builds "YoungWonks Focus.app" into ./build. Usage: scripts/bundle.sh [debug|release]
set -euo pipefail
cd "$(dirname "$0")/.."
CONFIG="${1:-release}"
swift build -c "$CONFIG"
BIN="$(swift build -c "$CONFIG" --show-bin-path)"
APP="build/YoungWonks Focus.app"
rm -rf build/FocusSprint.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN/FocusSprint" "$APP/Contents/MacOS/FocusSprint"
cp "$BIN/focussprint-vaultd" build/focussprint-vaultd
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>com.focussprint.app</string>
    <key>CFBundleName</key><string>YoungWonks Focus</string>
    <key>CFBundleDisplayName</key><string>YoungWonks Focus</string>
    <key>CFBundleExecutable</key><string>FocusSprint</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>NSAppleEventsUsageDescription</key>
    <string>YoungWonks Focus reads the address of the active browser tab during a sprint, to tell work sites from distractions.</string>
</dict>
</plist>
PLIST
# A real signing identity keeps the Screen Recording permission across rebuilds; ad-hoc signing resets it.
IDENTITY="${SIGN_ID:-$(security find-identity -v -p codesigning 2>/dev/null | awk 'NR==1 && $2 ~ /^[0-9A-F]{40}$/ {print $2}')}"
codesign --force --sign "${IDENTITY:--}" --identifier com.focussprint.vaultd build/focussprint-vaultd
codesign --force --sign "${IDENTITY:--}" "$APP"
echo "Built $APP ($CONFIG, signed with ${IDENTITY:-ad-hoc})"
