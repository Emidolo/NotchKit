using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Imaging;

namespace NotchKit;

sealed class Download(Uri url, DownloadMode mode, string title)
{
    public enum States { Waiting, Running, Done, Failed }
    public Uri Url => url;
    public DownloadMode Mode => mode;
    public string Title = title;
    public States State = States.Waiting;
    public double Fraction;
    public string? File;
    public string Error = "";
    public CancellationTokenSource? Running;
}

sealed class YouTubeModel
{
    public static readonly YouTubeModel Shared = new();

    /// A link waiting for "video or audio?", with whatever is known about it so far.
    public sealed class Prompt(Uri url)
    {
        public Uri Url => url;
        public string? Title, Duration, Error;
        public Uri? Thumbnail;
        /// Made once, so progress updates don't fetch the thumbnail again.
        public ImageBrush? Image;
    }

    public Prompt? Offer { get; private set; }
    public List<Download> Downloads { get; } = [];
    /// One line of feedback under the link field.
    public string? Status { get; private set; }

    public string Quality
    {
        get => Prefs.Get("youtubeQuality", "1080");
        set => Prefs.Set("youtubeQuality", value);
    }
    public string AudioFormat
    {
        get => Prefs.Get("youtubeAudioFormat", "mp3");
        set => Prefs.Set("youtubeAudioFormat", value);
    }
    public string Directory
    {
        get => Prefs.Get("youtubeDirectory", Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), "Downloads"));
        set => Prefs.Set("youtubeDirectory", value);
    }
    public bool DetectClipboard
    {
        get => Prefs.Get("clipboardDetection", true);
        set => Prefs.Set("clipboardDetection", value);
    }

    /// The running download's progress; null when idle.
    // ponytail: yt-dlp reports video and audio streams separately, so the ring runs 0→100 twice for a video.
    public double? Progress => Downloads.FirstOrDefault(d => d.State == Download.States.Running)?.Fraction;

    /// Text landed on the clipboard.
    public void Copied(string text)
    {
        if (!DetectClipboard || !WidgetStore.IsEnabled(Widget.YouTube.Id)) return;
        if (YouTube.Link(text) is not Uri url || url == Offer?.Url || Downloads.Any(d => d.Url == url)) return;
        Show(url);
        NotchWindow.Shared.Selected = Widget.YouTube.Id;
        NotchWindow.Shared.Peek();
    }

    public void Submit(string link)
    {
        if (YouTube.Link(link) is Uri url) Show(url);
        else Status = "That isn't a YouTube video link.";
        Ui.Changed();
    }

    async void Show(Uri url)
    {
        Status = null;
        var prompt = Offer = new Prompt(url);
        Ui.Changed();
        if (Tool.Find("yt-dlp") is not string ytdlp) return;
        var result = await Tool.Run(ytdlp, YouTube.MetadataArguments(url));
        if (Offer != prompt) return;
        var lines = result.Output.Split('\n');
        if (result.Status == 0 && lines.Length >= 3)
        {
            prompt.Title = lines[0];
            prompt.Thumbnail = Uri.TryCreate(lines[1], UriKind.Absolute, out var thumbnail) ? thumbnail : null;
            // Under a minute yt-dlp prints bare seconds ("19").
            prompt.Duration = lines[2].Contains(':') ? lines[2] : "0:" + lines[2].PadLeft(2, '0');
        }
        else prompt.Error = Tool.LastError(result, "Couldn't read this video");
        Ui.Changed();
    }

    public void Dismiss()
    {
        Offer = null;
        Ui.Changed();
    }

    public void Start(DownloadMode mode)
    {
        if (Offer is not { } prompt) return;
        Downloads.Add(new Download(prompt.Url, mode, prompt.Title ?? prompt.Url.AbsoluteUri));
        Offer = null;
        StartNext();
    }

    /// Cancels a running download, or takes a waiting or finished one off the list.
    public void Remove(Download download)
    {
        download.Running?.Cancel();
        Downloads.Remove(download);
        Ui.Changed();
    }

    /// One download at a time, in the order they were added.
    async void StartNext()
    {
        Ui.Changed();
        if (Progress != null || Downloads.FirstOrDefault(d => d.State == Download.States.Waiting) is not Download next) return;
        next.State = Download.States.Running;
        next.Fraction = 0;
        KeepAwake.Shared.Evaluate();
        await Run(next);
        KeepAwake.Shared.Evaluate();
        StartNext();
    }

    async Task Run(Download download)
    {
        if (Tool.Find("yt-dlp") is not string ytdlp)
        {
            download.State = Download.States.Failed;
            download.Error = "yt-dlp is not installed";
            return;
        }
        var temp = Path.Combine(Path.GetTempPath(), $"NotchKit-download-{Guid.NewGuid()}");
        download.Running = new CancellationTokenSource();
        var arguments = YouTube.DownloadArguments(download.Url, download.Mode, Directory, temp, Tool.Find("ffmpeg"));
        var result = await Tool.Run(ytdlp, arguments, line =>
        {
            switch (YouTube.Event(line))
            {
                case ("progress", var value): download.Fraction = double.Parse(value, CultureInfo.InvariantCulture); break;
                case ("title", var value): download.Title = value; break;
                case ("file", var value): download.File = value; break;
                default: return;
            }
            Ui.Changed();
        }, download.Running.Token);
        try { System.IO.Directory.Delete(temp, true); } catch (IOException) { }   // nothing was left there
        download.Running = null;
        if (result.Status == 0 && download.File != null) download.State = Download.States.Done;
        else
        {
            // Also reached after a cancel, when the item is already off the list.
            download.State = Download.States.Failed;
            download.Error = Tool.LastError(result, "Download failed");
        }
    }

    public void PickDirectory()
    {
        if (Startup.ChooseFolder(Directory) is string folder) Directory = folder;
        // The notch closed when the cursor left for the dialog.
        NotchWindow.Shared.Expand();
        Ui.Changed();
    }

    /// yt-dlp breaks whenever YouTube changes something, so updating it is one click.
    public async void UpdateYtDlp()
    {
        if (Tool.Find("yt-dlp") is not string ytdlp) return;
        Status = "Updating yt-dlp…";
        Ui.Changed();
        // A winget copy is updated through winget; a standalone yt-dlp.exe knows how to replace itself.
        var winget = Tool.Find("winget");
        var result = ytdlp.Contains("WinGet", StringComparison.OrdinalIgnoreCase) && winget != null
            ? await Tool.Run(winget, ["upgrade", "--id", "yt-dlp.yt-dlp", "--exact", "--silent", "--accept-source-agreements", "--accept-package-agreements"])
            : await Tool.Run(ytdlp, ["-U"]);
        var version = (await Tool.Run(ytdlp, ["--version"])).Output.Trim();
        // winget exits non-zero when there was nothing newer to install.
        Status = result.Status == 0 || result.Output.Contains("No available upgrade", StringComparison.OrdinalIgnoreCase)
            ? $"yt-dlp is up to date ({version})." : Tool.LastError(result, "Update failed");
        Ui.Changed();
    }
}

