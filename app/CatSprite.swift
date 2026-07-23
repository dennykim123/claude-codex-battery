// Pixel cat mascot — emotes about your battery burn (time-attack mascot).
// Selectable styles (Settings → Cat), all on the same logical-pixel canvas/ink
// as the batteries so they read as one set:
//   nyan   — wide Nyan-Cat-grammar face: wide-set dot eyes, pink blush, low ω mouth (default)
//   slim   — slimmer face, punched eyes/mouth
//   slime  — RPG slime blob with squash-and-stretch bounce
// States: sleep (no usage) · walk (calm) · run (focused) · dash (heavy burn)
//         panic (projected empty) · happy (every battery golden)
import Foundation

enum CatState: String {
  case sleep, walk, run, dash, panic, happy
}

enum CatStyle: String, CaseIterable {
  case none, nyan, slim, slime
}

// Style resolution: CCB_CAT_STYLE env (testing) → saved choice → off by default
func currentCatStyle() -> CatStyle {
  if let e = ProcessInfo.processInfo.environment["CCB_CAT_STYLE"],
     let s = CatStyle(rawValue: e) { return s }
  if let saved = UserDefaults.standard.string(forKey: "catStyle") {
    if saved == "runner" { return .nyan } // style removed in favor of the faces
    if let s = CatStyle(rawValue: saved) { return s }
  }
  return .none
}

// All grids are 12 wide. A = ink · o = flame/gold accent · r = alert red · b = sweat blue
// p = pink blush · z = ink (zzz)

// ── nyan: wide face, wide-set eyes, pink cheeks, low ω mouth ──
private let NYAN_CALM = [
  ".A........A.", ".AA......AA.", "AAAAAAAAAAAA", "AA.AAAAAA.AA",
  "AAAAAAAAAAAA", "ApAA.AA.AApA", "AAAAA..AAAAA", ".AAAAAAAAAA.",
]
private let NYAN_BLINK = [
  ".A........A.", ".AA......AA.", "AAAAAAAAAAAA", "A..AAAAAA..A",
  "AAAAAAAAAAAA", "ApAA.AA.AApA", "AAAAA..AAAAA", ".AAAAAAAAAA.",
]
private let NYAN_SLEEP_1 = [
  ".A........Az", ".AA......AA.", "AAAAAAAAAAAz", "A..AAAAAA..A",
  "AAAAAAAAAAAA", "ApAA.AA.AApA", "AAAAA..AAAAA", ".AAAAAAAAAA.",
]
private let NYAN_SLEEP_2 = [
  ".A........A.", ".AA......AAz", "AAAAAAAAAAAA", "A..AAAAAA..A",
  "AAAAAAAAAAAA", "ApAA.AA.AApA", "AAAAA..AAAAA", ".AAAAAAAAAA.",
]
private let NYAN_FOCUS = [
  ".A........A.", ".AA......AA.", "AAAAAAAAAAAA", "AA.AAAAAA.AA",
  "AAAAAAAAAAAA", "ApAAAAAAAApA", "AAAA....AAAA", ".AAAAAAAAAA.",
]
private let NYAN_FOCUS_2 = [
  ".A........A.", "AAA......AA.", "AAAAAAAAAAAA", "AA.AAAAAA.AA",
  "AAAAAAAAAAAA", "ApAAAAAAAApA", "AAAA....AAAA", ".AAAAAAAAAA.",
]
private let NYAN_DASH_1 = [
  ".o........o.", ".AA......AA.", "AAAAAAAAAAAA", "AA.AAAAAA.AA",
  "AAAAAAAAAAAA", "ApAAAAAAAApA", "AAAA....AAAA", ".AAAAAAAAAA.",
]
private let NYAN_DASH_2 = [
  "oo........oo", ".AA......AA.", "AAAAAAAAAAAA", "AA.AAAAAA.AA",
  "AAAAAAAAAAAA", "ApAAAAAAAApA", "AAAA....AAAA", ".AAAAAAAAAA.",
]
private let NYAN_PANIC_1 = [
  ".A........A.", ".AA......AAb", "AAAAAAAAAAAA", "AA.AAAAAA.AA",
  "AAAAAAAAAAAb", "ApAAAAAAAApA", "AAAA....AAAA", ".AAAAAAAAAA.",
]
private let NYAN_PANIC_2 = [
  "..A........A", "..AA......AA", ".AAAAAAAAAAA", ".AA.AAAAAA.b",
  ".AAAAAAAAAAA", ".ApAAAAAAAAp", ".AAAA....AAA", "..AAAAAAAAAA",
]
private let NYAN_HAPPY_1 = [
  ".A........Ao", ".AA......AA.", "AAAAAAAAAAAA", "A..AAAAAA..A",
  "AAAAAAAAAAAo", "ApAA.AA.AApA", "AAAAA..AAAAA", ".AAAAAAAAAAo",
]
private let NYAN_HAPPY_2 = [
  "oA........A.", ".AA......AAo", "AAAAAAAAAAAA", "A..AAAAAA..A",
  "AAAAAAAAAAAA", "ApAA.AA.AApA", "AAAAA..AAAAA", "oAAAAAAAAAA.",
]

