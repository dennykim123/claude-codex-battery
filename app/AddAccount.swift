// Settings → Accounts → Add Claude/Codex account…: opens Terminal on a fresh config folder
// (~/.claude-2, ~/.codex-2, …) so a second login lands where discovery looks for it.
// The login itself stays with the person — the app only prepares the folder and the command.
import Cocoa

enum AccountKind: String { case claude, codex }

// First ~/.claude-N / ~/.codex-N (N ≥ 2) that holds no login yet. A folder left behind by an
// unfinished attempt is reused, so repeated clicks don't pile up empty folders. Anything else
// already at that name (a file, a broken link, a folder with other content) is left alone.
func nextFreeLoginDir(_ kind: AccountKind) -> String {
  for n in 2...99 {
    let dir = "\(HOME)/.\(kind.rawValue)-\(n)"
    switch loginDirState(kind, dir) {
    case .absent, .reusable: return dir
    case .taken: continue
    }
  }
  return "\(HOME)/.\(kind.rawValue)-\(Int(Date().timeIntervalSince1970))"
}

private enum LoginDirState { case absent, reusable, taken }

private func loginDirState(_ kind: AccountKind, _ dir: String) -> LoginDirState {
  let fm = FileManager.default
  // attributesOfItem does not follow links, so a dangling link still counts as "something here"
  guard (try? fm.attributesOfItem(atPath: dir)) != nil else { return .absent }
  var isDir: ObjCBool = false
  guard fm.fileExists(atPath: dir, isDirectory: &isDir), isDir.boolValue else { return .taken }
  let entries = (try? fm.contentsOfDirectory(atPath: dir)) ?? []
  if entries.isEmpty { return .reusable }
  switch kind {
  case .claude:
    // An unfinished attempt leaves a .claude.json without oauthAccount; a folder without
    // .claude.json at all (say, a copy of ~/.claude) is not ours to take over
    guard let cfg = jd(readJSONFile("\(dir)/.claude.json")) else { return .taken }
    return jd(cfg["oauthAccount"]) == nil ? .reusable : .taken
  case .codex:
    guard let auth = jd(readJSONFile("\(dir)/auth.json")) else {
      return fm.fileExists(atPath: "\(dir)/auth.json") ? .taken : .reusable
    }
    let token = jstr(jd(auth["tokens"])?["access_token"])
    let apiKey = jstr(auth["OPENAI_API_KEY"])
    return (token?.isEmpty == false || apiKey?.isEmpty == false) ? .taken : .reusable
  }
}

// Single-quoted for zsh: ' → '\''
private func shq(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

private func tildePath(_ p: String) -> String { p.hasPrefix(HOME) ? "~" + p.dropFirst(HOME.count) : p }

// The .command script Terminal runs. It never sees or stores a credential: the CLI's own
// login flow writes it (Keychain for Claude Code, auth.json for Codex).
func addAccountScript(_ kind: AccountKind, dir: String) -> String {
  let short = tildePath(dir)
  let say = { (s: String) in "printf '%s\\n' \(shq(s))" }
  var lines = [
    "#!/bin/zsh -l",
    "clear",
    // GUI-launched Terminal may miss PATH entries set in .zshrc; cover the usual install spots
    "export PATH=\"$HOME/.local/bin:$HOME/.claude/local:$HOME/.bun/bin:$HOME/.npm-global/bin:/opt/homebrew/bin:/usr/local/bin:$PATH\"",
    "mkdir -p \(shq(dir)) || exit 1",
  ]
  switch kind {
  case .claude:
    lines += [
      "if ! command -v claude >/dev/null 2>&1; then \(say(trf("'%@' command not found. Install it first, then try again.", "claude"))); exit 1; fi",
      say(trf("New Claude login · folder %@", short)),
      say(tr("When Claude Code opens, sign in with the other account (type /login if it doesn't ask).")),
      say(trf("To use this account later: %@", "CLAUDE_CONFIG_DIR=\(short) claude")),
      say(tr("The menu bar picks up the new account within 2 minutes.")),
      "echo",
      "export CLAUDE_CONFIG_DIR=\(shq(dir))",
      "exec claude",
    ]
  case .codex:
    lines += [
      "if ! command -v codex >/dev/null 2>&1; then \(say(trf("'%@' command not found. Install it first, then try again.", "codex"))); exit 1; fi",
      say(trf("New Codex login · folder %@", short)),
      say(tr("Sign in with the other account in the browser that opens.")),
      "echo",
      "CODEX_HOME=\(shq(dir)) codex login || exit 1",
      "echo",
      say(trf("To use this account later: %@", "CODEX_HOME=\(short) codex")),
      say(tr("The menu bar picks up the new account within 2 minutes.")),
      say(tr("Done. You can close this window.")),
    ]
  }
  return lines.joined(separator: "\n") + "\n"
}

// Writes the script to the temp folder and hands it to Terminal (the .command default app)
@discardableResult
func openAddAccountTerminal(_ kind: AccountKind) -> Bool {
  let dir = nextFreeLoginDir(kind)
  let path = NSTemporaryDirectory() + "ccb-add-\(kind.rawValue)-account.command"
  do {
    try addAccountScript(kind, dir: dir).write(toFile: path, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: path)
  } catch { return false }
  return NSWorkspace.shared.open(URL(fileURLWithPath: path))
}