sealed class YouTubeView : Grid
{
    readonly FrameworkElement needsTool;
    readonly ContentControl installYtDlp = new() { HorizontalAlignment = HorizontalAlignment.Center };
    readonly DockPanel main = new();
    readonly TextBox link = new() { VerticalContentAlignment = VerticalAlignment.Center };
    readonly ContentControl note = new();
    readonly TextBlock hint = Ui.Label("", 13, Ui.Secondary);
    readonly StackPanel list = new();
    readonly ScrollViewer scroller;
    readonly MenuItem detect;
    readonly MenuItem saveTo;

    public YouTubeView()
    {
        var model = YouTubeModel.Shared;
        needsTool = Ui.Column(8, Ui.EmptyHint(G.Download, "yt-dlp is needed", "It does the downloading. NotchKit installs it with winget."), installYtDlp);

        System.Windows.Automation.AutomationProperties.SetName(link, "Paste a YouTube link");
        link.KeyDown += (_, e) =>
        {
            if (e.Key != Key.Return) return;
            model.Submit(link.Text);
            if (model.Status == null) link.Text = "";
        };
        var quality = Ui.Picker("Video quality", v => model.Quality = v);
        Ui.SetOptions(quality, YouTube.Qualities.Select(q => (q == "best" ? "Best" : q + "p", q)), model.Quality);
        quality.ToolTip = "Video quality";
        var audio = Ui.Picker("Audio format", v => model.AudioFormat = v);
        Ui.SetOptions(audio, YouTube.AudioFormats.Select(f => (f.ToUpperInvariant(), f)), model.AudioFormat);
        audio.ToolTip = "Audio format";

        var more = Ui.IconButton(G.More, "Download options", () => { });
        more.ContextMenu = new ContextMenu();
        detect = new MenuItem { Header = "Detect Copied Links", IsCheckable = true };
        detect.Click += (_, _) => { model.DetectClipboard = detect.IsChecked; Ui.Changed(); };
        saveTo = new MenuItem();
        saveTo.Click += (_, _) => model.PickDirectory();
        var update = new MenuItem { Header = "Update yt-dlp" };
        update.Click += (_, _) => model.UpdateYtDlp();
        more.ContextMenu.Items.Add(detect);
        more.ContextMenu.Items.Add(saveTo);
        more.ContextMenu.Items.Add(new Separator());
        more.ContextMenu.Items.Add(update);
        more.Click += (_, _) => { more.ContextMenu.PlacementTarget = more; more.ContextMenu.IsOpen = true; };

        var toolbar = new DockPanel { Margin = new Thickness(0, 0, 0, 6) };
        var right = Ui.Row(6, quality, audio, more);
        right.Margin = new Thickness(6, 0, 0, 0);
        DockPanel.SetDock(right, Dock.Right);
        toolbar.Children.Add(right);
        toolbar.Children.Add(link);
        DockPanel.SetDock(toolbar, Dock.Top);
        DockPanel.SetDock(note, Dock.Top);
        main.Children.Add(toolbar);
        main.Children.Add(note);
        hint.HorizontalAlignment = HorizontalAlignment.Center;
        scroller = new ScrollViewer { Content = list, VerticalScrollBarVisibility = ScrollBarVisibility.Auto };
        main.Children.Add(new Grid { Children = { hint, scroller } });
        Children.Add(needsTool);
        Children.Add(main);
        Ui.Refresh += Update;
        Update();
    }

