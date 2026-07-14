// Codex rate limit — ChatGPT usage 엔드포인트 직접 조회 (위젯 2 포팅)
// 라이브(계정 단위, 전 디바이스 동일) 우선 → 실패 시 로컬 세션 로그 → 마지막 라이브 캐시.
import Foundation

struct CodexWindow {
  let usedPercent: Double
  let resetsAt: Int? // epoch 초
}

struct CodexCredits {
  let hasCredits: Bool
  let unlimited: Bool
  let balance: Double?
}

struct CodexUsage {
  let measuredAt: Int
  let live: Bool
  let limitId: String?
  let plan: String?
  let primary: CodexWindow? // ~5시간 창
  let secondary: CodexWindow? // ~주간 창
  let credits: CodexCredits? // premium 소진형 (창이 전혀 없을 때만)
}

struct WindowState {
  let pct: Double // 사용률 (리셋 지났으면 0)
  let resetsIn: Int?
  let stale: Bool
}

private let CODEX_AUTH = "\(HOME)/.codex/auth.json"
private let CODEX_SESSIONS = "\(HOME)/.codex/sessions"
private let CODEX_CACHE = "\(STATE_DIR)/.codex-usage.json"

private func readCodexToken() -> (token: String, account: String)? {
  if liveDisabled() { return nil }
  guard let d = jd(readJSONFile(CODEX_AUTH)),
        let t = jstr(jd(d["tokens"])?["access_token"]) else { return nil }
  return (t, jstr(jd(d["tokens"])?["account_id"]) ?? "")
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

// 라이브: /backend-api/wham/usage GET → 응답 필드(primary_window/limit_window_seconds/reset_at)를
// 세션 로그 형식으로 정규화. primary/secondary는 "그때 활성인 창"이라 창 길이로 슬롯 판별.
private func fetchCodexLive(now: Int) -> CodexUsage? {
  guard let c = readCodexToken() else { return nil }
  guard let raw = httpGet("https://chatgpt.com/backend-api/wham/usage",
                          headers: ["Authorization": "Bearer \(c.token)",
                                    "ChatGPT-Account-Id": c.account,
                                    "User-Agent": "codex-cli"], timeout: 5),
        let d = jd(try? JSONSerialization.jsonObject(with: raw))
  else { return nil }
  let rl = jd(d["rate_limit"])
  var primary: CodexWindow? = nil
  var secondary: CodexWindow? = nil
  for w0 in [rl?["primary_window"], rl?["secondary_window"]] {
    guard let w = jd(w0) else { continue }
    let secs = jn(w["limit_window_seconds"]) ?? 0
    if secs > 0, secs <= 6 * 3600 { primary = parseWindow(w, resetKey: "reset_at") } // ~5시간
    else { secondary = parseWindow(w, resetKey: "reset_at") } // ~주간(7일)
  }
  let credits = (primary == nil && secondary == nil) ? parseCredits(d["credits"]) : nil
  if primary == nil, secondary == nil, credits == nil { return nil }
  let result = CodexUsage(measuredAt: now, live: true, limitId: nil, plan: jstr(d["plan_type"]),
                          primary: primary, secondary: secondary, credits: credits)
  saveCache(result)
  return result
}

// 캐시는 SwiftBar 위젯과 동일 JSON 형식으로 유지 (양쪽에서 서로 읽을 수 있게)
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
  writeJSONFile(CODEX_CACHE, obj)
}

// 폴백 1: 가장 신선한 세션 로그(.jsonl)에서 rate_limits 스캔
private func codexFromSessions() -> CodexUsage? {
  guard FileManager.default.fileExists(atPath: CODEX_SESSIONS) else { return nil }
  var files: [(path: String, mtime: Int)] = []
  if let en = FileManager.default.enumerator(atPath: CODEX_SESSIONS) {
    for case let rel as String in en where rel.hasSuffix(".jsonl") {
      let p = CODEX_SESSIONS + "/" + rel
      files.append((p, fileMtime(p)))
    }
  }
  files.sort { $0.mtime > $1.mtime }
  for f in files.prefix(8) {
    guard let content = try? String(contentsOfFile: f.path, encoding: .utf8) else { continue }
    let lines = content.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "\n")
    for line in lines.reversed() {
      guard line.contains("rate_limits"),
            let obj = jd(try? JSONSerialization.jsonObject(with: Data(line.utf8))) else { continue }
      guard let rl = jd(jd(obj["payload"])?["rate_limits"]) ?? jd(obj["rate_limits"]),
            rl["primary"] != nil || rl["secondary"] != nil || rl["credits"] != nil else { continue }
      return CodexUsage(measuredAt: f.mtime, live: false,
                        limitId: jstr(rl["limit_id"]), plan: jstr(rl["plan_type"]),
                        primary: parseWindow(rl["primary"], resetKey: "resets_at"),
                        secondary: parseWindow(rl["secondary"], resetKey: "resets_at"),
                        credits: parseCredits(rl["credits"]))
    }
  }
  return nil
}

// 폴백 2: 마지막 라이브 캐시
private func codexFromCache() -> CodexUsage? {
  guard let c = jd(readJSONFile(CODEX_CACHE)) else { return nil }
  let primary = parseWindow(c["primary"], resetKey: "resets_at")
  let secondary = parseWindow(c["secondary"], resetKey: "resets_at")
  let credits = parseCredits(c["credits"])
  if primary == nil, secondary == nil, credits == nil { return nil }
  return CodexUsage(measuredAt: Int(jn(c["measuredAt"]) ?? 0), live: false,
                    limitId: jstr(c["limitId"]), plan: jstr(c["plan"]),
                    primary: primary, secondary: secondary, credits: credits)
}

func getCodex(now: Int) -> CodexUsage? {
  fetchCodexLive(now: now) ?? codexFromSessions() ?? codexFromCache()
}

func windowState(_ w: CodexWindow?, now: Int) -> WindowState? {
  guard let w = w else { return nil }
  let stale = (w.resetsAt ?? Int.max) < now
  return WindowState(pct: stale ? 0 : w.usedPercent,
                     resetsIn: w.resetsAt.map { $0 - now }, stale: stale)
}
