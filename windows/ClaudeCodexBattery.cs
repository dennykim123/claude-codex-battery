// ClaudeCodexBattery.cs — Claude & Codex usage battery for the Windows system tray.
// Windows port of the macOS SwiftBar plugin (claude-codex-usage.2m.js).
//
// Zero dependencies: compiles with the csc.exe bundled in every Windows
// (.NET Framework 4.x), so the source targets C# 5.
//
//   Claude: reads the Claude Code OAuth token from %USERPROFILE%\.claude\.credentials.json
//           and queries api.anthropic.com/api/oauth/usage (same data as /usage).
//           Token is kept in memory only — never written to disk or logs.
//   Codex : parses the newest rate_limits object from
//           %USERPROFILE%\.codex\sessions\**\*.jsonl (numbers only, never messages).
//
// Tray icons (one per service) are battery capsules drawn with GDI+ at runtime,
// with the service logo overlapping the capsule where Windows draws its charge bolt.
//
// Usage:  ClaudeCodexBattery.exe            run tray app (single instance)
//         ClaudeCodexBattery.exe --dump DIR render icons + status to DIR and exit (debug)

using System;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.Drawing.Text;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Net;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using System.Web.Script.Serialization;
using System.Windows.Forms;
using Microsoft.Win32;

namespace ClaudeCodexBattery
{
    static class Program
    {
        public const string Version = "1.4.0";

        [DllImport("user32.dll")]
        static extern bool SetProcessDPIAware();

        [STAThread]
        static void Main(string[] args)
        {
            if (args.Length >= 2 && args[0] == "--dump")
            {
                DebugDump.Run(args[1]);
                return;
            }
            bool showOnStart = args.Length >= 1 && args[0] == "--show"; // debug: open flyout immediately
            bool created;
            using (Mutex mx = new Mutex(true, "ClaudeCodexBatteryTray", out created))
            {
                if (!created) return; // already running
                SetProcessDPIAware();
                Application.EnableVisualStyles();
                Application.SetCompatibleTextRenderingDefault(false);
                Application.Run(new TrayApp(showOnStart));
            }
        }
    }

    // ── data model ─────────────────────────────────────────────
    class LimitWindow
    {
        public double UsedPct;
        public DateTime? ResetsAtUtc; // null = unknown
        public bool Stale;            // reset time already passed (treat as 0% used)
        public double RemainPct { get { return Stale ? 100.0 : Math.Max(0.0, Math.Min(100.0, 100.0 - UsedPct)); } }
    }

    class ClaudeUsage
    {
        public LimitWindow FiveHour;
        public LimitWindow Weekly;
        public LimitWindow TopModel;   // weekly scoped cap (e.g. Fable)
        public string TopModelName;
        public bool Live;              // false = served from local cache
        public DateTime MeasuredAtUtc;
    }

    class CodexUsage
    {
        public LimitWindow Primary;    // 5h
        public LimitWindow Secondary;  // weekly
        public bool CreditsMode;       // premium plan: credits instead of % windows
        public bool CreditsUnlimited;
        public bool CreditsAvailable;
        public string Plan;
        public DateTime MeasuredAtUtc;
    }

    // ── data fetchers ──────────────────────────────────────────
    static class Fetchers
    {
        static readonly string Home = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
        static readonly JavaScriptSerializer Json = new JavaScriptSerializer { MaxJsonLength = 64 * 1024 * 1024 };

        static string CacheDir { get { return Path.Combine(Home, ".claude", "ccbattery"); } }
        static string CachePath { get { return Path.Combine(CacheDir, "claude-usage.json"); } }

        static object Get(object o, string key)
        {
            IDictionary<string, object> d = o as IDictionary<string, object>;
            if (d != null && d.ContainsKey(key)) return d[key];
            return null;
        }

        static double? Num(object o)
        {
            if (o == null) return null;
            try { return Convert.ToDouble(o, CultureInfo.InvariantCulture); }
            catch { return null; }
        }

        // token exists only as a return value — never persisted anywhere
        static string ReadClaudeToken()
        {
            try
            {
                string raw = File.ReadAllText(Path.Combine(Home, ".claude", ".credentials.json"));
                object root = Json.DeserializeObject(raw);
                return Get(Get(root, "claudeAiOauth"), "accessToken") as string;
            }
            catch { return null; }
        }

        static string FetchClaudeRawLive()
        {
            string token = ReadClaudeToken();
            if (token == null) return null;
            try
            {
                ServicePointManager.SecurityProtocol |= SecurityProtocolType.Tls12;
                HttpWebRequest req = (HttpWebRequest)WebRequest.Create("https://api.anthropic.com/api/oauth/usage");
                req.Method = "GET";
                req.Timeout = 8000;
                req.Headers["Authorization"] = "Bearer " + token;
                req.Headers["anthropic-beta"] = "oauth-2025-04-20";
                using (WebResponse resp = req.GetResponse())
                using (StreamReader sr = new StreamReader(resp.GetResponseStream(), Encoding.UTF8))
                {
                    string body = sr.ReadToEnd();
                    if (Get(Json.DeserializeObject(body), "five_hour") == null) return null;
                    try
                    {
                        Directory.CreateDirectory(CacheDir);
                        File.WriteAllText(CachePath, body); // last good response; mtime = measured-at
                    }
                    catch { }
                    return body;
                }
            }
            catch { return null; }
        }

        static LimitWindow ParseWindow(object o, string pctKey)
        {
            if (o == null) return null;
            double? pct = Num(Get(o, pctKey));
            if (pct == null) return null;
            LimitWindow w = new LimitWindow { UsedPct = pct.Value };
            string iso = Get(o, "resets_at") as string;
            if (iso != null)
            {
                try { w.ResetsAtUtc = DateTimeOffset.Parse(iso, CultureInfo.InvariantCulture).UtcDateTime; }
                catch { }
            }
            return w;
        }

        public static ClaudeUsage GetClaude()
        {
            string raw = FetchClaudeRawLive();
            bool live = raw != null;
            DateTime measured = DateTime.UtcNow;
            if (raw == null)
            {
                try
                {
                    raw = File.ReadAllText(CachePath);
                    measured = File.GetLastWriteTimeUtc(CachePath);
                }
                catch { return null; }
            }
            try
            {
                object d = Json.DeserializeObject(raw);
                ClaudeUsage c = new ClaudeUsage { Live = live, MeasuredAtUtc = measured };
                c.FiveHour = ParseWindow(Get(d, "five_hour"), "utilization");
                c.Weekly = ParseWindow(Get(d, "seven_day"), "utilization");
                object[] limits = Get(d, "limits") as object[];
                if (limits != null)
                {
                    foreach (object l in limits)
                    {
                        string group = Get(l, "group") as string;
                        string model = Get(Get(Get(l, "scope"), "model"), "display_name") as string;
                        if (group == "weekly" && !string.IsNullOrEmpty(model))
                        {
                            c.TopModel = ParseWindow(l, "percent");
                            c.TopModelName = model;
                            break;
                        }
                    }
                }
                if (c.FiveHour == null && c.Weekly == null) return null;
                return c;
            }
            catch { return null; }
        }

