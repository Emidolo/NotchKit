using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;

namespace NotchKit;

// Pure logic, free of WPF and Win32, so the tests in ../Tests run it on any OS.

public static class WidgetOrder
{
    /// The saved order, minus widgets that no longer exist, plus new ones at the end.
    public static List<string> Resolve(IEnumerable<string> saved, IReadOnlyList<string> known)
    {
        var kept = new List<string>();
        foreach (var id in saved)
            if (known.Contains(id) && !kept.Contains(id)) kept.Add(id);
        return kept.Concat(known.Where(id => !kept.Contains(id))).ToList();
    }
}

/// What an input file is, which decides what it can become.
public enum Kind { Image, Pdf, Video, Audio }

public static class Formats
{
    static readonly HashSet<string> images = ["png", "jpg", "jpeg", "jfif", "gif", "bmp", "tif", "tiff", "webp", "heic", "heif", "ico"];
    static readonly HashSet<string> videos = ["mp4", "mov", "m4v", "mkv", "webm", "avi", "flv", "wmv", "ts", "mpg", "mpeg", "3gp"];
    static readonly HashSet<string> audios = ["mp3", "m4a", "aac", "wav", "flac", "ogg", "opus", "wma", "aif", "aiff"];

    public static Kind? KindOf(string path)
    {
        var ext = Path.GetExtension(path).TrimStart('.').ToLowerInvariant();
        if (ext == "pdf") return Kind.Pdf;
        if (videos.Contains(ext)) return Kind.Video;
        if (audios.Contains(ext)) return Kind.Audio;
        if (images.Contains(ext)) return Kind.Image;
        return null;
    }

    /// Output formats, as file extensions.
    // ponytail: no HEIC output (Windows has no stock encoder) and no PDF merging (needs a PDF parser, e.g. PdfSharp).
    public static string[] Outputs(Kind kind) => kind switch
    {
        Kind.Image => ["png", "jpg", "webp", "tiff", "gif", "bmp", "pdf"],
        Kind.Pdf => ["png", "jpg"],
        Kind.Video => ["mp4", "mov", "mkv", "webm", "gif", "mp3", "m4a", "wav", "flac", "ogg"],
        _ => ["mp3", "m4a", "wav", "flac", "ogg"],
    };

    public static bool HasQuality(string format) => format is "jpg" or "webp";

    /// Formats every file in the batch can become, in the first file's order.
    public static List<string> Common(IEnumerable<Kind> kinds)
    {
        var list = kinds.ToList();
        if (list.Count == 0) return [];
        return Outputs(list[0]).Where(f => list.All(k => Outputs(k).Contains(f))).ToList();
    }

    /// A path that doesn't exist yet: "name.ext", then "name 2.ext", "name 3.ext"… Originals are never overwritten.
    public static string FreePath(string directory, string name, string ext)
    {
        var path = Path.Combine(directory, $"{name}.{ext}");
        for (var n = 2; File.Exists(path) || Directory.Exists(path); n++)
            path = Path.Combine(directory, $"{name} {n}.{ext}");
        return path;
    }