    void Update()
    {
        var model = YouTubeModel.Shared;
        var ready = Tool.Find("yt-dlp") != null;
        needsTool.Visibility = ready ? Visibility.Collapsed : Visibility.Visible;
        main.Visibility = ready ? Visibility.Visible : Visibility.Collapsed;
        if (!ready)
        {
            installYtDlp.Content = ToolInstaller.Button("yt-dlp");
            return;
        }
        detect.IsChecked = model.DetectClipboard;
        saveTo.Header = $"Save to: {Path.GetFileName(model.Directory.TrimEnd('\\'))}…";
        note.Content = Tool.Find("ffmpeg") == null
            ? Ui.Row(6, Ui.Label("ffmpeg is needed to join video and audio.", 12, Ui.Orange), ToolInstaller.Button("ffmpeg"))
            : model.Status is string status ? Ui.Label(status, 12, Ui.Secondary) : null;

        var idle = model.Offer == null && model.Downloads.Count == 0;
        hint.Visibility = idle ? Visibility.Visible : Visibility.Collapsed;
        scroller.Visibility = idle ? Visibility.Collapsed : Visibility.Visible;
        hint.Text = model.DetectClipboard ? "Copy a YouTube link anywhere and it appears here." : "Paste a YouTube link above.";
        list.Children.Clear();
        if (model.Offer is { } prompt) list.Children.Add(Card(prompt, model));
        foreach (var download in model.Downloads) list.Children.Add(Row(download, model));
    }

