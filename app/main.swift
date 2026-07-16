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
  // 골든 배터리 시각 테스트용 (개발 전용)
  if ProcessInfo.processInfo.environment["CCB_GOLD_TEST"] != nil {
    return items.map { BattItem(label: $0.label, remain: $0.remain == nil ? nil : 100) }
  }
  return items
}

// 시작 시퀀스: 왼쪽 배터리부터 순서대로 0 → 실제 잔량으로 차오름 (숫자도 카운트업)
func introFrames(items: [BattItem], dark: Bool) -> [NSImage] {
  var out: [NSImage] = []
  let steps = 4
  for i in 0 ..< items.count {
    for s in 1 ... steps {
      let t = Double(s) / Double(steps)
      let frame = items.enumerated().map { j, it -> BattItem in
        let r: Double? = j < i ? it.remain
          : j == i ? it.remain.map { $0 * t }
          : it.remain == nil ? nil : 0
        return BattItem(label: it.label, remain: r)
      }
      if let img = renderBatteryImage(dark: dark, items: frame) { out.append(img) }
    }
  }
  return out
}

// 황금 배터리 광택 스윕 (골든 캡슐이 하나라도 있을 때)
func glintFrames(items: [BattItem], dark: Bool) -> [NSImage] {
  guard items.contains(where: { isGolden($0.remain) }) else { return [] }
  var out: [NSImage] = []
  for g in stride(from: 0, to: batteryGlintSpan() + 2, by: 2) {
    if let img = renderBatteryImage(dark: dark, items: items, glintX: g) { out.append(img) }
  }
  return out
}

class AppDelegate: NSObject, NSApplicationDelegate {
  var statusItem: NSStatusItem!
  var timer: Timer?
  var lastSnap: Snapshot? // 마지막 수집 결과 — 크기·테마 변경은 재수집 없이 이걸로 즉시 재렌더

  var loginItemEnabled: Bool {
    if #available(macOS 13.0, *) { return SMAppService.mainApp.status == .enabled }
    return false
  }

  func applicationDidFinishLaunching(_ n: Notification) {
    statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    statusItem.button?.title = "…"
    // 다크/라이트 전환 시 배터리 색 갱신
    DistributedNotificationCenter.default().addObserver(
      self, selector: #selector(rerender),
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
    a.messageText = L("로그인 시 자동으로 시작할까요?", "Start automatically at login?")
    a.informativeText = L("맥을 켤 때마다 메뉴바에 사용량 배터리가 자동으로 표시됩니다. 나중에 메뉴에서 언제든 바꿀 수 있습니다.",
                          "The usage battery will appear in your menu bar every time you start your Mac. You can change this anytime from the menu.")
    a.addButton(withTitle: L("자동 시작", "Start at Login"))
    a.addButton(withTitle: L("나중에", "Later"))
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

  // 데이터 재수집 없이 마지막 스냅샷으로 즉시 다시 그림 (크기·테마 변경용)
  @objc func rerender() {
    if let s = lastSnap { render(s) } else { refresh() }
  }

  // 픽셀 크기 기준으로 디스플레이 배율을 나눠 표시 (레티나 ÷2, 1x 모니터 ÷1) — 재적용에도 안전
  func setButtonImage(_ img: NSImage) {
    guard let btn = statusItem.button else { return }
    let scale = btn.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
    let rep = img.representations.first
    let pw = CGFloat(rep?.pixelsWide ?? Int(img.size.width))
    let ph = CGFloat(rep?.pixelsHigh ?? Int(img.size.height))
    img.size = NSSize(width: pw / scale, height: ph / scale)
    img.isTemplate = false
    btn.title = ""
    btn.image = img
  }

  // 프레임 시퀀스 재생 — 마지막 프레임에서 멈춤
  private var animTimer: Timer?
  func playFrames(_ frames: [NSImage], interval: TimeInterval) {
    animTimer?.invalidate()
    guard !frames.isEmpty else { return }
    var i = 0
    animTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] t in
      guard let self = self, i < frames.count else { t.invalidate(); return }
      self.setButtonImage(frames[i])
      i += 1
    }
  }

  private var introPlayed = false

