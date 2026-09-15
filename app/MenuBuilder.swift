// Dropdown menu construction — macOS system-menu tone: gauges live in the body, settings go in a submenu.
// All UI strings go through tr()/trf() (see Localization.swift).
import Cocoa

private let GRAY = "#8b949e"
private let WARN = "#d29922"

// Full state collected in a single refresh
struct Snapshot {
  let now: Int
  let claudeAll: [ClaudeUsage] // every Claude Code login, ~/.claude first
  let block: ClaudeBlock? // ccusage reads ~/.claude's logs, so this belongs to that login
  let models: (models: [ModelUse], total: Double)?
  let codexAll: [CodexUsage] // every Codex login, ~/.codex first
  let update: (latest: String?, hasUpdate: Bool)
  // Menu bar pick first (Settings → Menu bar account); the menu lists them in this order
  var claude: [ClaudeUsage] { barFirst(claudeAll, savedKey: CLAUDE_BAR_KEY) { $0.account.service } }
  var codexes: [CodexUsage] { barFirst(codexAll, savedKey: CODEX_BAR_KEY) { $0.account.home } }
  var usage: ClaudeUsage? { claude.first } // what the menu bar batteries show
  var codex: CodexUsage? { codexes.first }
}

// Account names appear only once there are two or more logins of a kind.
// Without an email the name is its stable position: "account 2".
private func claudeName(_ snap: Snapshot, _ u: ClaudeUsage) -> String {
  let i = snap.claudeAll.firstIndex { $0.account.service == u.account.service } ?? 0
  return u.account.label ?? trf("account %d", i + 1)
}