    static FrameworkElement Card(YouTubeModel.Prompt prompt, YouTubeModel model)
    {
        var card = new DockPanel();
        var thumbnail = new Border { Width = 64, Height = 36, CornerRadius = new CornerRadius(5), Background = Ui.Faint, Margin = new Thickness(0, 0, 8, 0) };
        if (prompt.Thumbnail != null)
            thumbnail.Background = prompt.Image ??= new ImageBrush(new BitmapImage(prompt.Thumbnail)) { Stretch = Stretch.UniformToFill };
        DockPanel.SetDock(thumbnail, Dock.Left);
        card.Children.Add(thumbnail);
        var quality = model.Quality == "best" ? "best quality" : model.Quality + "p";
        var buttons = Ui.Row(6,
            Ui.TextButton("Video", () => model.Start(new DownloadMode(false, model.Quality)), $"Download video ({quality}, MP4)"),
            Ui.TextButton("Audio", () => model.Start(new DownloadMode(true, model.AudioFormat)), $"Download audio only ({model.AudioFormat.ToUpperInvariant()})"),
            Ui.IconButton(G.Close, "Dismiss", model.Dismiss, 11));
        DockPanel.SetDock(buttons, Dock.Right);
        card.Children.Add(buttons);
        var detail = Ui.Label(prompt.Error ?? prompt.Duration ?? "Looking up…", 12, prompt.Error == null ? Ui.Secondary : Ui.Red);
        detail.ToolTip = prompt.Error;
        card.Children.Add(Ui.Column(1, Ui.Label(prompt.Title ?? prompt.Url.AbsoluteUri, 13, bold: true), detail));
        return new Border { Child = card, Padding = new Thickness(6), Background = Ui.Faint, CornerRadius = new CornerRadius(8), Margin = new Thickness(0, 0, 0, 4) };
    }

    static FrameworkElement Row(Download download, YouTubeModel model)
    {
        var row = new DockPanel { Height = 26 };
        var icon = Ui.Icon(download.Mode.Audio ? G.Music : G.Film, 13, Ui.Secondary);
        icon.Width = 20;
        DockPanel.SetDock(icon, Dock.Left);
        row.Children.Add(icon);
        var remove = Ui.IconButton(G.Close, download.State == Download.States.Running ? "Cancel" : "Remove", () => model.Remove(download), 11);
        UIElement status = download.State switch
        {
            Download.States.Waiting => Ui.Row(4, Ui.Label("Waiting", 12, Ui.Secondary), remove),
            Download.States.Running => Ui.Row(6, new ProgressBar { Width = 70, Height = 4, Minimum = 0, Maximum = 1, Value = download.Fraction, VerticalAlignment = VerticalAlignment.Center },
                                              Ui.Label($"{(int)(download.Fraction * 100)}%", 12, Ui.Secondary), remove),
            Download.States.Done => Ui.Row(2, Ui.IconButton(G.Reveal, "Show in Explorer", () => Ui.Reveal(download.File!), 13), remove),
            _ => Ui.Row(4, Ui.Icon(G.Warning, 12, Ui.Red), new TextBlock
            {
                Text = download.Error, Foreground = Ui.Red, FontSize = 12, MaxWidth = 200, ToolTip = download.Error,
                TextTrimming = TextTrimming.CharacterEllipsis, VerticalAlignment = VerticalAlignment.Center,
            }, remove),
        };
        DockPanel.SetDock(status, Dock.Right);
        row.Children.Add(status);
        row.Children.Add(Ui.Label(download.Title));
        return row;
    }
}
