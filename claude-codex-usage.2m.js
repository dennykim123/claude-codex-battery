#!/usr/bin/env bun
// <xbar.title>Claude & Codex Usage</xbar.title>
// <xbar.version>v3.0</xbar.version>
// <xbar.author>Denny Kim</xbar.author>
// <xbar.desc>Shows remaining Claude Code 5h-block and Codex rate limits as battery icons in the menu bar</xbar.desc>
// SwiftBar plugin, refreshes every 2 minutes. Menu bar = battery icons (self-rendered PNG), click = detailed gauges.

import { execSync, spawn } from "node:child_process";
import {
  readFileSync,
  writeFileSync,
  readdirSync,
  statSync,
  existsSync,
  mkdirSync,
} from "node:fs";
import { join, dirname } from "node:path";
import { homedir } from "node:os";
import zlib from "node:zlib";

const HOME = homedir();
// UI language: Korean on Korean-language macOS, English otherwise (CCB_LANG=ko|en to force)
const UI_KO = (() => {
  if (process.env.CCB_LANG) return process.env.CCB_LANG === "ko";
  try {
    const out = execSync("defaults read -g AppleLanguages 2>/dev/null", {
      encoding: "utf8",
      timeout: 3000,
    });
    const m = out.match(/"\s*([a-z]{2})/);
    return m?.[1] === "ko";
  } catch {
    return false;
  }
})();
const L = (ko, en) => (UI_KO ? ko : en);

// Locate binaries (paths differ per machine — portability)
function findBin(name, extra = []) {
  const cands = [
    ...extra,
    `${HOME}/.bun/bin/${name}`,
    "/opt/homebrew/bin/" + name,
    "/usr/local/bin/" + name,
  ];
  for (const c of cands) {
    try {
      if (existsSync(c)) return c;
    } catch {}
  }
  try {
    const p = execSync(`command -v ${name} 2>/dev/null`, {
      encoding: "utf8",
    }).trim();
    if (p) return p;
  } catch {}
  return name; // last resort: rely on PATH
}
const CCUSAGE = findBin("ccusage");
const CODEX_SESSIONS = `${HOME}/.codex/sessions`;
const now = Math.floor(Date.now() / 1000);

// ── Auto-update (notification + one click) ──
const VERSION = "2.3.2";
const SELF_DIR = dirname(process.argv[1] || `${HOME}/.swiftbar-plugins/x`);
const REPO_RAW =
  "https://raw.githubusercontent.com/dennykim123/claude-codex-battery/main";
const UPDATE_CACHE = `${HOME}/.claude/swiftbar/.update-check.json`;
function cmpVer(a, b) {
  const pa = String(a).split(".").map(Number);
  const pb = String(b).split(".").map(Number);
  for (let i = 0; i < 3; i++) {
    if ((pa[i] || 0) > (pb[i] || 0)) return 1;
    if ((pa[i] || 0) < (pb[i] || 0)) return -1;
  }
  return 0;
}
// Read the cached latest version; if 24h+ old, quietly check GitHub's VERSION file
// in the background (doesn't block rendering — detached spawn + unref)
function getUpdateInfo() {
  let cache = null;
  try {
    cache = JSON.parse(readFileSync(UPDATE_CACHE, "utf8"));
  } catch {}
  const age = cache?.checkedAt ? now - cache.checkedAt : Infinity;
  if (age > 24 * 3600) {
    try {
      const cmd =
        `latest=$(curl -fsL --max-time 8 "${REPO_RAW}/VERSION" 2>/dev/null | tr -d '[:space:]'); ` +
        `[ -n "$latest" ] && printf '{"checkedAt":%s,"latest":"%s"}' "${now}" "$latest" > "${UPDATE_CACHE}"`;
      const child = spawn("/bin/sh", ["-c", cmd], {
        detached: true,
        stdio: "ignore",
      });
      child.unref();
    } catch {}
  }
  const latest = cache?.latest;
  return { latest, hasUpdate: !!latest && cmpVer(latest, VERSION) > 0 };
}

// ══ Battery icon PNG renderer (pure JS, node:zlib only) ══════════
const CRC = (() => {
  const t = new Uint32Array(256);
  for (let n = 0; n < 256; n++) {
    let c = n;
    for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
    t[n] = c >>> 0;
  }
  return t;
})();
function crc32(buf) {
  let c = 0xffffffff;
  for (let i = 0; i < buf.length; i++) c = CRC[(c ^ buf[i]) & 0xff] ^ (c >>> 8);
  return (c ^ 0xffffffff) >>> 0;
}
function encodePNG(w, h, rgba) {
  const sig = Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]);
  const mk = (type, data) => {
    const len = Buffer.alloc(4);
    len.writeUInt32BE(data.length, 0);
    const body = Buffer.concat([Buffer.from(type), data]);
    const crc = Buffer.alloc(4);
    crc.writeUInt32BE(crc32(body), 0);
    return Buffer.concat([len, body, crc]);
  };
  const ihdr = Buffer.alloc(13);
  ihdr.writeUInt32BE(w, 0);
  ihdr.writeUInt32BE(h, 4);
  ihdr[8] = 8;
  ihdr[9] = 6;
  const stride = w * 4;
  const raw = Buffer.alloc((stride + 1) * h);
  for (let y = 0; y < h; y++) {
    raw[y * (stride + 1)] = 0;
    rgba.copy(raw, y * (stride + 1) + 1, y * stride, y * stride + stride);
  }
  const idat = zlib.deflateSync(raw, { level: 9 });
  return Buffer.concat([
    sig,
    mk("IHDR", ihdr),
    mk("IDAT", idat),
    mk("IEND", Buffer.alloc(0)),
  ]);
}
const SCALE = 2;
function makeCanvas(wl, hl) {
  const w = wl * SCALE,
    h = hl * SCALE;
  const buf = Buffer.alloc(w * h * 4, 0);
  const set = (x, y, col) => {
    if (x < 0 || y < 0 || x >= wl || y >= hl) return;
    const [r, g, b, a = 255] = col;
    for (let dy = 0; dy < SCALE; dy++)
      for (let dx = 0; dx < SCALE; dx++) {
        const px = ((y * SCALE + dy) * w + (x * SCALE + dx)) * 4;
        buf[px] = r;
        buf[px + 1] = g;
        buf[px + 2] = b;
        buf[px + 3] = a;
      }
  };
  return { w, h, buf, set };
}
const _rect = (cv, x, y, rw, rh, col) => {
  for (let j = 0; j < rh; j++)
    for (let i = 0; i < rw; i++) cv.set(x + i, y + j, col);
};
const _stroke = (cv, x, y, rw, rh, col) => {
  for (let i = 1; i < rw - 1; i++) {
    cv.set(x + i, y, col);
    cv.set(x + i, y + rh - 1, col);
  }
  for (let j = 1; j < rh - 1; j++) {
    cv.set(x, y + j, col);
    cv.set(x + rw - 1, y + j, col);
  }
};
// ── Size presets: big (default) / small — toggled via the dropdown row or ~/.claude/swiftbar/.batt-size ──
const SIZE_FILE = `${HOME}/.claude/swiftbar/.batt-size`;
let SIZE = "big";
try {
  if (readFileSync(SIZE_FILE, "utf8").trim() === "small") SIZE = "small";
} catch {}

