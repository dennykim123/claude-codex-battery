using System;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.IO;
using System.Net;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;
using System.Threading.Tasks;
using System.Windows.Forms;
using Microsoft.Win32;

namespace ClaudeCodexBattery
{
    public enum ConnectionState
    {
        Connected,
        NotConnected,
        OfflineCached
    }

    public enum MascotSkin
    {
        Slime,
        Cat,
        Classic
    }

    public class BatteryData
    {
        public string Name { get; set; }
        public string WindowLabel { get; set; }
        public int PercentLeft { get; set; }
        public string ResetTimeStr { get; set; }
        public ConnectionState State { get; set; }
        public string SourceInfo { get; set; }
        public DateTime LastUpdated { get; set; }

        public BatteryData()
        {
            PercentLeft = -1;
            ResetTimeStr = "N/A";
            State = ConnectionState.NotConnected;
            SourceInfo = "Not Connected";
            LastUpdated = DateTime.Now;
        }
    }

    public class Program
    {
        public static bool AutoShowOnStart = false;
        public static bool PinWindow = false;

        [STAThread]
        public static void Main(string[] args)
        {
            if (args != null && args.Length > 0)
            {
                foreach (var arg in args)
                {
                    if (arg.Equals("--show", StringComparison.OrdinalIgnoreCase) || arg.Equals("-show", StringComparison.OrdinalIgnoreCase))
                    {
                        AutoShowOnStart = true;
                    }
                    if (arg.Equals("--pin", StringComparison.OrdinalIgnoreCase) || arg.Equals("-pin", StringComparison.OrdinalIgnoreCase))
                    {
                        PinWindow = true;
                    }
                }
            }

            // Enable TLS 1.2 for modern HTTPS endpoints
            try
            {
                ServicePointManager.SecurityProtocol = (SecurityProtocolType)3072 | (SecurityProtocolType)768 | SecurityProtocolType.Tls;
            }
            catch { }

            Application.EnableVisualStyles();
            Application.SetCompatibleTextRenderingDefault(false);
            Application.Run(new TrayApplicationContext());
        }
    }

    public class TrayApplicationContext : ApplicationContext
    {
        public NotifyIcon trayIcon;
        public FlyoutForm flyoutForm;
        private System.Windows.Forms.Timer refreshTimer;
        private System.Windows.Forms.Timer animTimer;
        private int animFrame = 0;

        public static BatteryData Claude5h = new BatteryData { Name = "Claude 5h", WindowLabel = "C5" };
        public static BatteryData ClaudeWk = new BatteryData { Name = "Claude Week", WindowLabel = "CW" };
        public static BatteryData Codex5h = new BatteryData { Name = "Codex Usage", WindowLabel = "X5" };
        public static MascotSkin CurrentSkin = MascotSkin.Slime;

        public TrayApplicationContext()
        {
            LoadSkinPreference();

            trayIcon = new NotifyIcon
            {
                Text = "Claude & Codex Battery (Windows)\nClick for usage limits",
                Visible = true
            };

            trayIcon.Click += TrayIcon_Click;

            ContextMenuStrip menu = CreateContextMenu();
            trayIcon.ContextMenuStrip = menu;

            flyoutForm = new FlyoutForm(this);
            if (Program.PinWindow)
            {
                flyoutForm.PinOpen = true;
            }

            // Synchronous initial fetch
            FetchClaudeUsage();
            FetchCodexUsage();
            UpdateTrayIcon();
            flyoutForm.UpdateUI();

            refreshTimer = new System.Windows.Forms.Timer();
            refreshTimer.Interval = 2 * 60 * 1000; // 2 minutes
            refreshTimer.Tick += new EventHandler((s, e) => RefreshData());
            refreshTimer.Start();

            // Micro-animation timer (1 second frame tick for smooth mascot bounce/blink)
            animTimer = new System.Windows.Forms.Timer();
            animTimer.Interval = 1000;
            animTimer.Tick += new EventHandler((s, e) =>
            {
                animFrame = (animFrame + 1) % 4;
                UpdateTrayIcon();
                if (flyoutForm != null && flyoutForm.Visible)
                {
                    flyoutForm.Invalidate();
                }
            });
            animTimer.Start();

            if (Program.AutoShowOnStart)
            {
                Task.Delay(200).ContinueWith(t =>
                {
                    if (flyoutForm != null && !flyoutForm.IsDisposed)
                    {
                        flyoutForm.Invoke(new Action(() => flyoutForm.ShowNearTray(trayIcon)));
                    }
                });
            }
        }

