// Every Claude Code / Codex login on this Mac, so people who keep two or three accounts
// see each one in the menu and can pick which one the menu bar batteries follow.
// Claude Code stores one Keychain item per config dir: "Claude Code-credentials" for
// ~/.claude, "Claude Code-credentials-<first 8 hex of sha256(dir)>" per CLAUDE_CONFIG_DIR.
// Codex keeps one auth.json per CODEX_HOME (~/.codex, ~/.codex-work, …).
import Foundation
import Security

let CLAUDE_DEFAULT_SERVICE = "Claude Code-credentials"
let CODEX_DEFAULT_HOME = "\(HOME)/.codex"
let CLAUDE_BAR_KEY = "claudeBarAccount" // UserDefaults: Keychain service the menu bar follows
let CODEX_BAR_KEY = "codexBarAccount" // UserDefaults: CODEX_HOME the menu bar follows

// A non-default login whose token lapsed this long ago is a leftover (a deleted config
// dir, a test sandbox), not an account in use: Claude Code and Codex renew tokens they use.
private let STALE_LOGIN_SECS = 7 * 86400

struct ClaudeCred {
  let token: String
  let exp: Int? // epoch seconds
  let uuid: String? // accountUuid
}

struct ClaudeAccount {
  let service: String // Keychain service, also the cache key
  let uuid: String?
  let label: String? // email, when a .claude.json names this account
  let cred: ClaudeCred? // nil in .no-live mode or when nothing could be read
  var isDefault: Bool { service == CLAUDE_DEFAULT_SERVICE }
  // ~/.claude keeps the file name the SwiftBar widget shares; others get their suffix
  var usageCachePath: String {
    "\(STATE_DIR)/.claude-usage\(service.dropFirst(CLAUDE_DEFAULT_SERVICE.count)).json"
  }
}

