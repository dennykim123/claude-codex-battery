// Dropdown menu construction — macOS system-menu tone: gauges live in the body, settings go in a submenu.
// All UI strings go through tr()/trf() (see Localization.swift).
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

// One remaining-percentage gauge line, e.g. "5h    ▕████████████░░░░░░░░▏  85%  ·  resets 3h 57m"
private func gaugeRow(_ menu: NSMenu, _ label: String, pct: Double, resetText: String?) {
  let r = max(0, 100 - pct)
  var t = "\(label) ▕\(gaugeBar(r, 20))▏ \(Int(r.rounded()))%"
  if let reset = resetText { t += "  ·  \(reset)" }
  row(menu, t, mono: true, color: heatRemainHex(r))
}

private func resetText(_ resetsAt: Int?, now: Int) -> String? {
  guard let ra = resetsAt else { return nil }
  return ra < now ? tr("reset") : tr("resets") + " " + fmtDur(ra - now)
}

func buildMenu(_ snap: Snapshot, swiftBarDup: Bool, target: AppDelegate) -> NSMenu {
  let menu = NSMenu()
  let now = snap.now
  let hasClaude = snap.usage != nil || snap.block != nil
  let hasCodex = snap.codex != nil
  let labels = gaugeLabels()

  if swiftBarDup {
    row(menu, tr("⚠️ SwiftBar widget is also running — batteries appear twice"),
        size: 12, color: "#FF9F0A")
    menu.addItem(.separator())
  }

  // ── Claude ──
  if hasClaude {
    row(menu, "Claude Code · " + tr("% left"), size: 13, color: GRAY)
    if let u = snap.usage {
      if let w = u.fiveHour { gaugeRow(menu, labels.five, pct: w.pct, resetText: resetText(w.resetsAt, now: now)) }
      if let w = u.weekly { gaugeRow(menu, labels.week, pct: w.pct, resetText: resetText(w.resetsAt, now: now)) }
      if let f = u.fable { gaugeRow(menu, f.model, pct: f.pct, resetText: resetText(f.resetsAt, now: now)) }
      if !u.live {
        row(menu, "⚠ " + trf("cached %@ ago — check login/network", fmtDur(now - u.measuredAt)),
            size: 11, color: WARN)
      }
    }
    if let b = snap.block {
      let cph = b.costPerHour.map { String(format: "%.1f", $0) } ?? "?"
      row(menu, trf("this block  $%.2f · %@ tokens · $%@/h", b.cost, fmtTok(b.tokens), cph),
          mono: true, size: 11, color: GRAY)
    }
    // Per-model detail lives in a submenu to keep the body short
    if let m = snap.models, !m.models.isEmpty {
      let sub = NSMenu()
      let maxCost = m.models[0].cost > 0 ? m.models[0].cost : 1
      for mu in m.models {
        let label = shortModel(mu.name).padding(toLength: 9, withPad: " ", startingAt: 0)
        row(sub, String(format: "%@▕%@▏ $%.1f  %@", label, gaugeBar(mu.cost / maxCost * 100, 12),
                        mu.cost, fmtTok(mu.tokens)), mono: true)
      }
      let parent = row(menu, trf("today by model · $%.0f total", m.total), size: 11, color: GRAY)
      parent.submenu = sub
    }
    menu.addItem(.separator())
  }

  // ── Codex ──
  if let cx = snap.codex {
    let suffix = cx.plan.map { " · \($0)" } ?? cx.limitId.map { " · \($0)" } ?? ""
    row(menu, "Codex\(suffix) · " + tr("% left"), size: 13, color: GRAY)
    let p = windowState(cx.primary, now: now)
    let s = windowState(cx.secondary, now: now)
    if p == nil, s == nil, let cr = cx.credits {
      if cr.unlimited {
        row(menu, tr("credits  unlimited"), mono: true, color: "#3fb950")
      } else if !cr.hasCredits || (cr.balance ?? 0) <= 0 {
        row(menu, tr("credits  exhausted — buy more or wait for reset"), mono: true, color: "#f85149")
      } else {
        row(menu, trf("credits  balance %.0f", cr.balance ?? 0), mono: true, color: "#3fb950")
      }
    }
    func codexReset(_ w: WindowState) -> String? {
      w.stale ? tr("reset") : w.resetsIn.map { tr("resets") + " " + fmtDur($0) }
    }
    if let p = p { gaugeRow(menu, labels.five, pct: p.pct, resetText: codexReset(p)) }
    if let s = s { gaugeRow(menu, labels.week, pct: s.pct, resetText: codexReset(s)) }
    if !cx.live {
      row(menu, "⚠ " + trf("data from %@ ago — check login/network", fmtDur(now - cx.measuredAt)),
          size: 11, color: WARN)
    }
    menu.addItem(.separator())
  }

  if !hasClaude, !hasCodex {
    row(menu, tr("Run Claude Code or Codex and usage will appear here"), size: 12, color: GRAY)
    menu.addItem(.separator())
  }

  // ── footer ──
  if snap.update.hasUpdate, let latest = snap.update.latest {
    row(menu, trf("Install v%@ update — one click (current v%@)", latest, APP_VERSION),
        color: "#28963f", action: #selector(AppDelegate.selfUpdate(_:)), target: target, repr: latest)
  }
  row(menu, tr("Refresh"), action: #selector(AppDelegate.refresh), target: target, key: "r")

  // Settings submenu — size · language · auto-start · shortcuts · version
  let settings = NSMenu()
  let sizeMenu = NSMenu()
  let size = currentBattSize()
  row(sizeMenu, tr("Big"), action: #selector(AppDelegate.setSizeBig), target: target,
      state: size == "big" ? .on : .off)
  row(sizeMenu, tr("Small"), action: #selector(AppDelegate.setSizeSmall), target: target,
      state: size == "small" ? .on : .off)
  row(settings, tr("Battery size")).submenu = sizeMenu

  let langMenu = NSMenu()
  let saved = UserDefaults.standard.string(forKey: "uiLang") ?? "auto"
  row(langMenu, tr("System default"), action: #selector(AppDelegate.setLang(_:)), target: target,
      repr: "auto", state: saved == "auto" ? .on : .off)
  langMenu.addItem(.separator())
  for l in LANG_DISPLAY {
    row(langMenu, l.name, action: #selector(AppDelegate.setLang(_:)), target: target,
        repr: l.code, state: saved == l.code ? .on : .off)
  }
  row(settings, tr("Language")).submenu = langMenu

  if #available(macOS 13.0, *) {
    row(settings, tr("Start at login"),
        action: #selector(AppDelegate.toggleLoginItem), target: target,
        state: target.loginItemEnabled ? .on : .off)
  }
  settings.addItem(.separator())
  if snap.block != nil {
    row(settings, tr("Open ccusage dashboard"), action: #selector(AppDelegate.openDashboard), target: target)
  }
  row(settings, tr("Open GitHub page"),
      action: #selector(AppDelegate.openLink(_:)), target: target, repr: REPO_URL)
  settings.addItem(.separator())
  row(settings, "v\(APP_VERSION) · Claude & Codex Usage Battery", size: 11, color: GRAY)
  row(menu, tr("Settings")).submenu = settings

  menu.addItem(.separator())
  menu.addItem(NSMenuItem(title: tr("Quit"),
                          action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
  return menu
}
