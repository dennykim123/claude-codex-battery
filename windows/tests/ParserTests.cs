using System;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Threading;
using System.Windows.Forms;
using ClaudeCodexBattery;

public static class ParserTests
{
    private static int failures;

    [STAThread]
    public static int Main()
    {
        Application.SetUnhandledExceptionMode(UnhandledExceptionMode.ThrowException);
        Console.WriteLine("ParserTests: start | apartment=" + Thread.CurrentThread.GetApartmentState());
        try
        {
            return RunTests();
        }
        catch (Exception ex)
        {
            Console.Error.WriteLine("ParserTests: unhandled " + ex.GetType().FullName + ": " + ex.Message);
            if (!string.IsNullOrEmpty(ex.StackTrace)) Console.Error.WriteLine(ex.StackTrace);
            return 1;
        }
    }

    private static int RunTests()
    {
        TrayApplicationContext parser = new TrayApplicationContext(true);

        AssertFalse(parser.ParseClaudeJson("{}", ConnectionState.Connected, "test"), "Claude rejects missing windows");
        AssertTrue(parser.ParseClaudeJson(
            "{\"five_hour\":{\"utilization\":23.4,\"resets_at\":\"2099-01-01T00:00:00Z\"}," +
            "\"seven_day\":{\"utilization\":70,\"resets_at\":\"2099-01-02T00:00:00Z\"}}",
            ConnectionState.Connected, "test"), "Claude parses valid response");
        AssertEqual(77, TrayApplicationContext.Claude5h.PercentLeft, "Claude 5h remaining");
        AssertEqual(30, TrayApplicationContext.ClaudeWk.PercentLeft, "Claude weekly remaining");

        AssertFalse(parser.ParseCodexLiveJson("{}", ConnectionState.Connected, "test"), "Codex rejects missing rate_limit");
        AssertTrue(parser.ParseCodexLiveJson(
            "{\"rate_limit\":{\"primary_window\":{\"used_percent\":12,\"limit_window_seconds\":18000,\"reset_at\":4102444800}," +
            "\"secondary_window\":{\"used_percent\":34,\"limit_window_seconds\":604800,\"reset_at\":4102444800}}}",
            ConnectionState.Connected, "test"), "Codex parses valid response");
        AssertEqual(88, TrayApplicationContext.Codex5h.PercentLeft, "Codex 5h remaining");
        AssertEqual(66, TrayApplicationContext.CodexWk.PercentLeft, "Codex weekly remaining");

        ResetUsage();
        AssertTrue(parser.ParseClaudeJson(
            "{\"seven_day\":{\"utilization\":100,\"resets_at\":\"2099-01-02T00:00:00Z\"}}",
            ConnectionState.OfflineCached, "test"), "Claude accepts a weekly-only response");
        AssertEqual(-1, TrayApplicationContext.Claude5h.PercentLeft, "Claude missing 5h stays unavailable");
        AssertEqual(0, TrayApplicationContext.ClaudeWk.PercentLeft, "Claude 100% used clamps to zero remaining");

        ResetUsage();
        AssertTrue(parser.ParseCodexLiveJson(
            "{\"rate_limit\":{\"primary_window\":{\"used_percent\":44.6,\"limit_window_seconds\":604800,\"reset_at\":4102444800}," +
            "\"secondary_window\":{\"used_percent\":5,\"limit_window_seconds\":18000,\"reset_at\":4102444800}}}",
            ConnectionState.Connected, "test"), "Codex classifies reversed API window order by duration");
        AssertEqual(95, TrayApplicationContext.Codex5h.PercentLeft, "Codex reversed 5h remaining");
        AssertEqual(55, TrayApplicationContext.CodexWk.PercentLeft, "Codex decimal weekly remaining");

        ResetUsage();
        AssertFalse(parser.ParseCodexLiveJson(
            "{\"rate_limit\":{\"primary_window\":{\"limit_window_seconds\":18000}}}",
            ConnectionState.Connected, "test"), "Codex rejects windows without percentages");
        AssertEqual(-1, TrayApplicationContext.Codex5h.PercentLeft, "Codex never invents a missing percentage");

        ResetUsage();
        AssertTrue(parser.ParseClaudeJson(
            "{\"five_hour\":{\"utilization\":-5,\"extra\":{\"future\":true}}," +
            "\"seven_day\":{\"utilization\":150}}",
            ConnectionState.Connected, "test"), "Claude ignores unknown fields and accepts numeric boundaries");
        AssertEqual(100, TrayApplicationContext.Claude5h.PercentLeft, "Claude negative usage clamps to 100 remaining");
        AssertEqual(0, TrayApplicationContext.ClaudeWk.PercentLeft, "Claude over-100 usage clamps to zero remaining");
        AssertEqual("unknown", TrayApplicationContext.Claude5h.ResetTimeStr, "Claude missing reset is explicit");

        ResetUsage();
        AssertTrue(parser.ParseClaudeJson(
            "{\"five_hour\":{\"utilization\":10},\"limits\":[" +
            "{\"kind\":\"weekly_scoped\",\"percent\":91,\"resets_at\":\"2099-01-02T00:00:00Z\"," +
            "\"scope\":{\"model\":{\"display_name\":\"Fable\"}}}]}",
            ConnectionState.Connected, "test"), "Claude parses a Fable scoped weekly limit");
        AssertEqual(9, TrayApplicationContext.FableWk.PercentLeft, "Fable weekly remaining");

        ResetUsage();
        AssertTrue(parser.ParseClaudeJson(
            "{\"five_hour\":{\"utilization\":10},\"limits\":[" +
            "{\"kind\":\"weekly_scoped\",\"percent\":50,\"scope\":{\"model\":{\"display_name\":\"Other\"}}}]}",
            ConnectionState.Connected, "test"), "Claude ignores unrelated scoped model limits");
        AssertEqual(-1, TrayApplicationContext.FableWk.PercentLeft, "Fable remains hidden when its limit is absent");

        ResetUsage();
        AssertTrue(parser.ParseCodexLiveJson(
            "{\"unknown_top_level\":true,\"rate_limit\":{\"primary_window\":{\"used_percent\":\"25\",\"limit_window_seconds\":18000,\"reset_at\":1}}}",
            ConnectionState.Connected, "test"), "Codex tolerates unknown fields and numeric strings");
        AssertEqual(75, TrayApplicationContext.Codex5h.PercentLeft, "Codex numeric string percentage");
        AssertEqual("now", TrayApplicationContext.Codex5h.ResetTimeStr, "Expired reset is explicit");

        AssertThrows(delegate
        {
            parser.ParseClaudeJson("{truncated", ConnectionState.Connected, "test");
        }, "Malformed Claude JSON is rejected by the parser");
        AssertThrows(delegate
        {
            parser.ParseCodexLiveJson("<html>error</html>", ConnectionState.Connected, "test");
        }, "HTML Codex error body is rejected by the parser");

        AssertTrue(parser.TryBeginRefresh(), "First refresh enters the gate");
        for (int i = 0; i < 20; i++)
        {
            AssertFalse(parser.TryBeginRefresh(), "Concurrent refresh is rejected " + i);
        }
        parser.EndRefresh();
        AssertTrue(parser.TryBeginRefresh(), "Refresh gate reopens after completion");
        parser.EndRefresh();

        // Some CI and agent sandboxes allow writes only below the checkout. Keep
        // this disposable fixture local instead of assuming the user temp path is writable.
        string cacheDirectory = Path.Combine(Environment.CurrentDirectory,
            ".parser-tests-" + Guid.NewGuid().ToString("N"));
        string cacheFile = Path.Combine(cacheDirectory, "usage.json");
        try
        {
            TrayApplicationContext.WriteCacheAtomic(cacheFile, "one");
            TrayApplicationContext.WriteCacheAtomic(cacheFile, "two");
            AssertEqual("two", File.ReadAllText(cacheFile), "Atomic cache replaces existing content");
            AssertEqual(0, Directory.GetFiles(cacheDirectory, "*.tmp.*").Length, "Atomic cache leaves no temp files");
        }
        finally
        {
            if (Directory.Exists(cacheDirectory)) Directory.Delete(cacheDirectory, true);
        }

        MetricVisibilitySettings defaultVisibility = MetricVisibilitySettings.Parse(new string[0]);
        AssertTrue(defaultVisibility.Get("claude5h"), "Visibility defaults Claude 5h to shown");
        AssertTrue(defaultVisibility.Get("codexWeek"), "Visibility defaults Codex Week to shown");

        MetricVisibilitySettings visibility = MetricVisibilitySettings.Parse(new string[]
        {
            "pinOpen=True",
            "claude5h=False",
            "fableWeek=False",
            "codexWeek=not-a-bool",
            "futureSetting=False"
        });
        AssertFalse(visibility.Get("claude5h"), "Visibility parses hidden Claude 5h");
        AssertFalse(visibility.Get("fableWeek"), "Visibility parses hidden Fable Week");
        AssertTrue(visibility.Get("codexWeek"), "Invalid visibility value preserves the default");

        visibility.Set("codex5h", false);
        MetricVisibilitySettings visibilityRoundTrip = MetricVisibilitySettings.Parse(visibility.ToLines());
        AssertFalse(visibilityRoundTrip.Get("claude5h"), "Visibility round trip preserves Claude 5h");
        AssertFalse(visibilityRoundTrip.Get("fableWeek"), "Visibility round trip preserves Fable Week");
        AssertFalse(visibilityRoundTrip.Get("codex5h"), "Visibility round trip preserves Codex 5h");
        AssertTrue(visibilityRoundTrip.Get("claudeWeek"), "Visibility round trip preserves shown rows");

        RunPhase("mascot-state", RunCharacterStateTests);
        RunPhase("mascot-registry", RunCharacterRegistryTests);
        RunPhase("mascot-renderer-gdi", RunCharacterRendererTests);
        RunPhase("mascot-picker-winforms", RunCharacterPickerTests);

        if (failures == 0) Console.WriteLine("Parser, refresh gate, cache, settings, and mascot tests passed.");
        return failures == 0 ? 0 : 1;
    }

