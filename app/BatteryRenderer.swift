// Menu bar battery icon renderer — vector capsules drawn with Core Graphics
// (Matches the macOS battery glyph: rounded body, terminal nub, anti-aliased system-font digits)
import Cocoa
import CoreText

struct BattItem {
  let label: String // "C5"·"CW"·"CF"·"X5"·"XW"·"X" — the first letter is the group (C/X)
  let remain: Double? // remaining % (nil means an empty capsule)
}

// Per-preset geometry. Everything but the body height is derived from the proportions measured
// off the system glyph (SF Symbol "battery.0percent", rendered at 200pt and probed pixel by pixel):
//   body 1.94:1 · stroke 12.0% of body height · body→nub gap 9.0%
//   nub 14.3% wide x 38.3% tall · corner radius ~33.8%
// Matching these is what makes the capsule read as a macOS battery rather than a rounded box.
private struct Preset {
  let bh: CGFloat // body height — the one free dimension
  let numSize, labelSize, numGap: CGFloat
  let gap, ggap, pad, lblgap: CGFloat
  let H: CGFloat

  var bw: CGFloat { bh * 1.94 }
  var bwBare: CGFloat { bh * 1.94 }
  var stroke: CGFloat { bh * 0.120 }
  var nubGap: CGFloat { bh * 0.090 }
  var nubW: CGFloat { bh * 0.143 }
  var nubH: CGFloat { bh * 0.383 }
  var radius: CGFloat { bh * 0.338 }
  var inset: CGFloat { bh * 0.120 + bh * 0.085 }
  var advance: CGFloat { bw + nubGap + nubW }
}

private let PRESET_BIG = Preset(bh: 9, numSize: 7, labelSize: 8.5, numGap: 2.2,
                                gap: 3, ggap: 7, pad: 2, lblgap: 2.5, H: 13)
private let PRESET_SMALL = Preset(bh: 8.33, numSize: 6.5, labelSize: 8, numGap: 1.8,
                                  gap: 2.5, ggap: 6, pad: 1.5, lblgap: 2, H: 12)

// Where the remaining % is drawn. Outside and off let the capsule carry a solid macOS-style fill;
// inside keeps the widget compact by tucking the number into the body over a tint.
enum NumStyle: String {
  case inside, outside, off
}

// How many batteries reach the menu bar. The system battery glyph is 22x11pt, so five capsules
// plus labels dwarf it — showing only the binding limit per group keeps the widget in that league.
enum ShowMode: String {
  case all, group, one
}

let SHOW_FILE = "\(STATE_DIR)/.batt-show"
func currentShowMode() -> ShowMode {
  let s = (try? String(contentsOfFile: SHOW_FILE, encoding: .utf8))?
    .trimmingCharacters(in: .whitespacesAndNewlines)
  return ShowMode(rawValue: s ?? "") ?? .all
}

// Keeps only the tightest limit — the one about to bite — per group, or overall
func filterForShowMode(_ items: [BattItem]) -> [BattItem] {
  let mode = currentShowMode()
  guard mode != .all, !items.isEmpty else { return items }
  let tightest: ([BattItem]) -> BattItem? = { group in
    group.min { ($0.remain ?? 101) < ($1.remain ?? 101) }
  }
  if mode == .one { return [tightest(items)].compactMap { $0 } }
  var seen: [Character] = []
  var out: [BattItem] = []
  for item in items where !seen.contains(item.label.first!) {
    seen.append(item.label.first!)
    if let pick = tightest(items.filter { $0.label.first == item.label.first }) { out.append(pick) }
  }
  return out
}

let NUM_FILE = "\(STATE_DIR)/.batt-number"
func currentNumStyle() -> NumStyle {
  let s = (try? String(contentsOfFile: NUM_FILE, encoding: .utf8))?
    .trimmingCharacters(in: .whitespacesAndNewlines)
  return NumStyle(rawValue: s ?? "") ?? .inside
}

