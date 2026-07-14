#!/usr/bin/env bun
// <xbar.title>Claude & Codex Usage</xbar.title>
// <xbar.version>v3.0</xbar.version>
// <xbar.author>개발부스러기</xbar.author>
// <xbar.desc>Claude Code 5시간 블록 + Codex rate limit을 메뉴바에 배터리 아이콘으로 상시 표시</xbar.desc>
// SwiftBar 플러그인: 1분마다 갱신. 메뉴바=배터리 잔량 아이콘(자체 PNG), 클릭=상세 게이지.

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
// 바이너리 경로 자동 탐지 (환경별로 다름 — 이식성)
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
  return name; // 최후: PATH에 의존
}
const CCUSAGE = findBin("ccusage");
const CODEX_SESSIONS = `${HOME}/.codex/sessions`;
const now = Math.floor(Date.now() / 1000);

// ── 자동 업데이트 (알림 + 원클릭) ──
const VERSION = "2.1.1";
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
// 캐시된 최신 버전을 읽고, 24h+ 지났으면 백그라운드로 GitHub VERSION만 조용히 확인
// (렌더를 막지 않음 — spawn+unref로 detached 실행)
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

// ══ 배터리 아이콘 PNG 렌더 (순수 JS, node:zlib만) ══════════
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
// ── 크기 프리셋: big(기본) / small — 드롭다운 ↕ 행 또는 ~/.claude/swiftbar/.batt-size 로 전환 ──
const SIZE_FILE = `${HOME}/.claude/swiftbar/.batt-size`;
let SIZE = "big";
try {
  if (readFileSync(SIZE_FILE, "utf8").trim() === "small") SIZE = "small";
} catch {}

// 4x6 픽셀 폰트 (big 프리셋)
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
// 3x5 클래식 픽셀 폰트 (small 프리셋)
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
// 프리셋별 지오메트리: font/자간, 캡슐(bw×bh), 배치(capw·간격), 캔버스 높이, 숫자 y오프셋
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
// altCol/boundaryX 지정 시: 픽셀 x가 채움 경계(boundaryX) 왼쪽이면 altCol(밝은 채움 위 대비),
// 오른쪽(빈 배경)이면 col. 지정 없으면 col 단색(그룹 라벨용).
const chAdv = PRESET.adv; // big: 5px('1'만 4px 커닝 — "100" 물림 방지), small: 4px
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
// 실제 macOS 배터리 인디케이터 색 (Apple HIG system colors, 다크/라이트 각각)
function heatRemain(r, dark) {
  if (r <= 20) return dark ? [255, 69, 58] : [255, 59, 48]; // systemRed
  if (r < 50) return dark ? [255, 214, 10] : [255, 204, 0]; // systemYellow
  return dark ? [48, 209, 88] : [52, 199, 89]; // systemGreen
}
const heatRemainHex = (r) =>
  r <= 20 ? "#FF453A" : r < 50 ? "#FFD60A" : "#30D158"; // 드롭다운 게이지 (다크 기준)