    private static void RunPhase(string name, Action action)
    {
        Stopwatch timer = Stopwatch.StartNew();
        Console.WriteLine("ParserTests: begin " + name);
        action();
        timer.Stop();
        Console.WriteLine("ParserTests: end " + name + " | elapsedMs=" + timer.ElapsedMilliseconds);
    }

    private static void ResetUsage()
    {
        TrayApplicationContext.Claude5h = new BatteryData { Name = "Claude 5h", WindowLabel = "C5" };
        TrayApplicationContext.ClaudeWk = new BatteryData { Name = "Claude Week", WindowLabel = "CW" };
        TrayApplicationContext.FableWk = new BatteryData { Name = "Fable Week", WindowLabel = "FW" };
        TrayApplicationContext.Codex5h = new BatteryData { Name = "Codex 5h", WindowLabel = "X5" };
        TrayApplicationContext.CodexWk = new BatteryData { Name = "Codex Week", WindowLabel = "XW" };
    }

    private static void RunCharacterStateTests()
    {
        AssertEqual(UsageVisualState.Unknown, UsageVisualStateResolver.Resolve(-1), "Mascot unknown state");
        AssertEqual(UsageVisualState.Critical, UsageVisualStateResolver.Resolve(0), "Mascot zero is critical");
        AssertEqual(UsageVisualState.Critical, UsageVisualStateResolver.Resolve(19), "Mascot critical upper boundary");
        AssertEqual(UsageVisualState.Warning, UsageVisualStateResolver.Resolve(20), "Mascot warning lower boundary");
        AssertEqual(UsageVisualState.Warning, UsageVisualStateResolver.Resolve(49), "Mascot warning upper boundary");
        AssertEqual(UsageVisualState.Normal, UsageVisualStateResolver.Resolve(50), "Mascot normal lower boundary");
        AssertEqual(UsageVisualState.Normal, UsageVisualStateResolver.Resolve(100), "Mascot full is normal");

        CharacterRenderContext animated = new CharacterRenderContext(UsageVisualState.Normal, 5, CharacterSurface.Tray, false);
        CharacterRenderContext reduced = new CharacterRenderContext(UsageVisualState.Normal, 3, CharacterSurface.Tray, true);
        CharacterRenderContext unknown = new CharacterRenderContext(UsageVisualState.Unknown, 3, CharacterSurface.Tray, false);
        AssertEqual(1, animated.Frame, "Mascot frame wraps on central clock");
        AssertEqual(0, reduced.Frame, "Reduced motion uses the static frame");
        AssertEqual(0, unknown.Frame, "Unknown state uses the static frame");
    }