let SIZE_FILE = "\(STATE_DIR)/.batt-size"
func currentBattSize() -> String {
  let s = (try? String(contentsOfFile: SIZE_FILE, encoding: .utf8))?
    .trimmingCharacters(in: .whitespacesAndNewlines)
  return s == "big" ? "big" : "small"
}

// The canvas is always drawn at 2x so Retina stays sharp; the caller must divide by THIS,
// not by the display's backing scale, or a 1x display renders the widget at double size.
let RENDER_SCALE: CGFloat = 2

private func preset() -> Preset { currentBattSize() == "small" ? PRESET_SMALL : PRESET_BIG }

// Monochrome ink that tracks the menu bar appearance, plus one warning accent
private func inkColor(_ dark: Bool) -> CGColor {
  dark ? CGColor(red: 1, green: 1, blue: 1, alpha: 0.92)
       : CGColor(red: 0, green: 0, blue: 0, alpha: 0.85)
}

// The level is a tint rather than a solid block, so the number on top stays legible at every level.
// Only a nearly empty battery breaks the monochrome (systemRed, same as the macOS low-battery indicator)
private func fillColor(_ remain: Double, _ dark: Bool, solid: Bool) -> CGColor {
  guard remain <= 20 else {
    if solid { return inkColor(dark) }
    return dark ? CGColor(red: 1, green: 1, blue: 1, alpha: 0.40)
                : CGColor(red: 0, green: 0, blue: 0, alpha: 0.30)
  }
  let a: CGFloat = solid ? 1 : (dark ? 0.62 : 0.55)
  return dark ? CGColor(red: 1, green: 0.27, blue: 0.23, alpha: a)
              : CGColor(red: 1, green: 0.23, blue: 0.19, alpha: a)
}

func isGolden(_ remain: Double?) -> Bool { (remain ?? 0) >= 99.5 }

// Full span of the glint sweep — the length needed for the diagonal to fully cross the capsule
func batteryGlintSpan() -> Int {
  let p = preset()
  return Int(p.bw + p.bh)
}

// MARK: - Text as vector paths
// Glyph outlines let the digits be knocked out of the fill with a plain path fill,
// which keeps the contrast trick of the pixel renderer without any text-smoothing surprises.
private func textPath(_ s: String, _ size: CGFloat) -> (path: CGPath, width: CGFloat) {
  let font = NSFont.monospacedDigitSystemFont(ofSize: size, weight: .semibold)
  let attr = NSAttributedString(string: s, attributes: [.font: font])
  let line = CTLineCreateWithAttributedString(attr)
  let path = CGMutablePath()
  for run in (CTLineGetGlyphRuns(line) as? [CTRun] ?? []) {
    let count = CTRunGetGlyphCount(run)
    guard count > 0 else { continue }
    let attrs = CTRunGetAttributes(run) as NSDictionary
    guard let runFont = attrs[kCTFontAttributeName as String] else { continue }
    let ctFont = runFont as! CTFont
    var glyphs = [CGGlyph](repeating: 0, count: count)
    var positions = [CGPoint](repeating: .zero, count: count)
    CTRunGetGlyphs(run, CFRangeMake(0, count), &glyphs)
    CTRunGetPositions(run, CFRangeMake(0, count), &positions)
    for i in 0 ..< count {
      guard let glyph = CTFontCreatePathForGlyph(ctFont, glyphs[i], nil) else { continue }
      path.addPath(glyph, transform: CGAffineTransform(translationX: positions[i].x, y: positions[i].y))
    }
  }
  return (path, CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil)))
}

// Recenters a glyph path on its ink bounds, so digits sit optically centered rather than on the baseline
private func centered(_ p: CGPath, in rect: CGRect) -> CGPath {
  let b = p.boundingBoxOfPath
  guard !b.isNull, b.width > 0 else { return p }
  var t = CGAffineTransform(translationX: rect.midX - b.midX, y: rect.midY - b.midY)
  return p.copy(using: &t) ?? p
}

private func textWidth(_ s: String, _ size: CGFloat) -> CGFloat { textPath(s, size).width }

// MARK: - Capsule

