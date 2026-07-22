#!/bin/bash
# Claude & Codex Usage Battery — self-update
# Called from the widget dropdown's "🆕 Update". Downloads the latest script and replaces it in place.
set -e
RAW="https://raw.githubusercontent.com/dennykim123/claude-codex-battery/main"
DEST_DIR="$(cd "$(dirname "$0")" && pwd)"
DEST="$DEST_DIR/claude-codex-usage.2m.js"
BUN="$(command -v bun || echo "$HOME/.bun/bin/bun")"
TMP="$(mktemp)"

echo "Downloading the latest version..."
curl -fsSL --max-time 20 "$RAW/claude-codex-usage.2m.js" -o "$TMP"

# Minimal integrity check — did we get a proper download (shebang + core function present)
if ! head -1 "$TMP" | grep -q "bun" || ! grep -q "renderBatteryImage" "$TMP"; then
  echo "❌ Download verification failed — aborting update."
  rm -f "$TMP"
  exit 1
fi

# Back up the previous version then replace (rewrite shebang to this environment's bun path)
[ -f "$DEST" ] && cp "$DEST" "$DEST.bak"
sed "1s|.*|#!$BUN|" "$TMP" > "$DEST"
chmod +x "$DEST"
rm -f "$TMP"

# Clear the version cache + refresh SwiftBar
rm -f "$HOME/.claude/swiftbar/.update-check.json" 2>/dev/null || true
open "swiftbar://refreshallplugins" 2>/dev/null || true

echo "✅ Updated to the latest version. (previous: $DEST.bak)"
