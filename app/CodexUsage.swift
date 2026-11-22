// Codex rate limit — queries the ChatGPT usage endpoint directly (ported from widget 2)
// Prefers live data (account-level, same across all devices) → falls back to local session logs → last live cache.
// One reading per login: ~/.codex plus any other CODEX_HOME found (Accounts.swift).
import Foundation

struct CodexWindow {
  let usedPercent: Double
  let resetsAt: Int? // epoch seconds
}

struct CodexCredits {
  let hasCredits: Bool
  let unlimited: Bool
  let balance: Double?
}

struct CodexUsage {
  let account: CodexAccount
  let measuredAt: Int
  let live: Bool
  let limitId: String?
  let plan: String?
  let primary: CodexWindow? // ~5-hour window
  let secondary: CodexWindow? // ~weekly window
  let credits: CodexCredits? // premium consumable-style (only when there's no window at all)
}

struct WindowState {
  let pct: Double // usage rate (0 once past the reset)
  let resetsIn: Int?
  let stale: Bool
}

private func parseWindow(_ a: Any?, resetKey: String) -> CodexWindow? {
  guard let w = jd(a) else { return nil }
  return CodexWindow(usedPercent: jn(w["used_percent"]) ?? 0, resetsAt: resetTs(w[resetKey]))
}

private func parseCredits(_ a: Any?) -> CodexCredits? {
  guard let cr = jd(a) else { return nil }
  return CodexCredits(hasCredits: (cr["has_credits"] as? Bool) ?? false,
                      unlimited: (cr["unlimited"] as? Bool) ?? false,
                      balance: jn(cr["balance"]))
}

// Live: GET /backend-api/wham/usage → normalizes the response fields (primary_window/limit_window_seconds/reset_at)
// into the session-log format. primary/secondary are "whichever window is active at the time," so the slot is decided by window length.
// A failed call (expired token, 429, offline) pauses live calls 5 → 30 min instead of
// retrying every refresh. Kept per login (CODEX_HOME), since limits are per account.
private var codexPausedUntil: [String: Int] = [:]
private var codexPause: [String: Int] = [:]

private func pauseCodex(_ key: String, now: Int, retryAfter: Int?) {
  let pause = min(1800, max(300, codexPause[key, default: 0] * 2))
  codexPause[key] = pause
  codexPausedUntil[key] = now + max(min(retryAfter ?? 0, 1800), pause)
}

private func fetchCodexLive(_ acc: CodexAccount, now: Int) -> CodexUsage? {
  let key = acc.home
  if now < codexPausedUntil[key, default: 0] { return nil }
  // Only Codex renews its token; an expired one would just earn a 401
  guard let token = acc.token, codexTokenExp(acc) == 0 || codexTokenExp(acc) > now + 60 else { return nil }
  let res = httpFetch("https://chatgpt.com/backend-api/wham/usage",
                      headers: ["Authorization": "Bearer \(token)",
                                "ChatGPT-Account-Id": acc.accountId ?? "",
                                "User-Agent": "codex-cli"], timeout: 5)
  guard let raw = res.data,
        let d = jd(try? JSONSerialization.jsonObject(with: raw))
  else {
    pauseCodex(key, now: now, retryAfter: res.retryAfter)
    return nil
  }
  codexPause[key] = 0
  let rl = jd(d["rate_limit"])
  var primary: CodexWindow? = nil
  var secondary: CodexWindow? = nil
  for w0 in [rl?["primary_window"], rl?["secondary_window"]] {
    guard let w = jd(w0) else { continue }
    let secs = jn(w["limit_window_seconds"]) ?? 0
    if secs > 0, secs <= 6 * 3600 { primary = parseWindow(w, resetKey: "reset_at") } // ~5 hours
    else { secondary = parseWindow(w, resetKey: "reset_at") } // ~weekly (7 days)
  }
  let credits = (primary == nil && secondary == nil) ? parseCredits(d["credits"]) : nil
  if primary == nil, secondary == nil, credits == nil {
    pauseCodex(key, now: now, retryAfter: nil)
    return nil
  }
  let result = CodexUsage(account: acc, measuredAt: now, live: true, limitId: nil, plan: jstr(d["plan_type"]),
                          primary: primary, secondary: secondary, credits: credits)
  saveCache(result)
  return result
}