// One capsule: rounded body outline + terminal nub + remaining fill + the number knocked out of the fill
private func drawCapsule(_ ctx: CGContext, _ p: Preset, _ x: CGFloat, _ midY: CGFloat,
                         _ remain: Double?, _ dark: Bool, _ glintX: Int?, _ style: NumStyle) {
  let bw = style == .inside ? p.bw : p.bwBare
  let ink = inkColor(dark)
  let body = CGRect(x: x + p.stroke / 2, y: midY - p.bh / 2 + p.stroke / 2,
                    width: bw - p.stroke, height: p.bh - p.stroke)
  ctx.setStrokeColor(ink)
  ctx.setLineWidth(p.stroke)
  ctx.addPath(CGPath(roundedRect: body, cornerWidth: p.radius, cornerHeight: p.radius, transform: nil))
  ctx.strokePath()

  // Terminal nub, rounded on its outer edge like the system glyph
  let nub = CGRect(x: x + bw + p.nubGap, y: midY - p.nubH / 2, width: p.nubW, height: p.nubH)
  ctx.setFillColor(ink)
  ctx.addPath(CGPath(roundedRect: nub, cornerWidth: p.nubW / 2, cornerHeight: p.nubW / 2, transform: nil))
  ctx.fillPath()

  guard let remain = remain else { return }
  let v = max(0, min(100, remain))
  let inner = CGRect(x: x + p.inset, y: midY - p.bh / 2 + p.inset,
                     width: bw - p.inset * 2, height: p.bh - p.inset * 2)
  let fw = inner.width * CGFloat(v) / 100
  let filled = CGRect(x: inner.minX, y: inner.minY, width: fw, height: inner.height)
  let innerRadius = max(1, p.radius - p.inset + 0.4)

  if fw > 0.5 {
    ctx.saveGState()
    ctx.addPath(CGPath(roundedRect: inner, cornerWidth: innerRadius, cornerHeight: innerRadius, transform: nil))
    ctx.clip()
    ctx.setFillColor(fillColor(v, dark, solid: style != .inside || !fitsInside(v)))
    ctx.fill(filled)
    ctx.restoreGState()
  }

  // A full battery gets a diagonal shine sweeping across the fill (erased, so it reads in both themes)
  if isGolden(remain), let g = glintX {
    ctx.saveGState()
    ctx.clip(to: filled)
    ctx.setBlendMode(.clear)
    ctx.setAlpha(0.55)
    ctx.setLineWidth(2)
    ctx.move(to: CGPoint(x: filled.minX + CGFloat(g), y: filled.minY))
    ctx.addLine(to: CGPoint(x: filled.minX + CGFloat(g) - filled.height, y: filled.maxY))
    ctx.strokePath()
    ctx.restoreGState()
  }

  guard style == .inside, fitsInside(v) else { return }
  // The number always sits in solid ink on top of the tint — no boundary seam, readable at any level
  let s = String(Int(v.rounded()))
  var size = p.numSize
  var t = textPath(s, size)
  let maxW = inner.width - 1.5
  if t.width > maxW { // "100" needs a notch smaller than two digits
    size *= maxW / t.width
    t = textPath(s, size)
  }
  ctx.setFillColor(ink)
  ctx.addPath(centered(t.path, in: inner))
  ctx.fillPath()
}

// The mascot stays pixel art — it is a sprite, not a control
private func drawCat(_ ctx: CGContext, _ x: CGFloat, _ y: CGFloat,
                     _ style: CatStyle, _ state: CatState, _ frame: Int, _ dark: Bool) {
  let grid = catFrame(style, state, frame)
  let ink = inkColor(dark)
  for (r, rowStr) in grid.enumerated() {
    for (c, ch) in rowStr.enumerated() {
      let color: CGColor
      switch ch {
      case "A", "z": color = ink
      case "o": color = CGColor(red: 1, green: 0.59, blue: 0.20, alpha: 1)
      case "r": color = CGColor(red: 1, green: 0.27, blue: 0.24, alpha: 1)
      case "b": color = CGColor(red: 0.35, green: 0.71, blue: 1, alpha: 1)
      case "p": color = CGColor(red: 1, green: 0.59, blue: 0.67, alpha: 1)
      default: continue
      }
      ctx.setFillColor(color)
      ctx.fill(CGRect(x: x + CGFloat(c), y: y + CGFloat(grid.count - 1 - r), width: 1, height: 1))
    }
  }
}

