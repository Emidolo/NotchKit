using System.Text;
using System.Text.Json.Nodes;
using NotchKit;

var failures = 0;
void Check(bool ok, string what)
{
    if (ok) return;
    failures++;
    Console.WriteLine("FAIL: " + what);
}

// Widget order
Check(WidgetOrder.Resolve(["typer", "gone", "music", "typer"], ["music", "converter", "typer"]).SequenceEqual(["typer", "music", "converter"]),
      "saved order drops unknown and duplicate ids and appends new ones");

// Converter
Check(Formats.KindOf(@"C:\a\clip.MKV") == Kind.Video && Formats.KindOf("x.heic") == Kind.Image && Formats.KindOf("x.pdf") == Kind.Pdf
      && Formats.KindOf("x.flac") == Kind.Audio && Formats.KindOf("x.txt") == null, "file kinds");
Check(Formats.Common([Kind.Image, Kind.Pdf]).SequenceEqual(["png", "jpg"]), "common formats of image and pdf");
Check(Formats.Common([Kind.Video, Kind.Audio]).SequenceEqual(["mp3", "m4a", "wav", "flac", "ogg"]), "common formats of video and audio");
var dir = Directory.CreateTempSubdirectory().FullName;
File.WriteAllText(Path.Combine(dir, "a.png"), "");
File.WriteAllText(Path.Combine(dir, "a 2.png"), "");
Check(Formats.FreePath(dir, "a", "png") == Path.Combine(dir, "a 3.png"), "free path skips existing files");
var mp4 = Formats.FfmpegArguments("in.mov", "out.mp4", "mp4");
Check(mp4[^1] == "out.mp4" && mp4.Contains("libx264") && mp4.Contains("-n"), "ffmpeg mp4 arguments never overwrite");
Check(Formats.ProgressSeconds("out_time_us=2500000") == 2.5 && Formats.ProgressSeconds("out_time_us=N/A") == null
      && Formats.ProgressSeconds("frame=1") == null, "ffmpeg progress");

// PDF: every xref offset must point at its object.
var jpeg = new byte[] { 0xFF, 0xD8, 0xFF, 0xD9 };
var pdf = Pdf.FromJpegs([new(jpeg, 2, 1, 144, 72), new(jpeg, 1, 1, 72, 72)]);
var text = Encoding.Latin1.GetString(pdf);
var xref = text.LastIndexOf("\nxref\n", StringComparison.Ordinal) + 1;  // not the one in "startxref"
var rows = text[xref..].Split('\n').Skip(3).Take(8).ToList();
Check(text.StartsWith("%PDF-1.4") && text.EndsWith("%%EOF\n") && text.Contains("/Count 2"), "pdf header, trailer and page count");
Check(rows.Count == 8 && rows.Select((row, i) => text[(int)long.Parse(row[..10])..].StartsWith($"{i + 1} 0 obj")).All(x => x)
      && rows.All(r => r.Length == 19), "pdf xref offsets");

// YouTube
Check(YouTube.Link("https://www.youtube.com/watch?v=dQw4w9WgXcQ&t=1") != null, "watch link");
Check(YouTube.Link(" https://youtu.be/dQw4w9WgXcQ\n") != null, "short link");
Check(YouTube.Link("https://m.youtube.com/shorts/abc") != null && YouTube.Link("https://music.youtube.com/watch?v=x") != null, "shorts and music");
Check(YouTube.Link("https://youtube.com/watch") == null && YouTube.Link("https://youtube.com/watch?v=") == null, "watch without an id");
Check(YouTube.Link("https://evil.com/watch?v=x") == null && YouTube.Link("look https://youtu.be/x") == null
      && YouTube.Link("ftp://youtu.be/x") == null && YouTube.Link("https://youtu.be/") == null, "rejects other text");
var video = YouTube.DownloadArguments(new Uri("https://youtu.be/x"), new(false, "1080"), @"C:\Down", @"C:\Temp\t", @"C:\ff\ffmpeg.exe");
Check(video.Contains("res:1080,vcodec:h264,acodec:aac") && video.Contains("home:C:\\Down") && video[^2] == "--", "video download arguments");
var audio = YouTube.DownloadArguments(new Uri("https://youtu.be/x"), new(true, "mp3"), "d", "t", null);
Check(audio.Contains("-x") && audio.Contains("mp3") && !audio.Contains("--ffmpeg-location"), "audio download arguments");
Check(YouTube.Event("NKP  42.5%") == ("progress", "0.425") && YouTube.Event("NKT A title") == ("title", "A title")
      && YouTube.Event("NKF C:\\x.mp4") == ("file", "C:\\x.mp4") && YouTube.Event("[download] x") == null
      && YouTube.Event("NKP N/A") == null, "yt-dlp events");

