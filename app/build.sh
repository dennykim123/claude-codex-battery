#!/bin/bash
# Build the native menu bar app — compile with swiftc and assemble the .app bundle (no Xcode project needed)
set -e
cd "$(dirname "$0")"
APP="ClaudeCodexBattery.app"
NAME="ClaudeCodexBattery"
BID="com.dennykim.claude-codex-battery-app"
VERSION="$(cat ../VERSION)"

echo "🔨 Compiling…"
rm -rf "$APP" "$NAME"
swiftc -O *.swift -o "$NAME" -framework Cocoa -framework ServiceManagement

echo "📦 Assembling .app bundle…"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
mv "$NAME" "$APP/Contents/MacOS/$NAME"
cp AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>$NAME</string>
  <key>CFBundleIdentifier</key><string>$BID</string>
  <key>CFBundleName</key><string>Claude Codex Battery</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSUIElement</key><true/>
  <key>LSMinimumSystemVersion</key><string>12.0</string>
</dict>
</plist>
PLIST

# Ad-hoc signing for local use (free — passes Gatekeeper on your own Mac. Use release.sh for public distribution)
codesign --force --deep --sign - "$APP" 2>/dev/null && echo "✅ ad-hoc signing complete" || echo "ⓘ skipped ad-hoc signing"

echo "✅ Build complete: $(pwd)/$APP (v$VERSION)"