// 4x6 pixel font (big preset)
const FONT46 = {
  0: ["0110", "1001", "1001", "1001", "1001", "0110"],
  1: ["0010", "0110", "0010", "0010", "0010", "0111"],
  2: ["0110", "1001", "0010", "0100", "1000", "1111"],
  3: ["1110", "0001", "0110", "0001", "1001", "0110"],
  4: ["0010", "0110", "1010", "1111", "0010", "0010"],
  5: ["1111", "1000", "1110", "0001", "1001", "0110"],
  6: ["0110", "1000", "1110", "1001", "1001", "0110"],
  7: ["1111", "0001", "0010", "0100", "0100", "0100"],
  8: ["0110", "1001", "0110", "1001", "1001", "0110"],
  9: ["0110", "1001", "1001", "0111", "0001", "0110"],
  C: ["0110", "1001", "1000", "1000", "1001", "0110"],
  X: ["1001", "1001", "0110", "0110", "1001", "1001"],
};
// 3x5 classic pixel font (small preset)
const FONT35 = {
  0: ["111", "101", "101", "101", "111"],
  1: ["010", "110", "010", "010", "111"],
  2: ["111", "001", "111", "100", "111"],
  3: ["111", "001", "111", "001", "111"],
  4: ["101", "101", "111", "001", "001"],
  5: ["111", "100", "111", "001", "111"],
  6: ["111", "100", "111", "101", "111"],
  7: ["111", "001", "001", "001", "001"],
  8: ["111", "101", "111", "101", "111"],
  9: ["111", "101", "111", "001", "111"],
  C: ["111", "100", "100", "100", "111"],
  X: ["101", "101", "010", "101", "101"],
};
// Per-preset geometry: font/advance, capsule (bw×bh), layout (capw·gaps), canvas height, digit y-offset
const PRESET =
  SIZE === "small"
    ? {
        font: FONT35,
        adv: () => 4,
        bw: 14,
        bh: 9,
        capw: 16,
        gap: 3,
        ggap: 7,
        pad: 1,
        lblgap: 2,
        H: 9,
        dy: 2,
      }
    : {
        font: FONT46,
        adv: (ch) => (ch === "1" ? 4 : 5),
        bw: 18,
        bh: 10,
        capw: 20,
        gap: 5,
        ggap: 10,
        pad: 2,
        lblgap: 3,
        H: 12,
        dy: 3,
      };
