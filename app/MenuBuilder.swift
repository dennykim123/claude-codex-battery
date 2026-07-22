// Dropdown menu construction — macOS system-menu tone: gauges live in the body, settings go in a submenu.
// All UI strings use L(ko, en) — auto-switches Korean/English based on system language.
import Cocoa

private let GRAY = "#8b949e"
private let WARN = "#d29922"

// Full state collected in a single refresh
struct Snapshot {
  let now: Int
  let usage: ClaudeUsage?
  let block: ClaudeBlock?
  let models: (models: [ModelUse], total: Double)?
  let codex: CodexUsage?
  let update: (latest: String?, hasUpdate: Bool)
}

@discardableResult
private func row(_ menu: NSMenu, _ text: String, mono: Bool = false, size: CGFloat = 0,
                 color: String? = nil, action: Selector? = nil, target: AnyObject? = nil,
                 repr: Any? = nil, key: String = "", state: NSControl.StateValue? = nil) -> NSMenuItem {
  let item = NSMenuItem(title: text, action: action, keyEquivalent: key)
  var font = NSFont.menuFont(ofSize: size)
  if mono { font = NSFont(name: "Menlo", size: size == 0 ? 12 : size) ?? font }
  var attrs: [NSAttributedString.Key: Any] = [.font: font]
  if let c = color.flatMap(hexColor) { attrs[.foregroundColor] = c }
  item.attributedTitle = NSAttributedString(string: text, attributes: attrs)
  item.target = target
  item.representedObject = repr
  if let s = state { item.state = s }
  menu.addItem(item)
  return item
}

// "5h  ▕████████████░░░░░░░░▏  85%  ·  resets 3h 57m" — one remaining-usage gauge line
private func gaugeRow(_ menu: NSMenu, _ label: String, pct: Double, resetText: String?) {
  let r = max(0, 100 - pct)
  var t = "\(label) ▕\(gaugeBar(r, 20))▏ \(Int(r.rounded()))%"
  if let reset = resetText { t += "  ·  \(reset)" }
  row(menu, t, mono: true, color: heatRemainHex(r))
}

private func resetText(_ resetsAt: Int?, now: Int) -> String? {
  guard let ra = resetsAt else { return nil }
  return ra < now ? L("리셋됨", "reset") : L("리셋 ", "resets ") + fmtDur(ra - now)
}

