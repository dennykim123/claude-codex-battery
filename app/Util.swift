// Shared utilities — path/format/process/HTTP/JSON helpers (ported from the widget JS's shared code)
import Cocoa

let HOME = NSHomeDirectory()
let STATE_DIR = "\(HOME)/.claude/swiftbar" // Shares cache/settings with the SwiftBar widget (same file format)
let REPO_URL = "https://github.com/dennykim123/claude-codex-battery"
let APP_VERSION = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"

func firstExisting(_ paths: [String]) -> String? { paths.first { FileManager.default.fileExists(atPath: $0) } }
func findBin(_ name: String) -> String? {
  firstExisting(["\(HOME)/.bun/bin/\(name)", "/opt/homebrew/bin/\(name)", "/usr/local/bin/\(name)"])
}

// Opt-out switch for live queries (same as the widget: touch ~/.claude/swiftbar/.no-live)
func liveDisabled() -> Bool { FileManager.default.fileExists(atPath: "\(STATE_DIR)/.no-live") }

// UI language: Korean if the system language is Korean, otherwise English (CCB_LANG=ko|en can force it for testing)
let UI_KO: Bool = {
  if let f = ProcessInfo.processInfo.environment["CCB_LANG"] { return f == "ko" }
  return Locale.preferredLanguages.first?.hasPrefix("ko") ?? false
}()
func L(_ ko: String, _ en: String) -> String { UI_KO ? ko : en }

func fmtDur(_ secs: Int) -> String {
  if secs <= 0 { return "0m" }
  let h = secs / 3600, m = (secs % 3600) / 60
  if h >= 24 { return "\(h / 24)d \(h % 24)h" }
  return h > 0 ? "\(h)h \(m)m" : "\(m)m"
}

func fmtTok(_ n: Double) -> String {
  if n >= 1e9 { return String(format: "%.1fB", n / 1e9) }
  if n >= 1e6 { return String(format: "%.1fM", n / 1e6) }
  if n >= 1e3 { return String(format: "%.0fK", n / 1e3) }
  return String(format: "%.0f", n)
}

// Partial-block gauge (▕█████▏) — ported from the widget's bar()
func gaugeBar(_ pctIn: Double, _ w: Int) -> String {
  let pct = max(0, min(100, pctIn))
  let filled = pct / 100 * Double(w)
  var fb = Int(filled)
  var idx = Int(((filled - Double(fb)) * 8).rounded())
  if idx == 8 { fb += 1; idx = 0 }
  fb = min(fb, w)
  let part = ["", "▏", "▎", "▍", "▌", "▋", "▊", "▉"]
  var s = String(repeating: "█", count: fb)
  var used = fb
  if idx > 0 && fb < w { s += part[idx]; used += 1 }
  s += String(repeating: "░", count: max(0, w - used))
  return s
}

// Remaining % → signal color (dropdown, dark-mode based — same as the widget's heatRemainHex)
func heatRemainHex(_ r: Double) -> String { r <= 20 ? "#FF453A" : r < 50 ? "#FFD60A" : "#30D158" }

func hexColor(_ s: String) -> NSColor? {
  var h = s
  guard h.hasPrefix("#") else { return nil }
  h.removeFirst()
  guard h.count == 6, let v = Int(h, radix: 16) else { return nil }
  return NSColor(red: CGFloat((v >> 16) & 0xff) / 255, green: CGFloat((v >> 8) & 0xff) / 255,
                 blue: CGFloat(v & 0xff) / 255, alpha: 1)
}

// Run an external command (with timeout, nil on failure) — for ccusage/security only
func runCmd(_ bin: String, _ args: [String], timeout: TimeInterval = 10) -> String? {
  let p = Process()
  p.executableURL = URL(fileURLWithPath: bin)
  p.arguments = args
  var env = ProcessInfo.processInfo.environment
  env["PATH"] = "\(HOME)/.bun/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
  p.environment = env
  let out = Pipe()
  p.standardOutput = out
  p.standardError = Pipe()
  p.standardInput = FileHandle.nullDevice
  do { try p.run() } catch { return nil }
  let killer = DispatchWorkItem { if p.isRunning { p.terminate() } }
  DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
  let data = out.fileHandleForReading.readDataToEndOfFile()
  p.waitUntilExit()
  killer.cancel()
  guard p.terminationStatus == 0 else { return nil }
  return String(data: data, encoding: .utf8)
}

// Synchronous HTTP GET (only 2xx counts as success) — token stays in headers only, never in files/process args
// If CCB_DEBUG=1, prints status/errors to stderr (for diagnostics)
func httpGet(_ urlStr: String, headers: [String: String], timeout: TimeInterval = 8) -> Data? {
  guard let url = URL(string: urlStr) else { return nil }
  var req = URLRequest(url: url, timeoutInterval: timeout)
  headers.forEach { req.setValue($1, forHTTPHeaderField: $0) }
  let sem = DispatchSemaphore(value: 0)
  var result: Data? = nil
  URLSession.shared.dataTask(with: req) { d, r, e in
    let code = (r as? HTTPURLResponse)?.statusCode ?? -1
    if (200 ..< 300).contains(code) { result = d }
    if ProcessInfo.processInfo.environment["CCB_DEBUG"] != nil {
      let msg = "[httpGet] \(url.host ?? "?") status=\(code)\(e.map { " err=\($0.localizedDescription)" } ?? "")\n"
      FileHandle.standardError.write(Data(msg.utf8))
    }
    sem.signal()
  }.resume()
  if sem.wait(timeout: .now() + timeout + 2) == .timedOut,
     ProcessInfo.processInfo.environment["CCB_DEBUG"] != nil {
    FileHandle.standardError.write(Data("[httpGet] \(url.host ?? "?") semaphore TIMEOUT\n".utf8))
  }
  return result
}

// JSON access helpers (dynamic schema — built on JSONSerialization)
func jd(_ a: Any?) -> [String: Any]? { a as? [String: Any] }
func ja(_ a: Any?) -> [Any]? { a as? [Any] }
func jn(_ a: Any?) -> Double? { (a as? NSNumber)?.doubleValue }
func jstr(_ a: Any?) -> String? { a as? String }

func readJSONFile(_ path: String) -> Any? {
  guard let d = FileManager.default.contents(atPath: path) else { return nil }
  return try? JSONSerialization.jsonObject(with: d)
}

func writeJSONFile(_ path: String, _ obj: Any) {
  try? FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                                           withIntermediateDirectories: true)
  if let d = try? JSONSerialization.data(withJSONObject: obj) {
    try? d.write(to: URL(fileURLWithPath: path))
  }
}

func parseISO(_ s: String?) -> Int? {
  guard let s = s else { return nil }
  let f1 = ISO8601DateFormatter()
  f1.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
  if let d = f1.date(from: s) { return Int(d.timeIntervalSince1970) }
  let f2 = ISO8601DateFormatter()
  if let d = f2.date(from: s) { return Int(d.timeIntervalSince1970) }
  return nil
}

// Reset time: accepts both a number (epoch seconds) and an ISO string
func resetTs(_ v: Any?) -> Int? {
  if let n = jn(v) { return Int(n) }
  return parseISO(jstr(v))
}

func fileMtime(_ path: String) -> Int {
  let d = (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate]) as? Date
  return Int(d?.timeIntervalSince1970 ?? 0)
}