const NUM = PRESET.font;
// With altCol/boundaryX: pixels left of the fill boundary use altCol (contrast on the bright
// fill), pixels right of it (empty background) use col. Without them: solid col (group labels).
const chAdv = PRESET.adv; // big: 5px ('1' kerns to 4px so "100" doesn't collide), small: 4px
function drawNum(cv, x, y, str, col, altCol, boundaryX) {
  let cx = x;
  for (const ch of str) {
    const g = NUM[ch];
    if (g)
      for (let r = 0; r < g.length; r++)
        for (let c = 0; c < g[r].length; c++)
          if (g[r][c] === "1") {
            const px = cx + c;
            cv.set(px, y + r, altCol && px < boundaryX ? altCol : col);
          }
    cx += chAdv(ch);
  }
  return cx;
}
const numW = (s) => [...s].reduce((w, ch) => w + chAdv(ch), 0) - 1;
// Real macOS battery indicator colors (Apple HIG system colors, dark/light variants)
function heatRemain(r, dark) {
  if (r <= 20) return dark ? [255, 69, 58] : [255, 59, 48]; // systemRed
  if (r < 50) return dark ? [255, 214, 10] : [255, 204, 0]; // systemYellow
  return dark ? [48, 209, 88] : [52, 199, 89]; // systemGreen
}
const heatRemainHex = (r) =>
  r <= 20 ? "#FF453A" : r < 50 ? "#FFD60A" : "#30D158"; // dropdown gauges (dark theme)
// One capsule: outline + remaining fill + the remaining number inside (always shown, incl. 100)
function drawCapsule(cv, x, midY, remain, ink, dark) {
  const bw = PRESET.bw,
    bh = PRESET.bh,
    by = midY - Math.floor(bh / 2);
  _stroke(cv, x, by, bw, bh, ink);
  _rect(cv, x + bw, by + 3, 2, bh - 6, ink); // terminal nub
  if (remain != null) {
    const innerW = bw - 4;
    const v = Math.max(0, Math.min(100, remain));
    const fw = Math.round((v / 100) * innerW);
    if (fw > 0) _rect(cv, x + 2, by + 2, fw, bh - 4, heatRemain(remain, dark));
    const s = String(Math.round(v));
    const tx = x + Math.floor((bw - numW(s)) / 2);
    // Dark digits over the bright fill, ink digits over the empty background → contrast everywhere
    drawNum(
      cv,
      tx,
      midY - PRESET.dy,
      s,
      ink,
      [30, 30, 30],
      x + 2 + (fw > 0 ? fw : 0),
    );
  }
  return x + bw + 2;
}
// N capsules (items=[{label,remain}]). Group label letter (C=Claude / X=Codex) before each group.
function renderBatteryImage(dark, items) {
  const ink = dark ? [235, 235, 235] : [45, 45, 45];
  const CAPW = PRESET.capw,
    GAP = PRESET.gap,
    GGAP = PRESET.ggap,
    PAD = PRESET.pad,
    LBLGAP = PRESET.lblgap;
  const H = PRESET.H;
  const midY = Math.floor(H / 2);
  // Width calculation (including group labels)
  let W = PAD * 2;
  let pg = null;
  for (let i = 0; i < items.length; i++) {
    const g = items[i].label[0];
    if (g !== pg) {
      if (pg !== null) W += GGAP;
      W += numW(g) + LBLGAP;
      pg = g;
    } else W += GAP;
    W += CAPW;
  }
  const cv = makeCanvas(Math.max(W, 8), H);
  let x = PAD;
  pg = null;
  for (let i = 0; i < items.length; i++) {
    const g = items[i].label[0];
    if (g !== pg) {
      if (pg !== null) x += GGAP;
      drawNum(cv, x, midY - PRESET.dy, g, ink); // group label C or X
      x += numW(g) + LBLGAP;
      pg = g;
    } else x += GAP;
    drawCapsule(cv, x, midY, items[i].remain, ink, dark);
    x += CAPW;
  }
  return encodePNG(cv.w, cv.h, cv.buf).toString("base64");
}
function isDarkMode() {
  try {
    return (
      execSync("defaults read -g AppleInterfaceStyle 2>/dev/null", {
        encoding: "utf8",
        timeout: 3000,
      }).trim() === "Dark"
    );
  } catch {
    return false;
  }
}

// ── Gauge renderer (partial blocks, zero dependencies) ──────────
const FULL = "█",
  EMPTY = "░",
  PART = ["", "▏", "▎", "▍", "▌", "▋", "▊", "▉"];
function bar(pct, w) {
  pct = Math.max(0, Math.min(100, pct || 0));
  const filled = (pct / 100) * w;
  let fb = Math.floor(filled);
  let idx = Math.round((filled - fb) * 8);
  if (idx === 8) {
    fb++;
    idx = 0;
  }
  fb = Math.min(fb, w);
  let s = FULL.repeat(fb),
    used = fb;
  if (idx > 0 && fb < w) {
    s += PART[idx];
    used++;
  }
  s += EMPTY.repeat(Math.max(0, w - used));
  return s;
}
// Usage % → traffic-light color (GitHub palette)
function heat(pct) {
  if (pct >= 80) return "#f85149"; // red
  if (pct >= 50) return "#d29922"; // amber
  return "#3fb950"; // green
}

