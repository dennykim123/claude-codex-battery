# 🔋 Claude & Codex Usage Battery

<p align="center">
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-blue.svg" alt="License: MIT"></a>
  <img src="https://img.shields.io/badge/platform-macOS-000000?logo=apple&logoColor=white" alt="Platform: macOS">
  <img src="https://img.shields.io/badge/SwiftBar-plugin-FF9500" alt="SwiftBar plugin">
  <img src="https://img.shields.io/badge/runtime-bun-14151A?logo=bun&logoColor=white" alt="Runtime: bun">
  <img src="https://img.shields.io/badge/dependencies-none-brightgreen.svg" alt="Zero dependencies">
  <a href="https://github.com/dennykim123/claude-codex-battery/stargazers"><img src="https://img.shields.io/github/stars/dennykim123/claude-codex-battery?style=flat&logo=github" alt="GitHub stars"></a>
</p>

> A macOS menu bar widget that shows your remaining **Claude Code** and **Codex** usage limits as battery icons — so you never have to open `/usage` again.

> **Windows?** A native system-tray port lives in [`windows/`](windows/README.md) — same data sources, zero dependencies (compiles with the `csc.exe` built into Windows).

<p align="center">
  <img src="docs/menubar@2x.png" alt="Menu bar battery widget" width="280">
</p>

`C` = Claude · `X` = Codex. Each battery shows the **remaining %** of a limit window — full & green means plenty left, red means almost out. Click for a detailed breakdown with reset times.

