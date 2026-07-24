using System;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.IO;
using System.Net;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using System.Web.Script.Serialization;
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
        private static Mutex singleInstanceMutex;

        [STAThread]
        public static void Main(string[] args)
        {
            bool createdNew;
            singleInstanceMutex = new Mutex(true, @"Local\ClaudeCodexBattery.SingleInstance", out createdNew);
            if (!createdNew)
            {
                singleInstanceMutex.Dispose();
                return;
            }

            try
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
                ServicePointManager.SecurityProtocol = (SecurityProtocolType)3072; // TLS 1.2
            }
            catch { }

            Application.EnableVisualStyles();
            Application.SetCompatibleTextRenderingDefault(false);
            Application.Run(new TrayApplicationContext());
            }
            finally
            {
                try { singleInstanceMutex.ReleaseMutex(); }
                catch (ApplicationException) { }
                singleInstanceMutex.Dispose();
            }
        }
    }

    public class TrayApplicationContext : ApplicationContext
    {
        public NotifyIcon trayIcon;
        public FlyoutForm flyoutForm;
        private System.Windows.Forms.Timer refreshTimer;
        private System.Windows.Forms.Timer animTimer;
        private int animFrame = 0;
        private int refreshInProgress;

        public static BatteryData Claude5h = new BatteryData { Name = "Claude 5h", WindowLabel = "C5" };
        public static BatteryData ClaudeWk = new BatteryData { Name = "Claude Week", WindowLabel = "CW" };
        public static BatteryData FableWk = new BatteryData { Name = "Fable Week", WindowLabel = "FW" };
        public static BatteryData Codex5h = new BatteryData { Name = "Codex 5h", WindowLabel = "X5" };
        public static BatteryData CodexWk = new BatteryData { Name = "Codex Week", WindowLabel = "XW" };
        public static MascotSkin CurrentSkin = MascotSkin.Slime;

        internal TrayApplicationContext(bool skipInitialization)
        {
            // Parser tests use this constructor to avoid creating UI or making network requests.
        }

        public TrayApplicationContext()
        {
            LoadSkinPreference();

            trayIcon = new NotifyIcon
            {
                Text = "Claude & Codex Battery (Windows)\nClick for usage limits",
                Visible = true
            };

            trayIcon.Click += TrayIcon_Click;

            flyoutForm = new FlyoutForm(this);
            if (Program.PinWindow)
            {
                flyoutForm.SetPinOpen(true);
            }

            ContextMenuStrip menu = CreateContextMenu(false);
            trayIcon.ContextMenuStrip = menu;

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
                if (flyoutForm != null && flyoutForm.Visible) flyoutForm.Invalidate();
            });
            animTimer.Start();

            if (Program.AutoShowOnStart)
            {
                flyoutForm.ShowNearTray(trayIcon);
            }
        }

        public ContextMenuStrip CreateContextMenu()
        {
            return CreateContextMenu(false);
        }

        public ContextMenuStrip CreateContextMenu(bool disposeOnClose)
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
            var pinWindowItem = new ToolStripMenuItem("Keep window open");
            pinWindowItem.Checked = flyoutForm != null && flyoutForm.PinOpen;
            pinWindowItem.Click += new EventHandler((s, e) =>
            {
                bool enabled = !flyoutForm.PinOpen;
                flyoutForm.SetPinOpen(enabled);
                pinWindowItem.Checked = enabled;
            });
            menu.Items.Add(pinWindowItem);

            var alwaysOnTopItem = new ToolStripMenuItem("Always on top");
            alwaysOnTopItem.Checked = flyoutForm != null && flyoutForm.AlwaysOnTopEnabled;
            alwaysOnTopItem.Click += new EventHandler((s, e) =>
            {
                bool enabled = !flyoutForm.AlwaysOnTopEnabled;
                flyoutForm.SetAlwaysOnTop(enabled);
                alwaysOnTopItem.Checked = enabled;
            });
            menu.Items.Add(alwaysOnTopItem);

            menu.Items.Add("-");
            var autoStartItem = new ToolStripMenuItem("Start at Windows Login");
            autoStartItem.Checked = IsAutoStartEnabled();
            autoStartItem.Click += new EventHandler((s, e) =>
            {
                bool enabled = !IsAutoStartEnabled();
                SetAutoStart(enabled);
                autoStartItem.Checked = enabled;
            });
            menu.Items.Add(autoStartItem);
            menu.Items.Add("-");
            menu.Items.Add("Exit", null, new EventHandler((s, e) => ExitApp()));
            if (disposeOnClose)
            {
                menu.Closed += new ToolStripDropDownClosedEventHandler((s, e) => menu.Dispose());
            }
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
            if (!TryBeginRefresh()) return;

            Task.Run(new Action(() =>
            {
                try
                {
                    FetchClaudeUsage();
                    FetchCodexUsage();

                    if (flyoutForm != null && !flyoutForm.IsDisposed && flyoutForm.IsHandleCreated)
                    {
                        flyoutForm.Invoke(new Action(() =>
                        {
                            UpdateTrayIcon();
                            flyoutForm.UpdateUI();
                        }));
                    }
                }
                catch (InvalidOperationException) { }
                finally { EndRefresh(); }
            }));
        }

        internal bool TryBeginRefresh()
        {
            return Interlocked.CompareExchange(ref refreshInProgress, 1, 0) == 0;
        }

        internal void EndRefresh()
        {
            Interlocked.Exchange(ref refreshInProgress, 0);
        }

        private void UpdateTrayIcon()
        {
            bool hasClaude = (Claude5h.State != ConnectionState.NotConnected || ClaudeWk.State != ConnectionState.NotConnected);
            bool hasCodex = (Codex5h.State != ConnectionState.NotConnected || CodexWk.State != ConnectionState.NotConnected);
            int activePct = Codex5h.PercentLeft >= 0 ? Codex5h.PercentLeft :
                            CodexWk.PercentLeft >= 0 ? CodexWk.PercentLeft :
                            Claude5h.PercentLeft >= 0 ? Claude5h.PercentLeft : ClaudeWk.PercentLeft;

            StringBuilder tooltip = new StringBuilder();
            if (hasCodex)
            {
                BatteryData codexTip = Codex5h.PercentLeft >= 0 ? Codex5h : CodexWk;
                tooltip.AppendLine(string.Format("Codex: {0}% left (resets {1})", codexTip.PercentLeft, codexTip.ResetTimeStr));
            }
            if (hasClaude)
            {
                BatteryData claudeTip = Claude5h.PercentLeft >= 0 ? Claude5h : ClaudeWk;
                tooltip.AppendLine(string.Format("Claude: {0}% left (resets {1})", claudeTip.PercentLeft, claudeTip.ResetTimeStr));
            }
            if (!hasCodex && !hasClaude)
            {
                tooltip.AppendLine("Claude & Codex: Not Connected");
            }
            tooltip.Append("Click to open dashboard");

            string tipStr = tooltip.ToString();
            // NotifyIcon.Text is limited to 63 characters on .NET Framework/Windows.
            // Both services together can exceed it and otherwise crash during startup.
            if (tipStr.Length > 63) tipStr = tipStr.Substring(0, 63);
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
                        int claudePct = Claude5h.PercentLeft >= 0 ? Claude5h.PercentLeft : ClaudeWk.PercentLeft;
                        int codexPct = Codex5h.PercentLeft >= 0 ? Codex5h.PercentLeft : CodexWk.PercentLeft;
                        DrawGauge(g, 3, 3, 11, 26, claudePct, "C");
                        DrawGauge(g, 18, 3, 11, 26, codexPct, "X");
                    }
                    else
                    {
                        int pct = activePct;

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
                        Icon previous = trayIcon.Icon;
                        trayIcon.Icon = cloned;
                        trayIcon.Visible = true;
                        if (previous != null) previous.Dispose();
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
            int moodPct = pct < 0 ? 50 : pct;
            Color slimeColor = pct < 0 ? Color.FromArgb(125, 130, 145) :
                               pct >= 50 ? Color.FromArgb(46, 204, 113) :
                               pct >= 20 ? Color.FromArgb(241, 196, 15) : Color.FromArgb(231, 76, 60);

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

                if (moodPct >= 50)
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
                else if (moodPct >= 20)
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
            int moodPct = pct < 0 ? 50 : pct;
            Color catBody = pct < 0 ? Color.FromArgb(150, 154, 166) : Color.FromArgb(250, 245, 240);
            Color pink = Color.FromArgb(255, 130, 170);
            Color eyeCol = Color.FromArgb(25, 25, 35);

            int bounceY = (frame % 2 == 1 && moodPct >= 50) ? -1 : 0;

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

                if (moodPct >= 50)
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
                else if (moodPct >= 20)
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

        private static readonly JavaScriptSerializer Json = new JavaScriptSerializer();

        private void FetchClaudeUsage()
        {
            string userDir = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
            string stateDir = Path.Combine(userDir, ".claude", "swiftbar");
            string credFile = Path.Combine(userDir, ".claude", ".credentials.json");
            string cacheFile = Path.Combine(stateDir, ".claude-usage-windows.json");
            string noLiveFile = Path.Combine(stateDir, ".no-live");
            bool success = false;

            SetUnavailable(Claude5h, "Not connected");
            SetUnavailable(ClaudeWk, "Not connected");
            SetUnavailable(FableWk, "Not connected");

            if (!File.Exists(noLiveFile) && File.Exists(credFile))
            {
                try
                {
                    IDictionary<string, object> credentials = ParseObject(File.ReadAllText(credFile));
                    string token = GetString(GetValue(GetObject(credentials, "claudeAiOauth"), "accessToken"));
                    if (!string.IsNullOrEmpty(token))
                    {
                        HttpWebRequest req = CreateRequest("https://api.anthropic.com/api/oauth/usage", token);
                        req.Headers.Add("anthropic-beta", "oauth-2025-04-20");
                        using (WebResponse resp = req.GetResponse())
                        using (StreamReader sr = new StreamReader(resp.GetResponseStream()))
                        {
                            string json = sr.ReadToEnd();
                            success = ParseClaudeJson(json, ConnectionState.Connected, "Live Anthropic OAuth API");
                            if (success)
                            {
                                Directory.CreateDirectory(stateDir);
                                WriteCacheAtomic(cacheFile, json);
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
                    success = ParseClaudeJson(File.ReadAllText(cacheFile), ConnectionState.OfflineCached, "Cached Anthropic response");
                }
                catch { }
            }
        }

        internal bool ParseClaudeJson(string json, ConnectionState state, string source)
        {
            IDictionary<string, object> root = ParseObject(json);
            bool fiveHour = ApplyUsageWindow(Claude5h, GetObject(root, "five_hour"), "utilization", "resets_at", state, source);
            bool weekly = ApplyUsageWindow(ClaudeWk, GetObject(root, "seven_day"), "utilization", "resets_at", state, source);
            bool fableWeekly = ParseClaudeScopedLimit(root, "Fable", FableWk, state, source);
            return fiveHour || weekly || fableWeekly;
        }

        private bool ParseClaudeScopedLimit(IDictionary<string, object> root, string modelName,
            BatteryData target, ConnectionState state, string source)
        {
            object[] limits = GetValue(root, "limits") as object[];
            if (limits == null) return false;

            for (int i = 0; i < limits.Length; i++)
            {
                IDictionary<string, object> limit = limits[i] as IDictionary<string, object>;
                if (limit == null || !string.Equals(GetString(GetValue(limit, "kind")), "weekly_scoped", StringComparison.OrdinalIgnoreCase)) continue;

                IDictionary<string, object> scope = GetObject(limit, "scope");
                IDictionary<string, object> model = GetObject(scope, "model");
                string displayName = GetString(GetValue(model, "display_name"));
                if (!string.Equals(displayName, modelName, StringComparison.OrdinalIgnoreCase)) continue;

                return ApplyUsageWindow(target, limit, "percent", "resets_at", state, source);
            }
            return false;
        }

        private void FetchCodexUsage()
        {
            string userDir = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
            string stateDir = Path.Combine(userDir, ".claude", "swiftbar");
            string authFile = Path.Combine(userDir, ".codex", "auth.json");
            string cacheFile = Path.Combine(stateDir, ".codex-usage-windows.json");
            string sessionsDir = Path.Combine(userDir, ".codex", "sessions");
            string noLiveFile = Path.Combine(stateDir, ".no-live");
            bool success = false;

            SetUnavailable(Codex5h, "Not connected");
            SetUnavailable(CodexWk, "Not connected");

            if (!File.Exists(noLiveFile) && File.Exists(authFile))
            {
                try
                {
                    IDictionary<string, object> auth = ParseObject(File.ReadAllText(authFile));
                    IDictionary<string, object> tokens = GetObject(auth, "tokens");
                    string token = GetString(GetValue(tokens, "access_token"));
                    string accountId = GetString(GetValue(tokens, "account_id"));
                    if (!string.IsNullOrEmpty(token))
                    {
                        HttpWebRequest req = CreateRequest("https://chatgpt.com/backend-api/wham/usage", token);
                        req.UserAgent = "codex-cli";
                        if (!string.IsNullOrEmpty(accountId)) req.Headers.Add("ChatGPT-Account-Id", accountId);
                        using (WebResponse resp = req.GetResponse())
                        using (StreamReader sr = new StreamReader(resp.GetResponseStream()))
                        {
                            string json = sr.ReadToEnd();
                            success = ParseCodexLiveJson(json, ConnectionState.Connected, "Live ChatGPT usage API");
                            if (success)
                            {
                                Directory.CreateDirectory(stateDir);
                                WriteCacheAtomic(cacheFile, json);
                            }
                        }
                    }
                }
                catch { }
            }

            if (!success) success = ReadCodexSessionFallback(sessionsDir);

            if (!success && File.Exists(cacheFile))
            {
                try
                {
                    success = ParseCodexLiveJson(File.ReadAllText(cacheFile), ConnectionState.OfflineCached, "Cached ChatGPT response");
                }
                catch { }
            }
        }

        private bool ReadCodexSessionFallback(string sessionsDir)
        {
            if (!Directory.Exists(sessionsDir)) return false;
            try
            {
                FileInfo[] files = new DirectoryInfo(sessionsDir).GetFiles("*.jsonl", SearchOption.AllDirectories);
                Array.Sort(files, delegate(FileInfo a, FileInfo b) { return b.LastWriteTimeUtc.CompareTo(a.LastWriteTimeUtc); });
                int fileCount = Math.Min(8, files.Length);
                for (int f = 0; f < fileCount; f++)
                {
                    string[] lines = File.ReadAllLines(files[f].FullName);
                    for (int i = lines.Length - 1; i >= 0; i--)
                    {
                        if (!lines[i].Contains("rate_limits")) continue;
                        try
                        {
                            IDictionary<string, object> root = ParseObject(lines[i]);
                            IDictionary<string, object> payload = GetObject(root, "payload");
                            IDictionary<string, object> limits = GetObject(payload, "rate_limits") ?? GetObject(root, "rate_limits");
                            if (limits == null) continue;
                            string source = "Session log (" + files[f].LastWriteTime.ToString("g") + ")";
                            bool parsed = ParseCodexWindows(GetObject(limits, "primary"), GetObject(limits, "secondary"),
                                "window_minutes", "resets_at", ConnectionState.OfflineCached, source);
                            if (parsed) return true;
                        }
                        catch { }
                    }
                }
            }
            catch { }
            return false;
        }

        internal bool ParseCodexLiveJson(string json, ConnectionState state, string source)
        {
            IDictionary<string, object> root = ParseObject(json);
            IDictionary<string, object> limits = GetObject(root, "rate_limit");
            if (limits == null) return false;
            return ParseCodexWindows(GetObject(limits, "primary_window"), GetObject(limits, "secondary_window"),
                "limit_window_seconds", "reset_at", state, source);
        }

        private bool ParseCodexWindows(IDictionary<string, object> first, IDictionary<string, object> second,
            string durationKey, string resetKey, ConnectionState state, string source)
        {
            bool parsed = false;
            IDictionary<string, object>[] windows = new IDictionary<string, object>[] { first, second };
            for (int i = 0; i < windows.Length; i++)
            {
                IDictionary<string, object> window = windows[i];
                if (window == null) continue;
                double? duration = GetNumber(GetValue(window, durationKey));
                bool shortWindow;
                if (duration.HasValue)
                {
                    double seconds = durationKey == "window_minutes" ? duration.Value * 60.0 : duration.Value;
                    shortWindow = seconds <= 6 * 60 * 60;
                }
                else
                {
                    shortWindow = i == 0;
                }
                BatteryData target = shortWindow ? Codex5h : CodexWk;
                parsed = ApplyUsageWindow(target, window, "used_percent", resetKey, state, source) || parsed;
            }
            return parsed;
        }

        private HttpWebRequest CreateRequest(string url, string token)
        {
            HttpWebRequest req = (HttpWebRequest)WebRequest.Create(url);
            req.Headers.Add("Authorization", "Bearer " + token);
            req.UserAgent = "claude-codex-battery-win/1.0";
            req.Timeout = 5000;
            req.ReadWriteTimeout = 5000;
            return req;
        }

        private bool ApplyUsageWindow(BatteryData target, IDictionary<string, object> window, string usedKey,
            string resetKey, ConnectionState state, string source)
        {
            if (window == null) return false;
            double? used = GetNumber(GetValue(window, usedKey));
            if (!used.HasValue) return false;
            target.PercentLeft = Math.Max(0, Math.Min(100, (int)Math.Round(100.0 - used.Value)));
            target.ResetTimeStr = FormatReset(GetValue(window, resetKey));
            target.State = state;
            target.SourceInfo = source;
            target.LastUpdated = DateTime.Now;
            return true;
        }

        private void SetUnavailable(BatteryData data, string source)
        {
            data.PercentLeft = -1;
            data.ResetTimeStr = "Unavailable";
            data.State = ConnectionState.NotConnected;
            data.SourceInfo = source;
        }

        private string FormatReset(object value)
        {
            if (value == null) return "unknown";
            DateTimeOffset resetAt;
            string text = GetString(value);
            if (!string.IsNullOrEmpty(text) && DateTimeOffset.TryParse(text, out resetAt))
            {
                return FormatDuration(resetAt.UtcDateTime - DateTime.UtcNow);
            }
            double? epoch = GetNumber(value);
            if (epoch.HasValue)
            {
                try
                {
                    DateTime utc = new DateTime(1970, 1, 1, 0, 0, 0, DateTimeKind.Utc).AddSeconds(epoch.Value);
                    return FormatDuration(utc - DateTime.UtcNow);
                }
                catch { }
            }
            return "unknown";
        }

        private string FormatDuration(TimeSpan remaining)
        {
            if (remaining.TotalSeconds <= 0) return "now";
            if (remaining.Days > 0) return string.Format("{0}d {1}h", remaining.Days, remaining.Hours);
            if (remaining.Hours > 0) return string.Format("{0}h {1}m", remaining.Hours, remaining.Minutes);
            return string.Format("{0}m", Math.Max(1, remaining.Minutes));
        }

        private IDictionary<string, object> ParseObject(string json)
        {
            return Json.DeserializeObject(json) as IDictionary<string, object>;
        }

        private IDictionary<string, object> GetObject(IDictionary<string, object> obj, string key)
        {
            return GetValue(obj, key) as IDictionary<string, object>;
        }

        private object GetValue(IDictionary<string, object> obj, string key)
        {
            if (obj == null || !obj.ContainsKey(key)) return null;
            return obj[key];
        }

        private string GetString(object value)
        {
            return value as string;
        }

        private double? GetNumber(object value)
        {
            if (value == null) return null;
            try { return Convert.ToDouble(value, System.Globalization.CultureInfo.InvariantCulture); }
            catch { return null; }
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
            Icon currentIcon = trayIcon.Icon;
            trayIcon.Icon = null;
            if (currentIcon != null) currentIcon.Dispose();
            trayIcon.Dispose();
            Application.Exit();
        }

        internal static void WriteCacheAtomic(string path, string content)
        {
            string directory = Path.GetDirectoryName(path);
            if (!string.IsNullOrEmpty(directory)) Directory.CreateDirectory(directory);

            string tempPath = path + ".tmp." + Guid.NewGuid().ToString("N");
            try
            {
                File.WriteAllText(tempPath, content, new UTF8Encoding(false));
                if (File.Exists(path))
                {
                    File.Replace(tempPath, path, null, true);
                }
                else
                {
                    File.Move(tempPath, path);
                }
            }
            finally
            {
                if (File.Exists(tempPath)) File.Delete(tempPath);
            }
        }
    }

    public class FlyoutForm : Form
    {
        [DllImport("dwmapi.dll")]
        private static extern int DwmSetWindowAttribute(IntPtr hwnd, int attr, ref int attrValue, int attrSize);

        [DllImport("user32.dll")]
        private static extern bool ReleaseCapture();

        [DllImport("user32.dll")]
        private static extern IntPtr SendMessage(IntPtr hwnd, int msg, IntPtr wParam, IntPtr lParam);

        private const int DWMWA_WINDOW_CORNER_PREFERENCE = 33;
        private const int DWMWCP_ROUND = 2; // Win11 Glass Round Corners
        private const int WM_NCLBUTTONDOWN = 0x00A1;
        private const int HTCAPTION = 2;

        private TrayApplicationContext appContext;
        private Label lblHeader;
        private Panel pnlClaude5h, pnlClaudeWk, pnlFableWk, pnlCodex5h, pnlCodexWk;
        private Label lblClaude5h, lblClaudeWk, lblFableWk, lblCodex5h, lblCodexWk;
        private Label lblStatus;
        private Button btnRefresh, btnSettings, btnClose;
        private ContextMenuStrip settingsMenu;
        private ToolTip headerToolTip;
        public bool PinOpen = false;
        public bool AlwaysOnTopEnabled { get; private set; }
        private int catAnimFrame;
        private readonly string windowSettingsFile;
        private readonly string windowPositionFile;

        public FlyoutForm(TrayApplicationContext ctx)
        {
            appContext = ctx;
            string stateDir = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".claude", "swiftbar");
            windowSettingsFile = Path.Combine(stateDir, ".windows-window-settings");
            windowPositionFile = Path.Combine(stateDir, ".windows-window-position");

            this.FormBorderStyle = FormBorderStyle.None;
            this.Text = "Claude & Codex Battery";
            this.AccessibleName = "Claude and Codex usage limits";
            this.StartPosition = FormStartPosition.Manual;
            this.ShowInTaskbar = Program.AutoShowOnStart;
            this.AlwaysOnTopEnabled = true;
            this.TopMost = true;
            this.Size = new Size(270, 205);
            this.BackColor = Color.FromArgb(15, 17, 26); // Deep Obsidian Glass Backdrop
            this.DoubleBuffered = true;
            LoadWindowSettings();
            this.MouseDown += new MouseEventHandler(BeginWindowDrag);

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
                Font = new Font("Segoe UI Variable Display", 9.5f, FontStyle.Bold),
                ForeColor = Color.White,
                Location = new Point(10, 9),
                AutoSize = true
            };
            lblHeader.Cursor = Cursors.SizeAll;
            lblHeader.MouseDown += new MouseEventHandler(BeginWindowDrag);
            this.Controls.Add(lblHeader);

            int y = 36;

            pnlClaude5h = CreateMetricRow(ref y, "Claude 5h", out lblClaude5h);
            pnlClaudeWk = CreateMetricRow(ref y, "Claude Week", out lblClaudeWk);
            pnlFableWk = CreateMetricRow(ref y, "Fable Week", out lblFableWk);
            pnlCodex5h = CreateMetricRow(ref y, "Codex 5h", out lblCodex5h);
            pnlCodexWk = CreateMetricRow(ref y, "Codex Week", out lblCodexWk);

            // Status indicator with live green dot
            lblStatus = new Label
            {
                Text = "● Status: Initializing...",
                Font = new Font("Segoe UI", 7.5f),
                ForeColor = Color.FromArgb(140, 148, 175),
                Location = new Point(12, y + 2),
                Size = new Size(296, 16),
                AutoEllipsis = true,
                Visible = false
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
            settingsMenu = appContext.CreateContextMenu(false);
            btnSettings.Click += new EventHandler((s, e) =>
            {
                settingsMenu.Show(btnSettings, new Point(0, btnSettings.Height + 4));
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
            ConfigureCompactHeaderActions();
        }

        private void ConfigureCompactHeaderActions()
        {
            headerToolTip = new ToolTip();

            btnSettings.Text = "⚙";
            btnSettings.AccessibleName = "Settings";
            btnSettings.Font = new Font("Segoe UI Symbol", 9.5f);
            btnSettings.TextAlign = ContentAlignment.MiddleCenter;
            btnSettings.Padding = new Padding(0);
            btnSettings.Location = new Point(182, 6);
            btnSettings.Size = new Size(24, 24);
            btnSettings.FlatAppearance.BorderSize = 0;
            DrawCenteredHeaderIcon(btnSettings, "⚙");
            headerToolTip.SetToolTip(btnSettings, "Settings");

            btnRefresh.Text = "↻";
            btnRefresh.AccessibleName = "Refresh usage";
            btnRefresh.Font = new Font("Segoe UI Symbol", 10f);
            btnRefresh.TextAlign = ContentAlignment.MiddleCenter;
            btnRefresh.Padding = new Padding(0);
            btnRefresh.Location = new Point(210, 6);
            btnRefresh.Size = new Size(24, 24);
            btnRefresh.FlatAppearance.BorderSize = 0;
            DrawCenteredHeaderIcon(btnRefresh, "↻");
            headerToolTip.SetToolTip(btnRefresh, "Refresh usage");

            btnClose.Text = "✕";
            btnClose.AccessibleName = "Close dashboard";
            btnClose.Font = new Font("Segoe UI Symbol", 10f);
            btnClose.TextAlign = ContentAlignment.MiddleCenter;
            btnClose.Padding = new Padding(0);
            btnClose.Location = new Point(238, 6);
            btnClose.Size = new Size(24, 24);
            btnClose.FlatAppearance.BorderSize = 0;
            DrawCenteredHeaderIcon(btnClose, "✕");
            headerToolTip.SetToolTip(btnClose, "Close dashboard");
        }

        private void DrawCenteredHeaderIcon(Button button, string glyph)
        {
            button.Text = string.Empty;
            button.Paint += new PaintEventHandler((s, e) =>
            {
                TextRenderer.DrawText(e.Graphics, glyph, button.Font, button.ClientRectangle, button.ForeColor,
                    TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter |
                    TextFormatFlags.NoPadding | TextFormatFlags.SingleLine);
            });
        }

        private Panel CreateMetricRow(ref int y, string labelText, out Label valueLabel)
        {
            Panel pnl = new Panel
            {
                Location = new Point(10, y),
                Size = new Size(250, 34),
                BackColor = Color.FromArgb(22, 25, 38)
            };

            Label title = new Label
            {
                Text = labelText,
                Font = new Font("Segoe UI Semibold", 8.5f),
                ForeColor = Color.FromArgb(215, 220, 240),
                Location = new Point(8, 3),
                AutoSize = true
            };
            pnl.Controls.Add(title);

            valueLabel = new Label
            {
                Text = "--%",
                Font = new Font("Segoe UI Variable Display", 8.5f, FontStyle.Bold),
                ForeColor = Color.White,
                Location = new Point(88, 3),
                Size = new Size(154, 17),
                TextAlign = ContentAlignment.TopRight
            };
            pnl.Controls.Add(valueLabel);

            y += 39;
            this.Controls.Add(pnl);
            return pnl;
        }

        public void UpdateUI()
        {
            bool hasClaude5h = TrayApplicationContext.Claude5h.State != ConnectionState.NotConnected;
            bool hasClaudeWk = TrayApplicationContext.ClaudeWk.State != ConnectionState.NotConnected;
            bool hasFableWk = TrayApplicationContext.FableWk.State != ConnectionState.NotConnected;
            bool hasCodex5h = TrayApplicationContext.Codex5h.State != ConnectionState.NotConnected;
            bool hasCodexWk = TrayApplicationContext.CodexWk.State != ConnectionState.NotConnected;
            bool hasClaude = hasClaude5h || hasClaudeWk || hasFableWk;
            bool hasCodex = hasCodex5h || hasCodexWk;

            int y = 36;

            if (hasClaude)
            {
                pnlClaude5h.Visible = hasClaude5h;
                pnlClaudeWk.Visible = hasClaudeWk;
                pnlFableWk.Visible = hasFableWk;
                if (hasClaude5h)
                {
                    pnlClaude5h.Location = new Point(10, y); y += 39;
                    UpdateRow(pnlClaude5h, lblClaude5h, TrayApplicationContext.Claude5h);
                }
                if (hasClaudeWk)
                {
                    pnlClaudeWk.Location = new Point(10, y); y += 39;
                    UpdateRow(pnlClaudeWk, lblClaudeWk, TrayApplicationContext.ClaudeWk);
                }
                if (hasFableWk)
                {
                    pnlFableWk.Location = new Point(10, y); y += 39;
                    UpdateRow(pnlFableWk, lblFableWk, TrayApplicationContext.FableWk);
                }
            }
            else
            {
                pnlClaude5h.Visible = false;
                pnlClaudeWk.Visible = false;
                pnlFableWk.Visible = false;
            }

            if (hasCodex)
            {
                pnlCodex5h.Visible = hasCodex5h;
                pnlCodexWk.Visible = hasCodexWk;
                if (hasCodex5h)
                {
                    pnlCodex5h.Location = new Point(10, y); y += 39;
                    UpdateRow(pnlCodex5h, lblCodex5h, TrayApplicationContext.Codex5h);
                }
                if (hasCodexWk)
                {
                    pnlCodexWk.Location = new Point(10, y); y += 39;
                    UpdateRow(pnlCodexWk, lblCodexWk, TrayApplicationContext.CodexWk);
                }
            }
            else
            {
                pnlCodex5h.Visible = false;
                pnlCodexWk.Visible = false;
            }

            int contentHeight = Math.Max(80, y + 6);
            this.Height = contentHeight;
            EnsureVisibleAfterResize();

            lblStatus.Location = new Point(10, y);

            string cSrc = !hasClaude ? "Claude: Offline" : (hasClaude5h ? TrayApplicationContext.Claude5h.SourceInfo :
                (hasClaudeWk ? TrayApplicationContext.ClaudeWk.SourceInfo : TrayApplicationContext.FableWk.SourceInfo));
            string xSrc = !hasCodex ? "Codex: Offline" : (hasCodex5h ? TrayApplicationContext.Codex5h.SourceInfo : TrayApplicationContext.CodexWk.SourceInfo);

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

            lblHeader.Text = hasCodex && hasClaude ? "⚡ Claude · Codex" :
                (hasClaude ? "⚡ Claude Limits" : "⚡ Codex Limits");
            this.Invalidate();
        }

        private void UpdateRow(Panel pnl, Label valLbl, BatteryData data)
        {
            valLbl.Text = string.Format("{0}% · {1}", data.PercentLeft, data.ResetTimeStr);
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

            int barX = 8;
            int barY = 25;
            int barW = 234;
            int barH = 4;

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

            catAnimFrame = (catAnimFrame + 1) % 4;
            int activePct = TrayApplicationContext.Codex5h.PercentLeft >= 0 ? TrayApplicationContext.Codex5h.PercentLeft :
                            TrayApplicationContext.CodexWk.PercentLeft >= 0 ? TrayApplicationContext.CodexWk.PercentLeft :
                            TrayApplicationContext.Claude5h.PercentLeft >= 0 ? TrayApplicationContext.Claude5h.PercentLeft :
                            TrayApplicationContext.ClaudeWk.PercentLeft >= 0 ? TrayApplicationContext.ClaudeWk.PercentLeft :
                            TrayApplicationContext.FableWk.PercentLeft;

            if (TrayApplicationContext.CurrentSkin == MascotSkin.Slime)
            {
                TrayApplicationContext.DrawFullSizeSlime(g, 132, 2, activePct, catAnimFrame);
            }
            else if (TrayApplicationContext.CurrentSkin == MascotSkin.Cat)
            {
                TrayApplicationContext.DrawFullSizeCat(g, 132, 2, activePct, catAnimFrame);
            }

            // Glassmorphic Outer Border Glow
            using (Pen pen = new Pen(Color.FromArgb(80, 100, 140, 220), 1.5f))
            {
                g.DrawRectangle(pen, 0, 0, this.Width - 1, this.Height - 1);
            }
        }

        private void EnsureVisibleAfterResize()
        {
            Rectangle workingArea = Screen.FromRectangle(this.Bounds).WorkingArea;
            int x = Math.Max(workingArea.Left, Math.Min(this.Left, workingArea.Right - this.Width));
            int y = Math.Max(workingArea.Top, Math.Min(this.Top, workingArea.Bottom - this.Height));
            if (x != this.Left || y != this.Top) this.Location = new Point(x, y);
        }

        public void SetPinOpen(bool enabled)
        {
            PinOpen = enabled;
            SaveWindowSettings();
        }

        public void SetAlwaysOnTop(bool enabled)
        {
            AlwaysOnTopEnabled = enabled;
            this.TopMost = enabled;
            SaveWindowSettings();
        }

        private void BeginWindowDrag(object sender, MouseEventArgs e)
        {
            if (e.Button != MouseButtons.Left) return;
            ReleaseCapture();
            SendMessage(this.Handle, WM_NCLBUTTONDOWN, new IntPtr(HTCAPTION), IntPtr.Zero);
            SaveWindowPosition();
        }

        private void LoadWindowSettings()
        {
            try
            {
                if (!File.Exists(windowSettingsFile)) return;
                string[] lines = File.ReadAllLines(windowSettingsFile);
                foreach (string line in lines)
                {
                    string[] parts = line.Split(new char[] { '=' }, 2);
                    if (parts.Length != 2) continue;
                    bool value;
                    if (!bool.TryParse(parts[1], out value)) continue;
                    if (parts[0] == "pinOpen") PinOpen = value;
                    if (parts[0] == "alwaysOnTop")
                    {
                        AlwaysOnTopEnabled = value;
                        this.TopMost = value;
                    }
                }
            }
            catch { }
        }

        private void SaveWindowSettings()
        {
            try
            {
                Directory.CreateDirectory(Path.GetDirectoryName(windowSettingsFile));
                File.WriteAllLines(windowSettingsFile, new string[]
                {
                    "pinOpen=" + PinOpen.ToString(),
                    "alwaysOnTop=" + AlwaysOnTopEnabled.ToString()
                });
            }
            catch { }
        }

        private Point? LoadWindowPosition()
        {
            try
            {
                if (!File.Exists(windowPositionFile)) return null;
                string[] parts = File.ReadAllText(windowPositionFile).Trim().Split(',');
                int x, y;
                if (parts.Length != 2 || !int.TryParse(parts[0], out x) || !int.TryParse(parts[1], out y)) return null;
                Rectangle candidate = new Rectangle(x, y, this.Width, this.Height);
                foreach (Screen screen in Screen.AllScreens)
                {
                    if (screen.WorkingArea.IntersectsWith(candidate)) return new Point(x, y);
                }
            }
            catch { }
            return null;
        }

        private void SaveWindowPosition()
        {
            try
            {
                Directory.CreateDirectory(Path.GetDirectoryName(windowPositionFile));
                File.WriteAllText(windowPositionFile, this.Left + "," + this.Top);
            }
            catch { }
        }

        public void ShowNearTray(NotifyIcon icon)
        {
            Point? savedPosition = LoadWindowPosition();
            if (savedPosition.HasValue)
            {
                this.Location = savedPosition.Value;
            }
            else
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
            }
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

        protected override void Dispose(bool disposing)
        {
            if (disposing && settingsMenu != null)
            {
                settingsMenu.Dispose();
                settingsMenu = null;
            }
            if (disposing && headerToolTip != null)
            {
                headerToolTip.Dispose();
                headerToolTip = null;
            }
            base.Dispose(disposing);
        }
    }
}