// ── Shared utils ──────────────────────────────────────────────
const fmtDur = (secs) => {
  if (secs <= 0) return "0m";
  const h = Math.floor(secs / 3600);
  const m = Math.floor((secs % 3600) / 60);
  if (h >= 24) return `${Math.floor(h / 24)}d ${h % 24}h`;
  return h > 0 ? `${h}h ${m}m` : `${m}m`;
};
const fmtTok = (n) => {
  if (n >= 1e9) return `${(n / 1e9).toFixed(1)}B`;
  if (n >= 1e6) return `${(n / 1e6).toFixed(1)}M`;
  if (n >= 1e3) return `${(n / 1e3).toFixed(0)}K`;
  return `${n}`;
};

// ── 1. Claude Code: active 5-hour block ────────────────────────
function getClaude() {
  try {
    const raw = execSync(`${CCUSAGE} blocks --active --json`, {
      encoding: "utf8",
      timeout: 20000,
      stdio: ["ignore", "pipe", "ignore"],
    });
    const data = JSON.parse(raw);
    const b =
      (data.blocks || []).find((x) => x.isActive) || (data.blocks || [])[0];
    if (!b) return null;
    const startTs = Math.floor(new Date(b.startTime).getTime() / 1000);
    const endTs = Math.floor(new Date(b.endTime).getTime() / 1000);
    const span = Math.max(1, endTs - startTs);
    const elapsedPct = Math.max(
      0,
      Math.min(100, ((now - startTs) / span) * 100),
    );
    return {
      elapsedPct,
      remainMin:
        b.projection?.remainingMinutes ??
        Math.max(0, Math.floor((endTs - now) / 60)),
      cost: b.costUSD || 0,
      tokens: b.totalTokens || 0,
      projCost: b.projection?.totalCost ?? null,
      costPerHour: b.burnRate?.costPerHour ?? null,
    };
  } catch (e) {
    return { error: String(e.message || e).split("\n")[0] };
  }
}

// ── 1b. Claude usage by model today (Opus/Sonnet/Fable/Haiku) ──
const MODEL_NAMES = {
  "claude-fable-5": "Fable 5",
  "claude-opus-4-8": "Opus 4.8",
  "claude-opus-4-7": "Opus 4.7",
  "claude-sonnet-5": "Sonnet 5",
  "claude-haiku-4-5-20251001": "Haiku 4.5",
};
const shortModel = (n) => MODEL_NAMES[n] || (n || "").replace("claude-", "");
function getClaudeModels() {
  try {
    const d = new Date();
    const ymd = `${d.getFullYear()}${String(d.getMonth() + 1).padStart(2, "0")}${String(d.getDate()).padStart(2, "0")}`;
    const raw = execSync(`${CCUSAGE} daily --breakdown --json --since ${ymd}`, {
      encoding: "utf8",
      timeout: 20000,
      stdio: ["ignore", "pipe", "ignore"],
    });
    const day = (JSON.parse(raw).daily || []).slice(-1)[0];
    if (!day) return null;
    const models = (day.modelBreakdowns || [])
      .map((m) => ({
        name: m.modelName,
        cost: m.cost || 0,
        tokens:
          (m.inputTokens || 0) +
          (m.outputTokens || 0) +
          (m.cacheCreationTokens || 0) +
          (m.cacheReadTokens || 0),
      }))
      .filter((m) => m.cost > 0.005)
      .sort((a, b) => b.cost - a.cost);
    if (!models.length) return null;
    return { models, total: models.reduce((s, m) => s + m.cost, 0) };
  } catch {
    return null;
  }
}

// ── 1c. Claude real rate limits — queried live from Anthropic's OAuth usage API ──
// Uses this Mac's Claude Code login token (Keychain) to fetch the same data /usage shows.
// Numbers are account-level, so usage from every device/surface is included.
// Fallbacks on failure: own cache (last good response) → legacy usage-cache.json files.
const CLAUDE_STATE_DIR = `${HOME}/.claude/swiftbar`;
const CLAUDE_USAGE_CACHE = `${CLAUDE_STATE_DIR}/.claude-usage.json`;
// Codex also supports live account-level queries: GET the ChatGPT usage endpoint
// (/backend-api/wham/usage) that Codex CLI itself polls every 60s, using the auth.json token.
// The response reports current limits without spending tokens, so it beats session logs
// (which are local and differ per machine).
const CODEX_AUTH = `${HOME}/.codex/auth.json`;
const CODEX_USAGE_CACHE = `${CLAUDE_STATE_DIR}/.codex-usage.json`;
const LEGACY_USAGE_FILES = [
  `${HOME}/.claude/MEMORY/STATE/usage-cache.json`,
  `${HOME}/.claude/PAI/MEMORY/STATE/usage-cache.json`,
];

// The token exists only as a return value — never written to files, logs, or process args
function readClaudeToken() {
  // Opt-out: `touch ~/.claude/swiftbar/.no-live` disables Keychain access / live queries
  // — clicking 'Deny' on the Keychain prompt would re-prompt every 2 minutes; use this instead.
  if (existsSync(`${CLAUDE_STATE_DIR}/.no-live`)) return null;
  try {
    const raw = execSync(
      'security find-generic-password -s "Claude Code-credentials" -w 2>/dev/null',
      { encoding: "utf8", timeout: 3000, stdio: ["ignore", "pipe", "ignore"] },
    ).trim();
    const t = JSON.parse(raw)?.claudeAiOauth?.accessToken;
    if (t) return t;
  } catch {}
  try {
    // For environments without the Keychain item (e.g. manual migration) — file credentials
    const raw = readFileSync(`${HOME}/.claude/.credentials.json`, "utf8");
    return JSON.parse(raw)?.claudeAiOauth?.accessToken ?? null;
  } catch {}
  return null;
}

