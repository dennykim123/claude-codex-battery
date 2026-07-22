// Claude & Codex Usage Battery — a fully standalone native menu bar app (RunCat style)
// Runs independently without SwiftBar/bun: keychain/auth file → queries the usage API directly → renders the battery.
import Cocoa
import ServiceManagement

let REFRESH_SECONDS = 120.0

// If SwiftBar has the same widget plugin enabled, the battery shows up twice — detect and warn
func swiftBarDuplicate() -> Bool {
  guard FileManager.default.fileExists(atPath: "\(HOME)/.swiftbar-plugins/claude-codex-usage.2m.js"),
        !NSRunningApplication.runningApplications(withBundleIdentifier: "com.ameba.SwiftBar").isEmpty
  else { return false }
  let disabled = UserDefaults(suiteName: "com.ameba.SwiftBar")?.array(forKey: "DisabledPlugins") as? [String] ?? []
  return !disabled.contains("claude-codex-usage.2m.js")
}

// Batch data collection (called from a background thread)
func collectSnapshot() -> Snapshot {
  let now = Int(Date().timeIntervalSince1970)
  return Snapshot(now: now,
                  usage: getClaudeUsage(now: now),
                  block: getClaudeBlock(now: now),
                  models: getClaudeModels(),
                  codex: getCodex(now: now),
                  update: getUpdateInfo(now: now))
}

// Snapshot → menu bar battery items (same logic as the widget JS's rendering code)
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
    // Only draws whichever window is active at the time — a missing window is omitted rather than shown as an empty capsule
    if let p = windowState(cx.primary, now: snap.now) {
      items.append(BattItem(label: "X5", remain: max(0, 100 - p.pct)))
    }
    if let s = windowState(cx.secondary, now: snap.now) {
      items.append(BattItem(label: "XW", remain: max(0, 100 - s.pct)))
    }
  } else if let cr = snap.codex?.credits {
    // premium consumable-style: has credits=100 / exhausted=0 / unlimited=100
    let remain: Double = cr.unlimited ? 100 : (cr.hasCredits && (cr.balance ?? 0) > 0 ? 100 : 0)
    items.append(BattItem(label: "X", remain: remain))
  }
  // For visually testing the golden battery (dev only)
  if ProcessInfo.processInfo.environment["CCB_GOLD_TEST"] != nil {
    return items.map { BattItem(label: $0.label, remain: $0.remain == nil ? nil : 100) }
  }
  return items
}

// Startup sequence: starting from the leftmost battery, fills from 0 → actual remaining value in order (the number counts up too)
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

