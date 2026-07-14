// 드롭다운 메뉴 구성 — macOS 시스템 메뉴 톤: 게이지는 본문, 설정류는 "설정" 서브메뉴로
import Cocoa

private let GRAY = "#8b949e"
private let WARN = "#d29922"

// 한 번의 새로고침에서 수집한 전체 상태
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

// "5시간  ▕████████████░░░░░░░░▏  85%  ·  리셋 3h 57m" — 잔량 게이지 한 줄
private func gaugeRow(_ menu: NSMenu, _ label: String, pct: Double,
                      resetText: String?, now: Int) {
  let r = max(0, 100 - pct)
  var t = "\(label) ▕\(gaugeBar(r, 20))▏ \(Int(r.rounded()))%"
  if let reset = resetText { t += "  ·  \(reset)" }
  row(menu, t, mono: true, color: heatRemainHex(r))
}

private func resetText(_ resetsAt: Int?, now: Int) -> String? {
  guard let ra = resetsAt else { return nil }
  return ra < now ? "리셋됨" : "리셋 \(fmtDur(ra - now))"
}

func buildMenu(_ snap: Snapshot, swiftBarDup: Bool, target: AppDelegate) -> NSMenu {
  let menu = NSMenu()
  let now = snap.now
  let hasClaude = snap.usage != nil || snap.block != nil
  let hasCodex = snap.codex != nil

  if swiftBarDup {
    row(menu, "⚠️ SwiftBar 위젯도 실행 중 — 배터리가 두 벌 표시됩니다", size: 12, color: "#FF9F0A")
    menu.addItem(.separator())
  }

  // ── Claude ──
  if hasClaude {
    row(menu, "Claude Code · 남은 %", size: 13, color: GRAY)
    if let u = snap.usage {
      if let w = u.fiveHour { gaugeRow(menu, "5시간", pct: w.pct, resetText: resetText(w.resetsAt, now: now), now: now) }
      if let w = u.weekly { gaugeRow(menu, "주간 ", pct: w.pct, resetText: resetText(w.resetsAt, now: now), now: now) }
      if let f = u.fable { gaugeRow(menu, f.model, pct: f.pct, resetText: resetText(f.resetsAt, now: now), now: now) }
      if !u.live {
        row(menu, "⚠ \(fmtDur(now - u.measuredAt)) 전 캐시 — 로그인·네트워크 확인", size: 11, color: WARN)
      }
    }
    if let b = snap.block {
      let cph = b.costPerHour.map { String(format: "%.1f", $0) } ?? "?"
      row(menu, String(format: "이번 블록  $%.2f · %@ 토큰 · $%@/h", b.cost, fmtTok(b.tokens), cph),
          mono: true, size: 11, color: GRAY)
    }
    // 모델별 상세는 서브메뉴로 — 본문을 짧게 유지
    if let m = snap.models, !m.models.isEmpty {
      let sub = NSMenu()
      let maxCost = m.models[0].cost > 0 ? m.models[0].cost : 1
      for mu in m.models {
        let label = shortModel(mu.name).padding(toLength: 9, withPad: " ", startingAt: 0)
        row(sub, String(format: "%@▕%@▏ $%.1f  %@", label, gaugeBar(mu.cost / maxCost * 100, 12),
                        mu.cost, fmtTok(mu.tokens)), mono: true)
      }
      let parent = row(menu, String(format: "오늘 모델별 · 합 $%.0f", m.total), size: 11, color: GRAY)
      parent.submenu = sub
    }
    menu.addItem(.separator())
  }

  // ── Codex ──
  if let cx = snap.codex {
    let suffix = cx.plan.map { " · \($0)" } ?? cx.limitId.map { " · \($0)" } ?? ""
    row(menu, "Codex\(suffix) · 남은 %", size: 13, color: GRAY)
    let p = windowState(cx.primary, now: now)
    let s = windowState(cx.secondary, now: now)
    if p == nil, s == nil, let cr = cx.credits {
      if cr.unlimited {
        row(menu, "크레딧  무제한", mono: true, color: "#3fb950")
      } else if !cr.hasCredits || (cr.balance ?? 0) <= 0 {
        row(menu, "크레딧  소진 — 구매 또는 리셋 대기", mono: true, color: "#f85149")
      } else {
        row(menu, String(format: "크레딧  잔액 %.0f", cr.balance ?? 0), mono: true, color: "#3fb950")
      }
    }
    func codexReset(_ w: WindowState) -> String? {
      w.stale ? "리셋됨" : w.resetsIn.map { "리셋 \(fmtDur($0))" }
    }
    if let p = p { gaugeRow(menu, "5시간", pct: p.pct, resetText: codexReset(p), now: now) }
    if let s = s { gaugeRow(menu, "주간 ", pct: s.pct, resetText: codexReset(s), now: now) }
    if !cx.live {
      row(menu, "⚠ \(fmtDur(now - cx.measuredAt)) 전 데이터 — 로그인·네트워크 확인", size: 11, color: WARN)
    }
    menu.addItem(.separator())
  }

  if !hasClaude, !hasCodex {
    row(menu, "Claude Code나 Codex를 실행하면 사용량이 표시됩니다", size: 12, color: GRAY)
    menu.addItem(.separator())
  }

  // ── footer ──
  if snap.update.hasUpdate, let latest = snap.update.latest {
    row(menu, "새 버전 v\(latest) — GitHub에서 받기", color: "#28963f",
        action: #selector(AppDelegate.openLink(_:)), target: target, repr: "\(REPO_URL)/releases")
  }
  row(menu, "새로고침", action: #selector(AppDelegate.refresh), target: target, key: "r")

  // 설정 서브메뉴 — 크기·자동 시작·바로가기·버전
  let settings = NSMenu()
  let sizeMenu = NSMenu()
  let size = currentBattSize()
  row(sizeMenu, "크게", action: #selector(AppDelegate.setSizeBig), target: target,
      state: size == "big" ? .on : .off)
  row(sizeMenu, "작게", action: #selector(AppDelegate.setSizeSmall), target: target,
      state: size == "small" ? .on : .off)
  row(settings, "배터리 크기").submenu = sizeMenu
  if #available(macOS 13.0, *) {
    row(settings, "로그인 시 자동 시작", action: #selector(AppDelegate.toggleLoginItem), target: target,
        state: target.loginItemEnabled ? .on : .off)
  }
  settings.addItem(.separator())
  if snap.block != nil {
    row(settings, "ccusage 대시보드 열기", action: #selector(AppDelegate.openDashboard), target: target)
  }
  row(settings, "GitHub 페이지 열기", action: #selector(AppDelegate.openLink(_:)), target: target, repr: REPO_URL)
  settings.addItem(.separator())
  row(settings, "v\(APP_VERSION) · Claude & Codex Usage Battery", size: 11, color: GRAY)
  row(menu, "설정").submenu = settings

  menu.addItem(.separator())
  menu.addItem(NSMenuItem(title: "종료", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
  return menu
}
