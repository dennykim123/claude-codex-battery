// Claude's actual rate limit — queries the Anthropic OAuth usage API directly (ported from widget 1c)
// Fetches /usage data straight from the server using this Mac's Claude Code login token (keychain).
// Figures are aggregated at the account level. On failure: own cache → legacy usage-cache.json fallback.
import Foundation

struct UsageWindow {
  let pct: Double // usage %
  let resetsAt: Int? // epoch seconds
}

struct FableWindow {
  let pct: Double
  let resetsAt: Int?
  let model: String
}

struct ClaudeUsage {
  let measuredAt: Int
  let live: Bool
  let fiveHour: UsageWindow?
  let weekly: UsageWindow?
  let fable: FableWindow?
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
private var claudeTokenDeniedUntil: Int = 0

func invalidateClaudeToken() { cachedClaudeToken = nil }

private func readClaudeToken() -> String? {
  if liveDisabled() { return nil }
  if let t = cachedClaudeToken { return t }
  if Int(Date().timeIntervalSince1970) < claudeTokenDeniedUntil { return nil }
#if MAS_BUILD
  // Sandboxed: query the Keychain item directly (user approves an access prompt once)
  let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                          kSecAttrService as String: "Claude Code-credentials",
                          kSecReturnData as String: true,
                          kSecMatchLimit as String: kSecMatchLimitOne]
  var out: CFTypeRef?
  if SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
     let d = out as? Data,
     let obj = try? JSONSerialization.jsonObject(with: d),
     let t = jstr(jd(jd(obj)?["claudeAiOauth"])?["accessToken"]) {
    cachedClaudeToken = t
    return t
  }
  claudeTokenDeniedUntil = Int(Date().timeIntervalSince1970) + 3600
  return nil
#else
  if let raw = runCmd("/usr/bin/security", ["find-generic-password", "-s", "Claude Code-credentials", "-w"], timeout: 3),
     let obj = try? JSONSerialization.jsonObject(with: Data(raw.trimmingCharacters(in: .whitespacesAndNewlines).utf8)),
     let t = jstr(jd(jd(obj)?["claudeAiOauth"])?["accessToken"]) {
    cachedClaudeToken = t
    return t
  }
  // For environments without a keychain — Claude Code's file-based credentials
  if let obj = readJSONFile("\(HOME)/.claude/.credentials.json"),
     let t = jstr(jd(jd(obj)?["claudeAiOauth"])?["accessToken"]) {
    cachedClaudeToken = t
    return t
  }
  claudeTokenDeniedUntil = Int(Date().timeIntervalSince1970) + 3600
  return nil
#endif
}

private func fetchLive(now: Int) -> (data: [String: Any], measuredAt: Int, live: Bool)? {
  guard let token = readClaudeToken() else { return nil }
  guard let raw = httpGet("https://api.anthropic.com/api/oauth/usage",
                          headers: ["Authorization": "Bearer \(token)",
                                    "anthropic-beta": "oauth-2025-04-20"], timeout: 5),
        let obj = jd(try? JSONSerialization.jsonObject(with: raw)),
        obj["five_hour"] != nil
  else { invalidateClaudeToken(); return nil }
  writeJSONFile(USAGE_CACHE, ["fetchedAt": now, "data": obj])
  return (obj, now, true)
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

// 5-hour session / overall weekly / Fable weekly-scoped usage rates
func getClaudeUsage(now: Int) -> ClaudeUsage? {
  guard let src = fetchLive(now: now) ?? readFallback() else { return nil }
  let d = src.data
  func win(_ o: Any?) -> UsageWindow? {
    guard let w = jd(o) else { return nil }
    return UsageWindow(pct: jn(w["utilization"]) ?? 0, resetsAt: parseISO(jstr(w["resets_at"])))
  }
  // Fable's (or the top-tier model's) weekly-scoped limit
  var fable: FableWindow? = nil
  for l0 in ja(d["limits"]) ?? [] {
    guard let l = jd(l0) else { continue }
    if jstr(l["group"]) == "weekly",
       let mdl = jstr(jd(jd(l["scope"])?["model"])?["display_name"]) {
      fable = FableWindow(pct: jn(l["percent"]) ?? 0, resetsAt: parseISO(jstr(l["resets_at"])), model: mdl)
      break
    }
  }
  return ClaudeUsage(measuredAt: src.measuredAt, live: src.live,
                     fiveHour: win(d["five_hour"]), weekly: win(d["seven_day"]), fable: fable)
}
