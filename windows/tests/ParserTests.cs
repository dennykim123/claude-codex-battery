using System;
using System.IO;
using ClaudeCodexBattery;

public static class ParserTests
{
    private static int failures;

    public static int Main()
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

        string cacheDirectory = Path.Combine(Path.GetTempPath(), "ClaudeCodexBatteryTests-" + Guid.NewGuid().ToString("N"));
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

        if (failures == 0) Console.WriteLine("Parser, refresh gate, and cache tests passed.");
        return failures == 0 ? 0 : 1;
    }

    private static void ResetUsage()
    {
        TrayApplicationContext.Claude5h = new BatteryData { Name = "Claude 5h", WindowLabel = "C5" };
        TrayApplicationContext.ClaudeWk = new BatteryData { Name = "Claude Week", WindowLabel = "CW" };
        TrayApplicationContext.FableWk = new BatteryData { Name = "Fable Week", WindowLabel = "FW" };
        TrayApplicationContext.Codex5h = new BatteryData { Name = "Codex 5h", WindowLabel = "X5" };
        TrayApplicationContext.CodexWk = new BatteryData { Name = "Codex Week", WindowLabel = "XW" };
    }

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
