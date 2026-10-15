using System;
using System.IO;
using System.Linq;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using Microsoft.Win32;

namespace NotchKit;

/// Settings, as one JSON file in %APPDATA%\NotchKit. Every Set writes it.
static class Prefs
{
    static readonly string directory = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "NotchKit");
    static readonly string file = Path.Combine(directory, "settings.json");
    static readonly JsonObject data = Load();

    static JsonObject Load()
    {
        try { return JsonNode.Parse(File.ReadAllText(file)) as JsonObject ?? new JsonObject(); }
        catch (Exception) { return new JsonObject(); }   // missing or damaged: start from the defaults
    }

    public static T Get<T>(string key, T fallback)
    {
        try { return data[key] is JsonNode node ? node.Deserialize<T>() ?? fallback : fallback; }
        catch (Exception) { return fallback; }
    }

    public static void Set<T>(string key, T value)
    {
        data[key] = JsonSerializer.SerializeToNode(value);
        Directory.CreateDirectory(directory);
        var temporary = file + ".tmp";
        File.WriteAllText(temporary, data.ToJsonString(new JsonSerializerOptions { WriteIndented = true }));
        File.Move(temporary, file, true);
    }
}

static class Startup
{
    const string RunKey = @"Software\Microsoft\Windows\CurrentVersion\Run";
    static string Command => $"\"{Environment.ProcessPath}\"";

    /// Registers the copy that is running now.
    public static bool LaunchAtLogin
    {
        get
        {
            using var key = Registry.CurrentUser.OpenSubKey(RunKey);
            return key?.GetValue("NotchKit") as string == Command;
        }
        set
        {
            using var key = Registry.CurrentUser.CreateSubKey(RunKey);
            if (value) key.SetValue("NotchKit", Command);
            else key.DeleteValue("NotchKit", false);
        }
    }

    public static string? ChooseFolder(string? start)
    {
        var dialog = new OpenFolderDialog { InitialDirectory = start ?? "" };
        return dialog.ShowDialog() == true ? dialog.FolderName : null;
    }
}

/// A key combination for the system-wide "open the notch" shortcut. `Modifiers` uses RegisterHotKey's MOD_ flags,
/// which have the same values as WPF's ModifierKeys.
public record Shortcut(uint Modifiers, uint Key, string Label)
{
    public static readonly Shortcut Standard = new(1 | 2, 'N', "Ctrl+Alt+N");
    public static Shortcut Current => Prefs.Get<Shortcut?>("shortcut", null) ?? Standard;
}

sealed class SettingsWindow : Window
{
    static SettingsWindow? shown;
    readonly TabControl tabs = new();
    readonly StackPanel widgetList = new();
    readonly TextBlock shortcutRefused = Ui.Label("Windows refused this shortcut. Another app is probably using it; record a different one.", 12, Ui.Red);

    public static void Open(string? tab = null)
    {
        shown ??= new SettingsWindow();
        if (tab != null && shown.tabs.Items.OfType<TabItem>().FirstOrDefault(t => (string)t.Tag == tab) is TabItem item) shown.tabs.SelectedItem = item;
        shown.Show();
        if (shown.WindowState == WindowState.Minimized) shown.WindowState = WindowState.Normal;
        shown.Activate();
    }

    SettingsWindow()
    {
        Title = "NotchKit Settings";
        Width = 580;
        Height = 700;
        WindowStartupLocation = WindowStartupLocation.CenterScreen;
        tabs.Items.Add(Tab("General", "general", General()));
        tabs.Items.Add(Tab("Widgets", "widgets", Widgets()));
        tabs.Items.Add(Tab("Keep Awake", "keepAwake", KeepAwakeView.Settings()));
        Content = tabs;
        Action refresh = Update;
        Ui.Refresh += refresh;
        Closed += (_, _) => { Ui.Refresh -= refresh; shown = null; };
        Update();
    }

    static TabItem Tab(string title, string id, UIElement content) => new()
    {
        Header = title, Tag = id,
        Content = new ScrollViewer { Content = content, Padding = new Thickness(20, 12, 20, 20), VerticalScrollBarVisibility = ScrollBarVisibility.Auto },
    };