    /// Codecs are spelled out rather than left to ffmpeg's per-container defaults, which vary between builds.
    public static List<string> FfmpegArguments(string input, string output, string format)
    {
        var a = new List<string> { "-nostdin", "-n", "-v", "error", "-progress", "pipe:1", "-i", input };
        const string even = "scale=trunc(iw/2)*2:trunc(ih/2)*2";
        switch (format)
        {
            case "mp4" or "mov":
                // H.264 needs even dimensions; faststart lets the file play before it has fully loaded.
                a.AddRange(["-c:v", "libx264", "-pix_fmt", "yuv420p", "-vf", even, "-c:a", "aac", "-movflags", "+faststart"]);
                break;
            case "mkv":
                a.AddRange(["-c:v", "libx264", "-pix_fmt", "yuv420p", "-vf", even, "-c:a", "aac"]);
                break;
            case "webm":
                a.AddRange(["-c:v", "libvpx-vp9", "-crf", "32", "-b:v", "0", "-c:a", "libopus"]);
                break;
            case "gif":
                // ponytail: fixed 12 fps and 480px wide keep GIFs small; expose both if anyone asks.
                a.AddRange(["-vf", "fps=12,scale='min(480,iw)':-1:flags=lanczos,split[a][b];[a]palettegen[p];[b][p]paletteuse", "-loop", "0"]);
                break;
            case "mp3": a.AddRange(["-vn", "-c:a", "libmp3lame", "-q:a", "2"]); break;
            case "m4a": a.AddRange(["-vn", "-c:a", "aac", "-b:a", "192k"]); break;
            case "wav": a.AddRange(["-vn", "-c:a", "pcm_s16le"]); break;
            case "flac": a.AddRange(["-vn", "-c:a", "flac"]); break;
            case "ogg": a.AddRange(["-vn", "-c:a", "libopus", "-b:a", "160k"]); break;
        }
        a.Add(output);
        return a;
    }

    /// Seconds encoded so far, from a line of `ffmpeg -progress` output.
    public static double? ProgressSeconds(string line) =>
        line.StartsWith("out_time_us=") && double.TryParse(line[12..], NumberStyles.Float, CultureInfo.InvariantCulture, out var us)
            ? us / 1_000_000 : null;
}

/// Writes a PDF with one JPEG per page. Enough for "images → PDF" without a PDF library.
public static class Pdf
{
    /// `Width`/`Height` are the page size in points (1/72 inch).
    public record Page(byte[] Jpeg, int PixelWidth, int PixelHeight, double Width, double Height);

    public static byte[] FromJpegs(IReadOnlyList<Page> pages)
    {
        var output = new MemoryStream();
        var offsets = new List<long>();
        void Text(string s) => output.Write(Encoding.Latin1.GetBytes(s));
        void Begin() { offsets.Add(output.Position); Text($"{offsets.Count} 0 obj\n"); }
        static string N(double v) => v.ToString("0.##", CultureInfo.InvariantCulture);

        Text("%PDF-1.4\n%âãÏÓ\n");
        // Objects: 1 catalog, 2 page tree, then three per page (page, content stream, image).
        Begin(); Text("<< /Type /Catalog /Pages 2 0 R >>\nendobj\n");
        var kids = string.Join(" ", pages.Select((_, i) => $"{3 + i * 3} 0 R"));
        Begin(); Text($"<< /Type /Pages /Kids [{kids}] /Count {pages.Count} >>\nendobj\n");
        for (var i = 0; i < pages.Count; i++)
        {
            var p = pages[i];
            int content = 4 + i * 3, image = 5 + i * 3;
            Begin(); Text($"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 {N(p.Width)} {N(p.Height)}] " +
                          $"/Resources << /XObject << /Im0 {image} 0 R >> >> /Contents {content} 0 R >>\nendobj\n");
            var draw = $"q {N(p.Width)} 0 0 {N(p.Height)} 0 0 cm /Im0 Do Q";
            Begin(); Text($"<< /Length {draw.Length} >>\nstream\n{draw}\nendstream\nendobj\n");
            Begin(); Text($"<< /Type /XObject /Subtype /Image /Width {p.PixelWidth} /Height {p.PixelHeight} /ColorSpace /DeviceRGB " +
                          $"/BitsPerComponent 8 /Filter /DCTDecode /Length {p.Jpeg.Length} >>\nstream\n");
            output.Write(p.Jpeg);
            Text("\nendstream\nendobj\n");
        }
        var xref = output.Position;
        Text($"xref\n0 {offsets.Count + 1}\n0000000000 65535 f \n");
        foreach (var offset in offsets) Text($"{offset:D10} 00000 n \n");
        Text($"trailer\n<< /Size {offsets.Count + 1} /Root 1 0 R >>\nstartxref\n{xref}\n%%EOF\n");
        return output.ToArray();
    }
}