    private static void RunCharacterRegistryTests()
    {
        AssertEqual(6, CharacterRegistry.All.Count, "Character registry contains the Phase 1 six");
        string ids = "|";
        foreach (CharacterDefinition character in CharacterRegistry.All)
        {
            AssertFalse(ids.Contains("|" + character.Id + "|"), "Character id is unique " + character.Id);
            ids += character.Id + "|";
            AssertTrue(character.Renderer != null, "Character renderer exists " + character.Id);
            AssertTrue(character.Id.StartsWith("builtin:"), "Character id is namespaced " + character.Id);
        }
        AssertEqual("builtin:slime", CharacterRegistry.NormalizeSelectionId("slime"), "Legacy slime skin migrates");
        AssertEqual("builtin:cat", CharacterRegistry.NormalizeSelectionId("CAT"), "Legacy cat skin migrates case-insensitively");
        AssertEqual(CharacterRegistry.ClassicId, CharacterRegistry.NormalizeSelectionId("classic"), "Legacy classic skin migrates");
        AssertEqual("builtin:mushroom", CharacterRegistry.NormalizeSelectionId("builtin:mushroom"), "Namespaced character round trip");
        AssertEqual(CharacterRegistry.DefaultId, CharacterRegistry.NormalizeSelectionId("future:unknown"), "Unknown character falls back safely");
        AssertTrue(CharacterRegistry.IsClassic("classic"), "Classic remains a non-character display option");
    }