    public static StackPanel Section(string title, params UIElement[] rows)
    {
        var section = new StackPanel { Margin = new Thickness(0, 0, 0, 18) };
        section.Children.Add(new TextBlock { Text = title, FontSize = 15, FontWeight = FontWeights.SemiBold, Margin = new Thickness(0, 0, 0, 6) });
        foreach (var row in rows)
        {
            if (row is FrameworkElement element) element.Margin = new Thickness(0, 3, 0, 3);
            section.Children.Add(row);
        }
        return section;
    }

    public static CheckBox Check(string label, bool value, Action<bool> changed)
    {
        var box = new CheckBox { Content = label, IsChecked = value };
        box.Click += (_, _) => changed(box.IsChecked == true);
        return box;
    }

    public static TextBlock Note(string text) =>
        new() { Text = text, FontSize = 12, Opacity = 0.7, TextWrapping = TextWrapping.Wrap };

    static FrameworkElement Labeled(string label, FrameworkElement control)
    {
        var dock = new DockPanel();
        var text = new TextBlock { Text = label, VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(0, 0, 12, 0) };
        DockPanel.SetDock(text, Dock.Left);
        dock.Children.Add(text);
        dock.Children.Add(control);
        return dock;
    }

    StackPanel General()
    {
        var notch = NotchWindow.Shared;
        var delayLabel = new TextBlock();
        void ShowDelay(double v) => delayLabel.Text = $"Open after hovering for {v:0.00} s";
        var delay = new Slider { Minimum = 0, Maximum = 1, TickFrequency = 0.05, IsSnapToTickEnabled = true, Value = Prefs.Get("hoverDelay", 0.15) };
        delay.ValueChanged += (_, e) => { Prefs.Set("hoverDelay", e.NewValue); ShowDelay(e.NewValue); };
        ShowDelay(delay.Value);

        var height = Ui.Picker("Panel height", v => notch.PanelHeight = double.Parse(v));
        Ui.SetOptions(height, [("Compact", "180"), ("Regular", "220"), ("Tall", "300")], notch.PanelHeight.ToString());

        var recorder = new Button { HorizontalAlignment = HorizontalAlignment.Left, Padding = new Thickness(12, 4, 12, 5), ToolTip = "Click, then press the keys. Needs Ctrl or Alt. Esc cancels." };
        var recording = false;
        void ShowShortcut() => recorder.Content = recording ? "Press a shortcut…" : Shortcut.Current.Label;
        recorder.Click += (_, _) => { recording = !recording; ShowShortcut(); };
        recorder.LostKeyboardFocus += (_, _) => { recording = false; ShowShortcut(); };
        recorder.PreviewKeyDown += (_, e) =>
        {
            if (!recording) return;
            e.Handled = true;
            var key = e.Key == Key.System ? e.SystemKey : e.Key;
            if (key == Key.Escape) { recording = false; ShowShortcut(); return; }
            var modifiers = Keyboard.Modifiers;
            if (key is Key.LeftCtrl or Key.RightCtrl or Key.LeftAlt or Key.RightAlt or Key.LeftShift or Key.RightShift or Key.LWin or Key.RWin) return;
            // A plain letter must never become a global shortcut.
            if ((modifiers & (ModifierKeys.Control | ModifierKeys.Alt)) == 0) return;
            var name = key is >= Key.D0 and <= Key.D9 ? key.ToString()[1..] : key.ToString();
            var label = string.Join("+", new[] { (ModifierKeys.Control, "Ctrl"), (ModifierKeys.Alt, "Alt"), (ModifierKeys.Shift, "Shift"), (ModifierKeys.Windows, "Win") }
                .Where(m => modifiers.HasFlag(m.Item1)).Select(m => m.Item2).Append(name));
            Prefs.Set("shortcut", new Shortcut((uint)modifiers, (uint)KeyInterop.VirtualKeyFromKey(key), label));
            recording = false;
            ShowShortcut();
            AppHost.ApplyShortcut();
        };
        ShowShortcut();

        var launchNote = Note("Registers this copy of NotchKit.exe, so keep it where it is.");
        var launch = Check("Launch at login", Startup.LaunchAtLogin, on =>
        {
            try { Startup.LaunchAtLogin = on; launchNote.Text = "Registers this copy of NotchKit.exe, so keep it where it is."; }
            catch (Exception e) { launchNote.Text = e.Message; }
        });

        var converter = ConverterModel.Shared;
        var youTube = YouTubeModel.Shared;
        var converted = new TextBlock { TextTrimming = TextTrimming.CharacterEllipsis, VerticalAlignment = VerticalAlignment.Center };
        var downloads = new TextBlock { TextTrimming = TextTrimming.CharacterEllipsis, VerticalAlignment = VerticalAlignment.Center };
        void ShowFolders()
        {
            converted.Text = converter.OutputDirectory ?? "Next to the original";
            downloads.Text = youTube.Directory;
        }
        ShowFolders();

        var key = new PasswordBox { Password = AskModel.ApiKey };
        key.PasswordChanged += (_, _) => AskModel.ApiKey = key.Password;
        var model = new TextBox { Text = AskModel.Shared.Model };
        model.TextChanged += (_, _) => AskModel.Shared.Model = model.Text;

        return Ui.Column(0,
            Section("Notch",
                delayLabel, delay,
                Labeled("Panel height", height),
                Check("Hide over fullscreen apps", Prefs.Get("hideInFullscreen", false), on => { Prefs.Set("hideInFullscreen", on); notch.UpdateVisibility(); }),
                Check("Keyboard shortcut to open the notch", Prefs.Get("shortcutEnabled", true), on => { Prefs.Set("shortcutEnabled", on); AppHost.ApplyShortcut(); }),
                Labeled("Shortcut", recorder),
                shortcutRefused),
            Section("Startup", launch, launchNote),
            Section("Folders",
                Labeled("Converted files", Ui.Row(6, Ui.TextButton("Choose…", () => { if (Startup.ChooseFolder(converter.OutputDirectory) is string f) { converter.OutputDirectory = f; ShowFolders(); } }),
                                                     Ui.TextButton("Reset", () => { converter.OutputDirectory = null; ShowFolders(); }), converted)),
                Labeled("Downloads", Ui.Row(6, Ui.TextButton("Choose…", () => { if (Startup.ChooseFolder(youTube.Directory) is string f) { youTube.Directory = f; ShowFolders(); } }), downloads))),
            Section("Clipboard",
                Check("Offer a download when a YouTube link is copied", youTube.DetectClipboard, on => youTube.DetectClipboard = on)),
            Section("Ask",
                Labeled("OpenAI API key", key),
                Labeled("Model", model),
                Note($"Empty uses {AskApi.DefaultModel}. The key is kept in Windows Credential Manager and sent only to api.openai.com.")));
    }