// 캡슐 하나: 테두리 + 잔량 채움 + 안에 잔량 숫자(100 포함, 항상 표시)
function drawCapsule(cv, x, midY, remain, ink, dark) {
  const bw = PRESET.bw,
    bh = PRESET.bh,
    by = midY - Math.floor(bh / 2);
  _stroke(cv, x, by, bw, bh, ink);
  _rect(cv, x + bw, by + 3, 2, bh - 6, ink); // 단자
  if (remain != null) {
    const innerW = bw - 4;
    const v = Math.max(0, Math.min(100, remain));
    const fw = Math.round((v / 100) * innerW);
    if (fw > 0) _rect(cv, x + 2, by + 2, fw, bh - 4, heatRemain(remain, dark));
    const s = String(Math.round(v));
    const tx = x + Math.floor((bw - numW(s)) / 2);
    // 채움(밝은 system color) 위 픽셀은 어두운 숫자, 빈 배경 위는 ink → 어디서나 대비 확보
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
// 캡슐 N개(items=[{label,remain}]). 그룹(C=Claude / X=Codex) 앞에 라벨 문자.
function renderBatteryImage(dark, items) {
  const ink = dark ? [235, 235, 235] : [45, 45, 45];
  const CAPW = PRESET.capw,
    GAP = PRESET.gap,
    GGAP = PRESET.ggap,
    PAD = PRESET.pad,
    LBLGAP = PRESET.lblgap;
  const H = PRESET.H;
  const midY = Math.floor(H / 2);
  // 폭 계산 (그룹 라벨 포함)
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
      drawNum(cv, x, midY - PRESET.dy, g, ink); // 그룹 라벨 C 또는 X
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

// ── 게이지 렌더 (부분 블록, 의존성 0) ──────────────────────
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
// 사용률 → 색 (GitHub 신호색)
function heat(pct) {
  if (pct >= 80) return "#f85149"; // 빨강
  if (pct >= 50) return "#d29922"; // 노랑
  return "#3fb950"; // 초록
}

// ── 공용 유틸 ──────────────────────────────────────────────
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

// ── 1. Claude Code: 활성 5시간 블록 ────────────────────────
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

// ── 1b. Claude 오늘 모델별 사용 (Opus/Sonnet/Fable/Haiku) ──
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

// ── 1c. Claude 실제 rate limit — Anthropic OAuth usage API 직접 조회 ──
// 이 맥의 Claude Code 로그인 토큰(키체인)으로 /usage와 같은 데이터를 서버에서 직접
// 가져온다. 수치는 계정 단위 합산이라 다른 디바이스·데스크톱앱·웹 사용분도 포함.
// 실패 시 폴백: 자체 캐시(마지막 성공 응답) → 레거시 usage-cache.json 파일.
const CLAUDE_STATE_DIR = `${HOME}/.claude/swiftbar`;
const CLAUDE_USAGE_CACHE = `${CLAUDE_STATE_DIR}/.claude-usage.json`;
// Codex도 계정 단위 라이브 조회가 가능하다: Codex CLI가 자체적으로 60초마다 폴링하는
// ChatGPT usage 엔드포인트(/backend-api/wham/usage)를 auth.json의 토큰으로 직접 GET한다.
// 응답은 요청(토큰 소비) 없이 현재 한도만 주므로, 세션 로그(로컬·맥마다 다름) 대신 이걸 우선.
const CODEX_AUTH = `${HOME}/.codex/auth.json`;
const CODEX_USAGE_CACHE = `${CLAUDE_STATE_DIR}/.codex-usage.json`;
const LEGACY_USAGE_FILES = [
  `${HOME}/.claude/MEMORY/STATE/usage-cache.json`,
  `${HOME}/.claude/PAI/MEMORY/STATE/usage-cache.json`,
];

// 토큰은 반환값으로만 존재 — 파일·로그·프로세스 인자 어디에도 남기지 않는다
function readClaudeToken() {
  // 옵트아웃: 키체인 접근/라이브 조회를 원치 않으면 `touch ~/.claude/swiftbar/.no-live`
  // — 키체인 프롬프트에서 '거부'를 누르면 2분마다 다시 뜨므로, 그 대신 이 스위치를 쓴다.
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
    // 키체인이 없는 환경(예: 수동 이전) 대비 — Claude Code의 파일 자격증명
    const raw = readFileSync(`${HOME}/.claude/.credentials.json`, "utf8");
    return JSON.parse(raw)?.claudeAiOauth?.accessToken ?? null;
  } catch {}
  return null;
}

function fetchClaudeUsageLive() {
  const token = readClaudeToken();
  if (!token) return null;
  try {
    // Authorization 헤더는 stdin(-H @-)으로 전달 — ps 프로세스 목록에 토큰 노출 방지
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

// 5시간 세션 / 주간 전체 / Fable 주간(weekly_scoped) 사용률
function getClaudeUsage() {
  const src = fetchClaudeUsageLive() ?? readClaudeUsageFallback();
  if (!src) return null;
  const { data: d, measuredAt, live } = src;
  try {
    const toTs = (iso) => (iso ? Math.floor(Date.parse(iso) / 1000) : null);
    const win = (o) =>
      o ? { pct: o.utilization ?? 0, resetsAt: toTs(o.resets_at) } : null;
    // Fable(또는 최상위 모델) 주간 scoped 한도
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

// ── 2. Codex: 가장 신선한 rate_limits ──────────────────────
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
// auth.json에서 ChatGPT 토큰을 읽는다(.no-live면 라이브 조회 안 함, Claude와 같은 스위치).
function readCodexToken() {
  if (existsSync(`${CLAUDE_STATE_DIR}/.no-live`)) return null;
  try {
    const d = JSON.parse(readFileSync(CODEX_AUTH, "utf8"));
    const t = d?.tokens?.access_token;
    if (t) return { token: t, account: d?.tokens?.account_id || "" };
  } catch {}
  return null;
}

// 라이브: ChatGPT usage 엔드포인트를 직접 GET → 계정 단위 최신 한도(전 디바이스 동일).
// 응답 필드명이 세션 로그와 다르므로(primary_window/limit_window_seconds/reset_at)
// 세션 로그 형식(primary/window_minutes/resets_at)으로 정규화해 이후 로직을 그대로 쓴다.
function fetchCodexUsageLive() {
  const c = readCodexToken();
  if (!c) return null;
  try {
    // Authorization은 stdin(-H @-)으로 — ps 목록에 토큰 노출 방지 (Claude와 동일 패턴)
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
    // primary_window/secondary_window는 "5시간/주간" 고정이 아니라 그때 활성인 창이다
    // (5시간 미사용 시 주간 창이 primary로 오기도 함). limit_window_seconds로 판별해
    // 올바른 슬롯(5시간=primary / 주간=secondary)에 배치한다. 안 온 창은 null.
    let primary = null;
    let secondary = null;
    for (const w of [rl?.primary_window, rl?.secondary_window]) {
      if (!w) continue;
      const secs = w.limit_window_seconds || 0;
      if (secs && secs <= 6 * 3600)
        primary = norm(w); // ~5시간
      else secondary = norm(w); // ~주간(7일)
    }
    // credits는 창(primary/secondary)이 전혀 없을 때만 의미(premium 소진형). 세션 로그와 동일.
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
        // prolite=primary/secondary(%), premium=credits(잔액) — 둘 중 하나라도 있으면 유효
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

// 라이브(계정 단위, 전 디바이스 동일) 우선 → 실패 시 로컬 세션 로그 → 마지막 라이브 캐시.
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
// ── 렌더링 ─────────────────────────────────────────────────
const claude = getClaude();
const cusage = getClaudeUsage();
const cmodels = getClaudeModels();
const codex = getCodex();
const out = [];

// 메뉴바: 배터리 잔량 아이콘 (전부 "남은 %")
//   Claude(usage-cache): C5=5시간세션 · CW=주간전체 · CF=Fable 주간
//   Codex(rate_limits) : X5=5시간 · XW=주간
const rem = (pct) => (pct == null ? null : Math.max(0, 100 - pct));
// 한쪽만 쓰는 사용자 대응: 데이터가 있는 서비스만 표시
const hasClaude = !!cusage || !!(claude && !claude.error);
const hasCodex = !!codex;
const battItems = [];
// Claude — usage-cache 있으면 3종, 없어도 ccusage 블록이 있으면 C5만. 둘 다 없으면 Claude 배터리 생략.
if (cusage) {
  battItems.push({ label: "C5", remain: rem(cusage.fiveHour?.pct) });
  battItems.push({ label: "CW", remain: rem(cusage.weekly?.pct) });
  if (cusage.fable)
    battItems.push({ label: "CF", remain: rem(cusage.fable.pct) });
} else if (claude && !claude.error) {
  battItems.push({ label: "C5", remain: Math.max(0, 100 - claude.elapsedPct) });
}
// Codex — 세션 데이터 있을 때만. Codex 안 쓰는 사람에겐 X 배터리 자체를 안 그림.
if (codex && (codex.primary || codex.secondary)) {
  // prolite: 5시간·주간 % 창
  const p = windowState(codex.primary);
  const s = windowState(codex.secondary);
  // 그때 활성인 창만 그린다 — 없는 창은 빈 캡슐 대신 생략 (5시간 미사용 시 X5 없음)
  if (p) battItems.push({ label: "X5", remain: Math.max(0, 100 - p.pct) });
  if (s) battItems.push({ label: "XW", remain: Math.max(0, 100 - s.pct) });
} else if (codex && codex.credits) {
  // premium: 크레딧 잔액 (총량 미제공 → 있음=100 / 소진=0 / 무제한=100)
  const cr = codex.credits;
  const remain = cr.unlimited
    ? 100
    : cr.has_credits && Number(cr.balance) > 0
      ? 100
      : 0;
  battItems.push({ label: "X", remain });
}
// 잔량 숫자가 캡슐 안에 들어감 → 메뉴바는 이미지만. 라벨은 드롭다운 범례.
// 둘 다 없으면(신규/양쪽 미사용) 배터리 대신 안내 아이콘.
if (battItems.length) {
  out.push(`| image=${renderBatteryImage(isDarkMode(), battItems)}`);
} else {
  out.push("🔋 —");
}
out.push("---");
const codexLegend =
  codex?.credits && !codex.primary && !codex.secondary
    ? "X = Codex 크레딧"
    : "X5·XW = Codex 5시간·주간";
const legendParts = [];
if (hasClaude) legendParts.push("C5·CW·CF = Claude 5시간·주간·Fable");
if (hasCodex) legendParts.push(codexLegend);
if (legendParts.length) {
  out.push(
    `🔋 남은 %  ·  ${legendParts.join("  ·  ")} | size=11 color=#8b949e`,
  );
  out.push("---");
}

// Claude 상세 — hasClaude일 때만 (Claude Code 안 쓰면 섹션 자체 생략)
if (hasClaude) {
  out.push("Claude Code | size=13 color=#8b949e");
  if (cusage) {
    const winRow = (label, w) => {
      if (!w) return;
      const r = Math.max(0, 100 - (w.pct ?? 0));
      const reset = w.resetsAt
        ? w.resetsAt < now
          ? "리셋됨"
          : `리셋 ${fmtDur(w.resetsAt - now)}`
        : "";
      out.push(
        `${label} ▕${bar(r, 20)}▏ ${Math.round(r)}%  (사용 ${Math.round(w.pct ?? 0)}%)${reset ? "  ·  " + reset : ""} | font=Menlo color=${heatRemainHex(r)}`,
      );
    };
    winRow("5시간 남음", cusage.fiveHour);
    winRow("주간 남음 ", cusage.weekly);
    if (cusage.fable) winRow(`${cusage.fable.model} 남음`, cusage.fable);
    out.push(
      cusage.live
        ? `라이브 (Anthropic usage API — 전 디바이스 합산) | size=11 color=#8b949e`
        : `측정 ${fmtDur(now - cusage.measuredAt)} 전 (캐시 폴백 — Claude Code 로그인·네트워크 확인) | size=11 color=#d29922`,
    );
  }
  if (claude && !claude.error) {
    out.push(
      `블록 비용  $${claude.cost.toFixed(2)}  ·  ${fmtTok(claude.tokens)} 토큰  ·  $${claude.costPerHour?.toFixed(1) ?? "?"}/h | font=Menlo size=11 color=#8b949e`,
    );
  }
  // 오늘 모델별 사용 (최대 모델 대비 막대)
  if (cmodels && cmodels.models.length) {
    out.push(
      `오늘 모델별  ·  합 $${cmodels.total.toFixed(0)} | size=11 color=#8b949e`,
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

// Codex 상세 — hasCodex일 때만 (Codex 안 쓰면 섹션 자체 생략)
if (hasCodex) {
  out.push(
    `Codex${codex?.plan ? " · " + codex.plan : codex?.limitId ? " · " + codex.limitId : ""} | size=13 color=#8b949e`,
  );
  const p = windowState(codex.primary);
  const s = windowState(codex.secondary);
  // premium: primary/secondary 없이 크레딧 잔액만
  if (!p && !s && codex.credits) {
    const cr = codex.credits;
    if (cr.unlimited) {
      out.push("크레딧  무제한 | font=Menlo color=#3fb950");
    } else if (!cr.has_credits || Number(cr.balance) <= 0) {
      out.push("크레딧  소진 · 한도 초과 (0) | font=Menlo color=#f85149");
      out.push(
        "      Codex 설정에서 크레딧 구매 또는 리셋 대기 | font=Menlo size=11 color=#8b949e",
      );
    } else {
      out.push(`크레딧  잔액 ${cr.balance} | font=Menlo color=#3fb950`);
    }
  }
  if (p) {
    const reset = p.stale
      ? "리셋됨"
      : p.resetsIn != null
        ? `리셋 ${fmtDur(p.resetsIn)}`
        : "";
    const pr = Math.max(0, 100 - p.pct);
    out.push(
      `5시간 남음 ▕${bar(pr, 20)}▏ ${Math.round(pr)}%  (사용 ${Math.round(p.pct)}%) | font=Menlo color=${heatRemainHex(pr)}`,
    );
    out.push(`      ${reset} | font=Menlo size=11 color=#8b949e`);
  }
  if (s) {
    const reset = s.stale
      ? "리셋됨"
      : s.resetsIn != null
        ? `리셋 ${fmtDur(s.resetsIn)}`
        : "";
    const sr = Math.max(0, 100 - s.pct);
    out.push(
      `주간 남음  ▕${bar(sr, 20)}▏ ${Math.round(sr)}%  (사용 ${Math.round(s.pct)}%) | font=Menlo color=${heatRemainHex(sr)}`,
    );
    out.push(`      ${reset} | font=Menlo size=11 color=#8b949e`);
  }
  const age = now - codex.measuredAt;
  out.push(
    codex.live
      ? `라이브 (ChatGPT usage API — 전 디바이스 합산) | size=11 color=#8b949e`
      : `⚠ 라이브 조회 실패 — 로그인·네트워크 확인 (${fmtDur(age)} 전 로컬 로그값) | size=11 color=#d29922`,
  );
  out.push("---");
}

// 둘 다 없으면(신규/양쪽 미사용) 안내
if (!hasClaude && !hasCodex) {
  out.push(
    "Claude Code나 Codex를 실행하면 사용량이 표시됩니다 | size=12 color=gray",
  );
  out.push("---");
}

// 새 버전이 있으면 강조 원클릭 업데이트, 없어도 수동 업데이트 행은 항상 노출
const upd = getUpdateInfo();
if (upd.hasUpdate) {
  out.push(
    `🆕 v${upd.latest} 업데이트 (현재 v${VERSION}) | bash="${SELF_DIR}/.ccb-update.sh" terminal=false refresh=true color=#28963f`,
  );
} else {
  out.push(
    `⬆️ 지금 업데이트 — GitHub 최신으로 교체 (현재 v${VERSION}) | bash="${SELF_DIR}/.ccb-update.sh" terminal=false refresh=true`,
  );
}
out.push("🔄 지금 새로고침 | refresh=true");
// ccusage가 있을 때만(선택 의존) 대시보드 바로가기 노출
if (claude && !claude.error) {
  out.push(
    `📊 ccusage 대시보드 열기 | bash="${CCUSAGE}" param1=blocks param2=--active terminal=true`,
  );
}
out.push(
  `v${VERSION}  ·  Claude & Codex Usage Battery | size=11 color=#8b949e`,
);
// 크기 전환 — .batt-size 파일에 반대 프리셋을 기록하고 즉시 새로고침
{
  const other = SIZE === "big" ? "small" : "big";
  out.push(
    `↕ 배터리 크기: ${SIZE === "big" ? "크게 (기본)" : "작게"} — 클릭하면 ${other === "big" ? "크게" : "작게"}로 | bash=/bin/sh param1=-c param2="mkdir -p '${HOME}/.claude/swiftbar' && echo ${other} > '${SIZE_FILE}'" terminal=false refresh=true size=11 color=#8b949e`,
  );
}
out.push(
  `⭐ github.com/dennykim123/claude-codex-battery | href=https://github.com/dennykim123/claude-codex-battery size=11 color=#8b949e`,
);
// 위젯 끄기 — SwiftBar의 플러그인 비활성화 URL. 재활성화: SwiftBar 메뉴 → Plugins
out.push(
  `✕ 위젯 끄기 (SwiftBar 설정에서 재활성화) | href=swiftbar://disableplugin?plugin=claude-codex-usage size=11 color=#8b949e`,
);

console.log(out.join("\n"));