function fetchClaudeUsageLive() {
  const token = readClaudeToken();
  if (!token) return null;
  try {
    // Authorization header passed via stdin (-H @-) — keeps the token out of `ps` output
    const raw = execSync(
      `/usr/bin/curl -fsS --max-time 5 -H @- -H "anthropic-beta: oauth-2025-04-20" https://api.anthropic.com/api/oauth/usage`,
      {
        encoding: "utf8",
        timeout: 8000,
        input: `Authorization: Bearer ${token}\n`,
        stdio: ["pipe", "pipe", "ignore"],
      },
    );
    const d = JSON.parse(raw);
    if (!d?.five_hour) return null;
    try {
      mkdirSync(CLAUDE_STATE_DIR, { recursive: true });
      writeFileSync(
        CLAUDE_USAGE_CACHE,
        JSON.stringify({ fetchedAt: Math.floor(Date.now() / 1000), data: d }),
      );
    } catch {}
    return { data: d, measuredAt: Math.floor(Date.now() / 1000), live: true };
  } catch {
    return null;
  }
}

function readClaudeUsageFallback() {
  try {
    const c = JSON.parse(readFileSync(CLAUDE_USAGE_CACHE, "utf8"));
    if (c?.data?.five_hour)
      return { data: c.data, measuredAt: c.fetchedAt ?? 0, live: false };
  } catch {}
  for (const f of LEGACY_USAGE_FILES) {
    try {
      const d = JSON.parse(readFileSync(f, "utf8"));
      if (d?.five_hour)
        return {
          data: d,
          measuredAt: Math.floor(statSync(f).mtimeMs / 1000),
          live: false,
        };
    } catch {}
  }
  return null;
}

// 5-hour session / weekly overall / Fable weekly (weekly_scoped) utilization
function getClaudeUsage() {
  const src = fetchClaudeUsageLive() ?? readClaudeUsageFallback();
  if (!src) return null;
  const { data: d, measuredAt, live } = src;
  try {
    const toTs = (iso) => (iso ? Math.floor(Date.parse(iso) / 1000) : null);
    const win = (o) =>
      o ? { pct: o.utilization ?? 0, resetsAt: toTs(o.resets_at) } : null;
    // Weekly scoped cap for Fable (or whichever top model)
    let fable = null;
    for (const l of d.limits || []) {
      const mdl = l.scope?.model?.display_name;
      if (l.group === "weekly" && mdl) {
        fable = {
          pct: l.percent ?? 0,
          resetsAt: toTs(l.resets_at),
          model: mdl,
        };
        break;
      }
    }
    return {
      measuredAt,
      live,
      fiveHour: win(d.five_hour),
      weekly: win(d.seven_day),
      fable,
    };
  } catch {
    return null;
  }
}

// ── 2. Codex: freshest rate_limits ──────────────────────────────
function walkJsonl(dir, out) {
  let entries;
  try {
    entries = readdirSync(dir, { withFileTypes: true });
  } catch {
    return;
  }
  for (const ent of entries) {
    const p = join(dir, ent.name);
    if (ent.isDirectory()) walkJsonl(p, out);
    else if (ent.name.endsWith(".jsonl")) {
      try {
        out.push({ path: p, mtime: statSync(p).mtimeMs });
      } catch {}
    }
  }
}
// Read the ChatGPT token from auth.json (.no-live disables live queries, same switch as Claude)
function readCodexToken() {
  if (existsSync(`${CLAUDE_STATE_DIR}/.no-live`)) return null;
  try {
    const d = JSON.parse(readFileSync(CODEX_AUTH, "utf8"));
    const t = d?.tokens?.access_token;
    if (t) return { token: t, account: d?.tokens?.account_id || "" };
  } catch {}
  return null;
}