struct CodexAccount {
  let home: String // CODEX_HOME
  let accountId: String?
  let label: String? // email from the login's id_token
  let token: String?
  var isDefault: Bool { home == CODEX_DEFAULT_HOME }
  var usageCachePath: String {
    if isDefault { return "\(STATE_DIR)/.codex-usage.json" }
    let name = (home as NSString).lastPathComponent.drop { $0 == "." }
    let safe = String(name.map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" ? $0 : "_" })
    return "\(STATE_DIR)/.codex-usage-\(safe).json"
  }
}

func isClaudeLoginService(_ s: String) -> Bool {
  if s == CLAUDE_DEFAULT_SERVICE { return true }
  guard s.hasPrefix(CLAUDE_DEFAULT_SERVICE + "-") else { return false }
  let tail = s.dropFirst(CLAUDE_DEFAULT_SERVICE.count + 1)
  return tail.count == 8 && tail.allSatisfy { $0.isHexDigit }
}

// claudeAiOauth → token, expiry (arrives in ms) and the account it belongs to
func parseClaudeCred(_ obj: Any?) -> ClaudeCred? {
  guard let o = jd(jd(obj)?["claudeAiOauth"]), let t = jstr(o["accessToken"]), !t.isEmpty else { return nil }
  let exp = jn(o["expiresAt"]).map { $0 > 1e12 ? Int($0 / 1000) : Int($0) }
  return ClaudeCred(token: t, exp: exp, uuid: jstr(o["accountUuid"]))
}

// The payload of a JWT (no signature check — it only labels a login we already hold)
func jwtClaims(_ jwt: String?) -> [String: Any]? {
  guard let parts = jwt?.split(separator: "."), parts.count >= 2 else { return nil }
  var b64 = parts[1].replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
  b64 += String(repeating: "=", count: (4 - b64.count % 4) % 4)
  guard let d = Data(base64Encoded: b64) else { return nil }
  return jd(try? JSONSerialization.jsonObject(with: d))
}

// One login per account: the same account signed into two dirs shows once,
// from the default dir when it is one of them, else from the freshest token.
private func dedupe<T>(_ xs: [T], id: (T) -> String?, isDefault: (T) -> Bool,
                       fresher: (T, T) -> Bool) -> [T] {
  var out: [T] = []
  for x in xs {
    guard let k = id(x), let i = out.firstIndex(where: { id($0) == k }) else { out.append(x); continue }
    if !isDefault(out[i]), isDefault(x) || fresher(x, out[i]) { out[i] = x }
  }
  return out
}

// Accounts named in caches, for .no-live mode (no Keychain or auth.json reads at all)
private func cachedAccountTags(prefix: String) -> [(file: String, tag: [String: Any]?)] {
  let names = (try? FileManager.default.contentsOfDirectory(atPath: STATE_DIR)) ?? []
  return names.filter { $0.hasPrefix(prefix) && $0.hasSuffix(".json") }.sorted().map { name in
    (name, jd(jd(readJSONFile("\(STATE_DIR)/\(name)"))?["account"]))
  }
}

// ── Claude ──

#if MAS_BUILD
// Sandboxed: only the default login, read with SecItemCopyMatching (the user approves an
// access prompt once). Held for the process lifetime so the Keychain is asked at most once
// per launch; an expired token is re-read every 5 min, a denial backs off for an hour.
private var masCred: ClaudeCred?
private var masDeniedUntil = 0
private var masRecheckAt = 0

private func masClaudeCred(now: Int) -> ClaudeCred? {
  if let c = masCred, (c.exp ?? Int.max) > now + 60 { return c }
  if now < masDeniedUntil { return nil }
  if masCred != nil, now < masRecheckAt { return masCred }
  let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                          kSecAttrService as String: CLAUDE_DEFAULT_SERVICE,
                          kSecReturnData as String: true,
                          kSecMatchLimit as String: kSecMatchLimitOne]
  var out: CFTypeRef?
  guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data,
        let c = parseClaudeCred(try? JSONSerialization.jsonObject(with: d)) else {
    masDeniedUntil = now + 3600
    masCred = nil
    return nil
  }
  masCred = c
  if let exp = c.exp, exp <= now + 60 { masRecheckAt = now + 300 }
  return c
}

func forgetClaudeCred(_ service: String) { masCred = nil }
#else
// Attributes only (service + modification date): listing them needs no password prompt.
// An item's secret is re-read only after Claude Code rewrites it (token renewal, /login),
// so a switched account shows up on the next refresh instead of hours later.
private var claudeItemCache: [String: (mdat: Date?, cred: ClaudeCred?)] = [:]

private func claudeKeychainItems() -> [(service: String, mdat: Date?)] {
  let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                          kSecMatchLimit as String: kSecMatchLimitAll,
                          kSecReturnAttributes as String: true]
  var out: CFTypeRef?
  guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
        let items = out as? [[String: Any]] else { return [] }
  var seen = Set<String>()
  return items.compactMap { a in
    guard let s = a[kSecAttrService as String] as? String, isClaudeLoginService(s),
          seen.insert(s).inserted else { return nil }
    return (s, a[kSecAttrModificationDate as String] as? Date)
  }
}

// The listing can come back empty (a locked Keychain, an odd setup): the default item is
// then still asked for directly, as older builds did (no date → read every time)
private func claudeLoginItems() -> [(service: String, mdat: Date?)] {
  let items = claudeKeychainItems()
  return items.contains { $0.service == CLAUDE_DEFAULT_SERVICE } ? items : [(CLAUDE_DEFAULT_SERVICE, nil)] + items
}

// The Keychain item was written by /usr/bin/security, so reading it the same way never prompts
private func claudeCred(_ service: String, mdat: Date?) -> ClaudeCred? {
  if let c = claudeItemCache[service], mdat != nil, c.mdat == mdat { return c.cred }
  guard let raw = runCmd("/usr/bin/security", ["find-generic-password", "-s", service, "-w"], timeout: 3)
  else { return nil } // not cached: a timeout is retried on the next refresh
  let json = try? JSONSerialization.jsonObject(with: Data(raw.trimmingCharacters(in: .whitespacesAndNewlines).utf8))
  let cred = parseClaudeCred(json)
  claudeItemCache[service] = (mdat, cred)
  return cred
}

