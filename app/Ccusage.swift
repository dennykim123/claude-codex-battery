// ccusage CLI integration (optional dependency — shows block cost / per-model usage only if installed)
import Foundation

struct ClaudeBlock {
  let elapsedPct: Double
  let remainMin: Int
  let cost: Double
  let tokens: Double
  let costPerHour: Double?
}

struct ModelUse {
  let name: String
  let cost: Double
  let tokens: Double
}

// Display names are derived from the id, never enumerated: "claude-opus-4-8"
// → "Opus 4.8", "claude-haiku-4-5-20251001" → "Haiku 4.5". A new model needs
// no code change; the override map is only for names the deriver gets wrong.
let MODEL_NAME_OVERRIDES: [String: String] = [:]

private func isVersionToken(_ t: Substring) -> Bool {
  !t.isEmpty && t.allSatisfy { $0.isNumber || $0 == "." } && t.contains(where: { $0.isNumber })
}

func prettyModel(_ raw: String) -> String {
  var stem = raw.hasPrefix("claude-") ? String(raw.dropFirst("claude-".count)) : raw
  // Trailing release date ("-20251001") is noise in a menu.
  if let dash = stem.lastIndex(of: "-") {
    let tail = stem[stem.index(after: dash)...]
    if tail.count == 8, tail.allSatisfy({ $0.isNumber }) { stem = String(stem[..<dash]) }
  }
  if stem.isEmpty { return raw }
  // Order-preserving: consecutive numeric parts merge into one version token,
  // so "opus-4-8" → "Opus 4.8" and "gpt-5-6-solaris" → "Gpt 5.6 Solaris".
  var tokens: [String] = []
  for part in stem.split(whereSeparator: { $0 == "-" || $0 == "_" }) {
    if isVersionToken(part), let last = tokens.last, isVersionToken(Substring(last)) {
      tokens[tokens.count - 1] = "\(last).\(part)"
    } else if isVersionToken(part) {
      tokens.append(String(part))
    } else {
      tokens.append(part.prefix(1).uppercased() + part.dropFirst())
    }
  }
  return tokens.isEmpty ? raw : tokens.joined(separator: " ")
}

func shortModel(_ n: String) -> String { MODEL_NAME_OVERRIDES[n] ?? prettyModel(n) }

func ccusagePath() -> String? {
#if MAS_BUILD
  return nil // sandbox forbids launching external binaries
#else
  return findBin("ccusage")
#endif
}

// Active 5-hour block (ccusage blocks --active)
func getClaudeBlock(now: Int) -> ClaudeBlock? {
  guard let bin = ccusagePath(),
        let raw = runCmd(bin, ["blocks", "--active", "--json"], timeout: 20),
        let obj = jd(try? JSONSerialization.jsonObject(with: Data(raw.utf8)))
  else { return nil }
  let blocks = (ja(obj["blocks"]) ?? []).compactMap(jd)
  guard let b = blocks.first(where: { ($0["isActive"] as? Bool) == true }) ?? blocks.first,
        let st = parseISO(jstr(b["startTime"])), let et = parseISO(jstr(b["endTime"]))
  else { return nil }
  let span = max(1, et - st)
  let elapsed = max(0, min(100, Double(now - st) / Double(span) * 100))
  let proj = jd(b["projection"])
  let remainMin = jn(proj?["remainingMinutes"]).map(Int.init) ?? max(0, (et - now) / 60)
  return ClaudeBlock(elapsedPct: elapsed, remainMin: remainMin,
                     cost: jn(b["costUSD"]) ?? 0, tokens: jn(b["totalTokens"]) ?? 0,
                     costPerHour: jn(jd(b["burnRate"])?["costPerHour"]))
}

// Today's usage by model (ccusage daily --breakdown)
func getClaudeModels() -> (models: [ModelUse], total: Double)? {
  guard let bin = ccusagePath() else { return nil }
  let df = DateFormatter()
  df.dateFormat = "yyyyMMdd"
  df.locale = Locale(identifier: "en_US_POSIX")
  let ymd = df.string(from: Date())
  guard let raw = runCmd(bin, ["daily", "--breakdown", "--json", "--since", ymd], timeout: 20),
        let obj = jd(try? JSONSerialization.jsonObject(with: Data(raw.utf8))),
        let day = (ja(obj["daily"]) ?? []).compactMap(jd).last
  else { return nil }
  let models = (ja(day["modelBreakdowns"]) ?? []).compactMap(jd)
    .map { m in
      ModelUse(name: jstr(m["modelName"]) ?? "",
               cost: jn(m["cost"]) ?? 0,
               tokens: (jn(m["inputTokens"]) ?? 0) + (jn(m["outputTokens"]) ?? 0)
                 + (jn(m["cacheCreationTokens"]) ?? 0) + (jn(m["cacheReadTokens"]) ?? 0))
    }
    .filter { $0.cost > 0.005 }
    .sorted { $0.cost > $1.cost }
  guard !models.isEmpty else { return nil }
  return (models, models.reduce(0) { $0 + $1.cost })
}