func buildMenu(_ snap: Snapshot, swiftBarDup: Bool, target: AppDelegate) -> NSMenu {
  let menu = NSMenu()
  let now = snap.now
  let hasClaude = snap.usage != nil || snap.block != nil
  let hasCodex = snap.codex != nil
  let lblFive = L("5시간", "5h   ")
  let lblWeek = L("주간 ", "week ")

  if swiftBarDup {
    row(menu, L("⚠️ SwiftBar 위젯도 실행 중 — 배터리가 두 벌 표시됩니다",
                "⚠️ SwiftBar widget is also running — batteries appear twice"),
        size: 12, color: "#FF9F0A")
    menu.addItem(.separator())
  }

  // ── Claude ──
  if hasClaude {
    row(menu, L("Claude Code · 남은 %", "Claude Code · % left"), size: 13, color: GRAY)
    if let u = snap.usage {
      if let w = u.fiveHour { gaugeRow(menu, lblFive, pct: w.pct, resetText: resetText(w.resetsAt, now: now)) }
      if let w = u.weekly { gaugeRow(menu, lblWeek, pct: w.pct, resetText: resetText(w.resetsAt, now: now)) }
      if let f = u.fable { gaugeRow(menu, f.model, pct: f.pct, resetText: resetText(f.resetsAt, now: now)) }
      if !u.live {
        row(menu, "⚠ " + L("\(fmtDur(now - u.measuredAt)) 전 캐시 — 로그인·네트워크 확인",
                           "cached \(fmtDur(now - u.measuredAt)) ago — check login/network"),
            size: 11, color: WARN)
      }
    }
    if let b = snap.block {
      let cph = b.costPerHour.map { String(format: "%.1f", $0) } ?? "?"
      row(menu, String(format: L("이번 블록  $%.2f · %@ 토큰 · $%@/h", "this block  $%.2f · %@ tokens · $%@/h"),
                       b.cost, fmtTok(b.tokens), cph),
          mono: true, size: 11, color: GRAY)
    }
    // Per-model detail goes in a submenu — keeps the body short
    if let m = snap.models, !m.models.isEmpty {
      let sub = NSMenu()
      let maxCost = m.models[0].cost > 0 ? m.models[0].cost : 1
      for mu in m.models {
        let label = shortModel(mu.name).padding(toLength: 9, withPad: " ", startingAt: 0)
        row(sub, String(format: "%@▕%@▏ $%.1f  %@", label, gaugeBar(mu.cost / maxCost * 100, 12),
                        mu.cost, fmtTok(mu.tokens)), mono: true)
      }
      let parent = row(menu, String(format: L("오늘 모델별 · 합 $%.0f", "today by model · $%.0f total"), m.total),
                       size: 11, color: GRAY)
      parent.submenu = sub
    }
    menu.addItem(.separator())
  }

  // ── Codex ──
  if let cx = snap.codex {
    let suffix = cx.plan.map { " · \($0)" } ?? cx.limitId.map { " · \($0)" } ?? ""
    row(menu, "Codex\(suffix)" + L(" · 남은 %", " · % left"), size: 13, color: GRAY)
    let p = windowState(cx.primary, now: now)
    let s = windowState(cx.secondary, now: now)
    if p == nil, s == nil, let cr = cx.credits {
      if cr.unlimited {
        row(menu, L("크레딧  무제한", "credits  unlimited"), mono: true, color: "#3fb950")
      } else if !cr.hasCredits || (cr.balance ?? 0) <= 0 {
        row(menu, L("크레딧  소진 — 구매 또는 리셋 대기", "credits  exhausted — buy more or wait for reset"),
            mono: true, color: "#f85149")
      } else {
        row(menu, String(format: L("크레딧  잔액 %.0f", "credits  balance %.0f"), cr.balance ?? 0),
            mono: true, color: "#3fb950")
      }
    }
    func codexReset(_ w: WindowState) -> String? {
      w.stale ? L("리셋됨", "reset") : w.resetsIn.map { L("리셋 ", "resets ") + fmtDur($0) }
    }
    if let p = p { gaugeRow(menu, lblFive, pct: p.pct, resetText: codexReset(p)) }
    if let s = s { gaugeRow(menu, lblWeek, pct: s.pct, resetText: codexReset(s)) }
    if !cx.live {
      row(menu, "⚠ " + L("\(fmtDur(now - cx.measuredAt)) 전 데이터 — 로그인·네트워크 확인",
                         "data from \(fmtDur(now - cx.measuredAt)) ago — check login/network"),
          size: 11, color: WARN)
    }
    menu.addItem(.separator())
  }

  if !hasClaude, !hasCodex {
    row(menu, L("Claude Code나 Codex를 실행하면 사용량이 표시됩니다",
                "Run Claude Code or Codex and usage will appear here"), size: 12, color: GRAY)
    menu.addItem(.separator())
  }

  // ── footer ──
  if snap.update.hasUpdate, let latest = snap.update.latest {
    row(menu, L("v\(latest) 업데이트 설치 — 클릭 한 번 (현재 v\(APP_VERSION))",
                "Install v\(latest) update — one click (current v\(APP_VERSION))"),
        color: "#28963f", action: #selector(AppDelegate.selfUpdate(_:)), target: target, repr: latest)
  }
  row(menu, L("새로고침", "Refresh"), action: #selector(AppDelegate.refresh), target: target, key: "r")

  // Settings submenu — size, auto-start, shortcuts, version
  let settings = NSMenu()
  let sizeMenu = NSMenu()
  let size = currentBattSize()
  row(sizeMenu, L("크게", "Big"), action: #selector(AppDelegate.setSizeBig), target: target,
      state: size == "big" ? .on : .off)
  row(sizeMenu, L("작게", "Small"), action: #selector(AppDelegate.setSizeSmall), target: target,
      state: size == "small" ? .on : .off)
  row(settings, L("배터리 크기", "Battery size")).submenu = sizeMenu
  if #available(macOS 13.0, *) {
    row(settings, L("로그인 시 자동 시작", "Start at login"),
        action: #selector(AppDelegate.toggleLoginItem), target: target,
        state: target.loginItemEnabled ? .on : .off)
  }
  settings.addItem(.separator())
  if snap.block != nil {
    row(settings, L("ccusage 대시보드 열기", "Open ccusage dashboard"),
        action: #selector(AppDelegate.openDashboard), target: target)
  }
  row(settings, L("GitHub 페이지 열기", "Open GitHub page"),
      action: #selector(AppDelegate.openLink(_:)), target: target, repr: REPO_URL)
  settings.addItem(.separator())
  row(settings, "v\(APP_VERSION) · Claude & Codex Usage Battery", size: 11, color: GRAY)
  row(menu, L("설정", "Settings")).submenu = settings

  menu.addItem(.separator())
  menu.addItem(NSMenuItem(title: L("종료", "Quit"),
                          action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
  return menu
}