/// "best", or a maximum height such as "1080", for video; "mp3" or "m4a" for audio.
public record DownloadMode(bool Audio, string Value);

/// Pure helpers around yt-dlp: recognising links, building its arguments, reading its output.
public static class YouTube
{
    public static readonly string[] Qualities = ["best", "2160", "1440", "1080", "720", "480"];
    public static readonly string[] AudioFormats = ["mp3", "m4a"];

    /// The video link in `text`, if `text` is exactly one YouTube video URL. This is the gate for
    /// whatever lands on the clipboard, so anything that isn't plainly a video link is rejected.
    public static Uri? Link(string text)
    {
        text = text.Trim();
        if (text.Length == 0 || text.Any(char.IsWhiteSpace) || !Uri.TryCreate(text, UriKind.Absolute, out var uri)
            || (uri.Scheme != "https" && uri.Scheme != "http")) return null;
        var host = uri.Host.ToLowerInvariant();
        foreach (var prefix in new[] { "www.", "m." })
            if (host.StartsWith(prefix)) host = host[prefix.Length..];
        var path = uri.AbsolutePath;
        var isVideo = host switch
        {
            "youtu.be" => path.Length > 1,
            "youtube.com" or "music.youtube.com" => path.StartsWith("/shorts/") || path.StartsWith("/live/")
                || (path == "/watch" && uri.Query.TrimStart('?').Split('&').Any(p => p.StartsWith("v=") && p.Length > 2)),
            _ => false,
        };
        return isVideo ? uri : null;
    }

    public static List<string> MetadataArguments(Uri url) =>
        ["--no-playlist", "--no-warnings", "--print", "%(title)s", "--print", "%(thumbnail)s", "--print", "%(duration_string)s", "--", url.AbsoluteUri];

    /// `temp` holds the partial files, so a cancelled download leaves nothing in `directory`.
    public static List<string> DownloadArguments(Uri url, DownloadMode mode, string directory, string temp, string? ffmpeg)
    {
        var a = new List<string> { "--no-playlist", "--no-warnings", "--newline", "--progress",
            "--progress-template", "download:NKP %(progress._percent_str)s",
            "--print", "before_dl:NKT %(title)s", "--print", "after_move:NKF %(filepath)s",
            "-P", $"home:{directory}", "-P", $"temp:{temp}", "-o", "%(title)s.%(ext)s" };
        if (ffmpeg != null) a.AddRange(["--ffmpeg-location", Path.GetDirectoryName(ffmpeg)!]);
        if (mode.Audio)
            a.AddRange(["-x", "--audio-format", mode.Value, "--audio-quality", "0", "--embed-thumbnail", "--embed-metadata"]);
        else
            // Resolution first, then H.264/AAC when YouTube offers them at that size, so every player opens the file.
            a.AddRange(["-S", (mode.Value == "best" ? "res" : $"res:{mode.Value}") + ",vcodec:h264,acodec:aac", "--merge-output-format", "mp4"]);
        a.AddRange(["--", url.AbsoluteUri]);
        return a;
    }

    /// Decodes the lines requested by `DownloadArguments`: ("progress", "0.42"), ("title", …) or ("file", …).
    public static (string Kind, string Value)? Event(string line)
    {
        if (line.Length < 4) return null;
        var value = line[4..];
        return line[..4] switch
        {
            "NKP " => double.TryParse(value.Trim(' ', '%'), NumberStyles.Float, CultureInfo.InvariantCulture, out var p)
                ? ("progress", (p / 100).ToString(CultureInfo.InvariantCulture)) : null,
            "NKT " => ("title", value),
            "NKF " => ("file", value),
            _ => null,
        };
    }
}

public static class AskApi
{
    public const string DefaultModel = "gpt-5.6-luna";