    StackPanel Widgets() => Ui.Column(8, widgetList,
        Note("Use the arrows to reorder the tabs. A widget that is switched off also stops working in the background."));

    void Update()
    {
        shortcutRefused.Visibility = AppHost.ShortcutRefused ? Visibility.Visible : Visibility.Collapsed;
        shortcutRefused.TextWrapping = TextWrapping.Wrap;
        widgetList.Children.Clear();
        foreach (var widget in WidgetStore.All)
        {
            var row = new DockPanel { Margin = new Thickness(0, 2, 0, 2) };
            var enabled = new CheckBox { IsChecked = WidgetStore.IsEnabled(widget.Id), ToolTip = "Show this widget", MinWidth = 0 };
            enabled.Click += (_, _) => WidgetStore.SetEnabled(widget.Id, enabled.IsChecked == true);
            System.Windows.Automation.AutomationProperties.SetName(enabled, widget.Title);
            DockPanel.SetDock(enabled, Dock.Right);
            row.Children.Add(enabled);
            row.Children.Add(Ui.Row(6,
                Ui.IconButton(G.Up, $"Move {widget.Title} up", () => WidgetStore.Move(widget.Id, -1), 12),
                Ui.IconButton(G.Down, $"Move {widget.Title} down", () => WidgetStore.Move(widget.Id, 1), 12),
                Ui.Icon(widget.Glyph, 16), new TextBlock { Text = widget.Title, VerticalAlignment = VerticalAlignment.Center }));
            widgetList.Children.Add(row);
        }
    }
}
