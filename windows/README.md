# 🔋 Claude & Codex Usage Battery — Windows

Native Windows port of the macOS SwiftBar plugin: **one tray icon, one
dashboard**. The icon shows two slim battery gauges (left Claude, right Codex)
as an at-a-glance signal; clicking it opens a Windows-11-quick-settings-style
acrylic flyout — a dark slate operations panel with uniform metric rows
(label · bullet bar · remaining % in tabular mono numerals · reset countdown),
real service favicons, live/cache/stale status dots, native Segoe Fluent
icons, and a real autostart toggle switch. Bars and numbers animate in
(300 ms ease-out) on open.

Colors: green ≥ 50 % left, amber < 50 %, red ≤ 20 % — same scale as the
macOS widget. The tray tooltip carries the summary ("Claude 28% · Codex 100%
남음"). Data refreshes every 2 minutes.

## Install

```powershell
cd claude-codex-battery\windows
powershell -ExecutionPolicy Bypass -File .\install.ps1
```

That's it — **no runtime, no SDK, no dependencies**. The single C# source file
is compiled with `csc.exe`, which ships inside every Windows 10/11
(.NET Framework), into `%LOCALAPPDATA%\ClaudeCodexBattery\ClaudeCodexBattery.exe`.
The script also registers auto-start at login (per-user, no admin) and launches
the app.

> **Windows 11 hides new tray icons by default.** If you don't see the
> batteries, they're behind the `^` overflow chevron — open
> *Settings → Personalization → Taskbar → Other system tray icons* and turn
> **ClaudeCodexBattery** on (or just drag the icons out of the overflow flyout).

Uninstall everything with `.\uninstall.ps1`.

## Requirements

| | Required? | Notes |
|---|---|---|
| Windows 10/11 | ✅ | .NET Framework 4.x `csc.exe` is built in |
| Claude Code | ✅ for the Claude battery | just **logged in** on this machine — the app reuses `%USERPROFILE%\.claude\.credentials.json` to query the usage API |
| Codex CLI | optional | for the Codex battery; without it the icon is hidden |

## How it works

Same data sources as the macOS plugin:

- **Claude** — the Claude Code OAuth token from
  `%USERPROFILE%\.claude\.credentials.json` is used to query
  `api.anthropic.com/api/oauth/usage` (the same data `/usage` shows,
  account-level across all devices). The token lives in memory only — never
  written to disk, logs, or process arguments. The last good response is
  cached at `%USERPROFILE%\.claude\ccbattery\claude-usage.json` as an offline
  fallback (labeled "캐시" in the menu).
- **Codex** — the newest `rate_limits` object from
  `%USERPROFILE%\.codex\sessions\**\*.jsonl` (numbers only, never messages).
  Like on macOS, it's a snapshot from your last Codex run; the menu labels
  its age and warns past 3 hours.

The icons are drawn with GDI+ at runtime, sized to your DPI, and adapt to the
light/dark taskbar theme. The two service logos are the real favicons
(claude.ai and chatgpt.com), downloaded **once** via Google's public favicon
endpoint (`www.google.com/s2/favicons`) and cached in
`%LOCALAPPDATA%\ClaudeCodexBattery\` — until that download succeeds a
hand-drawn fallback glyph is used, so the app works fully offline. At render
time the favicon's background plate is keyed out (dominant-color chroma key)
so only the glyph remains, tinted like the native charge bolt — Claude keeps
its brand terracotta, Codex uses the theme ink color.

## Differences from the macOS widget

- One tray icon + a rich click dashboard, instead of one menu-bar capsule per
  limit window with a text dropdown.
- No `ccusage` cost breakdown, no auto-update check, and no Codex
  auto-refresh (`codex exec`) — the Windows port never spends tokens on its
  own.

## Debug

```powershell
ClaudeCodexBattery.exe --dump C:\some\dir
```

renders sample icons (16/24/32 px, light/dark) plus a `status.txt` with the
live parsed data, then exits.