// Live: GET the ChatGPT usage endpoint directly → account-level current limits (same on
// every device). Field names differ from session logs (primary_window/limit_window_seconds/
// reset_at), so normalize to the session-log shape (primary/window_minutes/resets_at).
function fetchCodexUsageLive() {
  const c = readCodexToken();
  if (!c) return null;
  try {
    // Authorization via stdin (-H @-) — keeps the token out of `ps` (same pattern as Claude)
    const raw = execSync(
      `/usr/bin/curl -fsS --max-time 5 -H @- -H "ChatGPT-Account-Id: ${c.account}" -H "User-Agent: codex-cli" https://chatgpt.com/backend-api/wham/usage`,
      {
        encoding: "utf8",
        timeout: 8000,
        input: `Authorization: Bearer ${c.token}\n`,
        stdio: ["pipe", "pipe", "ignore"],
      },
    );
    const d = JSON.parse(raw);
    const rl = d?.rate_limit;
    const norm = (w) =>
      w
        ? {
            used_percent: w.used_percent ?? 0,
            window_minutes: w.limit_window_seconds
              ? Math.round(w.limit_window_seconds / 60)
              : null,
            resets_at: w.reset_at ?? null,
          }
        : null;
    // primary_window/secondary_window aren't fixed "5h/weekly" — they're whatever windows are
    // active right now (with no recent 5h usage, the weekly window can arrive as primary).
    // Classify by limit_window_seconds into the right slot (5h=primary / weekly=secondary).
    let primary = null;
    let secondary = null;
    for (const w of [rl?.primary_window, rl?.secondary_window]) {
      if (!w) continue;
      const secs = w.limit_window_seconds || 0;
      if (secs && secs <= 6 * 3600)
        primary = norm(w); // ~5 hours
      else secondary = norm(w); // ~weekly (7 days)
    }
    // credits only matter when no windows at all (premium pay-per-use). Same as session logs.
    const credits =
      !primary && !secondary && d?.credits
        ? {
            has_credits: d.credits.has_credits,
            unlimited: d.credits.unlimited,
            balance: d.credits.balance,
          }
        : null;
    if (!primary && !secondary && !credits) return null;
    const result = {
      measuredAt: Math.floor(Date.now() / 1000),
      live: true,
      limitId: null,
      plan: d?.plan_type || null,
      primary,
      secondary,
      credits,
    };
    try {
      mkdirSync(CLAUDE_STATE_DIR, { recursive: true });
      writeFileSync(CODEX_USAGE_CACHE, JSON.stringify(result));
    } catch {}
    return result;
  } catch {
    return null;
  }
}

function getCodexFromSessions() {
  if (!existsSync(CODEX_SESSIONS)) return null;
  const files = [];
  walkJsonl(CODEX_SESSIONS, files);
  files.sort((a, b) => b.mtime - a.mtime);
  for (const f of files.slice(0, 8)) {
    try {
      const lines = readFileSync(f.path, "utf8").trim().split("\n");
      for (let i = lines.length - 1; i >= 0; i--) {
        if (!lines[i].includes("rate_limits")) continue;
        let obj;
        try {
          obj = JSON.parse(lines[i]);
        } catch {
          continue;
        }
        const rl = obj.payload?.rate_limits ?? obj.rate_limits;
        // prolite=primary/secondary (%), premium=credits (balance) — either shape is valid
        if (rl && (rl.primary || rl.secondary || rl.credits)) {
          return {
            measuredAt: Math.floor(f.mtime / 1000),
            live: false,
            limitId: rl.limit_id || null,
            plan: rl.plan_type || null,
            primary: rl.primary || null,
            secondary: rl.secondary || null,
            credits: rl.credits || null,
          };
        }
      }
    } catch {}
  }
  return null;
}

// Live (account-level, same on every device) first → local session logs → last live cache.
function getCodex() {
  const live = fetchCodexUsageLive();
  if (live) return live;
  const sess = getCodexFromSessions();
  if (sess) return sess;
  try {
    const c = JSON.parse(readFileSync(CODEX_USAGE_CACHE, "utf8"));
    if (c && (c.primary || c.secondary || c.credits))
      return { ...c, live: false };
  } catch {}
  return null;
}
function windowState(w) {
  if (!w) return null;
  const stale = w.resets_at && w.resets_at < now;
  return {
    pct: stale ? 0 : (w.used_percent ?? 0),
    resetsIn: w.resets_at ? w.resets_at - now : null,
    stale,
  };
}
// ── Rendering ──────────────────────────────────────────────────
const claude = getClaude();
const cusage = getClaudeUsage();
const cmodels = getClaudeModels();
const codex = getCodex();
const out = [];

// Menu bar: battery icons (all values are "remaining %")
//   Claude: C5=5h session · CW=weekly · CF=Fable weekly
//   Codex:  X5=5h · XW=weekly
const rem = (pct) => (pct == null ? null : Math.max(0, 100 - pct));
// Single-service users: only show the service that has data
const hasClaude = !!cusage || !!(claude && !claude.error);
const hasCodex = !!codex;
const battItems = [];
// Claude — 3 capsules with usage data, or C5 only from the ccusage block. Neither → skip.
if (cusage) {
  battItems.push({ label: "C5", remain: rem(cusage.fiveHour?.pct) });
  battItems.push({ label: "CW", remain: rem(cusage.weekly?.pct) });
  if (cusage.fable)
    battItems.push({ label: "CF", remain: rem(cusage.fable.pct) });
} else if (claude && !claude.error) {
  battItems.push({ label: "C5", remain: Math.max(0, 100 - claude.elapsedPct) });
}
// Codex — only with session data. No Codex → no X batteries at all.
if (codex && (codex.primary || codex.secondary)) {
  // prolite: 5h / weekly percentage windows
  const p = windowState(codex.primary);
  const s = windowState(codex.secondary);
  // Draw only the windows active right now — omit missing ones instead of empty capsules
  if (p) battItems.push({ label: "X5", remain: Math.max(0, 100 - p.pct) });
  if (s) battItems.push({ label: "XW", remain: Math.max(0, 100 - s.pct) });
} else if (codex && codex.credits) {
  // premium: credit balance (no totals available → has=100 / exhausted=0 / unlimited=100)
  const cr = codex.credits;
  const remain = cr.unlimited
    ? 100
    : cr.has_credits && Number(cr.balance) > 0
      ? 100
      : 0;
  battItems.push({ label: "X", remain });
}
// The remaining number sits inside each capsule → menu bar is image-only; labels live in the legend.
// No data at all (fresh install / neither tool used) → placeholder icon instead.
if (battItems.length) {
  out.push(`| image=${renderBatteryImage(isDarkMode(), battItems)}`);
} else {
  out.push("🔋 —");
}
out.push("---");
const codexLegend =
  codex?.credits && !codex.primary && !codex.secondary
    ? L("X = Codex 크레딧", "X = Codex credits")
    : L("X5·XW = Codex 5시간·주간", "X5·XW = Codex 5h·weekly");