    private static void RunCharacterRendererTests()
    {
        UsageVisualState[] states = new UsageVisualState[]
        {
            UsageVisualState.Unknown, UsageVisualState.Normal, UsageVisualState.Warning, UsageVisualState.Critical
        };

        foreach (CharacterDefinition character in CharacterRegistry.All)
        {
            int normalHash = 0;
            int unknownHash = 0;
            for (int s = 0; s < states.Length; s++)
            {
                for (int frame = 0; frame < 4; frame++)
                {
                    using (Bitmap bitmap = RenderCharacter(character, states[s], frame))
                    {
                        int opaque = CountOpaquePixels(bitmap);
                        AssertTrue(opaque >= 20, "Character renders visible pixels " + character.Id + " " + states[s] + " frame " + frame);
                        if (states[s] == UsageVisualState.Normal && frame == 0) normalHash = PixelHash(bitmap);
                        if (states[s] == UsageVisualState.Unknown && frame == 0) unknownHash = PixelHash(bitmap);
                    }
                }
            }
            AssertFalse(normalHash == unknownHash, "Unknown state is visually distinct " + character.Id);
        }

        using (Bitmap warmup = RenderCharacter(CharacterRegistry.All[0], UsageVisualState.Normal, 0)) { }
        GC.Collect();
        GC.WaitForPendingFinalizers();
        int before = GetGuiResources(Process.GetCurrentProcess().Handle, 0);
        for (int i = 0; i < 100; i++)
        {
            foreach (CharacterDefinition character in CharacterRegistry.All)
            {
                using (Bitmap bitmap = RenderCharacter(character, states[i % states.Length], i % 4)) { }
            }
        }
        GC.Collect();
        GC.WaitForPendingFinalizers();
        int after = GetGuiResources(Process.GetCurrentProcess().Handle, 0);
        if (before > 0 && after > 0) AssertTrue(after - before <= 8, "Repeated mascot rendering keeps GDI resources bounded");
    }

    private static Bitmap RenderCharacter(CharacterDefinition character, UsageVisualState state, int frame)
    {
        Bitmap bitmap = new Bitmap(32, 32);
        using (Graphics graphics = Graphics.FromImage(bitmap))
        {
            graphics.Clear(Color.Transparent);
            TrayApplicationContext.DrawCharacter(character, graphics, 2, 2, state, frame, CharacterSurface.Tray, false);
        }
        return bitmap;
    }

    private static int CountOpaquePixels(Bitmap bitmap)
    {
        int count = 0;
        for (int y = 0; y < bitmap.Height; y++)
        {
            for (int x = 0; x < bitmap.Width; x++) if (bitmap.GetPixel(x, y).A > 0) count++;
        }
        return count;
    }

    private static int PixelHash(Bitmap bitmap)
    {
        unchecked
        {
            int hash = 17;
            for (int y = 0; y < bitmap.Height; y++)
            {
                for (int x = 0; x < bitmap.Width; x++) hash = hash * 31 + bitmap.GetPixel(x, y).ToArgb();
            }
            return hash;
        }
    }