        static LimitWindow ParseCodexWindow(object o)
        {
            if (o == null) return null;
            double? pct = Num(Get(o, "used_percent"));
            if (pct == null) return null;
            LimitWindow w = new LimitWindow { UsedPct = pct.Value };
            double? resets = Num(Get(o, "resets_at")); // unix seconds
            if (resets != null)
            {
                w.ResetsAtUtc = new DateTime(1970, 1, 1, 0, 0, 0, DateTimeKind.Utc).AddSeconds(resets.Value);
                if (w.ResetsAtUtc < DateTime.UtcNow) w.Stale = true;
            }
            return w;
        }

        public static CodexUsage GetCodex()
        {
            string sessions = Path.Combine(Home, ".codex", "sessions");
            if (!Directory.Exists(sessions)) return null;
            List<FileInfo> files;
            try
            {
                files = Directory.EnumerateFiles(sessions, "*.jsonl", SearchOption.AllDirectories)
                    .Select(p => new FileInfo(p))
                    .OrderByDescending(f => f.LastWriteTimeUtc)
                    .Take(8)
                    .ToList();
            }
            catch { return null; }
            foreach (FileInfo f in files)
            {
                string[] lines;
                try { lines = File.ReadAllLines(f.FullName); }
                catch { continue; }
                for (int i = lines.Length - 1; i >= 0; i--)
                {
                    if (!lines[i].Contains("rate_limits")) continue;
                    object obj;
                    try { obj = Json.DeserializeObject(lines[i]); }
                    catch { continue; }
                    object rl = Get(Get(obj, "payload"), "rate_limits");
                    if (rl == null) rl = Get(obj, "rate_limits");
                    if (rl == null) continue;
                    object primary = Get(rl, "primary");
                    object secondary = Get(rl, "secondary");
                    object credits = Get(rl, "credits");
                    if (primary == null && secondary == null && credits == null) continue;
                    CodexUsage x = new CodexUsage
                    {
                        MeasuredAtUtc = f.LastWriteTimeUtc,
                        Plan = Get(rl, "plan_type") as string,
                        Primary = ParseCodexWindow(primary),
                        Secondary = ParseCodexWindow(secondary),
                    };
                    if (x.Plan == null) x.Plan = Get(rl, "limit_id") as string;
                    if (credits != null && x.Primary == null && x.Secondary == null)
                    {
                        x.CreditsMode = true;
                        object unl = Get(credits, "unlimited");
                        object has = Get(credits, "has_credits");
                        double? bal = Num(Get(credits, "balance"));
                        x.CreditsUnlimited = unl is bool && (bool)unl;
                        x.CreditsAvailable = x.CreditsUnlimited || ((has is bool && (bool)has) && bal != null && bal.Value > 0);
                    }
                    return x;
                }
            }
            return null;
        }
    }

    // ── favicons: fetched from the web once, cached locally ───
    // The service logos are the real favicons (claude.ai / chatgpt.com) via
    // Google's favicon endpoint — downloaded once, cached next to the exe's
    // data, hand-drawn glyph fallback until the download succeeds.
    static class Favicons
    {
        static readonly string Dir = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "ClaudeCodexBattery");
        static Bitmap _claude, _codex;
        static int _fetching;

        static string PathFor(IconRenderer.Logo logo)
        {
            return Path.Combine(Dir, logo == IconRenderer.Logo.Claude ? "favicon-claude.png" : "favicon-codex.png");
        }

        static string UrlFor(IconRenderer.Logo logo)
        {
            return logo == IconRenderer.Logo.Claude
                ? "https://www.google.com/s2/favicons?domain=claude.ai&sz=64"
                : "https://www.google.com/s2/favicons?domain=chatgpt.com&sz=64";
        }

        // Returns the favicon reduced to its GLYPH: dominant background color keyed
        // out to transparency, cropped to the glyph's bounding box. The renderer
        // tints it, so only the alpha silhouette matters.
        public static Bitmap Get(IconRenderer.Logo logo)
        {
            if (logo == IconRenderer.Logo.Claude && _claude != null) return _claude;
            if (logo == IconRenderer.Logo.Codex && _codex != null) return _codex;
            string p = PathFor(logo);
            if (File.Exists(p))
            {
                try
                {
                    Bitmap glyph;
                    using (Bitmap tmp = new Bitmap(p))
                        glyph = ToGlyph(tmp);
                    if (logo == IconRenderer.Logo.Claude) _claude = glyph; else _codex = glyph;
                    return glyph;
                }
                catch { try { File.Delete(p); } catch { } }
            }
            StartFetch();
            return null;
        }

        static Bitmap ToGlyph(Bitmap src)
        {
            int w = src.Width, h = src.Height;
            // dominant opaque color = the favicon's background plate
            Dictionary<int, int> counts = new Dictionary<int, int>();
            for (int y = 0; y < h; y++)
                for (int x = 0; x < w; x++)
                {
                    Color c = src.GetPixel(x, y);
                    if (c.A < 200) continue;
                    int key = ((c.R >> 4) << 8) | ((c.G >> 4) << 4) | (c.B >> 4);
                    int n;
                    counts.TryGetValue(key, out n);
                    counts[key] = n + 1;
                }
            int bestKey = -1, bestN = 0;
            foreach (KeyValuePair<int, int> kv in counts)
                if (kv.Value > bestN) { bestN = kv.Value; bestKey = kv.Key; }
            int br = ((bestKey >> 8) & 0xF) * 17, bg = ((bestKey >> 4) & 0xF) * 17, bb = (bestKey & 0xF) * 17;

            Bitmap outBmp = new Bitmap(w, h, PixelFormat.Format32bppArgb);
            int minX = w, minY = h, maxX = -1, maxY = -1;
            for (int y = 0; y < h; y++)
                for (int x = 0; x < w; x++)
                {
                    Color c = src.GetPixel(x, y);
                    if (c.A < 30) continue;
                    int dr = c.R - br, dg = c.G - bg, db = c.B - bb;
                    if (Math.Sqrt(dr * dr + dg * dg + db * db) < 90) continue; // background
                    outBmp.SetPixel(x, y, c);
                    if (x < minX) minX = x;
                    if (x > maxX) maxX = x;
                    if (y < minY) minY = y;
                    if (y > maxY) maxY = y;
                }
            if (maxX < 0) { outBmp.Dispose(); return new Bitmap(src); } // nothing left — keep original
            Rectangle box = Rectangle.FromLTRB(minX, minY, maxX + 1, maxY + 1);
            Bitmap cropped = outBmp.Clone(box, PixelFormat.Format32bppArgb);
            outBmp.Dispose();
            return cropped;
        }

