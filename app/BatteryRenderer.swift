// 메뉴바 배터리 아이콘 렌더러 — 위젯 JS의 픽셀 캔버스·폰트·지오메트리를 그대로 포팅
// (PNG 인코딩 대신 CGImage 직생성. 픽셀 배치는 JS와 1:1 동일)
import Cocoa

struct BattItem {
  let label: String // "C5"·"CW"·"CF"·"X5"·"XW"·"X" — 첫 글자가 그룹(C/X)
  let remain: Double? // 남은 % (nil이면 빈 캡슐)
}

// 4x6 픽셀 폰트 (big 프리셋)
private let FONT46: [Character: [String]] = [
  "0": ["0110", "1001", "1001", "1001", "1001", "0110"],
  "1": ["0010", "0110", "0010", "0010", "0010", "0111"],
  "2": ["0110", "1001", "0010", "0100", "1000", "1111"],
  "3": ["1110", "0001", "0110", "0001", "1001", "0110"],
  "4": ["0010", "0110", "1010", "1111", "0010", "0010"],
  "5": ["1111", "1000", "1110", "0001", "1001", "0110"],
  "6": ["0110", "1000", "1110", "1001", "1001", "0110"],
  "7": ["1111", "0001", "0010", "0100", "0100", "0100"],
  "8": ["0110", "1001", "0110", "1001", "1001", "0110"],
  "9": ["0110", "1001", "1001", "0111", "0001", "0110"],
  "C": ["0110", "1001", "1000", "1000", "1001", "0110"],
  "X": ["1001", "1001", "0110", "0110", "1001", "1001"],
]
// 3x5 클래식 픽셀 폰트 (small 프리셋)
private let FONT35: [Character: [String]] = [
  "0": ["111", "101", "101", "101", "111"],
  "1": ["010", "110", "010", "010", "111"],
  "2": ["111", "001", "111", "100", "111"],
  "3": ["111", "001", "111", "001", "111"],
  "4": ["101", "101", "111", "001", "001"],
  "5": ["111", "100", "111", "001", "111"],
  "6": ["111", "100", "111", "101", "111"],
  "7": ["111", "001", "001", "001", "001"],
  "8": ["111", "101", "111", "101", "111"],
  "9": ["111", "101", "111", "001", "111"],
  "C": ["111", "100", "100", "100", "111"],
  "X": ["101", "101", "010", "101", "101"],
]

// 프리셋별 지오메트리 (JS PRESET와 동일 수치)
private struct Preset {
  let font: [Character: [String]]
  let adv: (Character) -> Int // 자간 (big은 '1'만 4px 커닝)
  let bw, bh, capw, gap, ggap, pad, lblgap, H, dy: Int
}

private let PRESET_BIG = Preset(font: FONT46, adv: { $0 == "1" ? 4 : 5 },
                                bw: 18, bh: 10, capw: 20, gap: 5, ggap: 10, pad: 2, lblgap: 3, H: 12, dy: 3)
private let PRESET_SMALL = Preset(font: FONT35, adv: { _ in 4 },
                                  bw: 14, bh: 9, capw: 16, gap: 3, ggap: 7, pad: 1, lblgap: 2, H: 9, dy: 2)

let SIZE_FILE = "\(STATE_DIR)/.batt-size"
func currentBattSize() -> String {
  let s = (try? String(contentsOfFile: SIZE_FILE, encoding: .utf8))?
    .trimmingCharacters(in: .whitespacesAndNewlines)
  return s == "small" ? "small" : "big"
}

private typealias RGB = (r: UInt8, g: UInt8, b: UInt8)

// 논리 픽셀 캔버스 (SCALE=2 — 레티나 대비 2x 픽셀로 그림)
private final class Canvas {
  static let SCALE = 2
  let wl: Int, hl: Int, w: Int, h: Int
  var buf: [UInt8]
  init(_ wl: Int, _ hl: Int) {
    self.wl = wl
    self.hl = hl
    w = wl * Canvas.SCALE
    h = hl * Canvas.SCALE
    buf = [UInt8](repeating: 0, count: w * h * 4)
  }

  func set(_ x: Int, _ y: Int, _ col: RGB) {
    if x < 0 || y < 0 || x >= wl || y >= hl { return }
    for dy in 0 ..< Canvas.SCALE {
      for dx in 0 ..< Canvas.SCALE {
        let px = ((y * Canvas.SCALE + dy) * w + (x * Canvas.SCALE + dx)) * 4
        buf[px] = col.r
        buf[px + 1] = col.g
        buf[px + 2] = col.b
        buf[px + 3] = 255
      }
    }
  }

  func rect(_ x: Int, _ y: Int, _ rw: Int, _ rh: Int, _ col: RGB) {
    for j in 0 ..< rh { for i in 0 ..< rw { set(x + i, y + j, col) } }
  }