  func render(_ snap: Snapshot) {
    lastSnap = snap
    let items = battItems(snap)
    if let btn = statusItem.button {
      let dark = btn.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
      if !items.isEmpty, let finalImg = renderBatteryImage(dark: dark, items: items) {
        // 시작 시퀀스(최초 1회) + 황금 배터리 광택 스윕(있을 때마다) → 마지막은 실제 상태
        var frames: [NSImage] = []
        if !introPlayed {
          introPlayed = true
          frames += introFrames(items: items, dark: dark)
        }
        frames += glintFrames(items: items, dark: dark)
        if frames.isEmpty {
          setButtonImage(finalImg)
        } else {
          frames.append(finalImg)
          // CCB_ANIM_INTERVAL: 프레임 간격 재정의 (검증·데모용)
          let interval = ProcessInfo.processInfo.environment["CCB_ANIM_INTERVAL"].flatMap(Double.init) ?? 0.045
          playFrames(frames, interval: interval)
        }
      } else {
        btn.image = nil
        btn.title = "🔋 —"
      }
    }
    statusItem.menu = buildMenu(snap, swiftBarDup: swiftBarDuplicate(), target: self)
    // --pop-menu: 첫 렌더 직후 메뉴를 스스로 펼침 (스크린샷·검증용 — 보조 접근 불필요)
    if CommandLine.arguments.contains("--pop-menu"), !menuPopped {
      menuPopped = true
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
        guard let self = self, let btn = self.statusItem.button, let win = btn.window,
              let menu = self.statusItem.menu else { return }
        _ = (btn, win)
        NSApp.activate(ignoringOtherApps: true)
        // 주 디스플레이(원점 0,0) 메뉴바 아래 고정 좌표에 펼침 — 멀티 모니터에서도 캡처 위치 고정
        let screen = NSScreen.screens.first { $0.frame.origin == .zero } ?? NSScreen.screens[0]
        let pt = NSPoint(x: screen.frame.midX, y: screen.frame.maxY - 28)
        FileHandle.standardError.write(Data("popup: at \(pt)\n".utf8))
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
          menu.popUp(positioning: nil, at: pt, in: nil)
        }
      }
      return
    }
    // 온보딩은 첫 렌더가 화면에 나간 뒤에 — 모달이 데이터 표시를 막지 않도록
    if !promptShown {
      promptShown = true
      DispatchQueue.main.async { [weak self] in self?.firstRunAutoStartPrompt() }
    }
  }

  private var menuPopped = false

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
    rerender() // 렌더만 다시 — 데이터는 그대로라 즉시 반영
  }

  @objc func toggleLoginItem() {
    guard #available(macOS 13.0, *) else { return }
    let svc = SMAppService.mainApp
    if svc.status == .enabled { try? svc.unregister() } else { try? svc.register() }
    rerender() // 체크마크만 갱신하면 됨 — 재수집 불필요
  }

  // 원클릭 자동 업데이트 — 다운로드→서명 검증→자기 교체→재실행. 실패 시 릴리스 페이지 폴백
  @objc func selfUpdate(_ sender: NSMenuItem) {
    guard let v = sender.representedObject as? String else { return }
    statusItem.button?.image = nil
    statusItem.button?.title = L("⬇︎ 업데이트…", "⬇︎ Updating…")
    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
      do {
        try downloadAndInstallUpdate(version: v) { _ in }
        DispatchQueue.main.async { relaunchAfterUpdate() }
      } catch {
        DispatchQueue.main.async {
          self?.rerender()
          if let url = URL(string: "\(REPO_URL)/releases") { NSWorkspace.shared.open(url) }
        }
      }
    }
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

// ── --render-glint <path>: 글린트 중간 프레임을 PNG로 저장 (렌더 검증용) ──
if let idx = CommandLine.arguments.firstIndex(of: "--render-glint"), CommandLine.arguments.count > idx + 1 {
  let items = [BattItem(label: "C5", remain: 100), BattItem(label: "CW", remain: 100),
               BattItem(label: "X5", remain: 100)]
  if let img = renderBatteryImage(dark: true, items: items, glintX: 12),
     let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
     let png = rep.representation(using: .png, properties: [:]) {
    try? png.write(to: URL(fileURLWithPath: CommandLine.arguments[idx + 1]))
    print("saved")
  }
  exit(0)
}

// ── --self-update: 최신 버전 확인 후 즉시 설치 (헤드리스 검증·수동 업데이트용) ──
if CommandLine.arguments.contains("--self-update") {
  guard let latest = fetchLatestVersion() else { print("version check failed"); exit(1) }
  if cmpVer(latest, APP_VERSION) > 0 {
    do {
      try downloadAndInstallUpdate(version: latest) { print($0) }
      print("updated: v\(APP_VERSION) → v\(latest) at \(Bundle.main.bundlePath)")
    } catch {
      print("update failed: \(error)")
      exit(1)
    }
  } else {
    print("already latest (v\(APP_VERSION), remote v\(latest))")
  }
  exit(0)
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
