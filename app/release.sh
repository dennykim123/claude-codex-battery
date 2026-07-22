#!/bin/bash
# Notarized release build — Developer ID signing + notarization + staple + distribution zip
# One-time setup: (1) "Developer ID Application" certificate in Keychain
#                  (2) xcrun notarytool store-credentials ccb-notary --apple-id <apple-id> --team-id <team-id> --password <app-password>
set -e
cd "$(dirname "$0")"
APP="ClaudeCodexBattery.app"
VERSION="$(cat ../VERSION)"
PROFILE="ccb-notary"
ZIP="ClaudeCodexBattery-v${VERSION}.zip"

# Auto-detect the Developer ID Application certificate from Keychain
IDENTITY=$(security find-identity -v -p codesigning | grep -m1 "Developer ID Application" | sed 's/.*"\(.*\)"/\1/')
if [ -z "$IDENTITY" ]; then
  echo "❌ No Developer ID Application certificate found in Keychain."; exit 1
fi
echo "🔑 Signing identity: $IDENTITY"

./build.sh

echo "✍️  Developer ID signing (hardened runtime)…"
codesign --force --options runtime --timestamp --sign "$IDENTITY" "$APP"
codesign --verify --strict --verbose=2 "$APP"

echo "📤 Submitting for notarization (waiting for completion)…"
ditto -c -k --keepParent "$APP" "notary-upload.zip"
xcrun notarytool submit "notary-upload.zip" --keychain-profile "$PROFILE" --wait
rm -f notary-upload.zip

echo "📎 Stapling notarization ticket…"
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"

echo "🗜  Creating distribution zip… (the app's auto-update downloads this zip)"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"

echo "💿 Creating DMG… (for humans — background arrow + drag-to-install layout)"
DMG="ClaudeCodexBattery-v${VERSION}.dmg"
VOLNAME="Claude Codex Battery"
STAGE=$(mktemp -d)
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
mkdir "$STAGE/.background"
cp dmg-background.png "$STAGE/.background/bg.png"
rm -f "$DMG" rw-tmp.dmg
# If a volume with the same name is still mounted, the new one gets suffixed "name 1" and the Finder script touches the wrong disk
while [ -d "/Volumes/$VOLNAME" ]; do hdiutil detach "/Volumes/$VOLNAME" >/dev/null 2>&1 || break; done
[ -d "/Volumes/$VOLNAME 1" ] && hdiutil detach "/Volumes/$VOLNAME 1" >/dev/null 2>&1
hdiutil create -volname "$VOLNAME" -srcfolder "$STAGE" -ov -format UDRW rw-tmp.dmg >/dev/null
rm -rf "$STAGE"
MNT=$(hdiutil attach rw-tmp.dmg -nobrowse | grep Volumes | awk -F'\t' '{print $NF}')
# Use Finder to save icon view/background/positions (.DS_Store) — may need to grant automation permission the first time
osascript <<OSA
tell application "Finder"
  tell disk "$VOLNAME"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set the bounds of container window to {200, 120, 860, 520}
    set vo to the icon view options of container window
    set arrangement of vo to not arranged
    set icon size of vo to 104
    set text size of vo to 13
    set background picture of vo to file ".background:bg.png"
    set position of item "ClaudeCodexBattery.app" of container window to {165, 185}
    set position of item "Applications" of container window to {495, 185}
    update without registering applications
    delay 1
    close
  end tell
end tell
OSA
sync
hdiutil detach "$MNT" >/dev/null
hdiutil convert rw-tmp.dmg -format UDZO -o "$DMG" >/dev/null
rm -f rw-tmp.dmg
codesign --force --timestamp --sign "$IDENTITY" "$DMG"
echo "📤 Notarizing DMG (waiting for completion)…"
xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$DMG"

echo "✅ Done: $(pwd)/$ZIP + $(pwd)/$DMG (both pass Gatekeeper)"