    /// The text carried by one line of the streamed response; null for blank lines, keep-alives and `[DONE]`.
    public static string? Delta(string line)
    {
        if (!line.StartsWith("data:")) return null;
        try
        {
            using var doc = JsonDocument.Parse(line[5..]);
            var choices = doc.RootElement.GetProperty("choices");
            if (choices.GetArrayLength() == 0) return null;
            return choices[0].GetProperty("delta").TryGetProperty("content", out var c) && c.ValueKind == JsonValueKind.String ? c.GetString() : null;
        }
        catch (Exception e) when (e is JsonException or KeyNotFoundException or InvalidOperationException)
        {
            return null;
        }
    }

    /// OpenAI's own explanation from an error response, when it has one.
    public static string ErrorMessage(string body, int status)
    {
        try
        {
            using var doc = JsonDocument.Parse(body);
            if (doc.RootElement.GetProperty("error").GetProperty("message").GetString() is string message) return message;
        }
        catch (Exception e) when (e is JsonException or KeyNotFoundException or InvalidOperationException) { }
        return $"OpenAI answered with status {status}";
    }
}

public static class Typer
{
    public const ushort Return = 0x0D, Tab = 0x09;

    /// A virtual key for Return and Tab, which apps only understand as keys; every other character as text,
    /// so the keyboard layout doesn't matter. "\r\n" is one Return.
    public static List<(ushort Key, string Text)> Keystrokes(string text)
    {
        var list = new List<(ushort, string)>();
        var e = StringInfo.GetTextElementEnumerator(text);
        while (e.MoveNext())
        {
            var s = (string)e.Current;
            list.Add(s switch { "\n" or "\r" or "\r\n" => (Return, ""), "\t" => (Tab, ""), _ => ((ushort)0, s) });
        }
        return list;
    }
}

public enum ClaudeEvent { Working, Finished, Input, Ended }

/// What the user has asked to keep the PC awake for. Stored as JSON; keys missing from an older file keep their defaults.
public class KeepAwakeRules
{
    public class Proc
    {
        public string Name { get; set; } = "";
        public bool Enabled { get; set; } = true;
    }

    /// Let the screen sleep while the system stays awake.
    public bool AllowDisplaySleep { get; set; }
    public bool WhileProcesses { get; set; }
    public List<Proc> Processes { get; set; } =
        new[] { "Code", "Cursor", "WindowsTerminal", "devenv", "claude", "node", "python", "cargo", "MSBuild" }.Select(n => new Proc { Name = n }).ToList();
    /// A download or conversion in this app.
    public bool WhileBusy { get; set; } = true;
    public bool WhileOnAC { get; set; }
    public bool WhileExternalDisplay { get; set; }
    /// Driven by the Claude Code hooks (see ClaudeHooks).
    public bool WhileClaude { get; set; } = true;
    /// Minutes to stay awake after Claude finishes or asks for input.
    public int ClaudeGraceMinutes { get; set; } = 5;
    public bool ClaudeSound { get; set; } = true;
    /// On battery below this level, nothing keeps the PC awake.
    public bool BatteryFloorEnabled { get; set; } = true;
    public int BatteryFloor { get; set; } = 20;
    /// Closing the lid does nothing while keep-awake is active.
    public bool ClosedLid { get; set; }

    public static string ClaudeLabel(ClaudeEvent e) => e switch
    {
        ClaudeEvent.Working => "Claude is working…",
        ClaudeEvent.Input => "Claude needs input",
        _ => "Claude finished",
    };

    /// Why the PC should be awake right now (empty: let it sleep), or what overrode the reasons.
    public (List<string> Reasons, string? Blocked) Decide(KeepAwakeInputs inputs)
    {
        var reasons = new List<string>();
        if (inputs.Manual) reasons.Add("Turned on by you");
        if (WhileProcesses)
            reasons.AddRange(Processes.Where(p => p.Enabled && inputs.Processes.Contains(p.Name)).Select(p => $"{p.Name} is running"));
        if (WhileBusy && inputs.Busy) reasons.Add("A download or conversion is running");
        if (WhileClaude && inputs.Claude) reasons.Add("Claude Code is working");
        if (WhileOnAC && inputs.OnAC) reasons.Add("On AC power");
        if (WhileExternalDisplay && inputs.ExternalDisplay) reasons.Add("An external display is connected");
        if (BatteryFloorEnabled && !inputs.OnAC && inputs.Battery is int battery && battery < BatteryFloor && reasons.Count > 0)
            return ([], $"Battery below {BatteryFloor}%");
        return (reasons, null);
    }
}

