#!/bin/bash
# Publishes a new version: builds the signed, notarised installer and attaches it to a GitHub release.
# Installed Macs pick it up by themselves within a few hours; the website's download link always points at the latest.
#
#   1. Put the new number in the VERSION file and commit it.
#   2. DEVELOPER_ID_APP=... DEVELOPER_ID_INSTALLER=... NOTARY_PROFILE=... scripts/release.sh
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION="$(cat VERSION)"
: "${DEVELOPER_ID_APP:?Set DEVELOPER_ID_APP (see README: Releasing)}"
: "${DEVELOPER_ID_INSTALLER:?Set DEVELOPER_ID_INSTALLER (see README: Releasing)}"
: "${NOTARY_PROFILE:?Set NOTARY_PROFILE (see README: Releasing)}"
if [ -n "$(git status --porcelain)" ]; then echo "Commit or stash your changes first, so the release matches what is in git."; exit 1; fi
if gh release view "v$VERSION" >/dev/null 2>&1; then echo "Version $VERSION is already released. Raise the number in VERSION."; exit 1; fi

scripts/package.sh
# Refuse to publish anything a Mac would not accept.
spctl --assess --type install -vv build/YoungWonksFocus.pkg 2>&1 | grep -q "Notarized Developer ID" \
    || { echo "The installer is not notarised; not publishing."; exit 1; }

gh release create "v$VERSION" build/YoungWonksFocus.pkg --title "YoungWonks Focus $VERSION" \
    --notes "Installer for macOS 14 or later. Installed Macs update themselves."
echo "Released $VERSION."