// A full battery needs no number — dropping the third digit is what keeps the widget menu-bar sized
func fitsInside(_ v: Double) -> Bool { Int(v.rounded()) < 100 }

private func numText(_ remain: Double?) -> String {
  guard let r = remain else { return "" }
  return String(Int(max(0, min(100, r)).rounded()))
}

// How far the pen moves per battery — the trailing number only counts when it is drawn outside
private func itemAdvance(_ p: Preset, _ style: NumStyle, _ remain: Double?) -> CGFloat {
  let base = p.advance
  let s = numText(remain)
  guard style == .outside, !s.isEmpty else { return base }
  return base + p.numGap + textWidth(s, p.numSize)
}

// MARK: - Image

// N capsules + group label (C/X) → NSImage (2x pixels; the caller scales down to the display size)
// With `cat`, a pixel cat runs at the left edge, facing its battery "finish line".
func renderBatteryImage(dark: Bool, items: [BattItem], glintX: Int? = nil,
                        cat: CatState? = nil, catFrameIndex: Int = 0) -> NSImage? {
  let p = preset()
  let style = currentNumStyle()
  let fullLabel = currentShowMode() != .all
  let catStyle = currentCatStyle()
  let catSpan: CGFloat = (cat != nil && catStyle != .none) ? CGFloat(CAT_W) + 3 : 0

  var W = p.pad * 2 + catSpan
  var pg: Character? = nil
  for item in items {
    let g = item.label.first!
    if g != pg {
      if pg != nil { W += p.ggap }
      W += textWidth(fullLabel ? item.label : String(g), p.labelSize) + p.lblgap
      pg = g
    } else { W += p.gap }
    W += itemAdvance(p, style, item.remain)
  }

  let pw = Int((max(W, 8) * RENDER_SCALE).rounded(.up))
  let ph = Int((p.H * RENDER_SCALE).rounded(.up))
  guard let ctx = CGContext(data: nil, width: pw, height: ph, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
  else { return nil }
  ctx.scaleBy(x: RENDER_SCALE, y: RENDER_SCALE)
  ctx.setAllowsAntialiasing(true)
  ctx.setShouldAntialias(true)

  let midY = p.H / 2
  var x = p.pad
  if let c = cat, catStyle != .none {
    drawCat(ctx, x, (p.H - CGFloat(CAT_H)) / 2, catStyle, c, catFrameIndex, dark)
    x += catSpan
  }
  pg = nil
  for item in items {
    let g = item.label.first!
    if g != pg {
      if pg != nil { x += p.ggap }
      let text = fullLabel ? item.label : String(g)
      let lw = textWidth(text, p.labelSize)
      let slot = CGRect(x: x, y: midY - p.bh / 2, width: lw, height: p.bh)
      ctx.setFillColor(inkColor(dark))
      ctx.addPath(centered(textPath(text, p.labelSize).path, in: slot))
      ctx.fillPath()
      x += lw + p.lblgap
      pg = g
    } else { x += p.gap }
    drawCapsule(ctx, p, x, midY, item.remain, dark, glintX, style)
    let adv = itemAdvance(p, style, item.remain)
    if style == .outside, !numText(item.remain).isEmpty {
      let t = textPath(numText(item.remain), p.numSize)
      let slot = CGRect(x: x + adv - t.width, y: midY - p.bh / 2, width: t.width, height: p.bh)
      ctx.setFillColor(inkColor(dark))
      ctx.addPath(centered(t.path, in: slot))
      ctx.fillPath()
    }
    x += adv
  }

  guard let cg = ctx.makeImage() else { return nil }
  return NSImage(cgImage: cg, size: NSSize(width: pw, height: ph))
}