const legendParts = [];
if (hasClaude)
  legendParts.push(
    L(
      "C5·CW·CF = Claude 5시간·주간·Fable",
      "C5·CW·CF = Claude 5h·weekly·Fable",
    ),
  );
if (hasCodex) legendParts.push(codexLegend);
if (legendParts.length) {
  out.push(
    `🔋 ${L("남은 %", "% left")}  ·  ${legendParts.join("  ·  ")} | size=11 color=#8b949e`,
  );
  out.push("---");
}

// Claude details — only when hasClaude (section omitted entirely otherwise)
if (hasClaude) {
  out.push("Claude Code | size=13 color=#8b949e");
  if (cusage) {
    const winRow = (label, w) => {
      if (!w) return;
      const r = Math.max(0, 100 - (w.pct ?? 0));
      const reset = w.resetsAt
        ? w.resetsAt < now
          ? L("리셋됨", "reset")
          : `${L("리셋", "resets")} ${fmtDur(w.resetsAt - now)}`
        : "";
      out.push(
        `${label} ▕${bar(r, 20)}▏ ${Math.round(r)}%  (${L("사용", "used")} ${Math.round(w.pct ?? 0)}%)${reset ? "  ·  " + reset : ""} | font=Menlo color=${heatRemainHex(r)}`,
      );
    };
    winRow(L("5시간 남음", "5h left  "), cusage.fiveHour);
    winRow(L("주간 남음 ", "wk left  "), cusage.weekly);
    if (cusage.fable)
      winRow(`${cusage.fable.model} ${L("남음", "left")}`, cusage.fable);
    out.push(
      cusage.live
        ? `${L("라이브 (Anthropic usage API — 전 디바이스 합산)", "live (Anthropic usage API — all devices combined)")} | size=11 color=#8b949e`
        : `${L(`측정 ${fmtDur(now - cusage.measuredAt)} 전 (캐시 폴백 — Claude Code 로그인·네트워크 확인)`, `cached ${fmtDur(now - cusage.measuredAt)} ago (fallback — check Claude Code login/network)`)} | size=11 color=#d29922`,
    );
  }
  if (claude && !claude.error) {
    out.push(
      `${L("블록 비용", "block cost")}  $${claude.cost.toFixed(2)}  ·  ${fmtTok(claude.tokens)} ${L("토큰", "tokens")}  ·  $${claude.costPerHour?.toFixed(1) ?? "?"}/h | font=Menlo size=11 color=#8b949e`,
    );
  }
  // Today's per-model usage (bars relative to the top model)
  if (cmodels && cmodels.models.length) {
    out.push(
      `${L("오늘 모델별", "today by model")}  ·  ${L("합", "total")} $${cmodels.total.toFixed(0)} | size=11 color=#8b949e`,
    );
    const maxCost = cmodels.models[0].cost || 1;
    for (const m of cmodels.models) {
      const g = bar((m.cost / maxCost) * 100, 12);
      const label = shortModel(m.name).padEnd(9, " ");
      out.push(
        `${label}▕${g}▏ $${m.cost.toFixed(1)}  ${fmtTok(m.tokens)} | font=Menlo`,
      );
    }
  }
  out.push("---");
}