private func codexName(_ snap: Snapshot, _ cx: CodexUsage) -> String {
  let i = snap.codexAll.firstIndex { $0.account.home == cx.account.home } ?? 0
  return cx.account.label ?? trf("account %d", i + 1)
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

private func claudeRows(_ menu: NSMenu, _ u: ClaudeUsage, now: Int, labels: (five: String, week: String)) {
  if let w = u.fiveHour {
    gaugeRow(menu, labels.five, pct: w.pct, resetText: resetText(w.resetsAt, now: now))
  } else if u.live {
    gaugeRow(menu, labels.five, pct: 0, resetText: tr("no 5h window open"))
  } else {
    // Matches the "?" battery: say why there is no number instead of omitting the row
    row(menu, "\(labels.five) ?  ·  " + tr("unknown until the usage API answers"),
        mono: true, color: GRAY)
  }
  // Time-attack lap row: reach the reset (the finish line) before hitting 0%
  if let w = u.fiveHour, let ra = w.resetsAt, ra > now {
    let toFinish = fmtDur(ra - now)
    let panicking = max(0, 100 - w.pct) < 12 && ra - now > 1800
    if panicking {
      row(menu, "🏁 " + trf("lap: %@ to the finish — projected empty ⚠", toFinish),
          size: 11, color: "#f85149")
    } else {
      row(menu, "🏁 " + trf("lap: %@ to the finish — on pace ✓", toFinish),
          size: 11, color: "#3fb950")
    }
  }
  if let w = u.weekly { gaugeRow(menu, labels.week, pct: w.pct, resetText: resetText(w.resetsAt, now: now)) }
  for cap in u.modelCaps { gaugeRow(menu, cap.model, pct: cap.pct, resetText: resetText(cap.resetsAt, now: now)) }
  guard !u.live else { return }
  let msg: String
  if u.measuredAt == 0 {
    switch u.issue {
    case .rateLimited?: msg = tr("no reading yet — usage API busy, retrying soon")
    case .loginExpired?: msg = tr("no reading yet — Claude login expired, open Claude Code once")
    default: msg = tr("no reading yet — check login/network")
    }
  } else {
    let ago = fmtDur(now - u.measuredAt)
    switch u.issue {
    case .rateLimited?: msg = trf("cached %@ ago — usage API busy, retrying soon", ago)
    case .loginExpired?: msg = trf("cached %@ ago — Claude login expired, open Claude Code once", ago)
    default: msg = trf("cached %@ ago — check login/network", ago)
    }
  }
  row(menu, "⚠ " + msg, size: 11, color: WARN)
}

// ccusage block cost + per-model submenu (local logs of ~/.claude)
private func blockRows(_ menu: NSMenu, _ snap: Snapshot) {
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
}

// Settings → Accounts: which login the batteries follow, plus a way to add another one.
// Always shown (Developer ID build), so a single-login user can still find "add account".
// The MAS build reads only the default login, so it keeps the 2+ rule and has no add items.
private func accountMenu(_ snap: Snapshot, target: AppDelegate) -> NSMenu? {
#if MAS_BUILD
  guard snap.claudeAll.count > 1 || snap.codexAll.count > 1 else { return nil }
#endif
  let m = NSMenu()
  if !snap.claudeAll.isEmpty || !snap.codexAll.isEmpty {
    row(m, tr("Menu bar account"), size: 11, color: GRAY)
  }
  let bar = snap.usage?.account.service
  for u in snap.claudeAll {
    row(m, "Claude · " + claudeName(snap, u), action: #selector(AppDelegate.setBarAccount(_:)),
        target: target, repr: "claude\t" + u.account.service, state: u.account.service == bar ? .on : .off)
  }
  let cbar = snap.codex?.account.home
  for cx in snap.codexAll {
    row(m, "Codex · " + codexName(snap, cx), action: #selector(AppDelegate.setBarAccount(_:)),
        target: target, repr: "codex\t" + cx.account.home, state: cx.account.home == cbar ? .on : .off)
  }
#if !MAS_BUILD
  if !m.items.isEmpty { m.addItem(.separator()) }
  row(m, tr("Add Claude account…"), action: #selector(AppDelegate.addAccount(_:)), target: target, repr: "claude")
  row(m, tr("Add Codex account…"), action: #selector(AppDelegate.addAccount(_:)), target: target, repr: "codex")
#endif
  return m
}

func buildMenu(_ snap: Snapshot, swiftBarDup: Bool, target: AppDelegate) -> NSMenu {
  let menu = NSMenu()
  let now = snap.now
  let hasClaude = !snap.claudeAll.isEmpty || snap.block != nil
  let hasCodex = !snap.codexAll.isEmpty
  let labels = gaugeLabels()

  // An available update leads the menu, so it is seen on the next click rather than missed at the bottom
  if snap.update.hasUpdate, let latest = snap.update.latest {
    row(menu, "⬆︎ " + trf("Install v%@ update — one click (current v%@)", latest, APP_VERSION),
        color: "#28963f", action: #selector(AppDelegate.selfUpdate(_:)), target: target, repr: latest)
    menu.addItem(.separator())
  }

  if swiftBarDup {
    row(menu, tr("⚠️ SwiftBar widget is also running — batteries appear twice"),
        size: 12, color: "#FF9F0A")
    menu.addItem(.separator())
  }

  // ── Claude ── one section per login
  if hasClaude {
    let multi = snap.claude.count > 1
    // ccusage's block/model rows sit under the ~/.claude login they were read from
    let blockAt = snap.claude.firstIndex { $0.account.isDefault } ?? snap.claude.count - 1
    if snap.claude.isEmpty {
      row(menu, "Claude Code · " + tr("% left"), size: 13, color: GRAY)
      row(menu, "\(labels.five) ?  ·  " + tr("unknown until the usage API answers"),
          mono: true, color: GRAY)
      blockRows(menu, snap)
      menu.addItem(.separator())
    }
    for (i, u) in snap.claude.enumerated() {
      let who = multi ? " · " + claudeName(snap, u) : ""
      row(menu, "Claude Code\(who) · " + tr("% left"), size: 13, color: GRAY)
      claudeRows(menu, u, now: now, labels: labels)
      if i == blockAt { blockRows(menu, snap) }
      menu.addItem(.separator())
    }
  }

  // ── Codex ── one section per login
  for cx in snap.codexes {
    let who = snap.codexes.count > 1 ? " · " + codexName(snap, cx) : ""
    let suffix = cx.plan.map { " · \($0)" } ?? cx.limitId.map { " · \($0)" } ?? ""
    row(menu, "Codex\(who)\(suffix) · " + tr("% left"), size: 13, color: GRAY)
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
  if let acct = accountMenu(snap, target: target) { row(settings, tr("Accounts")).submenu = acct }

  let showMenu = NSMenu()
  let curShow = currentShowMode()
  for (mode, key) in [(ShowMode.group, "Tightest per group"), (.one, "Tightest only"), (.all, "All")] {
    row(showMenu, tr(key), action: #selector(AppDelegate.setShowMode(_:)), target: target,
        repr: mode.rawValue, state: curShow == mode ? .on : .off)
  }
  row(settings, tr("Batteries shown")).submenu = showMenu

  let numMenu = NSMenu()
  let curNum = currentNumStyle()
  for (style, key) in [(NumStyle.inside, "Inside"), (.outside, "Outside"), (.off, "Hidden")] {
    row(numMenu, tr(key), action: #selector(AppDelegate.setNumStyle(_:)), target: target,
        repr: style.rawValue, state: curNum == style ? .on : .off)
  }
  row(settings, tr("Number")).submenu = numMenu

  let catMenu = NSMenu()
  let curCat = currentCatStyle()
  for (style, key) in [(CatStyle.none, "Off"), (.nyan, "Wide face"),
                       (.slim, "Slim face"), (.slime, "Slime")] {
    row(catMenu, tr(key), action: #selector(AppDelegate.setCatStyle(_:)), target: target,
        repr: style.rawValue, state: curCat == style ? .on : .off)
  }
  row(settings, tr("Cat")).submenu = catMenu

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
#if MAS_BUILD
  if codexGrantedURL() == nil {
    row(settings, tr("Connect Codex folder…"),
        action: #selector(AppDelegate.connectCodex), target: target)
  }
#endif
  if snap.block != nil {
    row(settings, tr("Open ccusage dashboard"), action: #selector(AppDelegate.openDashboard), target: target)
  }
#if !MAS_BUILD
  row(settings, tr("Check for updates"), action: #selector(AppDelegate.checkForUpdates), target: target)
#endif
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
