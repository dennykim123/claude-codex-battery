// Claude's actual rate limit — queries the Anthropic OAuth usage API directly (ported from widget 1c)
// Fetches /usage data straight from the server using this Mac's Claude Code login token (keychain).
// Figures are aggregated at the account level. On failure: own cache → legacy usage-cache.json fallback.
import Foundation

struct UsageWindow {
  let pct: Double // usage %
  let resetsAt: Int? // epoch seconds
}

// A weekly cap scoped to one model. The name and the capsule label both come
// from the API response, so a model change needs no code change here.
struct ModelCapWindow {
  let pct: Double
  let resetsAt: Int?
  let model: String
  let label: String
}

// Why the last live fetch did not happen — shown in the menu instead of a generic warning
enum ClaudeIssue { case rateLimited, loginExpired, failed }

struct ClaudeUsage {
  let measuredAt: Int
  let live: Bool
  let issue: ClaudeIssue?
  let fiveHour: UsageWindow?
  let weekly: UsageWindow?
  let modelCaps: [ModelCapWindow]
}

private let USAGE_CACHE = "\(STATE_DIR)/.claude-usage.json"
private let LEGACY_USAGE_FILES = [
  "\(HOME)/.claude/MEMORY/STATE/usage-cache.json",
  "\(HOME)/.claude/PAI/MEMORY/STATE/usage-cache.json",
]

// Token exists only in the return value — never left in files, logs, or process arguments.
// Cached in memory for the process lifetime so the Keychain is consulted at most once per
// launch (an ad-hoc-signed build would otherwise re-prompt on every 2-minute refresh);
// a denial backs off for an hour instead of nagging.
private var cachedClaudeToken: String?
private var cachedClaudeTokenExp: Int?
private var claudeTokenDeniedUntil: Int = 0
private var claudeTokenRecheckAt: Int = 0
private var claudeIssue: ClaudeIssue?

func invalidateClaudeToken() { cachedClaudeToken = nil; cachedClaudeTokenExp = nil }

// claudeAiOauth → (accessToken, expiresAt in epoch seconds). expiresAt arrives in ms.
private func parseClaudeCred(_ obj: Any?) -> (token: String, exp: Int?)? {
  guard let o = jd(jd(obj)?["claudeAiOauth"]), let t = jstr(o["accessToken"]), !t.isEmpty else { return nil }
  let exp = jn(o["expiresAt"]).map { $0 > 1e12 ? Int($0 / 1000) : Int($0) }
  return (t, exp)
}

private func loadClaudeCred() -> (token: String, exp: Int?)? {
#if MAS_BUILD
  // Sandboxed: query the Keychain item directly (user approves an access prompt once)
  let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                          kSecAttrService as String: "Claude Code-credentials",
                          kSecReturnData as String: true,
                          kSecMatchLimit as String: kSecMatchLimitOne]
  var out: CFTypeRef?
  if SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data,
     let c = parseClaudeCred(try? JSONSerialization.jsonObject(with: d)) { return c }
  return nil
#else
  if let raw = runCmd("/usr/bin/security", ["find-generic-password", "-s", "Claude Code-credentials", "-w"], timeout: 3),
     let c = parseClaudeCred(try? JSONSerialization.jsonObject(with: Data(raw.trimmingCharacters(in: .whitespacesAndNewlines).utf8))) {
    return c
  }
  // For environments without a keychain — Claude Code's file-based credentials
  return parseClaudeCred(readJSONFile("\(HOME)/.claude/.credentials.json"))
#endif
}

// The access token lives ~8h and only Claude Code renews it, so an expired one is
// re-read at most every 5 min (Claude Code may have rewritten it) and never sent.
private func readClaudeToken(now: Int) -> String? {
  if liveDisabled() { return nil }
  if let t = cachedClaudeToken, (cachedClaudeTokenExp ?? Int.max) > now + 60 { return t }
  if now < claudeTokenDeniedUntil || now < claudeTokenRecheckAt { return nil }
  guard let c = loadClaudeCred() else {
    claudeTokenDeniedUntil = now + 3600
    return nil
  }
  if let exp = c.exp, exp <= now + 60 {
    invalidateClaudeToken()
    claudeTokenRecheckAt = now + 300
    claudeIssue = .loginExpired
    return nil
  }
  cachedClaudeToken = c.token
  cachedClaudeTokenExp = c.exp
  return c.token
}

// The usage endpoint rate-limits per account, and Claude Code / statuslines poll it too.
// After a 429, stop asking until Retry-After (or a doubling 5→30 min pause) has passed,
// since retrying every refresh keeps the limit from ever clearing.
private var rateLimitedUntil = 0
private var rateLimitPause = 0

