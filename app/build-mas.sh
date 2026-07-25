#!/bin/bash
# Mac App Store build — sandboxed variant (MAS_BUILD flag), local test signing.
# For submission, re-sign with "Apple Distribution" + package with productbuild.
set -e
cd "$(dirname "$0")"
APP="ClaudeCodexBattery-MAS.app"
NAME="ClaudeCodexBattery"
BID="com.dennykim.claude-codex-battery-app"
VERSION="$(cat ../VERSION)"

echo "🔨 Compiling (MAS_BUILD)…"
rm -rf "$APP" "$NAME"
swiftc -O -D MAS_BUILD *.swift -o "$NAME" -framework Cocoa -framework ServiceManagement

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
  <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
</dict>
</plist>
PLIST

# Local test: ad-hoc signing WITH the sandbox entitlements (sandbox is enforced)
codesign --force --entitlements mas.entitlements --sign - "$APP"
echo "✅ MAS build (sandboxed, ad-hoc): $(pwd)/$APP (v$VERSION)"
