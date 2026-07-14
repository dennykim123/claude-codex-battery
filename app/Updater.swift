// 자체 업데이트 — GitHub Releases에서 새 버전 zip을 받아 서명 검증 후 자기 자신을 교체
// 외부 프레임워크 없음. 교체 전 반드시 Developer ID + 팀(M8GF2R2569) 서명을 검증해
// 위변조된 zip이 설치되는 것을 막는다. 실패 시 원본을 되돌린다.
import Cocoa

let TEAM_ID = "M8GF2R2569"

enum UpdateError: Error, CustomStringConvertible {
  case download, unzip, verify, install
  var description: String {
    switch self {
    case .download: return "다운로드 실패"
    case .unzip: return "압축 해제 실패"
    case .verify: return "서명 검증 실패"
    case .install: return "설치 실패"
    }
  }
}

func downloadAndInstallUpdate(version: String, progress: (String) -> Void) throws {
  let url = "\(REPO_URL)/releases/download/v\(version)/ClaudeCodexBattery-v\(version).zip"
  let tmp = NSTemporaryDirectory() + "ccb-update-\(version)-\(ProcessInfo.processInfo.processIdentifier)"
  try? FileManager.default.removeItem(atPath: tmp)
  try FileManager.default.createDirectory(atPath: tmp, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(atPath: tmp) }

  progress("다운로드 중…")
  guard let data = httpGet(url, headers: [:], timeout: 60), !data.isEmpty else { throw UpdateError.download }
  let zipPath = tmp + "/update.zip"
  try data.write(to: URL(fileURLWithPath: zipPath))

  progress("압축 해제 중…")
  guard runCmd("/usr/bin/ditto", ["-x", "-k", zipPath, tmp], timeout: 30) != nil else { throw UpdateError.unzip }
  let newApp = tmp + "/ClaudeCodexBattery.app"

  progress("서명 검증 중…")
  let requirement = "anchor apple generic and certificate leaf[subject.OU] = \"\(TEAM_ID)\""
  guard runCmd("/usr/bin/codesign",
               ["--verify", "--strict", "--test-requirement=\(requirement)", newApp],
               timeout: 30) != nil else { throw UpdateError.verify }

  progress("설치 중…")
  let target = Bundle.main.bundlePath // 지금 실행 중인 번들 위치를 그대로 교체
  let backup = tmp + "/previous.app"
  try FileManager.default.moveItem(atPath: target, toPath: backup)
  do {
    try FileManager.default.moveItem(atPath: newApp, toPath: target)
  } catch {
    try? FileManager.default.moveItem(atPath: backup, toPath: target) // 롤백
    throw UpdateError.install
  }
}

// 교체된 새 버전을 열고 현재 인스턴스 종료 (이중 실행 방지 가드는 구버전이 먼저 죽어 무해)
func relaunchAfterUpdate() {
  let p = Process()
  p.executableURL = URL(fileURLWithPath: "/bin/sh")
  p.arguments = ["-c", "sleep 1; /usr/bin/open \"\(Bundle.main.bundlePath)\""]
  try? p.run()
  NSApp.terminate(nil)
}
