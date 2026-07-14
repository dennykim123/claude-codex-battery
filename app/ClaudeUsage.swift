// Claude 실제 rate limit — Anthropic OAuth usage API 직접 조회 (위젯 1c 포팅)
// 이 맥의 Claude Code 로그인 토큰(키체인)으로 /usage 데이터를 서버에서 직접 가져온다.
// 수치는 계정 단위 합산. 실패 시: 자체 캐시 → 레거시 usage-cache.json 폴백.
import Foundation

struct UsageWindow {
  let pct: Double // 사용률 %
  let resetsAt: Int? // epoch 초
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

// 토큰은 반환값으로만 존재 — 파일·로그·프로세스 인자 어디에도 남기지 않는다
private func readClaudeToken() -> String? {
  if liveDisabled() { return nil }
  if let raw = runCmd("/usr/bin/security", ["find-generic-password", "-s", "Claude Code-credentials", "-w"], timeout: 3),
     let obj = try? JSONSerialization.jsonObject(with: Data(raw.trimmingCharacters(in: .whitespacesAndNewlines).utf8)),
     let t = jstr(jd(jd(obj)?["claudeAiOauth"])?["accessToken"]) {
    return t
  }
  // 키체인이 없는 환경 대비 — Claude Code의 파일 자격증명
  if let obj = readJSONFile("\(HOME)/.claude/.credentials.json"),
     let t = jstr(jd(jd(obj)?["claudeAiOauth"])?["accessToken"]) {
    return t
  }
  return nil
}

private func fetchLive(now: Int) -> (data: [String: Any], measuredAt: Int, live: Bool)? {
  guard let token = readClaudeToken() else { return nil }
  guard let raw = httpGet("https://api.anthropic.com/api/oauth/usage",
                          headers: ["Authorization": "Bearer \(token)",
                                    "anthropic-beta": "oauth-2025-04-20"], timeout: 5),
        let obj = jd(try? JSONSerialization.jsonObject(with: raw)),
        obj["five_hour"] != nil
  else { return nil }
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

// 5시간 세션 / 주간 전체 / Fable 주간(weekly scoped) 사용률
func getClaudeUsage(now: Int) -> ClaudeUsage? {
  guard let src = fetchLive(now: now) ?? readFallback() else { return nil }
  let d = src.data
  func win(_ o: Any?) -> UsageWindow? {
    guard let w = jd(o) else { return nil }
    return UsageWindow(pct: jn(w["utilization"]) ?? 0, resetsAt: parseISO(jstr(w["resets_at"])))
  }
  // Fable(또는 최상위 모델) 주간 scoped 한도
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
