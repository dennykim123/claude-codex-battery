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
  "no 5h window open": [
    "ko": "5시간 창 없음",
    "ja": "5時間枠なし",
    "zh-Hans": "无进行中的 5 小时窗口",
    "zh-Hant": "無進行中的 5 小時視窗",
    "es": "sin ventana de 5 h abierta",
  ],
  "unknown until the usage API answers": [
    "ko": "사용량 API가 응답하기 전엔 알 수 없음",
    "ja": "使用量APIが応答するまで不明",
    "zh-Hans": "用量 API 响应前未知",
    "zh-Hant": "用量 API 回應前未知",
    "es": "desconocido hasta que responda la API de uso",
  ],
  "no reading yet — usage API busy, retrying soon": [
    "ko": "아직 받은 값 없음 — 사용량 API 제한, 잠시 후 재시도",
    "ja": "まだ取得できていません — 使用量APIが制限中、まもなく再試行",
    "zh-Hans": "尚无读数 — 用量 API 限流，稍后重试",
    "zh-Hant": "尚無讀數 — 用量 API 限流，稍後重試",
    "es": "aún sin lectura — API de uso saturada, reintentando pronto",
  ],
  "no reading yet — Claude login expired, open Claude Code once": [
    "ko": "아직 받은 값 없음 — Claude 로그인 만료, Claude Code를 한 번 실행하세요",
    "ja": "まだ取得できていません — Claudeのログイン期限切れ、Claude Codeを一度起動してください",
    "zh-Hans": "尚无读数 — Claude 登录已过期，请运行一次 Claude Code",
    "zh-Hant": "尚無讀數 — Claude 登入已過期，請執行一次 Claude Code",
    "es": "aún sin lectura — sesión de Claude caducada, abre Claude Code una vez",
  ],
  "no reading yet — check login/network": [
    "ko": "아직 받은 값 없음 — 로그인·네트워크 확인",
    "ja": "まだ取得できていません — ログイン/ネットワークを確認",
    "zh-Hans": "尚无读数 — 请检查登录/网络",
    "zh-Hant": "尚無讀數 — 請檢查登入/網路",
    "es": "aún sin lectura — revisa sesión/red",
  ],
  "Menu bar account": [
    "ko": "메뉴 막대에 표시할 계정",
    "ja": "メニューバーに表示するアカウント",
    "zh-Hans": "菜单栏显示的账户",
    "zh-Hant": "選單列顯示的帳號",
    "es": "Cuenta en la barra de menús",
  ],
  "account %d": [
    "ko": "계정 %d", "ja": "アカウント %d", "zh-Hans": "账户 %d", "zh-Hant": "帳號 %d", "es": "cuenta %d",
  ],
  "cached %@ ago — usage API busy, retrying soon": [
    "ko": "%@ 전 캐시 — 사용량 API 제한, 잠시 후 재시도",
    "ja": "%@前のキャッシュ — 使用量APIが制限中、まもなく再試行",
    "zh-Hans": "%@ 前的缓存 — 用量 API 限流，稍后重试",
    "zh-Hant": "%@ 前的快取 — 用量 API 限流，稍後重試",
    "es": "caché de hace %@ — API de uso saturada, reintentando pronto",
  ],
  "cached %@ ago — Claude login expired, open Claude Code once": [
    "ko": "%@ 전 캐시 — Claude 로그인 만료, Claude Code를 한 번 실행하세요",
    "ja": "%@前のキャッシュ — Claudeのログイン期限切れ、Claude Codeを一度起動してください",
    "zh-Hans": "%@ 前的缓存 — Claude 登录已过期，请运行一次 Claude Code",
    "zh-Hant": "%@ 前的快取 — Claude 登入已過期，請執行一次 Claude Code",
    "es": "caché de hace %@ — sesión de Claude caducada, abre Claude Code una vez",
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
  "lap: %@ to the finish — on pace ✓": [
    "ko": "랩: 결승선까지 %@ — 완주 페이스 ✓",
    "ja": "ラップ: ゴールまで%@ — 完走ペース ✓",
    "zh-Hans": "本圈：距终点 %@ — 可跑完 ✓",
    "zh-Hant": "本圈：距終點 %@ — 可跑完 ✓",
    "es": "vuelta: %@ a la meta — a buen ritmo ✓",
  ],
  "lap: %@ to the finish — projected empty ⚠": [
    "ko": "랩: 결승선까지 %@ — 이대로면 방전 ⚠",
    "ja": "ラップ: ゴールまで%@ — このままでは電池切れ ⚠",
    "zh-Hans": "本圈：距终点 %@ — 预计将耗尽 ⚠",
    "zh-Hant": "本圈：距終點 %@ — 預計將耗盡 ⚠",
    "es": "vuelta: %@ a la meta — se agotará ⚠",
  ],
  "Refresh": [
    "ko": "새로고침", "ja": "更新", "zh-Hans": "刷新", "zh-Hant": "重新整理", "es": "Actualizar",
  ],
  "Settings": [
    "ko": "설정", "ja": "設定", "zh-Hans": "设置", "zh-Hant": "設定", "es": "Ajustes",
  ],
  "Cat": ["ko": "고양이", "ja": "ネコ", "zh-Hans": "猫", "zh-Hant": "貓", "es": "Gato"],
  "Wide face": [
    "ko": "넓적 얼굴 (볼터치)", "ja": "丸顔 (ほっぺ)", "zh-Hans": "圆脸（腮红）",
    "zh-Hant": "圓臉（腮紅）", "es": "Cara ancha",
  ],
  "Slim face": [
    "ko": "갸름 얼굴", "ja": "細顔", "zh-Hans": "瘦脸", "zh-Hant": "瘦臉", "es": "Cara fina",
  ],
  "Slime": ["ko": "슬라임", "ja": "スライム", "zh-Hans": "史莱姆", "zh-Hant": "史萊姆", "es": "Slime"],
  "Off": ["ko": "끄기", "ja": "オフ", "zh-Hans": "关闭", "zh-Hant": "關閉", "es": "Desactivado"],
  "Select your ~/.codex folder to show Codex batteries": [
    "ko": "Codex 배터리를 표시하려면 ~/.codex 폴더를 선택하세요",
    "ja": "Codexバッテリーを表示するには ~/.codex フォルダを選択してください",
    "zh-Hans": "选择 ~/.codex 文件夹以显示 Codex 电池",
    "zh-Hant": "選擇 ~/.codex 資料夾以顯示 Codex 電池",
    "es": "Selecciona tu carpeta ~/.codex para mostrar las baterías de Codex",
  ],
  "Grant Access": [
    "ko": "접근 허용", "ja": "アクセスを許可", "zh-Hans": "授予访问", "zh-Hant": "授予存取",
    "es": "Conceder acceso",
  ],
  "Connect Codex folder…": [
    "ko": "Codex 폴더 연결…", "ja": "Codexフォルダを接続…", "zh-Hans": "连接 Codex 文件夹…",
    "zh-Hant": "連接 Codex 資料夾…", "es": "Conectar carpeta de Codex…",
  ],
  "Show Codex batteries too?": [
    "ko": "Codex 배터리도 표시할까요?", "ja": "Codexバッテリーも表示しますか？",
    "zh-Hans": "也显示 Codex 电池吗？", "zh-Hant": "也顯示 Codex 電池嗎？",
    "es": "¿Mostrar también las baterías de Codex?",
  ],
  "Grant one-time access to your ~/.codex folder so the app can read your Codex login. You can do this later from Settings.": [
    "ko": "앱이 Codex 로그인을 읽을 수 있도록 ~/.codex 폴더 접근을 한 번만 허용해 주세요. 나중에 설정에서도 할 수 있습니다.",
    "ja": "アプリがCodexのログインを読めるよう、~/.codex フォルダへのアクセスを一度だけ許可してください。後で設定からも行えます。",
    "zh-Hans": "请一次性授予 ~/.codex 文件夹的访问权限，以便应用读取您的 Codex 登录。之后也可在设置中进行。",
    "zh-Hant": "請一次性授予 ~/.codex 資料夾的存取權限，以便應用讀取您的 Codex 登入。之後也可在設定中進行。",
    "es": "Concede acceso una sola vez a tu carpeta ~/.codex para que la app pueda leer tu sesión de Codex. También puedes hacerlo luego en Ajustes.",
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
  "Check for updates": [
    "ko": "업데이트 확인", "ja": "アップデートを確認", "zh-Hans": "检查更新", "zh-Hant": "檢查更新",
    "es": "Buscar actualizaciones",
  ],
  "v%@ is available": [
    "ko": "v%@ 업데이트가 있습니다", "ja": "v%@ が利用可能です", "zh-Hans": "v%@ 可用",
    "zh-Hant": "v%@ 可用", "es": "v%@ está disponible",
  ],
  "You have v%@. Installing takes a few seconds and relaunches the app.": [
    "ko": "지금은 v%@입니다. 설치는 몇 초면 끝나고 앱이 다시 열립니다.",
    "ja": "現在は v%@ です。インストールは数秒で終わり、アプリが再起動します。",
    "zh-Hans": "当前为 v%@。安装只需几秒，完成后应用会重新启动。",
    "zh-Hant": "目前為 v%@。安裝只需幾秒，完成後 App 會重新啟動。",
    "es": "Tienes la v%@. La instalación tarda unos segundos y reinicia la app.",
  ],
  "Install now": [
    "ko": "지금 설치", "ja": "今すぐインストール", "zh-Hans": "立即安装", "zh-Hant": "立即安裝",
    "es": "Instalar ahora",
  ],
  "You're up to date (v%@)": [
    "ko": "최신 버전입니다 (v%@)", "ja": "最新バージョンです (v%@)", "zh-Hans": "已是最新版本 (v%@)",
    "zh-Hant": "已是最新版本 (v%@)", "es": "Tienes la última versión (v%@)",
  ],
  "Couldn't check for updates — check your network": [
    "ko": "업데이트를 확인하지 못했습니다 — 네트워크를 확인하세요",
    "ja": "アップデートを確認できませんでした — ネットワークを確認してください",
    "zh-Hans": "无法检查更新 — 请检查网络",
    "zh-Hant": "無法檢查更新 — 請檢查網路",
    "es": "No se pudo buscar actualizaciones — revisa tu red",
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