// The cache is kept in the same JSON format as the SwiftBar widget (so either side can read it)
private func saveCache(_ u: CodexUsage) {
  func winJSON(_ w: CodexWindow?) -> Any {
    guard let w = w else { return NSNull() }
    var o: [String: Any] = ["used_percent": w.usedPercent]
    if let r = w.resetsAt { o["resets_at"] = r }
    return o
  }
  var obj: [String: Any] = ["measuredAt": u.measuredAt, "live": u.live,
                            "primary": winJSON(u.primary), "secondary": winJSON(u.secondary)]
  if let p = u.plan { obj["plan"] = p }
  if let cr = u.credits {
    var c: [String: Any] = ["has_credits": cr.hasCredits, "unlimited": cr.unlimited]
    if let b = cr.balance { c["balance"] = b }
    obj["credits"] = c
  } else { obj["credits"] = NSNull() }
  // Which login wrote it — so a switched login never shows the old account's copy
  var tag: [String: Any] = ["home": u.account.home]
  if let id = u.account.accountId { tag["id"] = id }
  if let l = u.account.label { tag["label"] = l }
  obj["account"] = tag
  writeJSONFile(u.account.usageCachePath, obj)
}

// Fallback 1: scan rate_limits from the freshest session log (.jsonl)
private func codexFromSessions(_ acc: CodexAccount) -> CodexUsage? {
#if MAS_BUILD
  var files: [(path: String, mtime: Int, data: () -> String?)] = codexSessionFiles().map { f in
    (f.path.path, f.mtime, { () -> String? in
      guard let base = codexGrantedURL(), base.startAccessingSecurityScopedResource() else { return nil }
      defer { base.stopAccessingSecurityScopedResource() }
      return try? String(contentsOf: f.path, encoding: .utf8)
    })
  }
#else
  let sessions = "\(acc.home)/sessions"
  guard FileManager.default.fileExists(atPath: sessions) else { return nil }
  var files: [(path: String, mtime: Int, data: () -> String?)] = []
  if let en = FileManager.default.enumerator(atPath: sessions) {
    for case let rel as String in en where rel.hasSuffix(".jsonl") {
      let p = sessions + "/" + rel
      files.append((p, fileMtime(p), { try? String(contentsOfFile: p, encoding: .utf8) }))
    }
  }
#endif
  files.sort { $0.mtime > $1.mtime }
  for f in files.prefix(8) {
    guard let content = f.data() else { continue }
    let lines = content.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "\n")
    for line in lines.reversed() {
      guard line.contains("rate_limits"),
            let obj = jd(try? JSONSerialization.jsonObject(with: Data(line.utf8))) else { continue }
      guard let rl = jd(jd(obj["payload"])?["rate_limits"]) ?? jd(obj["rate_limits"]),
            rl["primary"] != nil || rl["secondary"] != nil || rl["credits"] != nil else { continue }
      return CodexUsage(account: acc, measuredAt: f.mtime, live: false,
                        limitId: jstr(rl["limit_id"]), plan: jstr(rl["plan_type"]),
                        primary: parseWindow(rl["primary"], resetKey: "resets_at"),
                        secondary: parseWindow(rl["secondary"], resetKey: "resets_at"),
                        credits: parseCredits(rl["credits"]))
    }
  }
  return nil
}

// Fallback 2: last live cache (skipped when another account wrote it)
private func codexFromCache(_ acc: CodexAccount) -> CodexUsage? {
  guard let c = jd(readJSONFile(acc.usageCachePath)) else { return nil }
  if let tagged = jstr(jd(c["account"])?["id"]), let mine = acc.accountId, tagged != mine { return nil }
  let primary = parseWindow(c["primary"], resetKey: "resets_at")
  let secondary = parseWindow(c["secondary"], resetKey: "resets_at")
  let credits = parseCredits(c["credits"])
  if primary == nil, secondary == nil, credits == nil { return nil }
  return CodexUsage(account: acc, measuredAt: Int(jn(c["measuredAt"]) ?? 0), live: false,
                    limitId: jstr(c["limitId"]), plan: jstr(c["plan"]),
                    primary: primary, secondary: secondary, credits: credits)
}

// One reading per Codex login (Accounts.swift)
func getCodexAll(now: Int) -> [CodexUsage] {
  discoverCodexAccounts(now: now).compactMap { acc in
    if let live = fetchCodexLive(acc, now: now) { return live }
    // Offline: a days-old session log must not outrank a cache written minutes ago
    return [codexFromSessions(acc), codexFromCache(acc)].compactMap { $0 }.max { $0.measuredAt < $1.measuredAt }
  }
}

func windowState(_ w: CodexWindow?, now: Int) -> WindowState? {
  guard let w = w else { return nil }
  let stale = (w.resetsAt ?? Int.max) < now
  return WindowState(pct: stale ? 0 : w.usedPercent,
                     resetsIn: w.resetsAt.map { $0 - now }, stale: stale)
}