// ── slim: genuinely narrow 8px face — almond outline, close-set eyes, tiny ω ──
private let SLIM_CALM = [
  "..A....A....", "..AA..AA....", ".AAAAAAAA...", ".AA.AA.AA...",
  ".AAAAAAAA...", ".AAA..AAA...", ".AAAAAAAA...", "..AAAAAA....",
]
private let SLIM_BLINK = [
  "..A....A....", "..AA..AA....", ".AAAAAAAA...", ".A..AA..A...",
  ".AAAAAAAA...", ".AAA..AAA...", ".AAAAAAAA...", "..AAAAAA....",
]
private let SLIM_SLEEP_1 = [
  "..A....A..z.", "..AA..AA....", ".AAAAAAAA..z", ".A..AA..A...",
  ".AAAAAAAA...", ".AAA..AAA...", ".AAAAAAAA...", "..AAAAAA....",
]
private let SLIM_SLEEP_2 = [
  "..A....A....", "..AA..AA..z.", ".AAAAAAAA...", ".A..AA..A...",
  ".AAAAAAAA...", ".AAA..AAA...", ".AAAAAAAA...", "..AAAAAA....",
]
private let SLIM_FOCUS = [
  "..A....A....", "..AA..AA....", ".AAAAAAAA...", ".AA.AA.AA...",
  ".AAAAAAAA...", ".AA....AA...", ".AAAAAAAA...", "..AAAAAA....",
]
private let SLIM_FOCUS_2 = [
  "..A....A....", ".AAA..AA....", ".AAAAAAAA...", ".AA.AA.AA...",
  ".AAAAAAAA...", ".AA....AA...", ".AAAAAAAA...", "..AAAAAA....",
]
private let SLIM_DASH_1 = [
  "..o....o....", "..AA..AA....", ".AAAAAAAA...", ".AA.AA.AA...",
  ".AAAAAAAA...", ".AA....AA...", ".AAAAAAAA...", "..AAAAAA....",
]
private let SLIM_DASH_2 = [
  ".oo....oo...", "..AA..AA....", ".AAAAAAAA...", ".AA.AA.AA...",
  ".AAAAAAAA...", ".AA....AA...", ".AAAAAAAA...", "..AAAAAA....",
]
private let SLIM_PANIC_1 = [
  "..A....A....", "..AA..AA..b.", ".AAAAAAAA...", ".AA.AA.AA.b.",
  ".AAAAAAAA...", ".AA....AA...", ".AAAAAAAA...", "..AAAAAA....",
]
private let SLIM_PANIC_2 = [
  "...A....A...", "...AA..AA.b.", "..AAAAAAAA..", "..AA.AA.AA..",
  "..AAAAAAAA..", "..AA....AA..", "..AAAAAAAA..", "...AAAAAA...",
]
private let SLIM_HAPPY_1 = [
  "..A....A..o.", "..AA..AA....", ".AAAAAAAA...", ".A..AA..A..o",
  ".AAAAAAAA...", ".AAA..AAA...", ".AAAAAAAA...", "..AAAAAA..o.",
]
private let SLIM_HAPPY_2 = [
  "..A....A....", "..AA..AA..o.", ".AAAAAAAA...", ".A..AA..A...",
  ".AAAAAAAA..o", ".AAA..AAA...", ".AAAAAAAA...", "..AAAAAA....",
]

