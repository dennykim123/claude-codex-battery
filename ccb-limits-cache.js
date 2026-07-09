#!/usr/bin/env bun
// Statusline hook that feeds the battery widget its Claude rate-limit data.
//
// Claude Code pipes session JSON — including `rate_limits` (5h / weekly
// used_percentage + resets_at) — to the configured statusLine command.
// That stdin JSON is the ONLY place Claude Code exposes rate limits, so this
// script sits in the statusline chain, caches them to
// ~/.claude/swiftbar/usage-cache.json in the widget's format, then hands the
// input through to the user's original statusline command untouched (or
// prints a minimal model-name line if the user had none).
//
// Wiring (done by install.sh):
//   bun .ccb-limits-cache.js --install
// rewrites statusLine.command in ~/.claude/settings.json to route through
// this script, wrapping any pre-existing command as argv[2].

import {
  readFileSync,
  writeFileSync,
  mkdirSync,
  renameSync,
  copyFileSync,
  existsSync,
} from "node:fs";
import { homedir } from "node:os";

const HOME = homedir();
const SETTINGS = `${HOME}/.claude/settings.json`;
const CACHE_DIR = `${HOME}/.claude/swiftbar`;

// ── install mode: wire ourselves into settings.json ──
if (process.argv[2] === "--install") {
  const shq = (x) => `'${String(x).replaceAll("'", `'\\''`)}'`;
  let s = {};
  if (existsSync(SETTINGS)) {
    // If settings.json is corrupt, fail loudly rather than overwrite it.
    s = JSON.parse(readFileSync(SETTINGS, "utf8"));
  }
  const cur = s.statusLine?.command ?? "";
  if (cur.includes(".ccb-limits-cache.js")) {
    console.log("statusline hook already wired");
    process.exit(0);
  }
  if (existsSync(SETTINGS)) copyFileSync(SETTINGS, `${SETTINGS}.ccb-bak`);
  const self = process.argv[1];
  const cmd = cur
    ? `${shq(process.execPath)} ${shq(self)} ${shq(cur)}`
    : `${shq(process.execPath)} ${shq(self)}`;
  s.statusLine = { type: "command", command: cmd };
  writeFileSync(SETTINGS, JSON.stringify(s, null, 2) + "\n");
  console.log(
    cur ? `wrapped existing statusline: ${cur}` : "installed as statusline",
  );
  process.exit(0);
}

// ── statusline mode: cache rate_limits, then pass through ──
const input = readFileSync(0, "utf8");
let j = {};
try {
  j = JSON.parse(input);
} catch {}

const rl = j.rate_limits;
if (rl && (rl.five_hour || rl.seven_day)) {
  try {
    // statusline gives epoch seconds; the widget parses ISO strings
    const iso = (t) =>
      t == null
        ? null
        : typeof t === "number"
          ? new Date(t * 1000).toISOString()
          : String(t);
    const win = (o) =>
      o ? { utilization: o.used_percentage ?? 0, resets_at: iso(o.resets_at) } : null;
    mkdirSync(CACHE_DIR, { recursive: true });
    const out = JSON.stringify({
      five_hour: win(rl.five_hour),
      seven_day: win(rl.seven_day),
    });
    // write + rename = atomic, so the widget never reads a partial file
    writeFileSync(`${CACHE_DIR}/usage-cache.json.tmp`, out);
    renameSync(`${CACHE_DIR}/usage-cache.json.tmp`, `${CACHE_DIR}/usage-cache.json`);
  } catch {
    // a cache failure must never break the user's statusline
  }
}

const orig = process.argv[2];
if (orig) {
  const p = Bun.spawnSync(["sh", "-c", orig], {
    stdin: Buffer.from(input),
    stdout: "inherit",
    stderr: "inherit",
  });
  process.exit(p.exitCode ?? 0);
} else {
  process.stdout.write(j.model?.display_name ?? "");
}
