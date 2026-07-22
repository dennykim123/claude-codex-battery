// UI localization — English (default), Korean, Japanese, Chinese (Simplified/Traditional), Spanish.
// Resolution order: CCB_LANG env → user's saved choice (Settings → Language) → system language → English.
// The choice is also written to ~/.claude/swiftbar/.lang so the SwiftBar widget follows it.
import Foundation

let SUPPORTED_LANGS = ["en", "ko", "ja", "zh-Hans", "zh-Hant", "es"]
let LANG_FILE = "\(STATE_DIR)/.lang"

func normLang(_ raw: String) -> String {
  let l = raw.lowercased()
  if l.hasPrefix("ko") { return "ko" }
  if l.hasPrefix("ja") { return "ja" }
  if l.hasPrefix("es") { return "es" }
  if l.hasPrefix("zh") {
    if l.contains("hant") || l.contains("-tw") || l.contains("-hk") || l.contains("-mo") { return "zh-Hant" }
    return "zh-Hans"
  }
  if l.hasPrefix("en") { return "en" }
  return raw
}

func resolveLang() -> String {
  if let f = ProcessInfo.processInfo.environment["CCB_LANG"] {
    let n = normLang(f)
    if SUPPORTED_LANGS.contains(n) { return n }
  }
  if let saved = UserDefaults.standard.string(forKey: "uiLang"), saved != "auto",
     SUPPORTED_LANGS.contains(saved) { return saved }
  for pref in Locale.preferredLanguages {
    let n = normLang(pref)
    if SUPPORTED_LANGS.contains(n) { return n }
  }
  return "en"
}

var UI_LANG = resolveLang()