// ── slime: RPG blob, squash-and-stretch bounce ──
private let SLIME_TALL = [
  ".....A......", "....AAA.....", "...AAAAA....", "..AAAAAAA...",
  ".AAAAAAAAA..", ".AA.AAA.AA..", ".AAAA..AAA..", ".AAAAAAAAA..",
]
private let SLIME_SQUASH = [
  "............", "............", ".....A......", "...AAAAA....",
  ".AAAAAAAAA..", "AAA.AAA.AAA.", "AAAAA..AAAA.", "AAAAAAAAAAA.",
]
private let SLIME_SLEEP_1 = [
  ".....A....z.", "....AAA.....", "...AAAAA...z", "..AAAAAAA...",
  ".AAAAAAAAA..", ".A..AAA..A..", ".AAAA..AAA..", ".AAAAAAAAA..",
]
private let SLIME_SLEEP_2 = [
  ".....A......", "....AAA...z.", "...AAAAA....", "..AAAAAAA...",
  ".AAAAAAAAA..", ".A..AAA..A..", ".AAAA..AAA..", ".AAAAAAAAA..",
]
private let SLIME_FOCUS_1 = [
  ".....A......", "....AAA.....", "...AAAAA....", "..AAAAAAA...",
  ".AAAAAAAAA..", ".AA.AAA.AA..", ".AAA....AA..", ".AAAAAAAAA..",
]
private let SLIME_FOCUS_2 = [
  "............", "............", ".....A......", "...AAAAA....",
  ".AAAAAAAAA..", "AAA.AAA.AAA.", "AAAA....AAA.", "AAAAAAAAAAA.",
]
private let SLIME_DASH_1 = [
  ".....A......", "...oAAA.....", "...AAAAA.o..", "..AAAAAAA...",
  "oAAAAAAAAA..", ".AA.AAA.AA..", ".AAA....AA..", ".AAAAAAAAAo.",
]
private let SLIME_DASH_2 = [
  "............", "............", ".....A..o...", "..oAAAAA....",
  ".AAAAAAAAAo.", "AAA.AAA.AAA.", "AAAA....AAA.", "AAAAAAAAAAA.",
]
private let SLIME_PANIC_1 = [
  ".....A......", "....AAA.....", "...AAAAA..b.", "..AAAAAAA...",
  ".AAAAAAAAAb.", ".AA.AAA.AA..", ".AAA....AA..", ".AAAAAAAAA..",
]
private let SLIME_PANIC_2 = [
  "......A.....", ".....AAA....", "....AAAAA.b.", "...AAAAAAA..",
  "..AAAAAAAAA.", "..AA.AAA.AA.", "..AAA....AA.", "..AAAAAAAAA.",
]
private let SLIME_HAPPY_1 = [
  ".....A....o.", "....AAA.....", "...AAAAA....", "..AAAAAAA..o",
  ".AAAAAAAAA..", ".A..AAA..A..", ".AAAA..AAA..", ".AAAAAAAAAo.",
]
private let SLIME_HAPPY_2 = [
  "............", "..........o.", ".....A......", "...AAAAA....",
  ".AAAAAAAAAo.", "AA..AAA..AA.", "AAAAA..AAAA.", "AAAAAAAAAAA.",
]

private let STYLE_FRAMES: [CatStyle: [CatState: [[String]]]] = [
  .nyan: [
    .sleep: [NYAN_SLEEP_1, NYAN_SLEEP_2],
    .walk: [NYAN_CALM, NYAN_CALM, NYAN_CALM, NYAN_BLINK], // occasional blink
    .run: [NYAN_FOCUS, NYAN_FOCUS_2],
    .dash: [NYAN_DASH_1, NYAN_DASH_2],
    .panic: [NYAN_PANIC_1, NYAN_PANIC_2],
    .happy: [NYAN_HAPPY_1, NYAN_HAPPY_2],
  ],
  .slim: [
    .sleep: [SLIM_SLEEP_1, SLIM_SLEEP_2],
    .walk: [SLIM_CALM, SLIM_CALM, SLIM_CALM, SLIM_BLINK],
    .run: [SLIM_FOCUS, SLIM_FOCUS_2],
    .dash: [SLIM_DASH_1, SLIM_DASH_2],
    .panic: [SLIM_PANIC_1, SLIM_PANIC_2],
    .happy: [SLIM_HAPPY_1, SLIM_HAPPY_2],
  ],
  .slime: [
    .sleep: [SLIME_SLEEP_1, SLIME_SLEEP_2],
    .walk: [SLIME_TALL, SLIME_SQUASH],
    .run: [SLIME_FOCUS_1, SLIME_FOCUS_2],
    .dash: [SLIME_DASH_1, SLIME_DASH_2],
    .panic: [SLIME_PANIC_1, SLIME_PANIC_2],
    .happy: [SLIME_HAPPY_1, SLIME_HAPPY_2],
  ],
]

let CAT_W = 12 // logical pixels
let CAT_H = 8

// Frame-cycle interval per state — the spread IS the burn-rate speedometer
func catTickInterval(_ s: CatState) -> TimeInterval {
  switch s {
  case .sleep: return 1.0
  case .walk: return 0.55
  case .run: return 0.3
  case .dash: return 0.12
  case .panic: return 0.15
  case .happy: return 0.4
  }
}

func catFrame(_ style: CatStyle, _ state: CatState, _ index: Int) -> [String] {
  let f = STYLE_FRAMES[style]?[state] ?? [NYAN_CALM]
  return f[index % f.count]
}
