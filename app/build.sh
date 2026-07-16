#!/bin/bash
# 네이티브 메뉴바 앱 빌드 — swiftc로 컴파일해 .app 번들 구성 (Xcode 프로젝트 불필요)
set -e
cd "$(dirname "$0")"
APP="ClaudeCodexBattery.app"
NAME="ClaudeCodexBattery"
BID="com.dennykim.claude-codex-battery-app"
VERSION="$(cat ../VERSION)"

echo "🔨 컴파일…"
rm -rf "$APP" "$NAME"
swiftc -O *.swift -o "$NAME" -framework Cocoa -framework ServiceManagement

echo "📦 .app 번들 구성…"
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

# 로컬 실행용 ad-hoc 서명 (무료 — 자기 맥에서 Gatekeeper 통과. 공개 배포는 release.sh)
codesign --force --deep --sign - "$APP" 2>/dev/null && echo "✅ ad-hoc 서명 완료" || echo "ⓘ ad-hoc 서명 생략"

echo "✅ 빌드 완료: $(pwd)/$APP (v$VERSION)"