func forgetClaudeCred(_ service: String) { claudeItemCache[service] = nil }

// accountUuid → email, from the .claude.json Claude Code keeps per config dir
// (~/.claude.json for ~/.claude, <dir>/.claude.json for a CLAUDE_CONFIG_DIR). Re-parsed
// only when one of those files changes.
private var emailCache: (sig: String, map: [String: String]) = ("", [:])

private func claudeEmails() -> [String: String] {
  let fm = FileManager.default
  var files = ["\(HOME)/.claude.json"]
  for base in [HOME, "\(HOME)/.config"] {
    for name in (try? fm.contentsOfDirectory(atPath: base)) ?? []
    where name.hasPrefix(".claude") || name.hasPrefix("claude") {
      let f = "\(base)/\(name)/.claude.json"
      if fm.fileExists(atPath: f) { files.append(f) }
    }
  }
  let sig = files.map { "\($0):\(fileMtime($0))" }.joined(separator: "|")
  if sig == emailCache.sig { return emailCache.map }
  var map: [String: String] = [:]
  for f in files {
    guard let oa = jd(jd(readJSONFile(f))?["oauthAccount"]),
          let u = jstr(oa["accountUuid"]), let e = jstr(oa["emailAddress"]), map[u] == nil else { continue }
    map[u] = e
  }
  emailCache = (sig, map)
  return map
}
#endif

func discoverClaudeAccounts(now: Int) -> [ClaudeAccount] {
  if liveDisabled() {
    return cachedAccountTags(prefix: ".claude-usage").compactMap { f in
      let suffix = f.file.dropFirst(".claude-usage".count).dropLast(".json".count)
      let svc = CLAUDE_DEFAULT_SERVICE + suffix
      guard isClaudeLoginService(svc) else { return nil }
      return ClaudeAccount(service: svc, uuid: jstr(f.tag?["uuid"]), label: jstr(f.tag?["label"]), cred: nil)
    }.sorted { $0.isDefault && !$1.isDefault }
      .withDefault { ClaudeAccount(service: CLAUDE_DEFAULT_SERVICE, uuid: nil, label: nil, cred: nil) }
  }
#if MAS_BUILD
  let c = masClaudeCred(now: now)
  return [ClaudeAccount(service: CLAUDE_DEFAULT_SERVICE, uuid: c?.uuid, label: nil, cred: c)]
#else
  let emails = claudeEmails()
  var found: [ClaudeAccount] = []
  for it in claudeLoginItems() {
    var cred = claudeCred(it.service, mdat: it.mdat)
    // No Keychain login for ~/.claude: Claude Code's file-based credentials
    if cred == nil, it.service == CLAUDE_DEFAULT_SERVICE {
      cred = parseClaudeCred(readJSONFile("\(HOME)/.claude/.credentials.json"))
    }
    guard let c = cred else { continue }
    if it.service != CLAUDE_DEFAULT_SERVICE, let exp = c.exp, exp < now - STALE_LOGIN_SECS { continue }
    found.append(ClaudeAccount(service: it.service, uuid: c.uuid, label: c.uuid.flatMap { emails[$0] }, cred: c))
  }
  if !found.contains(where: { $0.isDefault }) {
    // Still listed: its file credentials, or else its caches, can carry a reading
    let fc = parseClaudeCred(readJSONFile("\(HOME)/.claude/.credentials.json"))
    found.append(ClaudeAccount(service: CLAUDE_DEFAULT_SERVICE, uuid: fc?.uuid,
                               label: fc?.uuid.flatMap { emails[$0] }, cred: fc))
  }
  let unique = dedupe(found, id: { $0.uuid }, isDefault: { $0.isDefault },
                      fresher: { ($0.cred?.exp ?? 0) > ($1.cred?.exp ?? 0) })
  return unique.filter { $0.isDefault } + unique.filter { !$0.isDefault }.sorted {
    ($0.label ?? $0.service) < ($1.label ?? $1.service)
  }
#endif
}