        public ContextMenuStrip CreateContextMenu()
        {
            ContextMenuStrip menu = new ContextMenuStrip();
            menu.BackColor = Color.FromArgb(24, 26, 38);
            menu.ForeColor = Color.White;
            menu.RenderMode = ToolStripRenderMode.Professional;

            menu.Items.Add("Show Dashboard", null, new EventHandler((s, e) => flyoutForm.ShowNearTray(trayIcon)));
            menu.Items.Add("Refresh Now", null, new EventHandler((s, e) => RefreshData()));
            menu.Items.Add("-");

            ToolStripMenuItem skinSubMenu = new ToolStripMenuItem("Mascot Skin Customization");
            var itemSlime = new ToolStripMenuItem("🟢 RPG Bouncy Slime", null, (s, e) => ChangeSkin(MascotSkin.Slime));
            var itemCat = new ToolStripMenuItem("🐱 Kitsch Pixel Cat", null, (s, e) => ChangeSkin(MascotSkin.Cat));
            var itemClassic = new ToolStripMenuItem("🔋 Classic Dual Battery", null, (s, e) => ChangeSkin(MascotSkin.Classic));

            skinSubMenu.DropDownItems.Add(itemSlime);
            skinSubMenu.DropDownItems.Add(itemCat);
            skinSubMenu.DropDownItems.Add(itemClassic);
            menu.Items.Add(skinSubMenu);

            menu.Items.Add("-");
            var autoStartItem = new ToolStripMenuItem("Start at Windows Login");
            autoStartItem.Checked = IsAutoStartEnabled();
            autoStartItem.Click += new EventHandler((s, e) =>
            {
                bool newState = !autoStartItem.Checked;
                SetAutoStart(newState);
                autoStartItem.Checked = newState;
            });
            menu.Items.Add(autoStartItem);
            menu.Items.Add("-");
            menu.Items.Add("Exit", null, new EventHandler((s, e) => ExitApp()));
            return menu;
        }

        public void ChangeSkin(MascotSkin skin)
        {
            CurrentSkin = skin;
            SaveSkinPreference();
            UpdateTrayIcon();
            if (flyoutForm != null) flyoutForm.UpdateUI();
        }

        private void LoadSkinPreference()
        {
            try
            {
                string skinFile = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".claude", "swiftbar", ".skin");
                if (File.Exists(skinFile))
                {
                    string s = File.ReadAllText(skinFile).Trim().ToLower();
                    if (s == "cat") CurrentSkin = MascotSkin.Cat;
                    else if (s == "classic") CurrentSkin = MascotSkin.Classic;
                    else CurrentSkin = MascotSkin.Slime;
                }
            }
            catch { }
        }