/// The world as the rules see it. `Processes` should compare names case-insensitively.
public record KeepAwakeInputs(bool Manual = false, ISet<string>? RunningProcesses = null, bool Busy = false, bool OnAC = true,
                              int? Battery = null, bool ExternalDisplay = false, bool Claude = false)
{
    public ISet<string> Processes => RunningProcesses ?? new HashSet<string>();
}

/// Adds or removes the Claude Code hooks that tell NotchKit what Claude is doing. Each runs
/// `NotchKit.exe --claude <event>`, which only reaches an instance that is already running.
public static class ClaudeHooks
{
    static readonly (string Hook, string Event)[] events =
        [("UserPromptSubmit", "working"), ("Stop", "finished"), ("Notification", "input"), ("SessionEnd", "ended")];
    const string Mark = "_notchkit";

    public static ClaudeEvent? Parse(string text) => text.ToLowerInvariant() switch
    {
        "working" => ClaudeEvent.Working,
        "finished" => ClaudeEvent.Finished,
        "input" => ClaudeEvent.Input,
        "ended" => ClaudeEvent.Ended,
        _ => null,
    };

    /// Forward slashes, so the command reads the same in cmd and in the Git Bash that Claude Code uses.
    public static string Command(string exe, string evt) => $"\"{exe.Replace('\\', '/')}\" --claude {evt}";

    /// Other hooks are left alone, and installing twice changes nothing. Throws on a file that isn't a settings object.
    public static void Apply(JsonObject settings, bool install, string exe)
    {
        if (settings["hooks"] is not JsonObject hooks)
        {
            if (settings["hooks"] != null) throw new InvalidDataException("\"hooks\" isn't an object.");
            if (!install) return;
            hooks = new JsonObject();
            settings["hooks"] = hooks;
        }
        foreach (var (name, evt) in events)
        {
            if (hooks[name] is { } existing && existing is not JsonArray) continue;
            var entries = new JsonArray();
            foreach (var entry in (hooks[name] as JsonArray) ?? [])
                if (!(entry is JsonObject o && o[Mark] is JsonValue v && v.TryGetValue<bool>(out var mine) && mine))
                    entries.Add(entry?.DeepClone());
            if (install)
                entries.Add(new JsonObject
                {
                    ["hooks"] = new JsonArray(new JsonObject { ["type"] = "command", ["command"] = Command(exe, evt), ["timeout"] = 5 }),
                    [Mark] = true,
                });
            if (entries.Count > 0) hooks[name] = entries; else hooks.Remove(name);
        }
        if (hooks.Count == 0) settings.Remove("hooks");
    }
}

public static class PowerCfg
{
    /// The (AC, DC) values from `powercfg /q SCHEME_CURRENT SUB_BUTTONS LIDACTION`. The labels are localised,
    /// so this reads the last two hex numbers, which are always the current AC and DC indices.
    public static (int AC, int DC)? LidAction(string output)
    {
        var values = Regex.Matches(output, @"0x([0-9a-fA-F]{8})").Select(m => Convert.ToInt32(m.Groups[1].Value, 16)).ToList();
        return values.Count >= 2 ? (values[^2], values[^1]) : null;
    }

    /// 0 do nothing, 1 sleep, 2 hibernate, 3 shut down.
    public static bool IsLidAction(int value) => value is >= 0 and <= 3;
}

/// What the tray app asks NotchKitService for, one JSON line per change, over the pipe `PipeName`.
public record PowerState(bool Awake, bool Display, bool Lid)
{
    public const string PipeName = "NotchKitService";
    public static readonly PowerState Off = new(false, false, false);
}