// ── Codex ──

private func codexLogin(home: String) -> CodexAccount {
#if MAS_BUILD
  let auth = readCodexFile("auth.json").flatMap { jd(try? JSONSerialization.jsonObject(with: $0)) }
#else
  let auth = jd(readJSONFile("\(home)/auth.json"))
#endif
  let tokens = jd(auth?["tokens"])
  let claims = jwtClaims(jstr(tokens?["id_token"]))
  return CodexAccount(home: home, accountId: jstr(tokens?["account_id"]),
                      label: jstr(claims?["email"]), token: jstr(tokens?["access_token"]))
}

func discoverCodexAccounts(now: Int) -> [CodexAccount] {
  if liveDisabled() {
    return cachedAccountTags(prefix: ".codex-usage").compactMap { f -> CodexAccount? in
      if f.file == ".codex-usage.json" {
        return CodexAccount(home: CODEX_DEFAULT_HOME, accountId: jstr(f.tag?["id"]),
                            label: jstr(f.tag?["label"]), token: nil)
      }
      guard let home = jstr(f.tag?["home"]), home != CODEX_DEFAULT_HOME else { return nil }
      return CodexAccount(home: home, accountId: jstr(f.tag?["id"]), label: jstr(f.tag?["label"]), token: nil)
    }.sorted { $0.isDefault && !$1.isDefault }
      .withDefault { CodexAccount(home: CODEX_DEFAULT_HOME, accountId: nil, label: nil, token: nil) }
  }
#if MAS_BUILD
  return [codexLogin(home: CODEX_DEFAULT_HOME)]
#else
  // ~/.codex always (its session logs and cache work without a login), plus every other
  // ~/.codex* dir holding a login — the usual CODEX_HOME names (~/.codex-work, ~/.codex2)
  var found = [codexLogin(home: CODEX_DEFAULT_HOME)]
  let names = (try? FileManager.default.contentsOfDirectory(atPath: HOME)) ?? []
  for name in names.sorted() where name.hasPrefix(".codex") && name != ".codex" {
    let acc = codexLogin(home: "\(HOME)/\(name)")
    guard acc.token != nil else { continue }
    if codexTokenExp(acc) != 0, codexTokenExp(acc) < now - STALE_LOGIN_SECS { continue }
    found.append(acc)
  }
  // A copied or abandoned home (.codex-bak) must not hide the one Codex keeps renewing
  return dedupe(found, id: { $0.accountId }, isDefault: { $0.isDefault },
                fresher: { codexTokenExp($0) > codexTokenExp($1) })
#endif
}

func codexTokenExp(_ acc: CodexAccount) -> Int { jn(jwtClaims(acc.token)?["exp"]).map(Int.init) ?? 0 }

// The menu-bar pick (saved per kind), moved to the front; the first login when unset or gone
func barFirst<T>(_ xs: [T], savedKey: String, key: (T) -> String) -> [T] {
  guard let saved = UserDefaults.standard.string(forKey: savedKey),
        let i = xs.firstIndex(where: { key($0) == saved }), i > 0 else { return xs }
  return [xs[i]] + xs[..<i] + xs[(i + 1)...]
}

private extension Array {
  func withDefault(_ make: () -> Element) -> [Element] where Element == ClaudeAccount {
    contains { $0.isDefault } ? self : [make()] + self
  }
  func withDefault(_ make: () -> Element) -> [Element] where Element == CodexAccount {
    contains { $0.isDefault } ? self : [make()] + self
  }
}
