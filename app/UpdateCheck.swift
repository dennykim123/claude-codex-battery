// 업데이트 확인 — 24시간마다 GitHub VERSION을 백그라운드로 조용히 확인 (위젯과 동일 캐시)
import Foundation

private let UPDATE_CACHE = "\(STATE_DIR)/.update-check.json"
private let VERSION_URL = "https://raw.githubusercontent.com/dennykim123/claude-codex-battery/main/VERSION"

func cmpVer(_ a: String, _ b: String) -> Int {
  let pa = a.split(separator: ".").map { Int($0) ?? 0 }
  let pb = b.split(separator: ".").map { Int($0) ?? 0 }
  for i in 0 ..< 3 {
    let x = i < pa.count ? pa[i] : 0
    let y = i < pb.count ? pb[i] : 0
    if x > y { return 1 }
    if x < y { return -1 }
  }
  return 0
}

// 최신 버전 즉시 조회 (자체 업데이트용 — 캐시 우회)
func fetchLatestVersion() -> String? {
  guard let d = httpGet(VERSION_URL, headers: [:], timeout: 8),
        let v = String(data: d, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
        !v.isEmpty else { return nil }
  return v
}

func getUpdateInfo(now: Int) -> (latest: String?, hasUpdate: Bool) {
  let cache = jd(readJSONFile(UPDATE_CACHE))
  let age = cache.flatMap { jn($0["checkedAt"]) }.map { now - Int($0) } ?? Int.max
  if age > 24 * 3600 {
    DispatchQueue.global(qos: .background).async {
      if let d = httpGet(VERSION_URL, headers: [:], timeout: 8),
         let v = String(data: d, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
         !v.isEmpty {
        writeJSONFile(UPDATE_CACHE, ["checkedAt": now, "latest": v])
      }
    }
  }
  let latest = cache.flatMap { jstr($0["latest"]) }
  return (latest, latest.map { cmpVer($0, APP_VERSION) > 0 } ?? false)
}
