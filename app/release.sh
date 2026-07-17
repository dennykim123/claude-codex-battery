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

echo "💿 DMG 생성… (사람용 — 배경 화살표 + 드래그 설치 레이아웃)"
DMG="ClaudeCodexBattery-v${VERSION}.dmg"
VOLNAME="Claude Codex Battery"
STAGE=$(mktemp -d)
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
mkdir "$STAGE/.background"
cp dmg-background.png "$STAGE/.background/bg.png"
rm -f "$DMG" rw-tmp.dmg
# 같은 이름의 볼륨이 남아 있으면 새 볼륨이 "이름 1"로 붙어 Finder 스크립트가 엉뚱한 디스크를 만짐
while [ -d "/Volumes/$VOLNAME" ]; do hdiutil detach "/Volumes/$VOLNAME" >/dev/null 2>&1 || break; done
[ -d "/Volumes/$VOLNAME 1" ] && hdiutil detach "/Volumes/$VOLNAME 1" >/dev/null 2>&1
hdiutil create -volname "$VOLNAME" -srcfolder "$STAGE" -ov -format UDRW rw-tmp.dmg >/dev/null
rm -rf "$STAGE"
MNT=$(hdiutil attach rw-tmp.dmg -nobrowse | grep Volumes | awk -F'\t' '{print $NF}')
# Finder로 아이콘 뷰·배경·좌표 저장 (.DS_Store) — 최초 1회 자동화 권한 허용 필요할 수 있음
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
echo "📤 DMG 공증 (완료까지 대기)…"
xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$DMG"

echo "✅ 완료: $(pwd)/$ZIP + $(pwd)/$DMG (둘 다 Gatekeeper 통과)"
