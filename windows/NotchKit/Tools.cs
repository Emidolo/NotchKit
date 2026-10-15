using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;

namespace NotchKit;

public sealed record ToolResult(int Status, string Output, string Error);

/// External command-line tools (ffmpeg, yt-dlp, winget).
static class Tool
{
    /// winget puts the tools it installs here, and a running app's PATH doesn't pick that up until it restarts.
    static readonly string links = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Microsoft", "WinGet", "Links");

    static IEnumerable<string> SearchPath =>
        (Environment.GetEnvironmentVariable("PATH") ?? "").Split(';', StringSplitOptions.RemoveEmptyEntries).Append(links);

    public static string? Find(string name)
    {
        foreach (var directory in SearchPath)
        {
            try
            {
                var path = Path.Combine(directory.Trim('"'), name + ".exe");
                if (File.Exists(path)) return path;
            }
            catch (ArgumentException) { }   // a malformed PATH entry
        }
        return null;
    }

    /// The line worth showing a person when a tool fails: its last line of stderr (winget writes to stdout).
    public static string LastError(ToolResult result, string fallback) =>
        (result.Error + "\n" + result.Output).Split('\n').Select(l => l.Trim()).LastOrDefault(l => l.Length > 0 && !l.All(c => "-\\|/ ".Contains(c))) ?? fallback;

    /// Runs a tool out of process. `onLine` gets each line of stdout as it arrives, on the caller's thread.
    /// Cancelling kills the tool.
    public static async Task<ToolResult> Run(string tool, IEnumerable<string> arguments, Action<string>? onLine = null, CancellationToken cancel = default)
    {
        var info = new ProcessStartInfo(tool)
        {
            UseShellExecute = false, CreateNoWindow = true,
            RedirectStandardInput = true, RedirectStandardOutput = true, RedirectStandardError = true,
            StandardOutputEncoding = Encoding.UTF8, StandardErrorEncoding = Encoding.UTF8,
        };
        foreach (var argument in arguments) info.ArgumentList.Add(argument);
        // yt-dlp (Python) otherwise prints in the console code page, which mangles titles.
        info.Environment["PYTHONUTF8"] = "1";
        info.Environment["PYTHONIOENCODING"] = "utf-8";
        // Tools find each other (yt-dlp looks for ffmpeg) on PATH.
        info.Environment["PATH"] = links + ";" + Environment.GetEnvironmentVariable("PATH");

        using var process = new Process { StartInfo = info };
        try { process.Start(); }
        catch (Exception e) { return new(-1, "", e.Message); }
        process.StandardInput.Close();
        // Drained alongside stdout so a noisy tool can't fill the pipe and stall.
        var errors = process.StandardError.ReadToEndAsync();
        using var registration = cancel.Register(() => { try { process.Kill(true); } catch (InvalidOperationException) { } });
        var lines = new List<string>();
        while (await process.StandardOutput.ReadLineAsync() is string line)
        {
            lines.Add(line);
            onLine?.Invoke(line);
        }
        await process.WaitForExitAsync();
        return new(process.ExitCode, string.Join("\n", lines), (await errors).Trim());
    }
}

/// Installs missing tools with winget. Lives outside the views so an install survives the notch closing.
static class ToolInstaller
{
    static readonly Dictionary<string, string> packages = new() { ["ffmpeg"] = "Gyan.FFmpeg", ["yt-dlp"] = "yt-dlp.yt-dlp" };
    static readonly HashSet<string> installing = [];
    static readonly Dictionary<string, string> errors = [];

    public static async void Install(string tool)
    {
        if (installing.Contains(tool)) return;
        if (Tool.Find("winget") is not string winget)
        {
            errors[tool] = "winget (App Installer) is needed first.";
            Process.Start(new ProcessStartInfo("ms-windows-store://pdp/?productid=9NBLGGH4NNS1") { UseShellExecute = true });
            Ui.Changed();
            return;
        }
        installing.Add(tool);
        errors.Remove(tool);
        Ui.Changed();
        var result = await Tool.Run(winget, ["install", "--id", packages[tool], "--exact", "--silent",
                                             "--accept-source-agreements", "--accept-package-agreements"]);
        if (result.Status != 0) errors[tool] = Tool.LastError(result, $"winget install {packages[tool]} failed");
        installing.Remove(tool);
        Ui.Changed();
    }

    /// "Install <tool>" with a note while winget works and the error if it fails. Rebuilt by the views on refresh.
    public static FrameworkElement Button(string tool)
    {
        if (installing.Contains(tool)) return Ui.Label($"Installing {tool}…", 12, Ui.Secondary);
        var button = Ui.TextButton(errors.ContainsKey(tool) ? "Try Again" : $"Install {tool}", () => Install(tool), $"Runs “winget install {packages[tool]}”.");
        if (!errors.TryGetValue(tool, out var error)) return button;
        var message = Ui.Label(error, 12, Ui.Red);
        message.ToolTip = error;
        message.MaxWidth = 260;
        return Ui.Row(6, button, message);
    }
}