// Ask
Check(AskApi.Delta("data: {\"choices\":[{\"delta\":{\"content\":\"Hi\"}}]}") == "Hi", "stream delta");
Check(AskApi.Delta("data: [DONE]") == null && AskApi.Delta("") == null && AskApi.Delta("data: {\"choices\":[]}") == null
      && AskApi.Delta("data: {\"choices\":[{\"delta\":{}}]}") == null, "stream noise");
Check(AskApi.ErrorMessage("{\"error\":{\"message\":\"Bad key\"}}", 401) == "Bad key"
      && AskApi.ErrorMessage("nope", 500) == "OpenAI answered with status 500", "error message");

// Typer
var keys = Typer.Keystrokes("a\r\nb\tc👍");
Check(keys.SequenceEqual([((ushort)0, "a"), (Typer.Return, ""), ((ushort)0, "b"), (Typer.Tab, ""), ((ushort)0, "c"), ((ushort)0, "👍")]),
      "keystrokes: CRLF is one Return, emoji is one character");

// Keep awake
var rules = new KeepAwakeRules { WhileProcesses = true };
var running = new HashSet<string>(["code", "node"], StringComparer.OrdinalIgnoreCase);
var (reasons, blocked) = rules.Decide(new(RunningProcesses: running, Busy: true));
Check(reasons.SequenceEqual(["Code is running", "node is running", "A download or conversion is running"]) && blocked == null, "keep-awake reasons");
(reasons, blocked) = rules.Decide(new(Manual: true, OnAC: false, Battery: 10));
Check(reasons.Count == 0 && blocked == "Battery below 20%", "low battery blocks keep-awake");
(reasons, blocked) = rules.Decide(new(OnAC: false, Battery: 10));
Check(reasons.Count == 0 && blocked == null, "nothing to block when nothing asks");
var loaded = System.Text.Json.JsonSerializer.Deserialize<KeepAwakeRules>("{\"BatteryFloor\":30}")!;
Check(loaded.BatteryFloor == 30 && loaded.WhileBusy && loaded.Processes.Count > 0, "older saved rules keep new defaults");

// Claude hooks
var settings = JsonNode.Parse("{\"model\":\"x\",\"hooks\":{\"Stop\":[{\"hooks\":[{\"type\":\"command\",\"command\":\"echo hi\"}]}]}}")!.AsObject();
ClaudeHooks.Apply(settings, true, @"C:\Apps\NotchKit\NotchKit.exe");
ClaudeHooks.Apply(settings, true, @"C:\Apps\NotchKit\NotchKit.exe");
var stop = settings["hooks"]!["Stop"]!.AsArray();
Check(stop.Count == 2 && stop[1]!["hooks"]![0]!["command"]!.GetValue<string>() == "\"C:/Apps/NotchKit/NotchKit.exe\" --claude finished",
      "install keeps other hooks and is idempotent");
Check(settings["hooks"]!.AsObject().Count == 4, "four hook events");
ClaudeHooks.Apply(settings, false, "x");
Check(settings["hooks"]!.AsObject().Count == 1 && settings["hooks"]!["Stop"]!.AsArray().Count == 1 && settings["model"]!.GetValue<string>() == "x",
      "remove leaves only the user's hooks");
var empty = new JsonObject();
ClaudeHooks.Apply(empty, true, "x");
ClaudeHooks.Apply(empty, false, "x");
Check(empty.Count == 0, "install then remove on an empty file leaves it empty");
Check(ClaudeHooks.Parse("Working") == ClaudeEvent.Working && ClaudeHooks.Parse("1") == null, "claude event parsing");

// powercfg
var query = "Power Setting GUID: 5ca83367 (Lid close action)\n  Possible Setting Index: 000\n  Possible Setting Friendly Name: Do nothing\n" +
            "Current AC Power Setting Index: 0x00000001\nCurrent DC Power Setting Index: 0x00000002\n";
Check(PowerCfg.LidAction(query) == (1, 2) && PowerCfg.LidAction("nothing") == null, "powercfg lid action");

Console.WriteLine(failures == 0 ? "All checks passed." : $"{failures} failed.");
return failures == 0 ? 0 : 1;
