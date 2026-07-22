// Self-update — downloads a new version zip from GitHub Releases, verifies its signature, then replaces itself
// No external framework. Before replacing, always verifies the Developer ID + team (M8GF2R2569) signature
// to prevent a tampered zip from being installed. Restores the original on failure.
import Cocoa

let TEAM_ID = "M8GF2R2569"

enum UpdateError: Error, CustomStringConvertible {
  case download, unzip, verify, install
  var description: String {
    switch self {
    case .download: return tr("download failed")
    case .unzip: return tr("unzip failed")
    case .verify: return tr("signature verification failed")
    case .install: return tr("install failed")
    }
  }
}

func downloadAndInstallUpdate(version: String, progress: (String) -> Void) throws {
  let url = "\(REPO_URL)/releases/download/v\(version)/ClaudeCodexBattery-v\(version).zip"
  let tmp = NSTemporaryDirectory() + "ccb-update-\(version)-\(ProcessInfo.processInfo.processIdentifier)"
  try? FileManager.default.removeItem(atPath: tmp)
  try FileManager.default.createDirectory(atPath: tmp, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(atPath: tmp) }

  progress(tr("downloading…"))
  guard let data = httpGet(url, headers: [:], timeout: 60), !data.isEmpty else { throw UpdateError.download }
  let zipPath = tmp + "/update.zip"
  try data.write(to: URL(fileURLWithPath: zipPath))

  progress(tr("unzipping…"))
  guard runCmd("/usr/bin/ditto", ["-x", "-k", zipPath, tmp], timeout: 30) != nil else { throw UpdateError.unzip }
  let newApp = tmp + "/ClaudeCodexBattery.app"

  progress(tr("verifying signature…"))
  // The requirement string uses an "=" prefix to specify it inline (without it, codesign treats it as a file path)
  let requirement = "=anchor apple generic and certificate leaf[subject.OU] = \"\(TEAM_ID)\""
  guard runCmd("/usr/bin/codesign",
               ["--verify", "--strict", "--test-requirement", requirement, newApp],
               timeout: 30) != nil else { throw UpdateError.verify }

  progress(tr("installing…"))
  let target = Bundle.main.bundlePath // Replace the currently running bundle's location in place
  let backup = tmp + "/previous.app"
  try FileManager.default.moveItem(atPath: target, toPath: backup)
  do {
    try FileManager.default.moveItem(atPath: newApp, toPath: target)
  } catch {
    try? FileManager.default.moveItem(atPath: backup, toPath: target) // rollback
    throw UpdateError.install
  }
}

// Launches the newly replaced version and quits the current instance (the duplicate-launch guard is harmless since the old version dies first)
func relaunchAfterUpdate() {
  let p = Process()
  p.executableURL = URL(fileURLWithPath: "/bin/sh")
  p.arguments = ["-c", "sleep 1; /usr/bin/open \"\(Bundle.main.bundlePath)\""]
  try? p.run()
  NSApp.terminate(nil)
}
