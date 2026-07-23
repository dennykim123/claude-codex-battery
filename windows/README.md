# Native Windows Port (`windows/`) for Claude & Codex Battery

A zero-dependency Windows System Tray application showing your remaining Claude Code & Codex usage limits as dual battery gauges.

![Windows Flyout Screenshot](./docs/screenshot.png)

## Features
- **Zero-Dependency**: Compiles using `csc.exe` bundled in every Windows installation (.NET Framework 4.x). No Node.js, npm, or extra SDKs required.
- **Dual Battery Gauges**: Real-time GDI+ battery gauges drawn directly in your System Tray icon (`C` for Claude, `X` for Codex).
- **Windows 11 Acrylic Flyout**: Click the tray icon for a modern dark dashboard showing 5-hour & weekly limits, percentage remaining, reset countdowns, and data status.
- **Live OAuth APIs & Automatic Fallbacks**:
  - **Claude Code**: Queries `api.anthropic.com/api/oauth/usage` via local credentials (`%USERPROFILE%\.claude\.credentials.json`). Automatically falls back to local cache if offline.
  - **Codex**: Queries live ChatGPT Wham API (`chatgpt.com/backend-api/wham/usage`) via `%USERPROFILE%\.codex\auth.json`. Automatically falls back to session log parsing (`%USERPROFILE%\.codex\sessions\*.jsonl`).

## Quick Installation

Open PowerShell and run:

```powershell
cd windows
.\install.ps1
```

`install.ps1` will automatically:
1. Compile `ClaudeCodexBattery.cs` into `ClaudeCodexBattery.exe` using Windows built-in `csc.exe`.
2. Add the app to Windows Startup (`HKCU\...\Run`).
3. Launch the application immediately.

## Uninstallation

```powershell
cd windows
.\uninstall.ps1
```