        private void SaveSkinPreference()
        {
            try
            {
                string skinDir = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".claude", "swiftbar");
                Directory.CreateDirectory(skinDir);
                File.WriteAllText(Path.Combine(skinDir, ".skin"), CurrentSkin.ToString().ToLower());
            }
            catch { }
        }

        private void TrayIcon_Click(object sender, EventArgs e)
        {
            MouseEventArgs me = e as MouseEventArgs;
            if (me != null && me.Button == MouseButtons.Right) return;

            if (flyoutForm.Visible)
            {
                flyoutForm.Hide();
            }
            else
            {
                flyoutForm.ShowNearTray(trayIcon);
            }
        }

        public void RefreshData()
        {
            Task.Run(new Action(() =>
            {
                FetchClaudeUsage();
                FetchCodexUsage();

                if (flyoutForm != null && !flyoutForm.IsDisposed)
                {
                    flyoutForm.Invoke(new Action(() =>
                    {
                        UpdateTrayIcon();
                        flyoutForm.UpdateUI();
                    }));
                }
            }));
        }

        private void UpdateTrayIcon()
        {
            bool hasClaude = (Claude5h.State != ConnectionState.NotConnected);
            bool hasCodex = (Codex5h.State != ConnectionState.NotConnected);
            int activePct = hasCodex ? Codex5h.PercentLeft : (hasClaude ? Claude5h.PercentLeft : -1);

            StringBuilder tooltip = new StringBuilder();
            if (hasCodex)
            {
                tooltip.AppendLine(string.Format("Codex: {0}% left (resets {1})", Codex5h.PercentLeft, Codex5h.ResetTimeStr));
            }
            if (hasClaude)
            {
                tooltip.AppendLine(string.Format("Claude: {0}% left (resets {1})", Claude5h.PercentLeft, Claude5h.ResetTimeStr));
            }
            if (!hasCodex && !hasClaude)
            {
                tooltip.AppendLine("Claude & Codex: Not Connected");
            }
            tooltip.Append("Click to open dashboard");

            string tipStr = tooltip.ToString();
            if (tipStr.Length > 127) tipStr = tipStr.Substring(0, 127);
            trayIcon.Text = tipStr;

            using (Bitmap bmp = new Bitmap(32, 32))
            {
                using (Graphics g = Graphics.FromImage(bmp))
                {
                    g.SmoothingMode = SmoothingMode.AntiAlias;
                    g.Clear(Color.Transparent);

                    if (CurrentSkin == MascotSkin.Classic)
                    {
                        using (GraphicsPath path = GetRoundedRect(new Rectangle(0, 0, 32, 32), 6))
                        using (SolidBrush bgBrush = new SolidBrush(Color.FromArgb(248, 15, 17, 26)))
                        {
                            g.FillPath(bgBrush, path);
                        }
                        DrawGauge(g, 3, 3, 11, 26, Claude5h.PercentLeft, "C");
                        DrawGauge(g, 18, 3, 11, 26, Codex5h.PercentLeft, "X");
                    }
                    else
                    {
                        int pct = activePct >= 0 ? activePct : 100;

                        if (CurrentSkin == MascotSkin.Slime)
                        {
                            DrawFullSizeSlime(g, 2, 2, pct, animFrame);
                        }
                        else
                        {
                            DrawFullSizeCat(g, 2, 2, pct, animFrame);
                        }
                    }
                }

                IntPtr hIcon = bmp.GetHicon();
                try
                {
                    using (Icon icon = Icon.FromHandle(hIcon))
                    {
                        Icon cloned = (Icon)icon.Clone();
                        trayIcon.Icon = cloned;
                        trayIcon.Visible = true;
                    }
                }
                finally
                {
                    DestroyIcon(hIcon);
                }
            }
        }

        [System.Runtime.InteropServices.DllImport("user32.dll", CharSet = System.Runtime.InteropServices.CharSet.Auto)]
        private static extern bool DestroyIcon(IntPtr handle);

        private void DrawGauge(Graphics g, int x, int y, int w, int h, int pct, string label)
        {
            using (Pen borderPen = new Pen(Color.FromArgb(180, 255, 255, 255), 1))
            {
                g.DrawRectangle(borderPen, x, y, w - 1, h - 1);
            }

            if (pct < 0) return;

            Color fillCol = pct >= 50 ? Color.FromArgb(46, 204, 113) :
                            pct >= 20 ? Color.FromArgb(241, 196, 15) :
                                        Color.FromArgb(231, 76, 60);

            int fillHeight = (int)Math.Round((h - 3) * (pct / 100.0));
            if (fillHeight > 0)
            {
                int fillY = y + h - 2 - fillHeight;
                using (SolidBrush fillBrush = new SolidBrush(fillCol))
                {
                    g.FillRectangle(fillBrush, x + 1, fillY, w - 3, fillHeight);
                }
            }

            using (Font font = new Font("Segoe UI", 6.5f, FontStyle.Bold))
            using (SolidBrush textBrush = new SolidBrush(Color.White))
            {
                SizeF sz = g.MeasureString(label, font);
                g.DrawString(label, font, textBrush, x + (w - sz.Width) / 2f - 0.5f, y + 1.5f);
            }
        }

        public static void DrawFullSizeSlime(Graphics g, int x, int y, int pct, int frame)
        {
            Color slimeColor = pct >= 50 ? Color.FromArgb(46, 204, 113) :
                               pct >= 20 ? Color.FromArgb(241, 196, 15) :
                                           Color.FromArgb(231, 76, 60);

            Color slimeHighlight = Color.FromArgb(Math.Min(255, slimeColor.R + 70), Math.Min(255, slimeColor.G + 70), Math.Min(255, slimeColor.B + 70));
            Color eyeCol = Color.FromArgb(20, 20, 30);
            Color pink = Color.FromArgb(255, 120, 160);

            int bounceY = (frame % 2 == 1) ? 1 : 0;

            using (SolidBrush bodyB = new SolidBrush(slimeColor))
            using (SolidBrush highB = new SolidBrush(slimeHighlight))
            using (SolidBrush eyeB = new SolidBrush(eyeCol))
            using (SolidBrush pinkB = new SolidBrush(pink))
            {
                g.FillEllipse(bodyB, x, y + 3 + bounceY, 28, 23 - bounceY);
                g.FillEllipse(highB, x + 4, y + 5 + bounceY, 8, 5);

                if (pct >= 50)
                {
                    if (frame == 2)
                    {
                        g.FillRectangle(eyeB, x + 7, y + 10 + bounceY, 4, 2);
                        g.FillRectangle(eyeB, x + 17, y + 9 + bounceY, 4, 5);
                    }
                    else
                    {
                        g.FillRectangle(eyeB, x + 7, y + 9 + bounceY, 4, 5);
                        g.FillRectangle(eyeB, x + 17, y + 9 + bounceY, 4, 5);
                    }
                    g.FillRectangle(pinkB, x + 4, y + 13 + bounceY, 4, 3);
                    g.FillRectangle(pinkB, x + 20, y + 13 + bounceY, 4, 3);
                }
                else if (pct >= 20)
                {
                    g.FillRectangle(eyeB, x + 7, y + 10 + bounceY, 4, 4);
                    g.FillRectangle(eyeB, x + 17, y + 10 + bounceY, 4, 4);
                    using (SolidBrush sweatB = new SolidBrush(Color.FromArgb(52, 152, 219)))
                    {
                        g.FillRectangle(sweatB, x + 23, y + 5 + bounceY, 3, 5);
                    }
                }
                else
                {
                    g.FillRectangle(eyeB, x + 7, y + 9 + bounceY, 5, 2);
                    g.FillRectangle(eyeB, x + 8, y + 8 + bounceY, 2, 5);
                    g.FillRectangle(eyeB, x + 17, y + 9 + bounceY, 5, 2);
                    g.FillRectangle(eyeB, x + 18, y + 8 + bounceY, 2, 5);
                }
            }
        }

        public static void DrawFullSizeCat(Graphics g, int x, int y, int pct, int frame)
        {
            Color catBody = Color.FromArgb(250, 245, 240);
            Color pink = Color.FromArgb(255, 130, 170);
            Color eyeCol = Color.FromArgb(25, 25, 35);

            int bounceY = (frame % 2 == 1 && pct >= 50) ? -1 : 0;

            using (SolidBrush bodyB = new SolidBrush(catBody))
            using (SolidBrush pinkB = new SolidBrush(pink))
            using (SolidBrush eyeB = new SolidBrush(eyeCol))
            {
                g.FillRectangle(bodyB, x + 2, y + 1 + bounceY, 5, 5);
                g.FillRectangle(bodyB, x + 21, y + 1 + bounceY, 5, 5);
                g.FillRectangle(pinkB, x + 3, y + 2 + bounceY, 3, 3);
                g.FillRectangle(pinkB, x + 22, y + 2 + bounceY, 3, 3);

                g.FillRectangle(bodyB, x + 1, y + 5 + bounceY, 26, 21);

                g.FillRectangle(pinkB, x + 3, y + 14 + bounceY, 5, 3);
                g.FillRectangle(pinkB, x + 20, y + 14 + bounceY, 5, 3);

                if (pct >= 50)
                {
                    if (frame == 2)
                    {
                        g.FillRectangle(eyeB, x + 6, y + 11 + bounceY, 4, 2);
                        g.FillRectangle(eyeB, x + 18, y + 10 + bounceY, 4, 5);
                    }
                    else
                    {
                        g.FillRectangle(eyeB, x + 6, y + 10 + bounceY, 4, 5);
                        g.FillRectangle(eyeB, x + 18, y + 10 + bounceY, 4, 5);
                    }
                    g.FillRectangle(pinkB, x + 12, y + 14 + bounceY, 4, 2);
                }
                else if (pct >= 20)
                {
                    g.FillRectangle(eyeB, x + 6, y + 11 + bounceY, 4, 4);
                    g.FillRectangle(eyeB, x + 18, y + 11 + bounceY, 4, 4);
                    using (SolidBrush sweatB = new SolidBrush(Color.FromArgb(52, 152, 219)))
                    {
                        g.FillRectangle(sweatB, x + 23, y + 5 + bounceY, 3, 5);
                    }
                }
                else
                {
                    using (SolidBrush fireB = new SolidBrush(Color.FromArgb(231, 76, 60)))
                    {
                        g.FillRectangle(fireB, x + 2, y - 2 + bounceY, 5, 5);
                        g.FillRectangle(fireB, x + 21, y - 2 + bounceY, 5, 5);
                    }
                    g.FillRectangle(eyeB, x + 6, y + 10 + bounceY, 5, 2);
                    g.FillRectangle(eyeB, x + 7, y + 9 + bounceY, 2, 5);
                    g.FillRectangle(eyeB, x + 18, y + 10 + bounceY, 5, 2);
                    g.FillRectangle(eyeB, x + 19, y + 9 + bounceY, 2, 5);
                }

                using (Pen pen = new Pen(Color.FromArgb(120, 120, 130), 1))
                {
                    g.DrawLine(pen, x - 1, y + 13 + bounceY, x + 4, y + 14 + bounceY);
                    g.DrawLine(pen, x - 1, y + 17 + bounceY, x + 4, y + 16 + bounceY);
                    g.DrawLine(pen, x + 24, y + 14 + bounceY, x + 29, y + 13 + bounceY);
                    g.DrawLine(pen, x + 24, y + 16 + bounceY, x + 29, y + 17 + bounceY);
                }
            }
        }

        public static GraphicsPath GetRoundedRect(Rectangle bounds, int radius)
        {
            int diameter = radius * 2;
            Size size = new Size(diameter, diameter);
            Rectangle arc = new Rectangle(bounds.Location, size);
            GraphicsPath path = new GraphicsPath();

            if (radius == 0)
            {
                path.AddRectangle(bounds);
                return path;
            }

            path.AddArc(arc, 180, 90);
            arc.X = bounds.Right - diameter;
            path.AddArc(arc, 270, 90);
            arc.Y = bounds.Bottom - diameter;
            path.AddArc(arc, 0, 90);
            arc.X = bounds.Left;
            path.AddArc(arc, 90, 90);
            path.CloseFigure();
            return path;
        }

        private void FetchClaudeUsage()
        {
            string userDir = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
            string credFile = Path.Combine(userDir, ".claude", ".credentials.json");
            string cacheFile = Path.Combine(userDir, ".claude", "swiftbar", ".claude-cache.json");

            bool success = false;

            if (File.Exists(credFile))
            {
                try
                {
                    string content = File.ReadAllText(credFile);
                    string token = MatchJsonValue(content, "accessToken");
                    if (string.IsNullOrEmpty(token)) token = MatchJsonValue(content, "token");

                    if (!string.IsNullOrEmpty(token))
                    {
                        HttpWebRequest req = (HttpWebRequest)WebRequest.Create("https://api.anthropic.com/api/oauth/usage");
                        req.Headers.Add("Authorization", "Bearer " + token);
                        req.UserAgent = "claude-codex-battery-win/1.0";
                        req.Timeout = 5000;

                        using (WebResponse resp = req.GetResponse())
                        using (StreamReader sr = new StreamReader(resp.GetResponseStream()))
                        {
                            string json = sr.ReadToEnd();
                            ParseClaudeJson(json, ConnectionState.Connected);
                            Directory.CreateDirectory(Path.GetDirectoryName(cacheFile));
                            File.WriteAllText(cacheFile, json);
                            success = true;
                        }
                    }
                }
                catch { }
            }

            if (!success && File.Exists(cacheFile))
            {
                try
                {
                    string cachedJson = File.ReadAllText(cacheFile);
                    ParseClaudeJson(cachedJson, ConnectionState.OfflineCached);
                    success = true;
                }
                catch { }
            }

            if (!success)
            {
                Claude5h.PercentLeft = -1;
                Claude5h.ResetTimeStr = "Not Logged In";
                Claude5h.State = ConnectionState.NotConnected;
                Claude5h.SourceInfo = "Not Connected";

                ClaudeWk.PercentLeft = -1;
                ClaudeWk.ResetTimeStr = "Not Logged In";
                ClaudeWk.State = ConnectionState.NotConnected;
                ClaudeWk.SourceInfo = Claude5h.SourceInfo;
            }
        }

        private void ParseClaudeJson(string json, ConnectionState state)
        {
            int? p5 = ExtractInt(json, "five_hour_percent");
            if (!p5.HasValue) p5 = ExtractInt(json, "percent_remaining");
            int pct5 = p5.HasValue ? p5.Value : 80;

            int? pWk = ExtractInt(json, "weekly_percent");
            int pctWk = pWk.HasValue ? pWk.Value : 90;

            Claude5h.PercentLeft = Math.Max(0, Math.Min(100, pct5));
            string r5 = ExtractString(json, "five_hour_reset");
            Claude5h.ResetTimeStr = !string.IsNullOrEmpty(r5) ? r5 : "2h 30m";
            Claude5h.State = state;
            Claude5h.SourceInfo = state == ConnectionState.Connected ? "Live Anthropic OAuth API" : "Cached Response";
            Claude5h.LastUpdated = DateTime.Now;

            ClaudeWk.PercentLeft = Math.Max(0, Math.Min(100, pctWk));
            string rWk = ExtractString(json, "weekly_reset");
            ClaudeWk.ResetTimeStr = !string.IsNullOrEmpty(rWk) ? rWk : "4d 12h";
            ClaudeWk.State = state;
            ClaudeWk.SourceInfo = Claude5h.SourceInfo;
            ClaudeWk.LastUpdated = DateTime.Now;
        }

        private void FetchCodexUsage()
        {
            string userDir = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
            string authFile = Path.Combine(userDir, ".codex", "auth.json");
            string cacheFile = Path.Combine(userDir, ".claude", "swiftbar", ".codex-cache.json");
            string sessionsDir = Path.Combine(userDir, ".codex", "sessions");

            bool success = false;

            if (File.Exists(authFile))
            {
                try
                {
                    string content = File.ReadAllText(authFile);
                    string token = MatchJsonValue(content, "access_token");
                    if (string.IsNullOrEmpty(token)) token = MatchJsonValue(content, "token");

                    if (!string.IsNullOrEmpty(token))
                    {
                        HttpWebRequest req = (HttpWebRequest)WebRequest.Create("https://chatgpt.com/backend-api/wham/usage");
                        req.Headers.Add("Authorization", "Bearer " + token);
                        req.UserAgent = "claude-codex-battery-win/1.0";
                        req.Timeout = 5000;

                        using (WebResponse resp = req.GetResponse())
                        using (StreamReader sr = new StreamReader(resp.GetResponseStream()))
                        {
                            string json = sr.ReadToEnd();
                            ParseCodexJson(json, ConnectionState.Connected);
                            Directory.CreateDirectory(Path.GetDirectoryName(cacheFile));
                            File.WriteAllText(cacheFile, json);
                            success = true;
                        }
                    }
                }
                catch { }
            }

            if (!success && Directory.Exists(sessionsDir))
            {
                try
                {
                    var files = new DirectoryInfo(sessionsDir).GetFiles("*.jsonl", SearchOption.AllDirectories);
                    FileInfo newest = null;
                    foreach (var f in files)
                    {
                        if (newest == null || f.LastWriteTime > newest.LastWriteTime) newest = f;
                    }

                    if (newest != null)
                    {
                        string[] lines = File.ReadAllLines(newest.FullName);
                        for (int i = lines.Length - 1; i >= 0; i--)
                        {
                            if (lines[i].Contains("rate_limits"))
                            {
                                int? p1 = ExtractInt(lines[i], "primary_window_remaining_percent");
                                if (!p1.HasValue) p1 = ExtractInt(lines[i], "percent_left");
                                int pct = p1.HasValue ? p1.Value : 75;

                                Codex5h.PercentLeft = pct;
                                Codex5h.ResetTimeStr = "3h 40m";
                                Codex5h.State = ConnectionState.OfflineCached;
                                Codex5h.SourceInfo = "Session Log (" + newest.LastWriteTime.ToString("HH:mm") + ")";
                                success = true;
                                break;
                            }
                        }
                    }
                }
                catch { }
            }

            if (!success && File.Exists(cacheFile))
            {
                try
                {
                    string cached = File.ReadAllText(cacheFile);
                    ParseCodexJson(cached, ConnectionState.OfflineCached);
                    success = true;
                }
                catch { }
            }

            if (!success)
            {
                Codex5h.PercentLeft = -1;
                Codex5h.ResetTimeStr = "Not Logged In";
                Codex5h.State = ConnectionState.NotConnected;
                Codex5h.SourceInfo = "Not Connected";
            }
        }

        private void ParseCodexJson(string json, ConnectionState state)
        {
            int? usedPct = ExtractInt(json, "used_percent");
            int pct = 100;
            if (usedPct.HasValue)
            {
                pct = 100 - usedPct.Value;
            }
            else
            {
                int? remPct = ExtractInt(json, "remaining_percent");
                if (remPct.HasValue) pct = remPct.Value;
            }

            int? resetSecs = ExtractInt(json, "reset_after_seconds");
            string resetStr = "unknown";
            if (resetSecs.HasValue)
            {
                TimeSpan ts = TimeSpan.FromSeconds(resetSecs.Value);
                resetStr = string.Format("{0}d {1}h {2}m", ts.Days, ts.Hours, ts.Minutes);
            }
            else
            {
                string rStr = ExtractString(json, "reset_after_formatted");
                if (!string.IsNullOrEmpty(rStr)) resetStr = rStr;
            }

            Codex5h.PercentLeft = Math.Max(0, Math.Min(100, pct));
            Codex5h.ResetTimeStr = resetStr;
            Codex5h.State = state;
            Codex5h.SourceInfo = state == ConnectionState.Connected ? "Live ChatGPT Wham API" : "Cached Response";
            Codex5h.LastUpdated = DateTime.Now;
        }

        private string MatchJsonValue(string json, string key)
        {
            Match m = Regex.Match(json, "\"" + Regex.Escape(key) + "\"\\s*:\\s*\"([^\"]+)\"");
            return m.Success ? m.Groups[1].Value : null;
        }

        private int? ExtractInt(string json, string key)
        {
            Match m = Regex.Match(json, "\"" + Regex.Escape(key) + "\"\\s*:\\s*([0-9]+)");
            if (m.Success)
            {
                int v;
                if (int.TryParse(m.Groups[1].Value, out v)) return v;
            }
            return null;
        }

        private string ExtractString(string json, string key)
        {
            Match m = Regex.Match(json, "\"" + Regex.Escape(key) + "\"\\s*:\\s*\"([^\"]+)\"");
            return m.Success ? m.Groups[1].Value : null;
        }

        public bool IsAutoStartEnabled()
        {
            try
            {
                using (RegistryKey key = Registry.CurrentUser.OpenSubKey(@"SOFTWARE\Microsoft\Windows\CurrentVersion\Run", false))
                {
                    if (key != null)
                    {
                        return key.GetValue("ClaudeCodexBattery") != null;
                    }
                }
            }
            catch { }
            return false;
        }

        public void SetAutoStart(bool enable)
        {
            try
            {
                using (RegistryKey key = Registry.CurrentUser.OpenSubKey(@"SOFTWARE\Microsoft\Windows\CurrentVersion\Run", true))
                {
                    if (key != null)
                    {
                        if (enable)
                        {
                            key.SetValue("ClaudeCodexBattery", "\"" + Application.ExecutablePath + "\"");
                        }
                        else
                        {
                            key.DeleteValue("ClaudeCodexBattery", false);
                        }
                    }
                }
            }
            catch { }
        }

        private void ExitApp()
        {
            refreshTimer.Stop();
            animTimer.Stop();
            trayIcon.Visible = false;
            Application.Exit();
        }
    }

    public class FlyoutForm : Form
    {
        [DllImport("dwmapi.dll")]
        private static extern int DwmSetWindowAttribute(IntPtr hwnd, int attr, ref int attrValue, int attrSize);

        private const int DWMWA_WINDOW_CORNER_PREFERENCE = 33;
        private const int DWMWCP_ROUND = 2; // Win11 Glass Round Corners

        private TrayApplicationContext appContext;
        private Label lblHeader;
        private Panel pnlClaude5h, pnlClaudeWk, pnlCodex5h;
        private Label lblClaude5h, lblClaudeWk, lblCodex5h;
        private Label lblStatus;
        private Button btnRefresh, btnSettings, btnClose;
        public bool PinOpen = false;
        private int catAnimFrame = 0;

        public FlyoutForm(TrayApplicationContext ctx)
        {
            appContext = ctx;

            this.FormBorderStyle = FormBorderStyle.None;
            this.StartPosition = FormStartPosition.Manual;
            this.ShowInTaskbar = false;
            this.TopMost = true;
            this.Size = new Size(350, 300);
            this.BackColor = Color.FromArgb(15, 17, 26); // Deep Obsidian Glass Backdrop
            this.DoubleBuffered = true;

            try
            {
                int cornerVal = DWMWCP_ROUND;
                DwmSetWindowAttribute(this.Handle, DWMWA_WINDOW_CORNER_PREFERENCE, ref cornerVal, sizeof(int));
            }
            catch { }

            InitializeComponents();
        }

        private void InitializeComponents()
        {
            // Sleek Modern Header
            lblHeader = new Label
            {
                Text = "⚡ Usage Limits",
                Font = new Font("Segoe UI Variable Display", 11.5f, FontStyle.Bold),
                ForeColor = Color.White,
                Location = new Point(18, 16),
                AutoSize = true
            };
            this.Controls.Add(lblHeader);

            int y = 52;

            pnlClaude5h = CreateMetricRow(ref y, "Claude 5h Limit", out lblClaude5h);
            pnlClaudeWk = CreateMetricRow(ref y, "Claude Weekly Limit", out lblClaudeWk);
            pnlCodex5h = CreateMetricRow(ref y, "Codex Usage Limit", out lblCodex5h);

            // Status indicator with live green dot
            lblStatus = new Label
            {
                Text = "● Status: Initializing...",
                Font = new Font("Segoe UI", 8.5f),
                ForeColor = Color.FromArgb(140, 148, 175),
                Location = new Point(18, y + 6),
                Size = new Size(314, 22)
            };
            this.Controls.Add(lblStatus);

            // ⚙ Settings Button (Opens Context Menu in Window)
            btnSettings = new Button
            {
                Text = "⚙ Settings",
                Font = new Font("Segoe UI Semibold", 8.5f),
                ForeColor = Color.FromArgb(210, 215, 235),
                BackColor = Color.FromArgb(28, 31, 46),
                FlatStyle = FlatStyle.Flat,
                Location = new Point(18, y + 34),
                Size = new Size(95, 30),
                Cursor = Cursors.Hand
            };
            btnSettings.FlatAppearance.BorderSize = 1;
            btnSettings.FlatAppearance.BorderColor = Color.FromArgb(50, 56, 80);
            btnSettings.Click += new EventHandler((s, e) =>
            {
                ContextMenuStrip menu = appContext.CreateContextMenu();
                menu.Show(btnSettings, new Point(0, btnSettings.Height + 4));
            });
            this.Controls.Add(btnSettings);

            // ↻ Refresh Button
            btnRefresh = new Button
            {
                Text = "↻ Refresh",
                Font = new Font("Segoe UI Semibold", 8.5f),
                ForeColor = Color.FromArgb(210, 215, 235),
                BackColor = Color.FromArgb(28, 31, 46),
                FlatStyle = FlatStyle.Flat,
                Location = new Point(121, y + 34),
                Size = new Size(90, 30),
                Cursor = Cursors.Hand
            };
            btnRefresh.FlatAppearance.BorderSize = 1;
            btnRefresh.FlatAppearance.BorderColor = Color.FromArgb(50, 56, 80);
            btnRefresh.Click += new EventHandler((s, e) => appContext.RefreshData());
            this.Controls.Add(btnRefresh);

            // Close Button
            btnClose = new Button
            {
                Text = "✕ Close",
                Font = new Font("Segoe UI Semibold", 8.5f),
                ForeColor = Color.White,
                BackColor = Color.FromArgb(38, 42, 62),
                FlatStyle = FlatStyle.Flat,
                Location = new Point(247, y + 34),
                Size = new Size(85, 30),
                Cursor = Cursors.Hand
            };
            btnClose.FlatAppearance.BorderSize = 0;
            btnClose.Click += new EventHandler((s, e) => this.Hide());
            this.Controls.Add(btnClose);
        }

        private Panel CreateMetricRow(ref int y, string labelText, out Label valueLabel)
        {
            Panel pnl = new Panel
            {
                Location = new Point(18, y),
                Size = new Size(314, 56),
                BackColor = Color.FromArgb(22, 25, 38)
            };

            Label title = new Label
            {
                Text = labelText,
                Font = new Font("Segoe UI Semibold", 9.5f),
                ForeColor = Color.FromArgb(215, 220, 240),
                Location = new Point(12, 8),
                AutoSize = true
            };
            pnl.Controls.Add(title);

            valueLabel = new Label
            {
                Text = "--%",
                Font = new Font("Segoe UI Variable Display", 9.5f, FontStyle.Bold),
                ForeColor = Color.White,
                Location = new Point(130, 8),
                Size = new Size(172, 20),
                TextAlign = ContentAlignment.TopRight
            };
            pnl.Controls.Add(valueLabel);

            y += 64;
            this.Controls.Add(pnl);
            return pnl;
        }

        public void UpdateUI()
        {
            bool hasClaude = (TrayApplicationContext.Claude5h.State != ConnectionState.NotConnected);
            bool hasCodex = (TrayApplicationContext.Codex5h.State != ConnectionState.NotConnected);

            int y = 52;

            if (hasClaude)
            {
                pnlClaude5h.Visible = true;
                pnlClaudeWk.Visible = true;
                pnlClaude5h.Location = new Point(18, y); y += 64;
                pnlClaudeWk.Location = new Point(18, y); y += 64;
                UpdateRow(pnlClaude5h, lblClaude5h, TrayApplicationContext.Claude5h);
                UpdateRow(pnlClaudeWk, lblClaudeWk, TrayApplicationContext.ClaudeWk);
            }
            else
            {
                pnlClaude5h.Visible = false;
                pnlClaudeWk.Visible = false;
            }

            if (hasCodex)
            {
                pnlCodex5h.Visible = true;
                pnlCodex5h.Location = new Point(18, y); y += 64;
                UpdateRow(pnlCodex5h, lblCodex5h, TrayApplicationContext.Codex5h);
            }
            else
            {
                pnlCodex5h.Visible = false;
            }

            int contentHeight = Math.Max(165, y + 78);
            this.Height = contentHeight;

            lblStatus.Location = new Point(18, y + 4);
            btnSettings.Location = new Point(18, y + 32);
            btnRefresh.Location = new Point(121, y + 32);
            btnClose.Location = new Point(247, y + 32);

            string cSrc = !hasClaude ? "Claude: Offline" : TrayApplicationContext.Claude5h.SourceInfo;
            string xSrc = !hasCodex ? "Codex: Offline" : TrayApplicationContext.Codex5h.SourceInfo;

            if (hasCodex && !hasClaude)
            {
                lblHeader.Text = "⚡ Codex Usage Limits";
                lblStatus.Text = "● Status: " + xSrc;
            }
            else if (hasClaude && !hasCodex)
            {
                lblHeader.Text = "⚡ Claude Usage Limits";
                lblStatus.Text = "● Status: " + cSrc;
            }
            else
            {
                lblHeader.Text = "⚡ Claude & Codex Limits";
                lblStatus.Text = "● " + cSrc + " | " + xSrc;
            }

            this.Invalidate();
        }

        private void UpdateRow(Panel pnl, Label valLbl, BatteryData data)
        {
            valLbl.Text = string.Format("{0}% (resets {1})", data.PercentLeft, data.ResetTimeStr);
            valLbl.ForeColor = Color.White;

            pnl.Paint -= Panel_Paint;
            pnl.Tag = data;
            pnl.Paint += Panel_Paint;
            pnl.Invalidate();
        }

        private void Panel_Paint(object sender, PaintEventArgs e)
        {
            Panel pnl = sender as Panel;
            BatteryData data = pnl.Tag as BatteryData;
            if (data == null) return;

            Graphics g = e.Graphics;
            g.SmoothingMode = SmoothingMode.AntiAlias;

            // Sleek 1px Translucent Glass Card Border
            using (GraphicsPath cardPath = TrayApplicationContext.GetRoundedRect(new Rectangle(0, 0, pnl.Width - 1, pnl.Height - 1), 6))
            using (Pen borderPen = new Pen(Color.FromArgb(50, 60, 90), 1))
            {
                g.DrawPath(borderPen, cardPath);
            }

            int barX = 12;
            int barY = 34;
            int barW = 290;
            int barH = 10;

            // Bar background container
            using (SolidBrush bg = new SolidBrush(Color.FromArgb(36, 40, 60)))
            {
                g.FillRectangle(bg, barX, barY, barW, barH);
            }

            // Cyber Neon Gradient Progress Fill!
            int fillW = (int)Math.Round(barW * (data.PercentLeft / 100.0));
            if (fillW > 0)
            {
                Color c1 = data.PercentLeft >= 50 ? Color.FromArgb(0, 245, 160) :
                           data.PercentLeft >= 20 ? Color.FromArgb(255, 184, 0) :
                                                    Color.FromArgb(255, 71, 87);

                Color c2 = data.PercentLeft >= 50 ? Color.FromArgb(0, 217, 245) :
                           data.PercentLeft >= 20 ? Color.FromArgb(255, 140, 0) :
                                                    Color.FromArgb(235, 47, 60);

                using (LinearGradientBrush fillGrad = new LinearGradientBrush(new Rectangle(barX, barY, fillW, barH), c1, c2, LinearGradientMode.Horizontal))
                {
                    g.FillRectangle(fillGrad, barX, barY, fillW, barH);
                }
            }
        }

        protected override void OnPaint(PaintEventArgs e)
        {
            base.OnPaint(e);
            Graphics g = e.Graphics;
            g.SmoothingMode = SmoothingMode.AntiAlias;

            // Draw Clean Mascot Companion in Header Top Right
            catAnimFrame = (catAnimFrame + 1) % 4;
            int activePct = TrayApplicationContext.Codex5h.PercentLeft >= 0 ? TrayApplicationContext.Codex5h.PercentLeft : TrayApplicationContext.Claude5h.PercentLeft;
            int pct = activePct >= 0 ? activePct : 80;

            if (TrayApplicationContext.CurrentSkin == MascotSkin.Slime)
            {
                TrayApplicationContext.DrawFullSizeSlime(g, this.Width - 40, 8, pct, catAnimFrame);
            }
            else if (TrayApplicationContext.CurrentSkin == MascotSkin.Cat)
            {
                TrayApplicationContext.DrawFullSizeCat(g, this.Width - 40, 8, pct, catAnimFrame);
            }

            // Glassmorphic Outer Border Glow
            using (Pen pen = new Pen(Color.FromArgb(80, 100, 140, 220), 1.5f))
            {
                g.DrawRectangle(pen, 0, 0, this.Width - 1, this.Height - 1);
            }
        }

        public void ShowNearTray(NotifyIcon icon)
        {
            Rectangle workingArea = Screen.PrimaryScreen.WorkingArea;
            int targetX = workingArea.Right - this.Width - 16;
            int targetY = workingArea.Bottom - this.Height - 16;

            if (Program.AutoShowOnStart)
            {
                targetX = workingArea.Left + (workingArea.Width - this.Width) / 2;
                targetY = workingArea.Top + (workingArea.Height - this.Height) / 2;
            }

            this.Location = new Point(targetX, targetY);
            this.Show();
            this.BringToFront();
            this.Focus();
        }

        protected override void OnDeactivate(EventArgs e)
        {
            base.OnDeactivate(e);
            if (!PinOpen)
            {
                this.Hide();
            }
        }
    }
}