        static void StartFetch()
        {
            if (Interlocked.CompareExchange(ref _fetching, 1, 0) != 0) return;
            ThreadPool.QueueUserWorkItem(delegate
            {
                try { FetchSync(); }
                finally { Interlocked.Exchange(ref _fetching, 0); }
            });
        }

        public static void FetchSync()
        {
            try { Directory.CreateDirectory(Dir); } catch { return; }
            foreach (IconRenderer.Logo logo in new[] { IconRenderer.Logo.Claude, IconRenderer.Logo.Codex })
            {
                string p = PathFor(logo);
                if (File.Exists(p)) continue;
                try
                {
                    ServicePointManager.SecurityProtocol |= SecurityProtocolType.Tls12;
                    using (WebClient wc = new WebClient())
                    {
                        byte[] data = wc.DownloadData(UrlFor(logo));
                        using (MemoryStream ms = new MemoryStream(data))
                        using (Bitmap b = new Bitmap(ms))
                        {
                            if (b.Width >= 16) b.Save(p, ImageFormat.Png);
                        }
                    }
                }
                catch { }
            }
        }
    }

    // ── icon rendering (GDI+, favicon + % number + battery bar) ──
    static class IconRenderer
    {
        public enum Logo { Claude, Codex }

        [DllImport("user32.dll")]
        static extern bool DestroyIcon(IntPtr h);

        static Icon ToIcon(Bitmap bmp)
        {
            IntPtr h = bmp.GetHicon();
            try
            {
                using (Icon tmp = Icon.FromHandle(h))
                    return (Icon)tmp.Clone(); // deep copy, independent of the handle
            }
            finally { DestroyIcon(h); }
        }

        public static Icon DualIcon(int size, double? claudeRemain, double? codexRemain, bool lightTaskbar)
        {
            using (Bitmap bmp = RenderDual(size, claudeRemain, codexRemain, lightTaskbar)) return ToIcon(bmp);
        }

        // The single tray icon: one or two slim upright gauges (left = Claude,
        // right = Codex), each filling bottom-up in the heat color. The detailed
        // numbers live in the flyout — the icon is the at-a-glance signal.
        public static Bitmap RenderDual(int size, double? claudeRemain, double? codexRemain, bool lightTaskbar)
        {
            Bitmap bmp = new Bitmap(size, size, PixelFormat.Format32bppArgb);
            using (Graphics g = Graphics.FromImage(bmp))
            {
                g.SmoothingMode = SmoothingMode.AntiAlias;
                float S = size;
                Color ink = lightTaskbar ? Color.FromArgb(45, 45, 45) : Color.FromArgb(240, 240, 240);
                List<double?> bars = new List<double?>();
                bars.Add(claudeRemain);
                if (codexRemain != null) bars.Add(codexRemain);
                float barW = (float)Math.Round(S * (bars.Count == 2 ? 0.34f : 0.44f));
                float gap = (float)Math.Round(S * 0.12f);
                float total = barW * bars.Count + gap * (bars.Count - 1);
                float x0 = (float)Math.Round((S - total) / 2f);
                float t = Math.Max(1f, S / 16f);
                float nubH = Math.Max(1.5f, (float)Math.Round(S * 0.07f));
                for (int i = 0; i < bars.Count; i++)
                {
                    float bx = x0 + i * (barW + gap);
                    float by = nubH + t / 2f;
                    float bh = S - nubH - t - 0.5f;
                    float rad = barW * 0.28f;
                    using (GraphicsPath body = RoundedRect(bx, by, barW, bh, rad))
                    {
                        double? r = bars[i];
                        if (r != null)
                        {
                            float inset = t + 0.4f;
                            float maxH = bh - inset * 2f;
                            float fh = (float)(maxH * Math.Max(0.0, Math.Min(100.0, r.Value)) / 100.0);
                            if (fh > 0.5f)
                            {
                                fh = Math.Max(fh, 1.5f);
                                using (GraphicsPath fill = RoundedRect(bx + inset, by + inset + (maxH - fh), barW - inset * 2f, fh, Math.Max(1f, rad - 1.5f)))
                                using (SolidBrush fb = new SolidBrush(HeatRemain(r.Value)))
                                    g.FillPath(fb, fill);
                            }
                        }
                        using (Pen op = new Pen(ink, t))
                            g.DrawPath(op, body);
                    }
                    float nw = (float)Math.Round(barW * 0.5f);
                    using (SolidBrush nb = new SolidBrush(ink))
                        g.FillRectangle(nb, bx + (float)Math.Round((barW - nw) / 2f), 0.5f, nw, nubH);
                }
            }
            return bmp;
        }

        // Draws the glyph with its RGB replaced by a flat tint (alpha preserved).
        public static void DrawTinted(Graphics g, Bitmap glyph, Rectangle dst, Color tint)
        {
            using (ImageAttributes ia = new ImageAttributes())
            {
                ColorMatrix cm = new ColorMatrix(new float[][] {
                    new float[] { 0, 0, 0, 0, 0 },
                    new float[] { 0, 0, 0, 0, 0 },
                    new float[] { 0, 0, 0, 0, 0 },
                    new float[] { 0, 0, 0, 1, 0 },
                    new float[] { tint.R / 255f, tint.G / 255f, tint.B / 255f, 0, 1 },
                });
                ia.SetColorMatrix(cm);
                g.DrawImage(glyph, dst, 0, 0, glyph.Width, glyph.Height, GraphicsUnit.Pixel, ia);
            }
        }

        public static Color HeatRemain(double r)
        {
            if (r <= 20) return Color.FromArgb(239, 68, 68);   // red
            if (r < 50) return Color.FromArgb(234, 179, 8);    // amber
            return Color.FromArgb(34, 197, 94);                // green
        }

        static GraphicsPath RoundedRect(float x, float y, float w, float h, float r)
        {
            GraphicsPath p = new GraphicsPath();
            float d = r * 2f;
            p.AddArc(x, y, d, d, 180, 90);
            p.AddArc(x + w - d, y, d, d, 270, 90);
            p.AddArc(x + w - d, y + h - d, d, d, 0, 90);
            p.AddArc(x, y + h - d, d, d, 90, 90);
            p.CloseFigure();
            return p;
        }

        // Claude mark: orange starburst (rays of alternating length), halo pass for contrast
        public static void DrawClaudeLogo(Graphics g, float cx, float cy, float r, Color halo)
        {
            Color orange = Color.FromArgb(217, 119, 87); // Claude brand terracotta
            int rays = 8;
            float w = Math.Max(1.5f, r / 4.5f);
            for (int pass = 0; pass < 2; pass++)
            {
                Color col = pass == 0 ? halo : orange;
                float pw = pass == 0 ? w + Math.Max(0.8f, r / 10f) : w;
                using (Pen pen = new Pen(col, pw))
                {
                    pen.StartCap = LineCap.Round;
                    pen.EndCap = LineCap.Round;
                    for (int i = 0; i < rays; i++)
                    {
                        double a = Math.PI * 2 * i / rays - Math.PI / 2;
                        float len = (i % 2 == 0) ? r : r * 0.72f;
                        float x0 = cx + (float)Math.Cos(a) * r * 0.20f;
                        float y0 = cy + (float)Math.Sin(a) * r * 0.20f;
                        float x1 = cx + (float)Math.Cos(a) * len;
                        float y1 = cy + (float)Math.Sin(a) * len;
                        g.DrawLine(pen, x0, y0, x1, y1);
                    }
                }
            }
        }

        // Codex (OpenAI) mark approximated as a bold hexagonal knot ring
        public static void DrawCodexLogo(Graphics g, float cx, float cy, float r, Color halo, Color ink)
        {
            PointF[] hex = new PointF[6];
            for (int i = 0; i < 6; i++)
            {
                double a = Math.PI / 3 * i - Math.PI / 2;
                hex[i] = new PointF(cx + (float)Math.Cos(a) * r * 0.92f, cy + (float)Math.Sin(a) * r * 0.92f);
            }
            float w = Math.Max(1.6f, r / 2.8f);
            for (int pass = 0; pass < 2; pass++)
            {
                Color col = pass == 0 ? halo : ink;
                float pw = pass == 0 ? w + Math.Max(1f, r / 8f) : w;
                using (Pen pen = new Pen(col, pw))
                {
                    pen.LineJoin = LineJoin.Round;
                    g.DrawPolygon(pen, hex);
                }
            }
        }
    }

    // ── acrylic backdrop (Windows 10/11 SetWindowCompositionAttribute) ──
    static class Acrylic
    {
        [StructLayout(LayoutKind.Sequential)]
        struct AccentPolicy
        {
            public int AccentState;
            public int AccentFlags;
            public uint GradientColor; // AABBGGRR
            public int AnimationId;
        }

        [StructLayout(LayoutKind.Sequential)]
        struct WindowCompositionAttributeData
        {
            public int Attribute;
            public IntPtr Data;
            public int SizeOfData;
        }

        [DllImport("user32.dll")]
        static extern int SetWindowCompositionAttribute(IntPtr hwnd, ref WindowCompositionAttributeData data);

        // 4 = ACCENT_ENABLE_ACRYLICBLURBEHIND, 19 = WCA_ACCENT_POLICY
        public static bool Enable(IntPtr hwnd, uint tintAbgr)
        {
            try
            {
                AccentPolicy accent = new AccentPolicy { AccentState = 4, AccentFlags = 2, GradientColor = tintAbgr };
                int size = Marshal.SizeOf(typeof(AccentPolicy));
                IntPtr ptr = Marshal.AllocHGlobal(size);
                try
                {
                    Marshal.StructureToPtr(accent, ptr, false);
                    WindowCompositionAttributeData data = new WindowCompositionAttributeData
                    {
                        Attribute = 19,
                        Data = ptr,
                        SizeOfData = size,
                    };
                    return SetWindowCompositionAttribute(hwnd, ref data) != 0;
                }
                finally { Marshal.FreeHGlobal(ptr); }
            }
            catch { return false; }
        }
    }

    // ── flyout: modern popup shown when the tray icon is clicked ──
    // Styled after the Windows 11 quick-settings flyout: borderless rounded
    // acrylic window bottom-right above the taskbar, theme-aware, custom-painted.
    class FlyoutForm : Form
    {
        [DllImport("dwmapi.dll")]
        static extern int DwmSetWindowAttribute(IntPtr hwnd, int attr, ref int val, int size);

        readonly Func<bool> _isAutostart;
        readonly Action _toggleAutostart;
        readonly Action _refresh;
        readonly Action _exitApp;
        readonly Font _fTitle, _fSection, _fLabel, _fSmall, _fMono, _fMonoS, _fIcon;
        ClaudeUsage _claude;
        CodexUsage _codex;
        Rectangle _rRefresh, _rAuto, _rExit;
        int _hover; // 0 none, 1 refresh, 2 autostart, 3 exit
        bool _glass; // acrylic backdrop active
        public DateTime HiddenAtUtc = DateTime.MinValue;
        // open/refresh animation: gauges sweep in, numbers count up
        float _anim = 1f;
        System.Windows.Forms.Timer _animTimer;
        DateTime _animStart;

        public FlyoutForm(Func<bool> isAutostart, Action toggleAutostart, Action refresh, Action exitApp)
        {
            _isAutostart = isAutostart;
            _toggleAutostart = toggleAutostart;
            _refresh = refresh;
            _exitApp = exitApp;
            FormBorderStyle = FormBorderStyle.None;
            ShowInTaskbar = false;
            TopMost = true;
            StartPosition = FormStartPosition.Manual;
            DoubleBuffered = true;
            KeyPreview = true;
            BackColor = Color.Black; // GDI background (alpha 0) → shows the acrylic backdrop
            _fTitle = new Font("Segoe UI", 10.5f, FontStyle.Bold);
            _fSection = new Font("Segoe UI", 10f, FontStyle.Bold);
            _fLabel = new Font("Segoe UI", 9.25f);
            _fSmall = new Font("Segoe UI", 8.25f);
            // tabular mono numerals: count-up animation without layout jitter
            _fMono = TryFont(new[] { "Cascadia Mono", "Consolas" }, 10.5f, FontStyle.Bold);
            _fMonoS = TryFont(new[] { "Cascadia Mono", "Consolas" }, 8f, FontStyle.Regular);
            // native Windows icon font (quick-settings iconography)
            _fIcon = TryFont(new[] { "Segoe Fluent Icons", "Segoe MDL2 Assets" }, 10.5f, FontStyle.Regular);
        }

        static Font TryFont(string[] names, float size, FontStyle style)
        {
            foreach (string n in names)
            {
                try
                {
                    Font f = new Font(n, size, style, GraphicsUnit.Point);
                    if (f.Name == n) return f;
                    f.Dispose();
                }
                catch { }
            }
            return new Font("Segoe UI", size, style, GraphicsUnit.Point);
        }

        // status palette (slate + traffic light, shared with the tray icon)
        static readonly Color StGreen = Color.FromArgb(34, 197, 94);
        static readonly Color StAmber = Color.FromArgb(234, 179, 8);
        static readonly Color StRed = Color.FromArgb(239, 68, 68);

        void StartAnim()
        {
            _animStart = DateTime.UtcNow;
            _anim = 0f;
            if (_animTimer == null)
            {
                _animTimer = new System.Windows.Forms.Timer { Interval = 15 };
                _animTimer.Tick += delegate
                {
                    double t = (DateTime.UtcNow - _animStart).TotalMilliseconds / 300.0;
                    if (t >= 1.0) { _anim = 1f; _animTimer.Stop(); }
                    else _anim = (float)(1.0 - Math.Pow(1.0 - t, 3.0)); // ease-out cubic
                    Invalidate();
                };
            }
            _animTimer.Start();
        }

        protected override CreateParams CreateParams
        {
            get
            {
                CreateParams cp = base.CreateParams;
                cp.ExStyle |= 0x00000080; // WS_EX_TOOLWINDOW: no alt-tab entry
                return cp;
            }
        }

        protected override void OnHandleCreated(EventArgs e)
        {
            base.OnHandleCreated(e);
            int round = 2; // DWMWCP_ROUND
            try { DwmSetWindowAttribute(Handle, 33, ref round, 4); } catch { }
            bool light = TrayApp.IsLightTaskbar();
            int dark = light ? 0 : 1;
            try { DwmSetWindowAttribute(Handle, 20, ref dark, 4); } catch { }
            _glass = Acrylic.Enable(Handle, light ? 0xC8F2F2F2 : 0xB32A170F); // dark: slate #0F172A tint
        }

        // scale factor of the SAME graphics used for measuring and drawing —
        // Control.DeviceDpi can disagree with it and break the layout
        float DpiScale
        {
            get
            {
                try { using (Graphics g = CreateGraphics()) return g.DpiX / 96f; }
                catch { return DeviceDpi / 96f; }
            }
        }

        public void SetData(ClaudeUsage claude, CodexUsage codex)
        {
            _claude = claude;
            _codex = codex;
            using (Graphics g = CreateGraphics())
            {
                Size sz = LayoutAll(g, false);
                Size = sz;
            }
            if (Visible) StartAnim();
            Invalidate();
        }

        public void ShowNear()
        {
            if ((DateTime.UtcNow - HiddenAtUtc).TotalMilliseconds < 350) return; // click-to-toggle
            float s = DpiScale;
            Rectangle wa = Screen.FromPoint(Cursor.Position).WorkingArea;
            Location = new Point(wa.Right - Width - (int)(12 * s), wa.Bottom - Height - (int)(12 * s));
            StartAnim();
            Show();
            Activate();
        }

        protected override void OnDeactivate(EventArgs e)
        {
            base.OnDeactivate(e);
            HiddenAtUtc = DateTime.UtcNow;
            Hide();
        }

        protected override void OnKeyDown(KeyEventArgs e)
        {
            base.OnKeyDown(e);
            if (e.KeyCode == Keys.Escape) { HiddenAtUtc = DateTime.UtcNow; Hide(); }
        }

        protected override void OnPaint(PaintEventArgs e)
        {
            LayoutAll(e.Graphics, true);
        }

        protected override void OnMouseMove(MouseEventArgs e)
        {
            base.OnMouseMove(e);
            int h = _rRefresh.Contains(e.Location) ? 1
                : _rAuto.Contains(e.Location) ? 2
                : _rExit.Contains(e.Location) ? 3 : 0;
            if (h != _hover) { _hover = h; Invalidate(); }
            Cursor = h != 0 ? Cursors.Hand : Cursors.Default;
        }

        protected override void OnMouseLeave(EventArgs e)
        {
            base.OnMouseLeave(e);
            if (_hover != 0) { _hover = 0; Invalidate(); }
        }

        protected override void OnMouseUp(MouseEventArgs e)
        {
            base.OnMouseUp(e);
            if (e.Button != MouseButtons.Left) return;
            if (_rRefresh.Contains(e.Location)) _refresh();
            else if (_rAuto.Contains(e.Location)) { _toggleAutostart(); Invalidate(); }
            else if (_rExit.Contains(e.Location)) _exitApp();
        }

        static GraphicsPath RoundedPath(RectangleF r, float rad)
        {
            float d = Math.Min(rad * 2f, Math.Min(r.Width, r.Height));
            GraphicsPath p = new GraphicsPath();
            p.AddArc(r.X, r.Y, d, d, 180, 90);
            p.AddArc(r.Right - d, r.Y, d, d, 270, 90);
            p.AddArc(r.Right - d, r.Bottom - d, d, d, 0, 90);
            p.AddArc(r.X, r.Bottom - d, d, d, 90, 90);
            p.CloseFigure();
            return p;
        }

        static void FillRounded(Graphics g, RectangleF r, float rad, Color c)
        {
            using (GraphicsPath p = RoundedPath(r, rad))
            using (SolidBrush b = new SolidBrush(c))
                g.FillPath(b, p);
        }

        static void StrokeRounded(Graphics g, RectangleF r, float rad, Color c)
        {
            using (GraphicsPath p = RoundedPath(r, rad))
            using (Pen pen = new Pen(c))
                g.DrawPath(pen, p);
        }

        // Lays out (and optionally paints) the whole flyout; returns its size.
        // Design: a single dark "operations panel" (slate palette) - uniform
        // single-line metric rows (label | bar | % | reset), tabular mono
        // numerals, native Segoe Fluent icons, a real toggle switch.
        // Data-dense but scannable; no decorative glow.
        Size LayoutAll(Graphics g, bool draw)
        {
            bool light = TrayApp.IsLightTaskbar();
            float s = g.DpiX / 96f;
            int W = (int)(352 * s);
            int p = (int)(16 * s);

            Color text = light ? Color.FromArgb(27, 34, 44) : Color.FromArgb(241, 245, 249);
            Color sub = light ? Color.FromArgb(90, 100, 114) : Color.FromArgb(166, 176, 189);
            Color faint = light ? Color.FromArgb(134, 143, 155) : Color.FromArgb(122, 132, 146);
            Color track, hoverBg, divider, footerBg;
            if (_glass)
            {
                track = light ? Color.FromArgb(38, 0, 0, 0) : Color.FromArgb(36, 255, 255, 255);
                hoverBg = light ? Color.FromArgb(36, 0, 0, 0) : Color.FromArgb(26, 255, 255, 255);
                divider = light ? Color.FromArgb(28, 0, 0, 0) : Color.FromArgb(22, 255, 255, 255);
                footerBg = light ? Color.FromArgb(70, 255, 255, 255) : Color.FromArgb(64, 0, 0, 0);
            }
            else
            {
                track = light ? Color.FromArgb(226, 230, 236) : Color.FromArgb(42, 52, 66);
                hoverBg = light ? Color.FromArgb(232, 235, 240) : Color.FromArgb(45, 55, 70);
                divider = light ? Color.FromArgb(228, 231, 236) : Color.FromArgb(40, 49, 62);
                footerBg = light ? Color.FromArgb(238, 240, 244) : Color.FromArgb(21, 28, 39);
                if (draw) g.Clear(light ? Color.FromArgb(246, 247, 249) : Color.FromArgb(15, 23, 42));
            }

            g.SmoothingMode = SmoothingMode.AntiAlias;
            g.TextRenderingHint = TextRenderingHint.AntiAliasGridFit;

            SolidBrush bText = new SolidBrush(text);
            SolidBrush bSub = new SolidBrush(sub);
            SolidBrush bFaint = new SolidBrush(faint);
            int y = (int)(12 * s);

            // -- title row: label + refresh icon button --
            int tbH = (int)(30 * s);
            if (draw)
            {
                SizeF tm = g.MeasureString("사용량", _fTitle);
                g.DrawString("사용량", _fTitle, bText, p - 2f * s, y + (tbH - tm.Height) / 2f);
            }
            _rRefresh = new Rectangle(W - p - (int)(28 * s), y, (int)(28 * s), tbH);
            if (draw)
            {
                if (_hover == 1) FillRounded(g, _rRefresh, 5f * s, hoverBg);
                DrawGlyph(g, "\uE72C", _rRefresh, _hover == 1 ? text : sub); // Fluent: refresh
            }
            y += tbH + (int)(6 * s);

            // -- Claude section --
            {
                string status = _claude == null ? "데이터 없음"
                    : _claude.Live ? "라이브"
                    : string.Format("캐시 {0} 전", TrayApp.FmtDur(DateTime.UtcNow - _claude.MeasuredAtUtc));
                Color dotC = _claude == null ? StRed : _claude.Live ? StGreen : StAmber;
                y = SectionHeader(g, draw, s, W, p, y, IconRenderer.Logo.Claude, "Claude Code", status, dotC, bText, bSub, light);
                if (_claude != null)
                {
                    if (_claude.FiveHour != null) y = MetricRow(g, draw, s, W, p, y, "5시간", _claude.FiveHour, track, bSub, bFaint);
                    if (_claude.Weekly != null) y = MetricRow(g, draw, s, W, p, y, "주간", _claude.Weekly, track, bSub, bFaint);
                    if (_claude.TopModel != null && _claude.TopModelName != null)
                        y = MetricRow(g, draw, s, W, p, y, _claude.TopModelName, _claude.TopModel, track, bSub, bFaint);
                }
                else
                {
                    if (draw) g.DrawString("Claude Code 로그인을 확인하세요", _fSmall, bSub, p, y + 4f * s);
                    y += (int)(24 * s);
                }
            }
            y += (int)(4 * s);

            // -- Codex section --
            if (_codex != null)
            {
                if (draw) using (Pen dp = new Pen(divider)) g.DrawLine(dp, p, y, W - p, y);
                y += (int)(10 * s);
                TimeSpan age = DateTime.UtcNow - _codex.MeasuredAtUtc;
                string status = string.Format("{0} 전 측정", TrayApp.FmtDur(age));
                Color dotX = age.TotalHours >= 3 ? StAmber : StGreen;
                y = SectionHeader(g, draw, s, W, p, y, IconRenderer.Logo.Codex,
                    "Codex" + (string.IsNullOrEmpty(_codex.Plan) ? "" : " · " + _codex.Plan), status, dotX, bText, bSub, light);
                if (_codex.CreditsMode)
                {
                    string ct = _codex.CreditsUnlimited ? "크레딧 무제한"
                        : _codex.CreditsAvailable ? "크레딧 잔액 있음" : "크레딧 소진 · 한도 초과";
                    if (draw) g.DrawString(ct, _fLabel, bText, p, y + 4f * s);
                    y += (int)(26 * s);
                }
                else
                {
                    if (_codex.Primary != null) y = MetricRow(g, draw, s, W, p, y, "5시간", _codex.Primary, track, bSub, bFaint);
                    if (_codex.Secondary != null) y = MetricRow(g, draw, s, W, p, y, "주간", _codex.Secondary, track, bSub, bFaint);
                }
                if (age.TotalHours >= 3)
                {
                    if (draw) g.DrawString("리셋됐을 수 있음 · Codex를 쓰면 갱신됩니다", _fSmall, bFaint, p, y + 2f * s);
                    y += (int)(20 * s);
                }
            }
            y += (int)(10 * s);

            // -- footer strip: autostart toggle | version + exit --
            int stripTop = y;
            int footH = (int)(46 * s);
            if (draw)
                using (SolidBrush fb2 = new SolidBrush(footerBg))
                    g.FillRectangle(fb2, 0, stripTop, W, footH);
            int cyf = stripTop + footH / 2;

            bool on = _isAutostart();
            int tw = (int)(34 * s), th = (int)(16 * s);
            Rectangle tr = new Rectangle(p, cyf - th / 2, tw, th);
            SizeF am = g.MeasureString("자동 시작", _fLabel);
            _rAuto = new Rectangle(p - (int)(6 * s), stripTop + (int)(7 * s),
                tw + (int)(20 * s) + (int)am.Width, footH - (int)(14 * s));
            if (draw)
            {
                if (_hover == 2) FillRounded(g, _rAuto, 5f * s, hoverBg);
                int kd = th - (int)(6 * s);
                if (on)
                {
                    FillRounded(g, tr, th / 2f, StGreen);
                    using (SolidBrush kb = new SolidBrush(Color.White))
                        g.FillEllipse(kb, tr.Right - kd - 3f * s, tr.Y + 3f * s, kd, kd);
                }
                else
                {
                    StrokeRounded(g, tr, th / 2f, sub);
                    using (SolidBrush kb = new SolidBrush(sub))
                        g.FillEllipse(kb, tr.X + 3f * s, tr.Y + 3f * s, kd, kd);
                }
                g.DrawString("자동 시작", _fLabel, bText, tr.Right + 8f * s, cyf - am.Height / 2f);
            }

            SizeF em = g.MeasureString("종료", _fLabel);
            int exW = (int)(em.Width + 34 * s);
            _rExit = new Rectangle(W - p - exW + (int)(4 * s), stripTop + (int)(7 * s), exW, footH - (int)(14 * s));
            if (draw)
            {
                if (_hover == 3) FillRounded(g, _rExit, 5f * s, hoverBg);
                DrawGlyph(g, "\uE7E8", new Rectangle(_rExit.X, _rExit.Y, (int)(20 * s), _rExit.Height),
                    _hover == 3 ? text : sub); // Fluent: power
                g.DrawString("종료", _fLabel, bText, _rExit.X + 20f * s, cyf - em.Height / 2f);
            }
            if (draw)
            {
                string ver = "v" + Program.Version;
                SizeF vm = g.MeasureString(ver, _fSmall);
                float vx = _rExit.X - vm.Width - 12f * s;
                if (vx > _rAuto.Right + 8f * s)
                    g.DrawString(ver, _fSmall, bFaint, vx, cyf - vm.Height / 2f);
            }
            y = stripTop + footH;

            bText.Dispose();
            bSub.Dispose();
            bFaint.Dispose();
            return new Size(W, y);
        }

        // section header: favicon chip + title, status dot + text right-aligned
        int SectionHeader(Graphics g, bool draw, float s, int W, int p, int y, IconRenderer.Logo logo,
            string title, string status, Color dot, SolidBrush bText, SolidBrush bSub, bool light)
        {
            int h = (int)(28 * s);
            if (draw)
            {
                int cs = (int)(18 * s);
                Rectangle chip = new Rectangle(p, y + (h - cs) / 2, cs, cs);
                Color plate = logo == IconRenderer.Logo.Claude
                    ? Color.FromArgb(217, 119, 87)
                    : (light ? Color.FromArgb(27, 27, 27) : Color.White);
                Color glyphCol = logo == IconRenderer.Logo.Claude
                    ? Color.White
                    : (light ? Color.White : Color.FromArgb(27, 27, 27));
                FillRounded(g, chip, 4f * s, plate);
                Bitmap fav = Favicons.Get(logo);
                if (fav != null)
                {
                    float inset = cs * 0.17f;
                    float scale = Math.Min((cs - inset * 2f) / fav.Width, (cs - inset * 2f) / fav.Height);
                    int dw = Math.Max(1, (int)Math.Round(fav.Width * scale));
                    int dh = Math.Max(1, (int)Math.Round(fav.Height * scale));
                    g.InterpolationMode = InterpolationMode.HighQualityBicubic;
                    IconRenderer.DrawTinted(g, fav,
                        new Rectangle(chip.X + (cs - dw) / 2, chip.Y + (cs - dh) / 2, dw, dh), glyphCol);
                }
                else
                {
                    if (logo == IconRenderer.Logo.Claude)
                        IconRenderer.DrawClaudeLogo(g, chip.X + cs / 2f, chip.Y + cs / 2f, cs * 0.3f, plate);
                    else
                        IconRenderer.DrawCodexLogo(g, chip.X + cs / 2f, chip.Y + cs / 2f, cs * 0.3f, plate, glyphCol);
                }
                SizeF tm = g.MeasureString(title, _fSection);
                g.DrawString(title, _fSection, bText, p + cs + 8f * s, y + (h - tm.Height) / 2f);
                if (status.Length > 0)
                {
                    SizeF sm = g.MeasureString(status, _fSmall);
                    float sx = W - p - sm.Width;
                    using (SolidBrush db = new SolidBrush(dot))
                        g.FillEllipse(db, sx - 10f * s, y + h / 2f - 2.5f * s, 5f * s, 5f * s);
                    g.DrawString(status, _fSmall, bSub, sx, y + (h - sm.Height) / 2f);
                }
            }
            return y + h + (int)(2 * s);
        }

        // uniform metric row: label | bullet bar | % (mono, heat) | reset (mono)
        int MetricRow(Graphics g, bool draw, float s, int W, int p, int y, string label, LimitWindow w,
            Color track, SolidBrush bSub, SolidBrush bFaint)
        {
            int h = (int)(30 * s);
            if (draw)
            {
                double r = w.RemainPct;
                Color heat = IconRenderer.HeatRemain(r);
                float cy = y + h / 2f;
                int labelW = (int)(58 * s);
                int pctW = (int)(50 * s);
                int resetW = (int)(66 * s);

                SizeF lm = g.MeasureString(label, _fLabel);
                g.DrawString(label, _fLabel, bSub, p, cy - lm.Height / 2f);

                string pct = string.Format("{0}%", Math.Round(r * _anim));
                SizeF pm = g.MeasureString(pct, _fMono);
                float pctRight = W - p - resetW - 8f * s;
                using (SolidBrush hb = new SolidBrush(heat))
                    g.DrawString(pct, _fMono, hb, pctRight - pm.Width, cy - pm.Height / 2f);

                string reset = TrayApp.ResetText(w).Replace("리셋 ", "");
                if (reset.Length > 0)
                {
                    SizeF rm = g.MeasureString(reset, _fMonoS);
                    g.DrawString(reset, _fMonoS, bFaint, W - p - rm.Width, cy - rm.Height / 2f);
                }

                float bx = p + labelW;
                float barRight = W - p - resetW - pctW - 12f * s;
                int bh = (int)(4 * s);
                if (barRight - bx > 10f * s)
                {
                    RectangleF trk = new RectangleF(bx, cy - bh / 2f, barRight - bx, bh);
                    FillRounded(g, trk, bh / 2f, track);
                    float fw = (float)(trk.Width * Math.Max(0.0, Math.Min(100.0, r)) / 100.0) * _anim;
                    if (fw > bh) FillRounded(g, new RectangleF(bx, trk.Y, fw, bh), bh / 2f, heat);
                }
            }
            return y + h;
        }

        // Segoe Fluent icon glyph centered in a rect
        void DrawGlyph(Graphics g, string glyph, Rectangle r, Color col)
        {
            SizeF m = g.MeasureString(glyph, _fIcon);
            using (SolidBrush b = new SolidBrush(col))
                g.DrawString(glyph, _fIcon, b, r.X + (r.Width - m.Width) / 2f, r.Y + (r.Height - m.Height) / 2f);
        }
    }

    // ── tray application ───────────────────────────────────────
    class TrayApp : ApplicationContext
    {
        const int RefreshMs = 2 * 60 * 1000; // 2 minutes, same cadence as the SwiftBar plugin
        const string RunKey = @"Software\Microsoft\Windows\CurrentVersion\Run";
        const string RunName = "ClaudeCodexBattery";

        [DllImport("user32.dll")]
        static extern int GetSystemMetrics(int index); // 49 = SM_CXSMICON

        readonly NotifyIcon _icon;
        readonly FlyoutForm _flyout;
        readonly System.Windows.Forms.Timer _timer;
        readonly Form _sync; // hidden window: marshals worker results to the UI thread
        int _refreshing;

        public TrayApp(bool showOnStart)
        {
            _sync = new Form { ShowInTaskbar = false, WindowState = FormWindowState.Minimized, Opacity = 0 };
            IntPtr forceHandle = _sync.Handle; // force handle creation without showing

            _flyout = new FlyoutForm(
                new Func<bool>(IsAutostart),
                delegate { SetAutostart(!IsAutostart()); },
                delegate { RefreshAsync(); },
                delegate { Quit(); });

            _icon = new NotifyIcon
            {
                Text = "Claude · Codex 사용량 — 로딩 중",
                Icon = IconRenderer.DualIcon(IconSize(), null, null, IsLightTaskbar()),
                Visible = true,
            };
            _icon.MouseUp += delegate(object s, MouseEventArgs e)
            {
                if (e.Button == MouseButtons.Left || e.Button == MouseButtons.Right)
                    _flyout.ShowNear();
            };

            _timer = new System.Windows.Forms.Timer { Interval = RefreshMs };
            _timer.Tick += delegate { RefreshAsync(); };
            _timer.Start();
            RefreshAsync();

            if (showOnStart) // debug (--show): open the flyout once data has landed
            {
                System.Windows.Forms.Timer once = new System.Windows.Forms.Timer { Interval = 2500 };
                once.Tick += delegate { once.Stop(); _flyout.ShowNear(); };
                once.Start();
            }
        }

        static int IconSize()
        {
            int s = GetSystemMetrics(49);
            return s >= 16 ? s : 16;
        }

        internal static bool IsLightTaskbar()
        {
            try
            {
                object v = Registry.GetValue(@"HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize", "SystemUsesLightTheme", 0);
                return v != null && Convert.ToInt32(v) == 1;
            }
            catch { return false; }
        }

        void RefreshAsync()
        {
            if (Interlocked.CompareExchange(ref _refreshing, 1, 0) != 0) return;
            ThreadPool.QueueUserWorkItem(delegate
            {
                ClaudeUsage claude = null;
                CodexUsage codex = null;
                try { claude = Fetchers.GetClaude(); } catch { }
                try { codex = Fetchers.GetCodex(); } catch { }
                try
                {
                    _sync.BeginInvoke((MethodInvoker)delegate { Apply(claude, codex); });
                }
                catch { }
                Interlocked.Exchange(ref _refreshing, 0);
            });
        }

        internal static string FmtDur(TimeSpan ts)
        {
            if (ts.TotalSeconds <= 0) return "0m";
            int h = (int)ts.TotalHours;
            int m = ts.Minutes;
            if (h >= 24) return string.Format("{0}d {1}h", h / 24, h % 24);
            if (h > 0) return string.Format("{0}h {1}m", h, m);
            return string.Format("{0}m", m);
        }

        internal static string ResetText(LimitWindow w)
        {
            if (w == null || w.ResetsAtUtc == null) return "";
            if (w.Stale || w.ResetsAtUtc < DateTime.UtcNow) return "리셋됨";
            return "리셋 " + FmtDur(w.ResetsAtUtc.Value - DateTime.UtcNow);
        }

        void Apply(ClaudeUsage claude, CodexUsage codex)
        {
            double? c = null;
            if (claude != null)
            {
                LimitWindow m = claude.FiveHour != null ? claude.FiveHour : claude.Weekly;
                if (m != null) c = m.RemainPct;
            }
            double? x = null;
            if (codex != null)
            {
                if (codex.CreditsMode) x = codex.CreditsAvailable ? 100.0 : 0.0;
                else if (codex.Primary != null) x = codex.Primary.RemainPct;
                else if (codex.Secondary != null) x = codex.Secondary.RemainPct;
            }

            Icon old = _icon.Icon;
            _icon.Icon = IconRenderer.DualIcon(IconSize(), c, x, IsLightTaskbar());
            if (old != null) old.Dispose();

            StringBuilder tip = new StringBuilder();
            tip.Append(c != null ? string.Format("Claude {0}%", Math.Round(c.Value)) : "Claude —");
            if (x != null) tip.AppendFormat(" · Codex {0}%", Math.Round(x.Value));
            tip.Append(" 남음");
            string t = tip.ToString();
            if (t.Length > 63) t = t.Substring(0, 62) + "…";
            _icon.Text = t;

            _flyout.SetData(claude, codex);
        }

        static bool IsAutostart()
        {
            try
            {
                using (RegistryKey k = Registry.CurrentUser.OpenSubKey(RunKey))
                    return k != null && k.GetValue(RunName) != null;
            }
            catch { return false; }
        }

        static void SetAutostart(bool on)
        {
            try
            {
                using (RegistryKey k = Registry.CurrentUser.CreateSubKey(RunKey))
                {
                    if (on) k.SetValue(RunName, "\"" + Application.ExecutablePath + "\"");
                    else k.DeleteValue(RunName, false);
                }
            }
            catch { }
        }

        void Quit()
        {
            _flyout.Hide();
            _icon.Visible = false;
            _icon.Dispose();
            _timer.Stop();
            Application.Exit();
        }
    }

    // ── debug: render sample icons + live status to a directory ──
    static class DebugDump
    {
        public static void Run(string dir)
        {
            Directory.CreateDirectory(dir);
            Favicons.FetchSync(); // dump shows the final favicon-based icons
            double?[][] pairs = { new double?[] { 100, 98 }, new double?[] { 74, 41 }, new double?[] { 35, 80 }, new double?[] { 12, 5 }, new double?[] { null, null } };
            int[] sizes = { 16, 24, 32 };
            foreach (int size in sizes)
            {
                foreach (bool light in new[] { false, true })
                {
                    foreach (double?[] v in pairs)
                    {
                        string tag = v[0] == null ? "none" : ((int)v[0].Value).ToString();
                        string theme = light ? "light" : "dark";
                        using (Bitmap b = IconRenderer.RenderDual(size, v[0], v[1], light))
                            b.Save(Path.Combine(dir, string.Format("s{0}-dual-{1}-{2}.png", size, tag, theme)), ImageFormat.Png);
                    }
                }
            }

            // flyout snapshot with live data
            try
            {
                ClaudeUsage fc = Fetchers.GetClaude();
                CodexUsage fx = Fetchers.GetCodex();
                using (FlyoutForm fly = new FlyoutForm(
                    delegate { return true; }, delegate { }, delegate { }, delegate { }))
                {
                    fly.SetData(fc, fx);
                    using (Bitmap fb = new Bitmap(fly.Width, fly.Height))
                    {
                        fly.DrawToBitmap(fb, new Rectangle(0, 0, fly.Width, fly.Height));
                        fb.Save(Path.Combine(dir, "flyout.png"), ImageFormat.Png);
                    }
                }
            }
            catch (Exception ex)
            {
                File.WriteAllText(Path.Combine(dir, "flyout-error.txt"), ex.ToString());
            }

            StringBuilder sb = new StringBuilder();
            ClaudeUsage c = Fetchers.GetClaude();
            if (c != null)
            {
                sb.AppendLine(string.Format("claude live={0} measured={1:u}", c.Live, c.MeasuredAtUtc));
                if (c.FiveHour != null) sb.AppendLine(string.Format("  five_hour used={0}% remain={1}% resets={2:u}", c.FiveHour.UsedPct, c.FiveHour.RemainPct, c.FiveHour.ResetsAtUtc));
                if (c.Weekly != null) sb.AppendLine(string.Format("  weekly    used={0}% remain={1}% resets={2:u}", c.Weekly.UsedPct, c.Weekly.RemainPct, c.Weekly.ResetsAtUtc));
                if (c.TopModel != null) sb.AppendLine(string.Format("  {0} used={1}% remain={2}% resets={3:u}", c.TopModelName, c.TopModel.UsedPct, c.TopModel.RemainPct, c.TopModel.ResetsAtUtc));
            }
            else sb.AppendLine("claude: no data");
            CodexUsage x = Fetchers.GetCodex();
            if (x != null)
            {
                sb.AppendLine(string.Format("codex plan={0} measured={1:u} creditsMode={2}", x.Plan, x.MeasuredAtUtc, x.CreditsMode));
                if (x.Primary != null) sb.AppendLine(string.Format("  primary   used={0}% remain={1}% stale={2} resets={3:u}", x.Primary.UsedPct, x.Primary.RemainPct, x.Primary.Stale, x.Primary.ResetsAtUtc));
                if (x.Secondary != null) sb.AppendLine(string.Format("  secondary used={0}% remain={1}% stale={2} resets={3:u}", x.Secondary.UsedPct, x.Secondary.RemainPct, x.Secondary.Stale, x.Secondary.ResetsAtUtc));
            }
            else sb.AppendLine("codex: no data");
            File.WriteAllText(Path.Combine(dir, "status.txt"), sb.ToString());
            Console.WriteLine(sb.ToString());
        }
    }
}
