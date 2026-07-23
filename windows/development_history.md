# 📜 Windows Port Development & Feedback Evolution History

This document records the complete journey, architecture decisions, user feedback iterations, technical solutions, and PR submission roadmap for the Windows native port of [dennykim123/claude-codex-battery](https://github.com/dennykim123/claude-codex-battery).

---

## 1. Initial Inquiry & Port Feasibility
- **User Question**: Is `claude-codex-battery` portable to Windows?
- **Analysis**:
  - Main script `claude-codex-usage.2m.js` is pure Node/Bun JS using HTTP APIs.
  - Endpoints (`api.anthropic.com/api/oauth/usage`, `chatgpt.com/backend-api/wham/usage`) are OS-independent.
  - Primary OS adaptation required: **macOS Keychain / Menu Bar $\rightarrow$ Windows Credential / System Tray**.

---

## 2. Pull Request #3 (daehyeonxyz) & Maintainer (dennykim123) Synthesis
- **PR #3 (`daehyeonxyz`)**:
  - Introduced `windows/` isolated directory.
  - **Zero-Dependency**: Compiled single C# file using Windows built-in `csc.exe` (.NET Framework 4.x).
  - Used local session log scraping for Codex.
- **Maintainer (`dennykim123`) Feedback**:
  - Highly approved `csc.exe` zero-dependency approach.
  - Requested updating Codex to use the live account-level API (`chatgpt.com/backend-api/wham/usage` via `~/.codex/auth.json`).

---

## 3. Iterative User Feedback & UX Improvements

### Iteration 1: Technical Execution & TLS 1.2 Fix
- **Problem**: Default .NET Framework 4.5/4.8 `HttpWebRequest` failed on modern HTTPS endpoints with SSL/TLS error.
- **Solution**: Explicitly enforced `ServicePointManager.SecurityProtocol = Tls12` in C# startup.

### Iteration 2: Smart ConnectionState & Unused Service Hiding
- **User Feedback**: "If I don't use Claude Code, it shouldn't show '--%' or empty batteries. If disconnected, show 'Not Connected'."
- **Solution**:
  - Added `ConnectionState` enum (`Connected`, `NotConnected`, `OfflineCached`).
  - Hides Claude 5h & Weekly rows dynamically when Claude Code is not connected.
  - Dynamic window height resizing (shrinks to fit active service).

### Iteration 3: Dynamic Single / Dual Tray Battery Icon
- **User Feedback**: "If only Codex is connected, don't force double battery slots. Tray space is small!"
- **Solution**:
  - Single connected service $\rightarrow$ Single enlarged battery gauge + Pixel Cat Companion.
  - Dual connected services $\rightarrow$ Dual battery gauges (`C` & `X`).

### Iteration 4: Pixel Cat Mascot & Animation
- **User Feedback**: "Recent repos have cute cat companions. Add wit and animation so people want to pin it to their main taskbar!"
- **Solution**:
  - Rendered **Pixel Art Cat Mascot `(=^･ω･^=)`** directly in the tray icon and flyout header.
  - Real-time emotional state reactions:
    - **$\ge 50\%$**: Happy & winking cat `(=^･ω･^=)`
    - **$20\% - 49\%$**: Sweating/worried cat `(=^･-･^=) 💧`
    - **$< 20\%$**: Burning/panicked cat `(=^🔥^=)`
  - Live 1-second animation timer for winking/breathing.

### Iteration 5: Windows 11 Acrylic & Round Corners
- **User Feedback**: "Make the UI look truly Windows 11 native."
- **Solution**:
  - Hooked Win32 DWM API (`DwmSetWindowAttribute`) for `DWMWCP_ROUND` (12px rounded corners).
  - Styled slate backdrop, Segoe UI Variable font, and modern pill-style action buttons.

### Iteration 6: Mascot Skin Customization System (Cat / Slime / Classic)
- **User Feedback**: "Make the mascot visible inside the Flyout window too, and allow customizing skins so people want to keep it pinned to their taskbar!"
- **Solution**:
  - Added **Mascot Skin Customization** menu right in the Tray Context Menu:
    - 🟢 **RPG Bouncy Slime** (Default)
    - 🐱 **Kitsch Pixel Cat**
    - 🔋 **Classic Dual Battery**
  - Skin preference is saved to `%USERPROFILE%\.claude\swiftbar\.skin` for persistence across restarts.

### Iteration 7: Full-Size Prominent Mascot Tray & Hover Tooltips
- **User Feedback**: "Squeezing both the battery bar AND the mascot into 32x32 makes the mascot too small. Cuteness comes first!"
- **Solution**:
  - Mascot (Slime / Cat) fills the 32x32 tray icon space cleanly so it is large, clear, and super cute!

### Iteration 8: Pure Mascot Vector Art & MS-Standard Tooltip Optimization
- **User Feedback Critique**: "Look at Microsoft's UI designers. Compressing tiny 3-digit text into a 32px icon bitmap creates blurry noise. Remove text overlays from the mascot icon and leverage Windows native tooltips & flyouts!"
- **Solution**:
  - Removed blurry text overlays completely from the mascot tray icon.
  - Mascot is 100% clean, crisp, and high-definition pixel art.
  - Mouse hover over tray icon displays razor-sharp native Windows Tooltip (`Codex: 80% left (resets 5d 11h) | Click for full dashboard`).

### Iteration 9: In-Window Settings Gear `⚙` & Cyber Neon Glassmorphic Overhaul
- **User Feedback**: "Add an in-window Settings gear button to control options directly from the flyout window, and make the app design look ultra-modern instead of retro!"
- **Solution**:
  - Added **`⚙ Settings` button** directly inside the Flyout Dashboard window, allowing instant skin switching & autostart toggling directly from the popup!
  - Redesigned the Flyout UI to **Cyber Neon Glassmorphism (`#0F111A` obsidian backdrop + `#00F5A0` $\rightarrow$ `#00D9F5` vibrant gradient progress fill + translucent card borders)**.

---

## 🚀 Final Executable & Repository Package

| File | Purpose |
| :--- | :--- |
| `windows/ClaudeCodexBattery.cs` | Native C# application (WinForms + GDI+ + DWM + Cyber Neon Glass Engine) |
| `windows/install.ps1` | `csc.exe` build & autostart registration script |
| `windows/uninstall.ps1` | Cleanup script |
| `windows/docs/screenshot.png` | Captured flyout & tray UI screenshot |
| `windows/development_history.md` | Full development history log |
