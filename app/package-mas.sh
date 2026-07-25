#!/bin/bash
# Mac App Store packaging — Apple Distribution signing + provisioning profile + installer pkg.
# Prereqs in Keychain: "Apple Distribution: ..." and "3rd Party Mac Developer Installer" /
# "Mac Installer Distribution" certificates; profile path passed as $1.
set -e
cd "$(dirname "$0")"
APP="ClaudeCodexBattery-MAS.app"
VERSION="$(cat ../VERSION)"
PROFILE="${1:?usage: ./package-mas.sh <path-to-provisioning-profile>}"

./build-mas.sh

echo "📎 Embedding provisioning profile…"
cp "$PROFILE" "$APP/Contents/embedded.provisionprofile"

DIST_ID=$(security find-identity -v -p codesigning | grep -m1 "Apple Distribution" | sed 's/.*"\(.*\)"/\1/')
INST_ID=$(security find-identity -v | grep -m1 -E "Mac Installer Distribution|3rd Party Mac Developer Installer" | sed 's/.*"\(.*\)"/\1/')
[ -z "$DIST_ID" ] && { echo "❌ Apple Distribution certificate not in Keychain"; exit 1; }
[ -z "$INST_ID" ] && { echo "❌ Mac Installer Distribution certificate not in Keychain"; exit 1; }
echo "🔑 App signing:   $DIST_ID"
echo "🔑 Pkg signing:   $INST_ID"

echo "✍️  Signing with sandbox entitlements…"
codesign --force --options runtime --timestamp --entitlements mas.entitlements --sign "$DIST_ID" "$APP"
codesign --verify --strict --verbose=2 "$APP"

echo "📦 Building installer pkg…"
PKG="ClaudeCodexBattery-MAS-v${VERSION}.pkg"
rm -f "$PKG"
productbuild --component "$APP" /Applications --sign "$INST_ID" "$PKG"
echo "✅ Ready to upload with Transporter: $(pwd)/$PKG"
