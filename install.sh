#!/bin/bash
# Claude & Codex 사용량 배터리 위젯 — 설치 스크립트
set -e
cd "$(dirname "$0")"

echo "🔋 Claude & Codex Usage Battery — 설치"
echo "────────────────────────────────────"

# 1) bun (필수)
if ! command -v bun >/dev/null 2>&1; then
  echo "❌ bun이 없습니다. 먼저 설치하세요:"
  echo "   curl -fsSL https://bun.sh/install | bash"
  exit 1
fi
BUN=$(command -v bun)
echo "✅ bun: $BUN"

# 2) SwiftBar (필수)
if [ ! -d "/Applications/SwiftBar.app" ]; then
  echo "❌ SwiftBar가 없습니다. 먼저 설치하세요:"
  echo "   brew install swiftbar"
  exit 1
fi
echo "✅ SwiftBar"

# 3) ccusage (선택 — 없어도 배터리는 정상. 드롭다운의 비용/모델별 상세에만 사용)
if command -v ccusage >/dev/null 2>&1 || [ -x "$HOME/.bun/bin/ccusage" ]; then
  echo "✅ ccusage (드롭다운 비용 상세 표시됨)"
else
  echo "ⓘ  ccusage 없음 — 배터리 정상, 드롭다운 비용 상세만 생략 (원하면: bun add -g ccusage)"
fi

# 4) codex (선택 — 없으면 Codex 배터리는 안 뜨고 Claude만 표시)
if command -v codex >/dev/null 2>&1; then
  echo "✅ codex CLI (Codex 배터리 표시됨)"
else
  echo "ⓘ  codex CLI 없음 — Claude 배터리만 표시됩니다"
fi

# 5) 플러그인 배치 (shebang을 이 환경의 bun 절대경로로 — SwiftBar는 GUI라 PATH가 제한적)
PLUGIN_DIR="${SWIFTBAR_PLUGIN_DIR:-$HOME/.swiftbar-plugins}"
mkdir -p "$PLUGIN_DIR"
sed "1s|.*|#!$BUN|" claude-codex-usage.2m.js > "$PLUGIN_DIR/claude-codex-usage.2m.js"
chmod +x "$PLUGIN_DIR/claude-codex-usage.2m.js"
# self-update 스크립트를 dot 파일로 배치 (SwiftBar가 플러그인으로 오인 실행하지 않도록)
cp ccb-update.sh "$PLUGIN_DIR/.ccb-update.sh"
chmod +x "$PLUGIN_DIR/.ccb-update.sh"
echo "✅ 플러그인 배치: $PLUGIN_DIR"

# 6) SwiftBar에 폴더 지정 + 실행
BID=$(defaults read /Applications/SwiftBar.app/Contents/Info CFBundleIdentifier 2>/dev/null || echo "com.ameba.SwiftBar")
defaults write "$BID" PluginDirectory -string "$PLUGIN_DIR"
# 과거에 이 플러그인을 SwiftBar 메뉴에서 껐거나 .bak 오염 등으로 DisabledPlugins에 남아 있으면
# 파일이 멀쩡해도 메뉴바에 안 뜬다 → 재설치 시 비활성 목록에서 제거해 확실히 켠다.
if defaults read "$BID" DisabledPlugins 2>/dev/null | grep -q "claude-codex-usage.2m.js"; then
  REMAIN=$(defaults read "$BID" DisabledPlugins 2>/dev/null \
    | grep -oE '"[^"]+"' | tr -d '"' | grep -v "^claude-codex-usage.2m.js$" || true)
  defaults delete "$BID" DisabledPlugins 2>/dev/null || true
  if [ -n "$REMAIN" ]; then
    while IFS= read -r p; do [ -n "$p" ] && defaults write "$BID" DisabledPlugins -array-add "$p"; done <<< "$REMAIN"
  fi
  echo "ⓘ  플러그인이 SwiftBar 비활성 목록에 있어 자동으로 다시 켰습니다"
fi
# 7) launchd로 SwiftBar를 KeepAlive 관리 → 재부팅·절전복귀·"크래시"로 죽어도 즉시 자동 부활.
#    (SwiftBar 앱은 가끔 스스로 꺼지는데, 로그인 항목은 로그인 시 1회뿐이라 크래시엔 무력하다.
#     KeepAlive는 프로세스가 사라지는 즉시 다시 띄우므로 "자꾸 꺼짐 + 재실행 번거로움"을 함께 해결.)
SWIFTBAR_QUIT=$(osascript -e 'tell application "SwiftBar" to quit' 2>/dev/null || true)
sleep 1
# 중복 실행/등록 방지: 기존 로그인 항목이 있으면 제거하고 launchd로 일원화
osascript -e 'tell application "System Events" to delete (every login item whose name contains "SwiftBar")' >/dev/null 2>&1 || true
LABEL="com.dennykim.claude-codex-battery"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
mkdir -p "$HOME/Library/LaunchAgents"
cat > "$PLIST" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key>
  <array><string>/Applications/SwiftBar.app/Contents/MacOS/SwiftBar</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ProcessType</key><string>Interactive</string>
</dict>
</plist>
PL
launchctl bootout "gui/$(id -u)/$LABEL" >/dev/null 2>&1 || true
if launchctl bootstrap "gui/$(id -u)" "$PLIST" 2>/dev/null; then
  echo "✅ launchd 자동부활 등록 — 꺼져도(크래시·절전·재부팅) 즉시 다시 뜹니다"
else
  open -a SwiftBar
  echo "ⓘ  launchd 등록 실패 — SwiftBar만 실행했습니다 (메뉴에서 'Launch at Login' 권장)"
fi

echo "────────────────────────────────────"
echo "✅ 완료! 메뉴바 오른쪽에 배터리가 뜹니다."
echo "   갱신 주기: 2분 (파일명 .2m. 을 .1m. .5m. 등으로 바꾸면 조정)"
echo "   꺼져도 자동으로 다시 뜹니다. 완전히 끄려면:"
echo "   launchctl bootout gui/\$(id -u)/$LABEL && osascript -e 'quit app \"SwiftBar\"'"
