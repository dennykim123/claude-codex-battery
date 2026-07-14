// Claude & Codex Usage Battery — 완전 독립 네이티브 메뉴바 앱 (RunCat 스타일)
// SwiftBar·bun 없이 단독 동작: 키체인/인증 파일 → usage API 직접 조회 → 배터리 렌더.
import Cocoa
import ServiceManagement

let REFRESH_SECONDS = 120.0

// SwiftBar가 같은 위젯 플러그인을 켜둔 상태면 배터리가 두 벌 표시됨 — 감지해서 경고
func swiftBarDuplicate() -> Bool {
  guard FileManager.default.fileExists(atPath: "\(HOME)/.swiftbar-plugins/claude-codex-usage.2m.js"),
        !NSRunningApplication.runningApplications(withBundleIdentifier: "com.ameba.SwiftBar").isEmpty
  else { return false }
  let disabled = UserDefaults(suiteName: "com.ameba.SwiftBar")?.array(forKey: "DisabledPlugins") as? [String] ?? []
  return !disabled.contains("claude-codex-usage.2m.js")
}

// 데이터 일괄 수집 (백그라운드 스레드에서 호출)
func collectSnapshot() -> Snapshot {
  let now = Int(Date().timeIntervalSince1970)
  return Snapshot(now: now,
                  usage: getClaudeUsage(now: now),
                  block: getClaudeBlock(now: now),
                  models: getClaudeModels(),
                  codex: getCodex(now: now),
                  update: getUpdateInfo(now: now))
}

// 스냅샷 → 메뉴바 배터리 아이템 (위젯 JS 렌더링부와 동일 로직)
func battItems(_ snap: Snapshot) -> [BattItem] {
  var items: [BattItem] = []
  if let u = snap.usage {
    items.append(BattItem(label: "C5", remain: u.fiveHour.map { max(0, 100 - $0.pct) }))
    items.append(BattItem(label: "CW", remain: u.weekly.map { max(0, 100 - $0.pct) }))
    if let f = u.fable { items.append(BattItem(label: "CF", remain: max(0, 100 - f.pct))) }
  } else if let b = snap.block {
    items.append(BattItem(label: "C5", remain: max(0, 100 - b.elapsedPct)))
  }
  if let cx = snap.codex, cx.primary != nil || cx.secondary != nil {
    // 그때 활성인 창만 그린다 — 없는 창은 빈 캡슐 대신 생략
    if let p = windowState(cx.primary, now: snap.now) {
      items.append(BattItem(label: "X5", remain: max(0, 100 - p.pct)))
    }
    if let s = windowState(cx.secondary, now: snap.now) {
      items.append(BattItem(label: "XW", remain: max(0, 100 - s.pct)))
    }
  } else if let cr = snap.codex?.credits {
    // premium 소진형: 있음=100 / 소진=0 / 무제한=100
    let remain: Double = cr.unlimited ? 100 : (cr.hasCredits && (cr.balance ?? 0) > 0 ? 100 : 0)
    items.append(BattItem(label: "X", remain: remain))
  }
  return items
}

class AppDelegate: NSObject, NSApplicationDelegate {
  var statusItem: NSStatusItem!
  var timer: Timer?

  var loginItemEnabled: Bool {
    if #available(macOS 13.0, *) { return SMAppService.mainApp.status == .enabled }
    return false
  }

  func applicationDidFinishLaunching(_ n: Notification) {
    statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    statusItem.button?.title = "…"
    // 다크/라이트 전환 시 배터리 색 갱신
    DistributedNotificationCenter.default().addObserver(
      self, selector: #selector(refresh),
      name: NSNotification.Name("AppleInterfaceThemeChangedNotification"), object: nil)
    refresh()
    timer = Timer.scheduledTimer(withTimeInterval: REFRESH_SECONDS, repeats: true) { [weak self] _ in
      self?.refresh()
    }
  }

  // 첫 실행에만: 로그인 시 자동 시작 등록 제안 (RunCat식 온보딩)
  func firstRunAutoStartPrompt() {
    guard #available(macOS 13.0, *),
          !UserDefaults.standard.bool(forKey: "askedAutoStart"),
          SMAppService.mainApp.status != .enabled else { return }
    UserDefaults.standard.set(true, forKey: "askedAutoStart")
    let a = NSAlert()
    a.messageText = "로그인 시 자동으로 시작할까요?"
    a.informativeText = "맥을 켤 때마다 메뉴바에 사용량 배터리가 자동으로 표시됩니다. 나중에 메뉴에서 언제든 바꿀 수 있습니다."
    a.addButton(withTitle: "자동 시작")
    a.addButton(withTitle: "나중에")
    NSApp.activate(ignoringOtherApps: true)
    if a.runModal() == .alertFirstButtonReturn {
      try? SMAppService.mainApp.register()
    }
  }

  @objc func refresh() {
    DispatchQueue.global(qos: .utility).async { [weak self] in
      let snap = collectSnapshot()
      DispatchQueue.main.async { self?.render(snap) }
    }
  }

