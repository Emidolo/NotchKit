using System;
using System.IO;
using System.Linq;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using Windows.Media.Control;
using Windows.Storage.Streams;

namespace NotchKit;

/// Whatever Windows shows in its media flyout: Spotify, a browser tab, Media Player… through the system media session,
/// so no player needs a plugin and nothing is polled.
// ponytail: no volume slider. The session API has none; a per-app slider needs Core Audio's session COM interfaces.
sealed class MusicModel
{
    public static readonly MusicModel Shared = new();

    public bool HasSession { get; private set; }
    public string Title { get; private set; } = "";
    public string Artist { get; private set; } = "";
    public string Source { get; private set; } = "";
    public bool IsPlaying { get; private set; }
    public BitmapImage? Artwork { get; private set; }

    GlobalSystemMediaTransportControlsSessionManager? manager;
    GlobalSystemMediaTransportControlsSession? session;
    string artworkFor = "";
    bool started;

    public async void Start()
    {
        if (started) return;
        started = true;
        try { manager = await GlobalSystemMediaTransportControlsSessionManager.RequestAsync(); }
        catch (Exception) { return; }
        // The session events arrive on a thread-pool thread.
        manager.CurrentSessionChanged += (_, _) => OnUi(Attach);
        Attach();
    }

    static void OnUi(Action action) => Application.Current.Dispatcher.InvokeAsync(action);

    void Attach()
    {
        if (session != null)
        {
            session.MediaPropertiesChanged -= Changed;
            session.PlaybackInfoChanged -= Changed;
        }
        session = manager?.GetCurrentSession();
        if (session != null)
        {
            session.MediaPropertiesChanged += Changed;
            session.PlaybackInfoChanged += Changed;
        }
        _ = Refresh();
    }

    void Changed<T>(GlobalSystemMediaTransportControlsSession sender, T args) => OnUi(() => _ = Refresh());

    async Task Refresh()
    {
        var current = session;
        HasSession = current != null;
        if (current != null)
        {
            try
            {
                IsPlaying = current.GetPlaybackInfo()?.PlaybackStatus == GlobalSystemMediaTransportControlsSessionPlaybackStatus.Playing;
                Source = AppName(current.SourceAppUserModelId);
                var properties = await current.TryGetMediaPropertiesAsync();
                Title = properties.Title ?? "";
                Artist = properties.Artist ?? "";
                var key = Source + Title + Artist;
                if (key != artworkFor)
                {
                    artworkFor = key;
                    Artwork = properties.Thumbnail == null ? null : await Load(properties.Thumbnail);
                }
            }
            catch (Exception) { }   // the player quit while being read
        }
        Ui.Changed();
    }

    static async Task<BitmapImage> Load(IRandomAccessStreamReference reference)
    {
        using var stream = await reference.OpenReadAsync();
        var memory = new MemoryStream();
        await stream.AsStreamForRead().CopyToAsync(memory);
        memory.Position = 0;
        var image = new BitmapImage();
        image.BeginInit();
        image.CacheOption = BitmapCacheOption.OnLoad;
        image.StreamSource = memory;
        image.EndInit();
        image.Freeze();
        return image;
    }

    /// "Spotify.exe" or "SpotifyAB.SpotifyMusic_zpdnekdrzrea0!Spotify" → "Spotify".
    static string AppName(string id)
    {
        var name = id.Split('!').Last();
        if (name.EndsWith(".exe", StringComparison.OrdinalIgnoreCase)) name = name[..^4];
        return name.Split('.').Last();
    }

    public async void Send(string command)
    {
        if (session is not { } current) return;
        try
        {
            _ = command switch
            {
                "playpause" => await current.TryTogglePlayPauseAsync(),
                "next" => await current.TrySkipNextAsync(),
                _ => await current.TrySkipPreviousAsync(),
            };
        }
        catch (Exception) { }
    }
}

sealed class MusicView : Grid
{
    readonly Border artwork = new() { Width = 96, Height = 96, CornerRadius = new CornerRadius(10), Background = Ui.Faint };
    readonly TextBlock placeholder = Ui.Icon(G.Music, 30, Ui.Secondary);
    readonly TextBlock title = Ui.Label("", 15, bold: true);
    readonly TextBlock subtitle = Ui.Label("", 13, Ui.Secondary);
    readonly Button play;
    readonly DockPanel playing = new();
    readonly FrameworkElement idle = Ui.EmptyHint(G.Music, "Nothing playing", "Play something in Spotify, a browser or any media app to control it from here.");

    public MusicView()
    {
        MusicModel.Shared.Start();
        var model = MusicModel.Shared;
        artwork.Child = placeholder;
        DockPanel.SetDock(artwork, Dock.Left);
        play = Control(G.Play, "Play", 22, () => model.Send("playpause"));
        var details = new DockPanel { Margin = new Thickness(16, 0, 0, 0) };
        var text = Ui.Column(2, title, subtitle);
        DockPanel.SetDock(text, Dock.Top);
        details.Children.Add(text);
        var controls = Ui.Row(6, Control(G.Previous, "Previous", 16, () => model.Send("previous")), play, Control(G.Next, "Next", 16, () => model.Send("next")));
        controls.VerticalAlignment = VerticalAlignment.Bottom;
        details.Children.Add(controls);
        playing.Children.Add(artwork);
        playing.Children.Add(details);
        Children.Add(playing);
        Children.Add(idle);
        Ui.Refresh += Update;
        Update();
    }

    static Button Control(string glyph, string label, double size, Action action)
    {
        var button = Ui.IconButton(glyph, label, action, size);
        button.Width = 44;
        button.Height = 38;
        return button;
    }

    void Update()
    {
        var model = MusicModel.Shared;
        playing.Visibility = model.HasSession ? Visibility.Visible : Visibility.Collapsed;
        idle.Visibility = model.HasSession ? Visibility.Collapsed : Visibility.Visible;
        title.Text = model.Title.Length == 0 ? "Nothing playing" : model.Title;
        subtitle.Text = string.Join(" · ", new[] { model.Artist, model.Source }.Where(s => s.Length > 0));
        artwork.Background = model.Artwork != null ? new ImageBrush(model.Artwork) { Stretch = Stretch.UniformToFill } : Ui.Faint;
        placeholder.Visibility = model.Artwork != null ? Visibility.Collapsed : Visibility.Visible;
        ((TextBlock)play.Content).Text = model.IsPlaying ? G.Pause : G.Play;
        play.ToolTip = model.IsPlaying ? "Pause" : "Play";
        System.Windows.Automation.AutomationProperties.SetName(play, model.IsPlaying ? "Pause" : "Play");
    }
}