  // 모서리 1px 비운 라운드 테두리
  func stroke(_ x: Int, _ y: Int, _ rw: Int, _ rh: Int, _ col: RGB) {
    for i in 1 ..< max(1, rw - 1) {
      set(x + i, y, col)
      set(x + i, y + rh - 1, col)
    }
    for j in 1 ..< max(1, rh - 1) {
      set(x, y + j, col)
      set(x + rw - 1, y + j, col)
    }
  }
}

// 실제 macOS 배터리 인디케이터 색 (Apple HIG system colors)
private func heatRemain(_ r: Double, dark: Bool) -> RGB {
  if r <= 20 { return dark ? (255, 69, 58) : (255, 59, 48) } // systemRed
  if r < 50 { return dark ? (255, 214, 10) : (255, 204, 0) } // systemYellow
  return dark ? (48, 209, 88) : (52, 199, 89) // systemGreen
}

// altCol/boundaryX 지정 시: 픽셀 x가 채움 경계 왼쪽이면 altCol(밝은 채움 위 대비), 오른쪽이면 col
@discardableResult
private func drawNum(_ cv: Canvas, _ p: Preset, _ x: Int, _ y: Int, _ str: String,
                     _ col: RGB, _ altCol: RGB? = nil, _ boundaryX: Int = 0) -> Int {
  var cx = x
  for ch in str {
    if let g = p.font[ch] {
      for (r, rowStr) in g.enumerated() {
        for (c, bit) in rowStr.enumerated() where bit == "1" {
          let px = cx + c
          if let alt = altCol, px < boundaryX { cv.set(px, y + r, alt) }
          else { cv.set(px, y + r, col) }
        }
      }
    }
    cx += p.adv(ch)
  }
  return cx
}

private func numW(_ p: Preset, _ s: String) -> Int { s.reduce(0) { $0 + p.adv($1) } - 1 }

// 캡슐 하나: 테두리 + 잔량 채움 + 안에 잔량 숫자 (100 포함, 항상 표시)
private func drawCapsule(_ cv: Canvas, _ p: Preset, _ x: Int, _ midY: Int,
                         _ remain: Double?, _ ink: RGB, _ dark: Bool) {
  let by = midY - p.bh / 2
  cv.stroke(x, by, p.bw, p.bh, ink)
  cv.rect(x + p.bw, by + 3, 2, p.bh - 6, ink) // 단자
  guard let remain = remain else { return }
  let innerW = p.bw - 4
  let v = max(0, min(100, remain))
  let fw = Int((v / 100 * Double(innerW)).rounded())
  if fw > 0 { cv.rect(x + 2, by + 2, fw, p.bh - 4, heatRemain(remain, dark: dark)) }
  let s = String(Int(v.rounded()))
  let tx = x + (p.bw - numW(p, s)) / 2
  // 채움(밝은 system color) 위 픽셀은 어두운 숫자, 빈 배경 위는 ink → 어디서나 대비 확보
  drawNum(cv, p, tx, midY - p.dy, s, ink, (30, 30, 30), x + 2 + fw)
}

// 캡슐 N개 + 그룹 라벨(C/X) → NSImage (2x 픽셀, 표시 크기는 호출부에서 배율로 조정)
func renderBatteryImage(dark: Bool, items: [BattItem]) -> NSImage? {
  let p = currentBattSize() == "small" ? PRESET_SMALL : PRESET_BIG
  let ink: RGB = dark ? (235, 235, 235) : (45, 45, 45)
  // 폭 계산 (그룹 라벨 포함)
  var W = p.pad * 2
  var pg: Character? = nil
  for item in items {
    let g = item.label.first!
    if g != pg {
      if pg != nil { W += p.ggap }
      W += numW(p, String(g)) + p.lblgap
      pg = g
    } else { W += p.gap }
    W += p.capw
  }
  let cv = Canvas(max(W, 8), p.H)
  let midY = p.H / 2
  var x = p.pad
  pg = nil
  for item in items {
    let g = item.label.first!
    if g != pg {
      if pg != nil { x += p.ggap }
      drawNum(cv, p, x, midY - p.dy, String(g), ink) // 그룹 라벨 C 또는 X
      x += numW(p, String(g)) + p.lblgap
      pg = g
    } else { x += p.gap }
    drawCapsule(cv, p, x, midY, item.remain, ink, dark)
    x += p.capw
  }
  guard let provider = CGDataProvider(data: Data(cv.buf) as CFData),
        let cg = CGImage(width: cv.w, height: cv.h, bitsPerComponent: 8, bitsPerPixel: 32,
                         bytesPerRow: cv.w * 4, space: CGColorSpaceCreateDeviceRGB(),
                         bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                         provider: provider, decode: nil, shouldInterpolate: false,
                         intent: .defaultIntent)
  else { return nil }
  return NSImage(cgImage: cg, size: NSSize(width: cv.w, height: cv.h))
}