  func render(_ snap: Snapshot) {
    let items = battItems(snap)
    if let btn = statusItem.button {
      btn.image = nil
      btn.title = ""
      let dark = btn.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
      if !items.isEmpty, let img = renderBatteryImage(dark: dark, items: items) {
        // SwiftBar와 동일하게 디스플레이 배율로 나눔 (레티나 ÷2, 1x 모니터 ÷1)
        let scale = btn.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        img.size = NSSize(width: img.size.width / scale, height: img.size.height / scale)
        img.isTemplate = false
        btn.image = img
      } else {
        btn.title = "🔋 —"
      }
    }
    statusItem.menu = buildMenu(snap, swiftBarDup: swiftBarDuplicate(), target: self)
    // 온보딩은 첫 렌더가 화면에 나간 뒤에 — 모달이 데이터 표시를 막지 않도록
    if !promptShown {
      promptShown = true
      DispatchQueue.main.async { [weak self] in self?.firstRunAutoStartPrompt() }
    }
  }

  private var promptShown = false

  @objc func openLink(_ sender: NSMenuItem) {
    if let s = sender.representedObject as? String, let url = URL(string: s) {
      NSWorkspace.shared.open(url)
    }
  }

  @objc func setSizeBig() { setBattSize("big") }
  @objc func setSizeSmall() { setBattSize("small") }
  private func setBattSize(_ s: String) {
    try? FileManager.default.createDirectory(atPath: STATE_DIR, withIntermediateDirectories: true)
    try? s.write(toFile: SIZE_FILE, atomically: true, encoding: .utf8)
    refresh()
  }

  @objc func toggleLoginItem() {
    guard #available(macOS 13.0, *) else { return }
    let svc = SMAppService.mainApp
    if svc.status == .enabled { try? svc.unregister() } else { try? svc.register() }
    refresh()
  }

  // ccusage 대시보드를 터미널로 — .command 파일 경유 (권한 프롬프트 없이 Terminal 실행)
  @objc func openDashboard() {
    guard let bin = ccusagePath() else { return }
    let f = "\(STATE_DIR)/ccusage-dashboard.command"
    let sh = "#!/bin/sh\nexec \"\(bin)\" blocks --active\n"
    try? FileManager.default.createDirectory(atPath: STATE_DIR, withIntermediateDirectories: true)
    try? sh.write(toFile: f, atomically: true, encoding: .utf8)
    try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: f)
    NSWorkspace.shared.open(URL(fileURLWithPath: f))
  }
}

// ── --dump-menu: UI 없이 드롭다운 메뉴 구조를 텍스트로 출력 (검증용) ──
if CommandLine.arguments.contains("--dump-menu") {
  let snap = collectSnapshot()
  let d = AppDelegate()
  func walk(_ m: NSMenu, _ indent: String) {
    for it in m.items {
      if it.isSeparatorItem { print(indent + "────────") }
      else {
        print(indent + it.title + (it.state == .on ? "  [✓]" : "") + (it.submenu != nil ? "  ▸" : ""))
        if let sub = it.submenu { walk(sub, indent + "        ") }
      }
    }
  }
  walk(buildMenu(snap, swiftBarDup: swiftBarDuplicate(), target: d), "")
  exit(0)
}

// ── --dump: UI 없이 수집·렌더 데이터를 텍스트로 출력 (파이프라인 검증용) ──
if CommandLine.arguments.contains("--dump") {
  let snap = collectSnapshot()
  print("now:", snap.now)
  if let u = snap.usage {
    print("claude.live:", u.live)
    if let w = u.fiveHour { print("claude.5h: used \(w.pct)% resetsAt \(w.resetsAt ?? -1)") }
    if let w = u.weekly { print("claude.weekly: used \(w.pct)% resetsAt \(w.resetsAt ?? -1)") }
    if let f = u.fable { print("claude.fable(\(f.model)): used \(f.pct)%") }
  } else { print("claude: nil") }
  if let b = snap.block {
    print(String(format: "ccusage.block: cost $%.2f tokens %@ elapsed %.0f%%", b.cost, fmtTok(b.tokens), b.elapsedPct))
  } else { print("ccusage.block: nil") }
  if let m = snap.models {
    print("ccusage.models:", m.models.map { "\(shortModel($0.name)) $\(String(format: "%.1f", $0.cost))" }.joined(separator: ", "))
  }
  if let cx = snap.codex {
    print("codex.live:", cx.live, "plan:", cx.plan ?? "-")
    if let p = windowState(cx.primary, now: snap.now) { print("codex.5h: used \(p.pct)% resetsIn \(p.resetsIn ?? -1)s") }
    if let s = windowState(cx.secondary, now: snap.now) { print("codex.weekly: used \(s.pct)% resetsIn \(s.resetsIn ?? -1)s") }
    if let cr = cx.credits { print("codex.credits: has \(cr.hasCredits) unlimited \(cr.unlimited) balance \(cr.balance ?? 0)") }
  } else { print("codex: nil") }
  print("battItems:", battItems(snap).map { "\($0.label)=\($0.remain.map { String(Int($0.rounded())) } ?? "nil")" }.joined(separator: " "))
  print("swiftBarDuplicate:", swiftBarDuplicate())
  exit(0)
}

// ── 이중 실행 방지 — 같은 번들 ID의 인스턴스가 이미 떠 있으면 조용히 종료 ──
let myID = Bundle.main.bundleIdentifier ?? "com.dennykim.claude-codex-battery-app"
let myPID = ProcessInfo.processInfo.processIdentifier
if NSRunningApplication.runningApplications(withBundleIdentifier: myID)
  .contains(where: { $0.processIdentifier != myPID }) {
  exit(0)
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory) // 메뉴바 전용 (Dock 아이콘 없음)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
