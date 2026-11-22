// Claude's actual rate limit — queries the Anthropic OAuth usage API directly (ported from widget 1c)
// Fetches /usage data straight from the server using this Mac's Claude Code login token (keychain).
// One reading per Claude Code login (Accounts.swift); figures are account-level.
// On failure: that login's own cache → (default login only) legacy usage-cache.json.
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
  let account: ClaudeAccount
  let measuredAt: Int // 0 = logged in, but no reading has arrived yet
  let live: Bool
  let issue: ClaudeIssue?
  let fiveHour: UsageWindow?
  let weekly: UsageWindow?
  let modelCaps: [ModelCapWindow]
}

private let LEGACY_USAGE_FILES = [
  "\(HOME)/.claude/MEMORY/STATE/usage-cache.json",
  "\(HOME)/.claude/PAI/MEMORY/STATE/usage-cache.json",
]

// The usage endpoint rate-limits per account, and Claude Code / statuslines poll it too.
// After a 429, stop asking until Retry-After (or a doubling 5→30 min pause) has passed,
// since retrying every refresh keeps the limit from ever clearing. Kept per login.
private var rateLimitedUntil: [String: Int] = [:]
private var rateLimitPause: [String: Int] = [:]
private var claudeIssue: [String: ClaudeIssue] = [:]

// The endpoint allows only a handful of calls before it 429s, so a copy younger than
// this is served as-is instead of asking again on every 2-minute refresh.
private let USAGE_MIN_INTERVAL = 300

// A copy tagged with another account (a /login switch inside the same config dir) is not
// this login's reading. Untagged copies (older builds, the SwiftBar widget) are trusted.
private func readUsageCache(_ acc: ClaudeAccount) -> (data: [String: Any], at: Int)? {
  guard let c = jd(readJSONFile(acc.usageCachePath)), let data = jd(c["data"]),
        data["five_hour"] != nil else { return nil }
  if let tagged = jstr(jd(c["account"])?["uuid"]), let mine = acc.uuid, tagged != mine { return nil }
  return (data, Int(jn(c["fetchedAt"]) ?? 0))
}

private func fetchLive(_ acc: ClaudeAccount, now: Int) -> (data: [String: Any], measuredAt: Int, live: Bool)? {
  let key = acc.service
  if let c = readUsageCache(acc), (0..<USAGE_MIN_INTERVAL).contains(now - c.at) {
    claudeIssue[key] = nil
    return (c.data, c.at, true)
  }
  if now < rateLimitedUntil[key, default: 0] { return nil }
  guard let cred = acc.cred else {
    claudeIssue[key] = .failed
    return nil
  }
  // The access token lives ~8h and only Claude Code renews it, so an expired one is never sent
  if let exp = cred.exp, exp <= now + 60 {
    claudeIssue[key] = .loginExpired
    return nil
  }
  let res = httpFetch("https://api.anthropic.com/api/oauth/usage",
                      headers: ["Authorization": "Bearer \(cred.token)",
                                "anthropic-beta": "oauth-2025-04-20"], timeout: 5)
  if let raw = res.data,
     let obj = jd(try? JSONSerialization.jsonObject(with: raw)),
     obj["five_hour"] != nil {
    rateLimitPause[key] = 0
    claudeIssue[key] = nil
    var tag: [String: Any] = [:]
    if let u = acc.uuid { tag["uuid"] = u }
    if let l = acc.label { tag["label"] = l }
    writeJSONFile(acc.usageCachePath, ["fetchedAt": now, "data": obj, "account": tag])
    return (obj, now, true)
  }
  // Any failure pauses (5 → 30 min, or Retry-After); only an auth error drops the token
  if res.status == 401 || res.status == 403 {
    forgetClaudeCred(key)
    claudeIssue[key] = .loginExpired
    rateLimitedUntil[key] = now + 100
    return nil
  }
  claudeIssue[key] = res.status == 429 ? .rateLimited : .failed
  let pause = min(1800, max(300, rateLimitPause[key, default: 0] * 2))
  rateLimitPause[key] = pause
  rateLimitedUntil[key] = now + max(min(res.retryAfter ?? 0, 1800), pause)
  return nil
}

private func readFallback(_ acc: ClaudeAccount) -> (data: [String: Any], measuredAt: Int, live: Bool)? {
  if let c = readUsageCache(acc) { return (c.data, c.at, false) }
  guard acc.isDefault else { return nil }
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

// 5-hour session / overall weekly / per-model weekly-scoped usage rates, one per login
func getClaudeUsages(now: Int) -> [ClaudeUsage] {
  discoverClaudeAccounts(now: now).compactMap { getClaudeUsage($0, now: now) }
}

private func getClaudeUsage(_ acc: ClaudeAccount, now: Int) -> ClaudeUsage? {
  guard let src = fetchLive(acc, now: now) ?? readFallback(acc) else {
    // Logged in but nothing read yet: a "?" battery and the reason, rather than silence
    guard acc.cred != nil else { return nil }
    return ClaudeUsage(account: acc, measuredAt: 0, live: false, issue: claudeIssue[acc.service] ?? .failed,
                       fiveHour: nil, weekly: nil, modelCaps: [])
  }
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
  return ClaudeUsage(account: acc, measuredAt: src.measuredAt, live: src.live,
                     issue: src.live ? nil : claudeIssue[acc.service],
                     fiveHour: win(d["five_hour"]), weekly: win(d["seven_day"]), modelCaps: modelCaps)
}