// The endpoint allows only a handful of calls before it 429s, so a copy younger than
// this is served as-is instead of asking again on every 2-minute refresh.
private let USAGE_MIN_INTERVAL = 300

private func fetchLive(now: Int) -> (data: [String: Any], measuredAt: Int, live: Bool)? {
  if let c = jd(readJSONFile(USAGE_CACHE)), let data = jd(c["data"]), data["five_hour"] != nil,
     let at = jn(c["fetchedAt"]).map(Int.init), now - at < USAGE_MIN_INTERVAL {
    claudeIssue = nil
    return (data, at, true)
  }
  if now < rateLimitedUntil { return nil }
  guard let token = readClaudeToken(now: now) else { return nil }
  let res = httpFetch("https://api.anthropic.com/api/oauth/usage",
                      headers: ["Authorization": "Bearer \(token)",
                                "anthropic-beta": "oauth-2025-04-20"], timeout: 5)
  if let raw = res.data,
     let obj = jd(try? JSONSerialization.jsonObject(with: raw)),
     obj["five_hour"] != nil {
    rateLimitPause = 0
    claudeIssue = nil
    writeJSONFile(USAGE_CACHE, ["fetchedAt": now, "data": obj])
    return (obj, now, true)
  }
  // Any failure pauses (5 → 30 min, or Retry-After); only an auth error drops the token
  if res.status == 401 || res.status == 403 { invalidateClaudeToken() }
  claudeIssue = res.status == 429 ? .rateLimited : (res.status == 401 ? .loginExpired : .failed)
  rateLimitPause = min(1800, max(300, rateLimitPause * 2))
  rateLimitedUntil = now + max(res.retryAfter ?? 0, rateLimitPause)
  return nil
}

private func readFallback() -> (data: [String: Any], measuredAt: Int, live: Bool)? {
  if let c = jd(readJSONFile(USAGE_CACHE)), let data = jd(c["data"]), data["five_hour"] != nil {
    return (data, Int(jn(c["fetchedAt"]) ?? 0), false)
  }
  for f in LEGACY_USAGE_FILES {
    if let d = jd(readJSONFile(f)), d["five_hour"] != nil {
      return (d, fileMtime(f), false)
    }
  }
  return nil
}

// "Fable" → "CF", "Opus 4.8" → "CO". On a collision the rest of the name is
// walked, then a digit, so two model caps never share a label.
func claudeCapLabel(_ displayName: String, used: inout Set<String>) -> String {
  for ch in displayName.uppercased() where ch.isLetter || ch.isNumber {
    let cand = "C\(ch)"
    if !used.contains(cand) { used.insert(cand); return cand }
  }
  for i in 1...9 {
    let cand = "C\(i)"
    if !used.contains(cand) { used.insert(cand); return cand }
  }
  return "C?"
}

// 5-hour session / overall weekly / per-model weekly-scoped usage rates
func getClaudeUsage(now: Int) -> ClaudeUsage? {
  guard let src = fetchLive(now: now) ?? readFallback() else { return nil }
  let d = src.data
  // A window whose reset has passed (a cached copy after a 429 or offline) has been refilled
  func used(_ pct: Double, _ resetsAt: Int?) -> Double { (resetsAt ?? Int.max) <= now ? 0 : pct }
  func win(_ o: Any?) -> UsageWindow? {
    guard let w = jd(o), let pct = jn(w["utilization"]) else { return nil }
    let ra = parseISO(jstr(w["resets_at"]))
    return UsageWindow(pct: used(pct, ra), resetsAt: ra)
  }
  // Every weekly cap scoped to a model — one today (the top model), but the
  // API may report several, and dropping the extras would hide a real limit.
  var usedLabels: Set<String> = ["C5", "CW"]
  var modelCaps: [ModelCapWindow] = []
  for l0 in ja(d["limits"]) ?? [] {
    guard let l = jd(l0) else { continue }
    if jstr(l["group"]) == "weekly",
       let mdl = jstr(jd(jd(l["scope"])?["model"])?["display_name"]),
       let pct = jn(l["percent"]) {
      let ra = parseISO(jstr(l["resets_at"]))
      modelCaps.append(ModelCapWindow(pct: used(pct, ra),
                                      resetsAt: ra,
                                      model: mdl,
                                      label: claudeCapLabel(mdl, used: &usedLabels)))
    }
  }
  return ClaudeUsage(measuredAt: src.measuredAt, live: src.live, issue: src.live ? nil : claudeIssue,
                     fiveHour: win(d["five_hour"]), weekly: win(d["seven_day"]), modelCaps: modelCaps)
}