Built as a single [SwiftBar](https://github.com/swiftbar/SwiftBar) plugin — one self-contained script, **no third-party libraries**. The battery icons are rendered as PNGs from scratch in pure JavaScript (`node:zlib` only), so there's no image library and no `npm install`. Network calls: **one to Anthropic's official usage endpoint** (the same data `/usage` shows, fetched with your own local Claude Code login — [see Privacy](#privacy--security)) and an **optional once-a-day update check** ([see Updating](#updating)). (`ccusage` is an optional extra for the cost breakdown.)

---

## What it shows

| Group | Batteries | Source |
|-------|-----------|--------|
| **`C` Claude** | 5-hour session · weekly · **Fable** (top-model weekly cap) | Anthropic's OAuth usage API — queried live with your local Claude Code login; **account-level**, so usage from every device/surface is included |
| **`X` Codex** | 5-hour · weekly (or credit balance on the premium plan) | `~/.codex/sessions/**/*.jsonl` → `rate_limits` |

Click the widget for a dropdown with, per limit:

```
Claude Code
  5h remaining   ▕██████████████░░░░░░▏ 70%  (used 30%)  · resets 3h 18m
  weekly         ▕██████▋░░░░░░░░░░░░░▏ 33%  (used 67%)  · resets 3d 21h
  Fable          ▕████░░░░░░░░░░░░░░░░▏ 26%  (used 74%)  · resets 3d 21h
  today by model ▕████████████▏ Fable $75 · Opus $46 · Sonnet $5 …

Codex · prolite
  5h remaining   ▕████████████████████▏ 100% (used 0%)
  weekly         ▕████████████████▋░░░▏ 83%  (used 17%)
```

Colors follow a traffic-light scale: green ≥ 50 % left, amber < 50 %, red < 20 %.

---

## Requirements

| | Required? | Install |
|---|---|---|
| **macOS** | ✅ | — |
| **[SwiftBar](https://github.com/swiftbar/SwiftBar)** | ✅ | `brew install swiftbar` |
| **[bun](https://bun.sh)** | ✅ | `curl -fsSL https://bun.sh/install \| bash` |
| **Claude Code** | ✅ for `C` batteries | just needs to be **logged in** on this Mac (the widget reuses its login to query the usage API) |
| **Codex CLI** | optional | for the `X` batteries; without it, only Claude is shown |
| **[ccusage](https://github.com/ryoppippi/ccusage)** | optional | adds the cost / token / per-model breakdown in the dropdown — **the battery works fully without it** |

> **Note:** This widget shows *your own account's* limits — via your local Claude Code login and your local Codex session logs. If you don't use Claude Code (or Codex), there simply won't be any data to display.

---

## Install

```bash
git clone https://github.com/dennykim123/claude-codex-battery.git
cd claude-codex-battery
./install.sh
```

`install.sh` will:

1. Verify **bun** and **SwiftBar** are present (and tell you how to install them if not)
2. Copy the plugin into `~/.swiftbar-plugins/`, rewriting the shebang to your machine's `bun` path *(SwiftBar runs plugins with a minimal `PATH`, so an absolute shebang is required)*
3. Point SwiftBar at the plugin folder and launch it
4. Register SwiftBar as a login item, so the battery comes back automatically after a reboot

No `npm install`, no bundled libraries — the plugin is a single self-contained script.

The battery appears in your menu bar within a few seconds. It refreshes **every 2 minutes** (the `.2m.` in the filename).

### Manual install

If you prefer not to run the script:

```bash
mkdir -p ~/.swiftbar-plugins
# rewrite shebang to your bun path, then copy:
sed "1s|.*|#!$(command -v bun)|" claude-codex-usage.2m.js > ~/.swiftbar-plugins/claude-codex-usage.2m.js
chmod +x ~/.swiftbar-plugins/claude-codex-usage.2m.js
defaults write com.ameba.SwiftBar PluginDirectory -string ~/.swiftbar-plugins
open -a SwiftBar
```

---

## Updating

The widget checks GitHub for a newer version **at most once a day** — a tiny background request for the `VERSION` file. When a new version is out, a green **🆕 update** row appears in the dropdown; click it to replace the plugin in place and refresh (your previous copy is kept as `.bak`).

Prefer to do it yourself? From your clone: `git pull && ./install.sh`.

To turn the check off entirely, comment out the `getUpdateInfo()` call near the bottom of the script — then the only network call left is the Anthropic usage query.

---

## Privacy & security

- **Claude limits come straight from Anthropic.** The widget reads your Claude Code OAuth token from the macOS Keychain (item `Claude Code-credentials`) and calls `api.anthropic.com/api/oauth/usage` — the same endpoint `/usage` uses. The token is sent **only to api.anthropic.com**, passed via stdin (never visible in `ps`), and never written to disk or logs. macOS may show a one-time Keychain permission prompt — click **Always Allow**. (Clicking *Deny* makes macOS re-prompt on every refresh — if you'd rather the widget never touch the Keychain, run `touch ~/.claude/swiftbar/.no-live` instead; it then reads local cache files only, like v1.1.)
- **No other secrets read.** Codex `auth.json` and API keys are never touched.
- **No usage data leaves your machine.** Nothing is uploaded anywhere; the only outbound calls are the Anthropic usage query above and the optional daily update check ([Updating](#updating)).
- **No conversation content.** From Codex session logs it parses only the `rate_limits` object (numbers), never the messages.
- **Auditable in one sitting.** The whole widget is a single dependency-free script — grep for `curl`/`fetch` and you've seen every network call it can make.

---

## How accurate / in-sync is it?

**Claude — live.** Every refresh queries Anthropic's usage API directly with your local Claude Code login — the *same* server-side data `/usage` shows, so the numbers match it by construction. Because the limits are **account-level**, usage from every surface and device (terminal, desktop app, web, another machine) is already included. If the query fails (offline, logged out), the widget falls back to its last successful response and labels the reading with its age in amber.

**Codex — as fresh as your last Codex run.** Codex writes rate-limit data to its session logs *only while you use it*, and records no reset time. So the value is a snapshot from your most recent session — the dropdown labels it "measured N ago" and warns past 3h. Run Codex and it re-syncs instantly.

**TL;DR** — Claude is live (same source as `/usage`); Codex is a clearly-labeled snapshot from your last session, not a live feed.

---

## How it works

The whole thing is one `.js` file run by bun on a timer.

- **Battery icons** are drawn pixel-by-pixel into an RGBA buffer and encoded to PNG using only `node:zlib` (hand-rolled CRC32 + IHDR/IDAT/IEND chunks). A 5×7 bitmap font renders the numbers and the `C`/`X` group labels. SwiftBar displays the PNG at pixels ÷ 2 pt.
- **Claude limits** are fetched from Anthropic's OAuth usage endpoint using the Claude Code login token in your Keychain, with the last good response cached at `~/.claude/swiftbar/.claude-usage.json` as an offline fallback. The Fable cap is the `weekly_scoped` entry.
- **Codex limits** come from the newest session's `rate_limits`. The premium plan reports a `credits` object instead of percentages when exhausted; the widget handles both shapes.

### Codex has one quirk

Codex only writes limit data to session logs **while you use it**, and doesn't record a reset time when exhausted. So if you haven't run Codex in a while, the value can be stale. The widget:

- flags values older than 3 hours in the dropdown, and
- **optionally** runs `codex exec --sandbox read-only` in the background to refresh — but *only* when Codex is exhausted **and** the value is 2h+ old, at most once every 6 hours (≈4×/day, ~20k tokens each).

If you'd rather it never spend tokens on its own, comment out the `maybeAutoRefreshCodex(codex)` call near the render section.

---

## Customizing

| Want to change | Where |
|---|---|
| Refresh interval | filename `.2m.` → `.1m.`, `.5m.`, `.30s.`, … |
| Battery size | `drawCapsule`: `bw` / `bh` (5×7 font sets the floor) |
| Color thresholds | `heatRemain` / `heatRemainHex` (20 % / 50 %) |
| Disable Codex auto-refresh | comment out `maybeAutoRefreshCodex(codex)` |
| Disable live Claude API / Keychain access | `touch ~/.claude/swiftbar/.no-live` (falls back to local cache files) |
| Which Claude limits to show | the `battItems.push(...)` block |

---

## Why a SwiftBar plugin (and not a standalone app)?

A single script stays dependency-free, easy to audit, and trivial to fork — and its audience (Claude Code / Codex developers) already lives in the terminal, so `brew install swiftbar` is no barrier. A native `.app` would drop the SwiftBar requirement but adds a Swift codebase, Apple code-signing + notarization ($99/yr), and ongoing maintenance. **Roadmap:** if there's enough demand, ship a signed one-click menu-bar `.app` (likely bundling SwiftBar) for non-terminal users.

## Contributing

Issues and PRs welcome — especially for other plans/tools (e.g. mapping additional `rate_limit` shapes, or adding providers). Keep it dependency-free.

## License

[MIT](LICENSE)
