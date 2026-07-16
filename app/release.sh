#!/bin/bash
# 공증 배포 빌드 — Developer ID 서명 + notarization + staple + 배포용 zip
# 사전 준비(1회): ① 키체인에 "Developer ID Application" 인증서
#                ② xcrun notarytool store-credentials ccb-notary --apple-id <애플ID> --team-id <팀ID> --password <앱암호>
set -e
cd "$(dirname "$0")"
APP="ClaudeCodexBattery.app"
VERSION="$(cat ../VERSION)"
PROFILE="ccb-notary"
ZIP="ClaudeCodexBattery-v${VERSION}.zip"

# 키체인에서 Developer ID Application 인증서 자동 탐색
IDENTITY=$(security find-identity -v -p codesigning | grep -m1 "Developer ID Application" | sed 's/.*"\(.*\)"/\1/')
if [ -z "$IDENTITY" ]; then
  echo "❌ 키체인에 Developer ID Application 인증서가 없습니다."; exit 1
fi
echo "🔑 서명 인증서: $IDENTITY"

./build.sh

echo "✍️  Developer ID 서명 (hardened runtime)…"
codesign --force --options runtime --timestamp --sign "$IDENTITY" "$APP"
codesign --verify --strict --verbose=2 "$APP"

echo "📤 공증 제출 (완료까지 대기)…"
ditto -c -k --keepParent "$APP" "notary-upload.zip"
xcrun notarytool submit "notary-upload.zip" --keychain-profile "$PROFILE" --wait
rm -f notary-upload.zip

echo "📎 공증 티켓 스테이플…"
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"

echo "🗜  배포용 zip 생성… (앱 내 자동 업데이트가 이 zip을 받음)"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"

echo "💿 DMG 생성… (사람용 — 열어서 Applications로 드래그)"
DMG="ClaudeCodexBattery-v${VERSION}.dmg"
STAGE=$(mktemp -d)
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
rm -f "$DMG"
hdiutil create -volname "Claude Codex Battery" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE"
codesign --force --timestamp --sign "$IDENTITY" "$DMG"
echo "📤 DMG 공증 (완료까지 대기)…"
xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$DMG"

echo "✅ 완료: $(pwd)/$ZIP + $(pwd)/$DMG (둘 다 Gatekeeper 통과)"