// English text is the key; missing entries fall back to English.
private let TR: [String: [String: String]] = [
  "% left": [
    "ko": "남은 %", "ja": "残り%", "zh-Hans": "剩余 %", "zh-Hant": "剩餘 %", "es": "% restante",
  ],
  "reset": [
    "ko": "리셋됨", "ja": "リセット済み", "zh-Hans": "已重置", "zh-Hant": "已重置", "es": "reiniciado",
  ],
  "resets": [
    "ko": "리셋", "ja": "リセット", "zh-Hans": "重置", "zh-Hant": "重置", "es": "reinicia",
  ],
  "used": [
    "ko": "사용", "ja": "使用", "zh-Hans": "已用", "zh-Hant": "已用", "es": "usado",
  ],
  "cached %@ ago — check login/network": [
    "ko": "%@ 전 캐시 — 로그인·네트워크 확인",
    "ja": "%@前のキャッシュ — ログイン/ネットワークを確認",
    "zh-Hans": "%@ 前的缓存 — 请检查登录/网络",
    "zh-Hant": "%@ 前的快取 — 請檢查登入/網路",
    "es": "caché de hace %@ — revisa sesión/red",
  ],
  "data from %@ ago — check login/network": [
    "ko": "%@ 전 데이터 — 로그인·네트워크 확인",
    "ja": "%@前のデータ — ログイン/ネットワークを確認",
    "zh-Hans": "%@ 前的数据 — 请检查登录/网络",
    "zh-Hant": "%@ 前的資料 — 請檢查登入/網路",
    "es": "datos de hace %@ — revisa sesión/red",
  ],
  "this block  $%.2f · %@ tokens · $%@/h": [
    "ko": "이번 블록  $%.2f · %@ 토큰 · $%@/h",
    "ja": "現在のブロック  $%.2f · %@ tokens · $%@/h",
    "zh-Hans": "本时段  $%.2f · %@ tokens · $%@/h",
    "zh-Hant": "本時段  $%.2f · %@ tokens · $%@/h",
    "es": "este bloque  $%.2f · %@ tokens · $%@/h",
  ],
  "today by model · $%.0f total": [
    "ko": "오늘 모델별 · 합 $%.0f",
    "ja": "今日のモデル別 · 計 $%.0f",
    "zh-Hans": "今日按模型 · 共 $%.0f",
    "zh-Hant": "今日按模型 · 共 $%.0f",
    "es": "hoy por modelo · total $%.0f",
  ],
  "credits  unlimited": [
    "ko": "크레딧  무제한", "ja": "クレジット 無制限", "zh-Hans": "额度 无限", "zh-Hant": "額度 無限",
    "es": "créditos  ilimitados",
  ],
  "credits  exhausted — buy more or wait for reset": [
    "ko": "크레딧  소진 — 구매 또는 리셋 대기",
    "ja": "クレジット切れ — 購入するかリセットを待つ",
    "zh-Hans": "额度用尽 — 购买或等待重置",
    "zh-Hant": "額度用盡 — 購買或等待重置",
    "es": "créditos agotados — compra más o espera el reinicio",
  ],
  "credits  balance %.0f": [
    "ko": "크레딧  잔액 %.0f", "ja": "クレジット残高 %.0f", "zh-Hans": "额度余额 %.0f",
    "zh-Hant": "額度餘額 %.0f", "es": "créditos  saldo %.0f",
  ],
  "Run Claude Code or Codex and usage will appear here": [
    "ko": "Claude Code나 Codex를 실행하면 사용량이 표시됩니다",
    "ja": "Claude CodeまたはCodexを使うと使用量が表示されます",
    "zh-Hans": "运行 Claude Code 或 Codex 后将显示用量",
    "zh-Hant": "執行 Claude Code 或 Codex 後將顯示用量",
    "es": "Usa Claude Code o Codex y el consumo aparecerá aquí",
  ],
  "⚠️ SwiftBar widget is also running — batteries appear twice": [
    "ko": "⚠️ SwiftBar 위젯도 실행 중 — 배터리가 두 벌 표시됩니다",
    "ja": "⚠️ SwiftBarウィジェットも実行中 — バッテリーが二重に表示されます",
    "zh-Hans": "⚠️ SwiftBar 小组件也在运行 — 电池会显示两次",
    "zh-Hant": "⚠️ SwiftBar 小工具也在執行 — 電池會顯示兩次",
    "es": "⚠️ El widget de SwiftBar también está activo — las baterías se ven dos veces",
  ],
  "Install v%@ update — one click (current v%@)": [
    "ko": "v%@ 업데이트 설치 — 클릭 한 번 (현재 v%@)",
    "ja": "v%@ アップデートをインストール — ワンクリック (現在 v%@)",
    "zh-Hans": "一键安装 v%@ 更新（当前 v%@）",
    "zh-Hant": "一鍵安裝 v%@ 更新（目前 v%@）",
    "es": "Instalar actualización v%@ — un clic (actual v%@)",
  ],
  "Refresh": [
    "ko": "새로고침", "ja": "更新", "zh-Hans": "刷新", "zh-Hant": "重新整理", "es": "Actualizar",
  ],
  "Settings": [
    "ko": "설정", "ja": "設定", "zh-Hans": "设置", "zh-Hant": "設定", "es": "Ajustes",
  ],
  "Battery size": [
    "ko": "배터리 크기", "ja": "バッテリーサイズ", "zh-Hans": "电池大小", "zh-Hant": "電池大小",
    "es": "Tamaño de batería",
  ],
  "Big": ["ko": "크게", "ja": "大", "zh-Hans": "大", "zh-Hant": "大", "es": "Grande"],
  "Small": ["ko": "작게", "ja": "小", "zh-Hans": "小", "zh-Hant": "小", "es": "Pequeño"],
  "Language": ["ko": "언어", "ja": "言語", "zh-Hans": "语言", "zh-Hant": "語言", "es": "Idioma"],
  "System default": [
    "ko": "시스템 기본", "ja": "システム標準", "zh-Hans": "跟随系统", "zh-Hant": "跟隨系統",
    "es": "Predeterminado del sistema",
  ],
  "Start at login": [
    "ko": "로그인 시 자동 시작", "ja": "ログイン時に起動", "zh-Hans": "登录时启动",
    "zh-Hant": "登入時啟動", "es": "Iniciar al abrir sesión",
  ],
  "Open ccusage dashboard": [
    "ko": "ccusage 대시보드 열기", "ja": "ccusageダッシュボードを開く", "zh-Hans": "打开 ccusage 面板",
    "zh-Hant": "開啟 ccusage 面板", "es": "Abrir panel de ccusage",
  ],
  "Open GitHub page": [
    "ko": "GitHub 페이지 열기", "ja": "GitHubページを開く", "zh-Hans": "打开 GitHub 页面",
    "zh-Hant": "開啟 GitHub 頁面", "es": "Abrir página de GitHub",
  ],
  "Quit": ["ko": "종료", "ja": "終了", "zh-Hans": "退出", "zh-Hant": "結束", "es": "Salir"],
  "⬇︎ Updating…": [
    "ko": "⬇︎ 업데이트…", "ja": "⬇︎ 更新中…", "zh-Hans": "⬇︎ 更新中…", "zh-Hant": "⬇︎ 更新中…",
    "es": "⬇︎ Actualizando…",
  ],
  "Start automatically at login?": [
    "ko": "로그인 시 자동으로 시작할까요?", "ja": "ログイン時に自動で起動しますか？",
    "zh-Hans": "要在登录时自动启动吗？", "zh-Hant": "要在登入時自動啟動嗎？",
    "es": "¿Iniciar automáticamente al abrir sesión?",
  ],
  "The usage battery will appear in your menu bar every time you start your Mac. You can change this anytime from the menu.": [
    "ko": "맥을 켤 때마다 메뉴바에 사용량 배터리가 자동으로 표시됩니다. 나중에 메뉴에서 언제든 바꿀 수 있습니다.",
    "ja": "Macを起動するたびに使用量バッテリーがメニューバーに表示されます。メニューからいつでも変更できます。",
    "zh-Hans": "每次启动 Mac 时，用量电池都会显示在菜单栏中。之后可随时在菜单中更改。",
    "zh-Hant": "每次啟動 Mac 時，用量電池都會顯示在選單列中。之後可隨時在選單中更改。",
    "es": "La batería de consumo aparecerá en la barra de menús cada vez que inicies tu Mac. Puedes cambiarlo en el menú cuando quieras.",
  ],
  "Start at Login": [
    "ko": "자동 시작", "ja": "起動する", "zh-Hans": "自动启动", "zh-Hant": "自動啟動",
    "es": "Iniciar al abrir sesión",
  ],
  "Later": ["ko": "나중에", "ja": "後で", "zh-Hans": "以后再说", "zh-Hant": "以後再說", "es": "Más tarde"],
  "downloading…": [
    "ko": "다운로드 중…", "ja": "ダウンロード中…", "zh-Hans": "下载中…", "zh-Hant": "下載中…",
    "es": "descargando…",
  ],
  "unzipping…": [
    "ko": "압축 해제 중…", "ja": "展開中…", "zh-Hans": "解压中…", "zh-Hant": "解壓縮中…",
    "es": "descomprimiendo…",
  ],
  "verifying signature…": [
    "ko": "서명 검증 중…", "ja": "署名を検証中…", "zh-Hans": "验证签名中…", "zh-Hant": "驗證簽章中…",
    "es": "verificando firma…",
  ],
  "installing…": [
    "ko": "설치 중…", "ja": "インストール中…", "zh-Hans": "安装中…", "zh-Hant": "安裝中…",
    "es": "instalando…",
  ],
  "download failed": [
    "ko": "다운로드 실패", "ja": "ダウンロード失敗", "zh-Hans": "下载失败", "zh-Hant": "下載失敗",
    "es": "descarga fallida",
  ],
  "unzip failed": [
    "ko": "압축 해제 실패", "ja": "展開失敗", "zh-Hans": "解压失败", "zh-Hant": "解壓縮失敗",
    "es": "descompresión fallida",
  ],
  "signature verification failed": [
    "ko": "서명 검증 실패", "ja": "署名検証失敗", "zh-Hans": "签名验证失败", "zh-Hant": "簽章驗證失敗",
    "es": "verificación de firma fallida",
  ],
  "install failed": [
    "ko": "설치 실패", "ja": "インストール失敗", "zh-Hans": "安装失败", "zh-Hant": "安裝失敗",
    "es": "instalación fallida",
  ],
]

func tr(_ en: String) -> String {
  if UI_LANG == "en" { return en }
  return TR[en]?[UI_LANG] ?? en
}

func trf(_ en: String, _ args: CVarArg...) -> String {
  String(format: tr(en), arguments: args)
}

// Gauge labels padded per language so the Menlo bars line up
func gaugeLabels() -> (five: String, week: String) {
  switch UI_LANG {
  case "ko": return ("5시간", "주간 ")
  case "ja": return ("5時間", "週間 ")
  case "zh-Hans": return ("5小时", "每周 ")
  case "zh-Hant": return ("5小時", "每週 ")
  case "es": return ("5h   ", "sem. ")
  default: return ("5h   ", "week ")
  }
}

// Display names for the Language submenu (each in its own language)
let LANG_DISPLAY: [(code: String, name: String)] = [
  ("en", "English"), ("ko", "한국어"), ("ja", "日本語"),
  ("zh-Hans", "简体中文"), ("zh-Hant", "繁體中文"), ("es", "Español"),
]