// Codex details — only when hasCodex (section omitted entirely otherwise)
if (hasCodex) {
  out.push(
    `Codex${codex?.plan ? " · " + codex.plan : codex?.limitId ? " · " + codex.limitId : ""} | size=13 color=#8b949e`,
  );
  const p = windowState(codex.primary);
  const s = windowState(codex.secondary);
  // premium: no primary/secondary, credit balance only
  if (!p && !s && codex.credits) {
    const cr = codex.credits;
    if (cr.unlimited) {
      out.push(
        `${L("크레딧  무제한", "credits  unlimited")} | font=Menlo color=#3fb950`,
      );
    } else if (!cr.has_credits || Number(cr.balance) <= 0) {
      out.push(
        `${L("크레딧  소진 · 한도 초과 (0)", "credits  exhausted · limit reached (0)")} | font=Menlo color=#f85149`,
      );
      out.push(
        `      ${L("Codex 설정에서 크레딧 구매 또는 리셋 대기", "buy credits in Codex settings or wait for reset")} | font=Menlo size=11 color=#8b949e`,
      );
    } else {
      out.push(
        `${L("크레딧  잔액", "credits  balance")} ${cr.balance} | font=Menlo color=#3fb950`,
      );
    }
  }
  if (p) {
    const reset = p.stale
      ? L("리셋됨", "reset")
      : p.resetsIn != null
        ? `${L("리셋", "resets")} ${fmtDur(p.resetsIn)}`
        : "";
    const pr = Math.max(0, 100 - p.pct);
    out.push(
      `${L("5시간 남음", "5h left  ")} ▕${bar(pr, 20)}▏ ${Math.round(pr)}%  (${L("사용", "used")} ${Math.round(p.pct)}%) | font=Menlo color=${heatRemainHex(pr)}`,
    );
    out.push(`      ${reset} | font=Menlo size=11 color=#8b949e`);
  }
  if (s) {
    const reset = s.stale
      ? L("리셋됨", "reset")
      : s.resetsIn != null
        ? `${L("리셋", "resets")} ${fmtDur(s.resetsIn)}`
        : "";
    const sr = Math.max(0, 100 - s.pct);
    out.push(
      `${L("주간 남음 ", "wk left  ")} ▕${bar(sr, 20)}▏ ${Math.round(sr)}%  (${L("사용", "used")} ${Math.round(s.pct)}%) | font=Menlo color=${heatRemainHex(sr)}`,
    );
    out.push(`      ${reset} | font=Menlo size=11 color=#8b949e`);
  }
  const age = now - codex.measuredAt;
  out.push(
    codex.live
      ? `${L("라이브 (ChatGPT usage API — 전 디바이스 합산)", "live (ChatGPT usage API — all devices combined)")} | size=11 color=#8b949e`
      : `⚠ ${L(`라이브 조회 실패 — 로그인·네트워크 확인 (${fmtDur(age)} 전 로컬 로그값)`, `live query failed — check login/network (local log from ${fmtDur(age)} ago)`)} | size=11 color=#d29922`,
  );
  out.push("---");
}

// Neither service has data (fresh install) → hint
if (!hasClaude && !hasCodex) {
  out.push(
    `${L("Claude Code나 Codex를 실행하면 사용량이 표시됩니다", "Run Claude Code or Codex and usage will appear here")} | size=12 color=gray`,
  );
  out.push("---");
}

// Highlighted one-click update when a new version exists; manual update row always shown
const upd = getUpdateInfo();
if (upd.hasUpdate) {
  out.push(
    `🆕 ${L(`v${upd.latest} 업데이트 (현재 v${VERSION})`, `Update to v${upd.latest} (current v${VERSION})`)} | bash="${SELF_DIR}/.ccb-update.sh" terminal=false refresh=true color=#28963f`,
  );
} else {
  out.push(
    `⬆️ ${L(`지금 업데이트 — GitHub 최신으로 교체 (현재 v${VERSION})`, `Update now — replace with latest from GitHub (current v${VERSION})`)} | bash="${SELF_DIR}/.ccb-update.sh" terminal=false refresh=true`,
  );
}
out.push(`🔄 ${L("지금 새로고침", "Refresh now")} | refresh=true`);
// Dashboard shortcut only when ccusage is available (optional dependency)
if (claude && !claude.error) {
  out.push(
    `📊 ${L("ccusage 대시보드 열기", "Open ccusage dashboard")} | bash="${CCUSAGE}" param1=blocks param2=--active terminal=true`,
  );
}
out.push(
  `v${VERSION}  ·  Claude & Codex Usage Battery | size=11 color=#8b949e`,
);
// Size toggle — write the other preset to .batt-size and refresh immediately
{
  const other = SIZE === "big" ? "small" : "big";
  const cur =
    SIZE === "big" ? L("크게 (기본)", "big (default)") : L("작게", "small");
  const next = other === "big" ? L("크게", "big") : L("작게", "small");
  out.push(
    `↕ ${L("배터리 크기", "battery size")}: ${cur} — ${L("클릭하면", "click for")} ${next} | bash=/bin/sh param1=-c param2="mkdir -p '${HOME}/.claude/swiftbar' && echo ${other} > '${SIZE_FILE}'" terminal=false refresh=true size=11 color=#8b949e`,
  );
}
out.push(
  `⭐ github.com/dennykim123/claude-codex-battery | href=https://github.com/dennykim123/claude-codex-battery size=11 color=#8b949e`,
);
// Disable the widget — SwiftBar's plugin-disable URL. Re-enable: SwiftBar menu → Plugins
out.push(
  `✕ ${L("위젯 끄기 (SwiftBar 설정에서 재활성화)", "Disable widget (re-enable in SwiftBar settings)")} | href=swiftbar://disableplugin?plugin=claude-codex-usage size=11 color=#8b949e`,
);

console.log(out.join("\n"));