// Golden battery glint sweep (when at least one capsule is golden)
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
  var glintTimer: Timer?
  var lastSnap: Snapshot? // last collected result — size/theme changes re-render from this instantly without re-collecting

  var loginItemEnabled: Bool {
    if #available(macOS 13.0, *) { return SMAppService.mainApp.status == .enabled }
    return false
  }

  func applicationDidFinishLaunching(_ n: Notification) {
    statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    statusItem.button?.title = "…"
    // Refresh battery colors on dark/light mode switch
    DistributedNotificationCenter.default().addObserver(
      self, selector: #selector(rerender),
      name: NSNotification.Name("AppleInterfaceThemeChangedNotification"), object: nil)
    refresh()
    timer = Timer.scheduledTimer(withTimeInterval: REFRESH_SECONDS, repeats: true) { [weak self] _ in
      self?.refresh()
    }
    // The golden battery glint plays every 30s independently of data refresh (replays from cached state without re-collecting)
    let glintEvery = ProcessInfo.processInfo.environment["CCB_GLINT_SECONDS"].flatMap(Double.init) ?? 30.0
    glintTimer = Timer.scheduledTimer(withTimeInterval: glintEvery, repeats: true) { [weak self] _ in
      self?.playGoldenGlint()
    }
  }

  // Based on the cached snapshot, plays the glint sweep once if a golden battery is present
  func playGoldenGlint() {
    if ProcessInfo.processInfo.environment["CCB_DEBUG"] != nil {
      FileHandle.standardError.write(Data("glint tick: lastSnap=\(lastSnap != nil)\n".utf8))
    }
    guard let snap = lastSnap, let btn = statusItem.button else { return }
    let items = battItems(snap)
    let dark = btn.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    var frames = glintFrames(items: items, dark: dark)
    guard !frames.isEmpty, let final = renderBatteryImage(dark: dark, items: items) else { return }
    frames.append(final)
    let interval = ProcessInfo.processInfo.environment["CCB_ANIM_INTERVAL"].flatMap(Double.init) ?? 0.045
    playFrames(frames, interval: interval)
  }

  // First run only: prompts to register auto-start at login (RunCat-style onboarding)
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

  // Redraws immediately from the last snapshot without re-collecting data (for size/theme changes)
  @objc func rerender() {
    if let s = lastSnap { render(s) } else { refresh() }
  }

  // Divides by the display scale factor based on pixel size (Retina ÷2, 1x monitor ÷1) — safe to reapply
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

  // Plays a frame sequence — stops on the last frame
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
        // Startup sequence (once only) + golden battery glint sweep (whenever present) → the last frame is the actual state
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
          // CCB_ANIM_INTERVAL: overrides the frame interval (for verification/demo)
          let interval = ProcessInfo.processInfo.environment["CCB_ANIM_INTERVAL"].flatMap(Double.init) ?? 0.045
          playFrames(frames, interval: interval)
        }
      } else {
        btn.image = nil
        btn.title = "🔋 —"
      }
    }
    statusItem.menu = buildMenu(snap, swiftBarDup: swiftBarDuplicate(), target: self)
    // --pop-menu: pops the menu open by itself right after the first render (for screenshots/verification — no accessibility access needed)
    if CommandLine.arguments.contains("--pop-menu"), !menuPopped {
      menuPopped = true
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
        guard let self = self, let btn = self.statusItem.button, let win = btn.window,
              let menu = self.statusItem.menu else { return }
        _ = (btn, win)
        NSApp.activate(ignoringOtherApps: true)
        // Pops open at a fixed coordinate under the menu bar on the main display (origin 0,0) — keeps the capture position fixed even on multiple monitors
        let screen = NSScreen.screens.first { $0.frame.origin == .zero } ?? NSScreen.screens[0]
        let pt = NSPoint(x: screen.frame.midX, y: screen.frame.maxY - 28)
        FileHandle.standardError.write(Data("popup: at \(pt)\n".utf8))
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
          menu.popUp(positioning: nil, at: pt, in: nil)
        }
      }
      return
    }
    // Onboarding runs only after the first render has hit the screen — so the modal doesn't block the data from showing
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
    rerender() // re-render only — the data is unchanged so this reflects instantly
  }

  @objc func toggleLoginItem() {
    guard #available(macOS 13.0, *) else { return }
    let svc = SMAppService.mainApp
    if svc.status == .enabled { try? svc.unregister() } else { try? svc.register() }
    rerender() // only the checkmark needs updating — no need to re-collect
  }

  // One-click auto-update — download → verify signature → replace self → relaunch. Falls back to the releases page on failure
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

  // Opens the ccusage dashboard in Terminal — via a .command file (runs Terminal without a permission prompt)
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

// ── --render-glint <path>: saves an intermediate glint frame as PNG (for render verification) ──
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

// ── --self-update: checks the latest version and installs it immediately (for headless verification/manual updates) ──
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

// ── --dump-menu: prints the dropdown menu structure as text without UI (for verification) ──
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

// ── --dump: prints collection/render data as text without UI (for pipeline verification) ──
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

// ── Duplicate-launch guard — quits silently if an instance with the same bundle ID is already running ──
let myID = Bundle.main.bundleIdentifier ?? "com.dennykim.claude-codex-battery-app"
let myPID = ProcessInfo.processInfo.processIdentifier
if NSRunningApplication.runningApplications(withBundleIdentifier: myID)
  .contains(where: { $0.processIdentifier != myPID }) {
  exit(0)
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory) // menu bar only (no Dock icon)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