    private static void RunCharacterPickerTests()
    {
        TrayApplicationContext context = new TrayApplicationContext(true);
        using (CharacterPickerForm picker = new CharacterPickerForm(context, "cat", true))
        {
            AssertEqual(6, picker.CharacterCards.Count, "Picker has a 3x2 character grid");
            AssertEqual(3, picker.StatePreviews.Count, "Picker has three tray state previews");
            int selected = 0;
            int tabStops = 0;
            for (int i = 0; i < picker.CharacterCards.Count; i++)
            {
                CharacterCardButton card = picker.CharacterCards[i];
                AssertFalse(string.IsNullOrEmpty(card.AccessibleName), "Character card has an accessible name " + card.Character.Id);
                AssertEqual(i, card.TabIndex, "Character card follows grid tab order " + card.Character.Id);
                if (card.IsSelected) selected++;
                if (card.TabStop) tabStops++;
            }
            AssertEqual(1, selected, "Picker marks one selected character");
            AssertEqual(1, tabStops, "Radio group exposes one tab stop and uses arrow-key navigation");
            foreach (CharacterStatePreview preview in picker.StatePreviews)
            {
                AssertEqual(200, preview.Width, "Tray preview card width");
                AssertFalse(string.IsNullOrEmpty(preview.AccessibleName), "Tray preview has an accessible name");
            }
            CheckBox reduceMotion = (CheckBox)GetPrivateField(typeof(CharacterPickerForm), picker, "reduceMotionCheck");
            AssertTrue(reduceMotion.Checked, "Picker loads reduced-motion preference");

            TrayApplicationContext.CurrentVisualId = "builtin:cat";
            AssertTrue(picker.HandleCharacterSelectionKey(picker.CharacterCards[4], Keys.Enter),
                "Enter on a character card is handled as selection");
            AssertEqual("builtin:cat", TrayApplicationContext.CurrentVisualId,
                "Enter on a character card does not apply the dialog");
            Label selectedLabel = (Label)GetPrivateField(typeof(CharacterPickerForm), picker, "selectedLabel");
            AssertTrue(selectedLabel.Text.Contains("Sproutling"),
                "Enter on a character card updates the pending selection");
        }

        using (CharacterPickerForm classicPicker = new CharacterPickerForm(context, "classic", false))
        {
            RadioButton classic = (RadioButton)GetPrivateField(typeof(CharacterPickerForm), classicPicker, "classicOption");
            Label previewTitle = (Label)GetPrivateField(typeof(CharacterPickerForm), classicPicker, "previewTitle");
            AssertTrue(classic.Checked, "Picker keeps Classic as a separate non-character option");
            AssertTrue(previewTitle.Text.Contains("static gauge"), "Classic picker explains the static fallback");
        }

        using (CharacterPickerForm warmup = new CharacterPickerForm(context, "slime", false)) { }
        GC.Collect();
        GC.WaitForPendingFinalizers();
        int before = GetGuiResources(Process.GetCurrentProcess().Handle, 0);
        for (int i = 0; i < 30; i++)
        {
            using (CharacterPickerForm picker = new CharacterPickerForm(context, "builtin:robot", i % 2 == 0)) { }
        }
        GC.Collect();
        GC.WaitForPendingFinalizers();
        int after = GetGuiResources(Process.GetCurrentProcess().Handle, 0);
        if (before > 0 && after > 0) AssertTrue(after - before <= 12, "Repeated picker open and close keeps GDI resources bounded");
    }

    private static object GetPrivateField(Type type, object instance, string name)
    {
        FieldInfo field = type.GetField(name, BindingFlags.NonPublic | BindingFlags.Instance);
        if (field == null) throw new InvalidOperationException("Missing field " + name);
        return field.GetValue(instance);
    }

    [DllImport("user32.dll")]
    private static extern int GetGuiResources(IntPtr process, int flags);

    private static void AssertTrue(bool value, string name)
    {
        if (!value) Fail(name);
    }

    private static void AssertFalse(bool value, string name)
    {
        if (value) Fail(name);
    }

    private static void AssertEqual(int expected, int actual, string name)
    {
        if (expected != actual) Fail(name + ": expected " + expected + ", got " + actual);
    }

    private static void AssertEqual(string expected, string actual, string name)
    {
        if (expected != actual) Fail(name + ": expected " + expected + ", got " + actual);
    }

    private static void AssertEqual(UsageVisualState expected, UsageVisualState actual, string name)
    {
        if (expected != actual) Fail(name + ": expected " + expected + ", got " + actual);
    }

    private static void AssertThrows(Action action, string name)
    {
        try
        {
            action();
            Fail(name + ": expected an exception");
        }
        catch { }
    }

    private static void Fail(string message)
    {
        failures++;
        Console.Error.WriteLine("FAIL: " + message);
    }
}
