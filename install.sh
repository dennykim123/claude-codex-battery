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
cp ccb-limits-cache.js "$PLUGIN_DIR/.ccb-limits-cache.js"
echo "✅ 플러그인 배치: $PLUGIN_DIR"

# 6) Claude rate-limit 캐시 훅 연결 (C5·CW 배터리의 데이터 소스)
#    Claude Code는 rate limit을 statusline stdin으로만 노출하므로,
#    settings.json의 statusLine에 캐시 훅을 끼워 넣는다 (기존 statusline은 그대로 래핑).
if [ -d "$HOME/.claude" ]; then
  if "$BUN" "$PLUGIN_DIR/.ccb-limits-cache.js" --install; then
    echo "✅ Claude rate-limit 캐시 훅 연결 — 다음 Claude Code 세션부터 C5·CW가 실제 한도로 표시"
  else
    echo "⚠️  statusline 훅 연결 실패 — ~/.claude/settings.json 을 확인하세요 (C 배터리가 안 뜰 수 있음)"
  fi
else
  echo "ⓘ  ~/.claude 없음 — Claude Code 미사용이면 C 배터리는 표시되지 않습니다"
fi

# 7) SwiftBar에 폴더 지정 + 실행
BID=$(defaults read /Applications/SwiftBar.app/Contents/Info CFBundleIdentifier 2>/dev/null || echo "com.ameba.SwiftBar")
defaults write "$BID" PluginDirectory -string "$PLUGIN_DIR"
open -a SwiftBar

# 8) 로그인 항목 등록 → 재부팅/재로그인 후에도 자동으로 다시 뜸
if osascript -e 'tell application "System Events" to get the name of every login item' 2>/dev/null | grep -qi swiftbar; then
  echo "✅ 로그인 항목에 이미 등록됨 (재부팅 후 자동 실행)"
else
  if osascript -e 'tell application "System Events" to make login item at end with properties {path:"/Applications/SwiftBar.app", hidden:false}' >/dev/null 2>&1; then
    echo "✅ 로그인 항목 등록 (재부팅 후 자동 실행)"
  else
    echo "ⓘ  로그인 항목 자동 등록 실패 — SwiftBar 메뉴에서 'Launch at Login'을 켜주세요"
  fi
fi

echo "────────────────────────────────────"
echo "✅ 완료! 메뉴바 오른쪽에 배터리가 뜹니다."
echo "   갱신 주기: 2분 (파일명 .2m. 을 .1m. .5m. 등으로 바꾸면 조정)"
echo "   재부팅 후에도 자동으로 다시 뜹니다."
