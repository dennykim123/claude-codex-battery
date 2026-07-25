// Mac App Store build only — sandbox-compatible access helpers.
// The sandbox blocks ~/.codex, so the user grants the folder once via an open
// panel; we persist a security-scoped bookmark and read through it thereafter.
#if MAS_BUILD
import Cocoa

private let CODEX_BOOKMARK_KEY = "codexBookmark"

// Real home directory (NSHomeDirectory() returns the sandbox container)
func realHomeDir() -> String {
  if let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir {
    return String(cString: dir)
  }
  return NSHomeDirectory()
}

// Resolve the granted ~/.codex folder, if any
func codexGrantedURL() -> URL? {
  guard let data = UserDefaults.standard.data(forKey: CODEX_BOOKMARK_KEY) else { return nil }
  var stale = false
  guard let url = try? URL(resolvingBookmarkData: data, options: .withSecurityScope,
                           relativeTo: nil, bookmarkDataIsStale: &stale) else { return nil }
  if stale, let fresh = try? url.bookmarkData(options: .withSecurityScope,
                                             includingResourceValuesForKeys: nil, relativeTo: nil) {
    UserDefaults.standard.set(fresh, forKey: CODEX_BOOKMARK_KEY)
  }
  return url
}

// Read a file inside the granted folder (relative path like "auth.json")
func readCodexFile(_ relative: String) -> Data? {
  guard let base = codexGrantedURL() else { return nil }
  guard base.startAccessingSecurityScopedResource() else { return nil }
  defer { base.stopAccessingSecurityScopedResource() }
  return try? Data(contentsOf: base.appendingPathComponent(relative))
}

// List .jsonl session files (path, mtime) inside the granted folder
func codexSessionFiles() -> [(path: URL, mtime: Int)] {
  guard let base = codexGrantedURL() else { return [] }
  guard base.startAccessingSecurityScopedResource() else { return [] }
  defer { base.stopAccessingSecurityScopedResource() }
  let sessions = base.appendingPathComponent("sessions")
  guard let en = FileManager.default.enumerator(at: sessions, includingPropertiesForKeys: [.contentModificationDateKey]) else { return [] }
  var out: [(URL, Int)] = []
  for case let url as URL in en where url.pathExtension == "jsonl" {
    let d = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? nil
    out.append((url, Int(d?.timeIntervalSince1970 ?? 0)))
  }
  return out
}

// One-time open panel pointed at the real ~/.codex; stores the bookmark
@discardableResult
func promptCodexAccess() -> Bool {
  let panel = NSOpenPanel()
  panel.message = tr("Select your ~/.codex folder to show Codex batteries")
  panel.prompt = tr("Grant Access")
  panel.canChooseFiles = false
  panel.canChooseDirectories = true
  panel.allowsMultipleSelection = false
  panel.showsHiddenFiles = true
  panel.directoryURL = URL(fileURLWithPath: realHomeDir() + "/.codex")
  NSApp.activate(ignoringOtherApps: true)
  guard panel.runModal() == .OK, let url = panel.url else { return false }
  guard let bm = try? url.bookmarkData(options: .withSecurityScope,
                                      includingResourceValuesForKeys: nil, relativeTo: nil) else { return false }
  UserDefaults.standard.set(bm, forKey: CODEX_BOOKMARK_KEY)
  return true
}
#endif
