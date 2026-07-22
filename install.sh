#!/bin/bash
# Claude & Codex usage battery widget — install script
set -e
cd "$(dirname "$0")"

echo "🔋 Claude & Codex Usage Battery — Install"
echo "────────────────────────────────────"

# 1) bun (required)
if ! command -v bun >/dev/null 2>&1; then
  echo "❌ bun not found. Install it first:"
  echo "   curl -fsSL https://bun.sh/install | bash"
  exit 1
fi
BUN=$(command -v bun)
echo "✅ bun: $BUN"

# 2) SwiftBar (required)
if [ ! -d "/Applications/SwiftBar.app" ]; then
  echo "❌ SwiftBar not found. Install it first:"
  echo "   brew install swiftbar"
  exit 1
fi
echo "✅ SwiftBar"

# 3) ccusage (optional — battery works fine without it; used only for cost/model details in the dropdown)
if command -v ccusage >/dev/null 2>&1 || [ -x "$HOME/.bun/bin/ccusage" ]; then
  echo "✅ ccusage (dropdown cost details enabled)"
else
  echo "ⓘ  ccusage not found — battery works fine, dropdown cost details are just skipped (install with: bun add -g ccusage)"
fi

# 4) codex (optional — without it, only the Claude battery shows, no Codex battery)
if command -v codex >/dev/null 2>&1; then
  echo "✅ codex CLI (Codex battery enabled)"
else
  echo "ⓘ  codex CLI not found — only the Claude battery will be shown"
fi

# 5) Deploy the plugin (rewrite shebang to this environment's absolute bun path — SwiftBar is a GUI app with a limited PATH)
PLUGIN_DIR="${SWIFTBAR_PLUGIN_DIR:-$HOME/.swiftbar-plugins}"
mkdir -p "$PLUGIN_DIR"
sed "1s|.*|#!$BUN|" claude-codex-usage.2m.js > "$PLUGIN_DIR/claude-codex-usage.2m.js"
chmod +x "$PLUGIN_DIR/claude-codex-usage.2m.js"
# Deploy the self-update script as a dotfile (so SwiftBar doesn't mistake it for a plugin and run it)
cp ccb-update.sh "$PLUGIN_DIR/.ccb-update.sh"
chmod +x "$PLUGIN_DIR/.ccb-update.sh"
echo "✅ Plugin deployed: $PLUGIN_DIR"

# 6) Point SwiftBar at the folder + launch
BID=$(defaults read /Applications/SwiftBar.app/Contents/Info CFBundleIdentifier 2>/dev/null || echo "com.ameba.SwiftBar")
defaults write "$BID" PluginDirectory -string "$PLUGIN_DIR"
# If this plugin was previously disabled from the SwiftBar menu, or got stuck in DisabledPlugins
# due to .bak contamination etc, it won't show in the menu bar even if the file is fine → on reinstall, remove it from the disabled list to make sure it's enabled.
if defaults read "$BID" DisabledPlugins 2>/dev/null | grep -q "claude-codex-usage.2m.js"; then
  REMAIN=$(defaults read "$BID" DisabledPlugins 2>/dev/null \
    | grep -oE '"[^"]+"' | tr -d '"' | grep -v "^claude-codex-usage.2m.js$" || true)
  defaults delete "$BID" DisabledPlugins 2>/dev/null || true
  if [ -n "$REMAIN" ]; then
    while IFS= read -r p; do [ -n "$p" ] && defaults write "$BID" DisabledPlugins -array-add "$p"; done <<< "$REMAIN"
  fi
  echo "ⓘ  Plugin was in SwiftBar's disabled list — automatically re-enabled it"
fi
# 7) Manage SwiftBar with launchd KeepAlive → instantly auto-revives after reboot, sleep/wake, or a "crash".
#    (SwiftBar occasionally quits on its own, and a login item only fires once at login, so it can't handle a crash.
#     KeepAlive relaunches the process the moment it disappears, solving both "keeps quitting" and "annoying to relaunch".)
SWIFTBAR_QUIT=$(osascript -e 'tell application "SwiftBar" to quit' 2>/dev/null || true)
sleep 1
# Prevent duplicate runs/registration: remove any existing login item and consolidate on launchd
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
  echo "✅ launchd auto-revive registered — comes right back even if it dies (crash, sleep, reboot)"
else
  open -a SwiftBar
  echo "ⓘ  launchd registration failed — launched SwiftBar only (recommend enabling 'Launch at Login' from its menu)"
fi

echo "────────────────────────────────────"
echo "✅ Done! The battery now shows on the right side of the menu bar."
echo "   Refresh interval: 2 minutes (adjust by renaming .2m. to .1m., .5m., etc.)"
echo "   It auto-revives even when killed. To fully disable it:"
echo "   launchctl bootout gui/\$(id -u)/$LABEL && osascript -e 'quit app \"SwiftBar\"'"
