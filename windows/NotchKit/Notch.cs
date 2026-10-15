using System;
using System.Collections.Generic;
using System.Linq;
using System.Runtime.InteropServices;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Media.Animation;
using System.Windows.Threading;

namespace NotchKit;

/// One tool in the expanded notch. Its view is built once and kept, so typed text survives switching tabs.
sealed class Widget(string id, string title, string glyph, Func<FrameworkElement> makeView, Func<FrameworkElement?>? indicator = null)
{
    public string Id => id;
    public string Title => title;
    public string Glyph => glyph;
    /// Small view shown on the collapsed notch while the widget has something going on; null when idle.
    public FrameworkElement? Indicator() => indicator?.Invoke();
    FrameworkElement? view;
    public FrameworkElement View => view ??= makeView();

    public static readonly Widget Music = new("music", "Music", G.Music, () => new MusicView());
    public static readonly Widget Converter = new("converter", "Converter", G.Convert, () => new ConverterView(),
        () => ConverterModel.Shared.Progress is double p ? Ui.ProgressRing(p) : null);
    public static readonly Widget YouTube = new("youtube", "YouTube", G.Download, () => new YouTubeView(),
        () => YouTubeModel.Shared.Progress is double p ? Ui.ProgressRing(p) : null);
    public static readonly Widget KeepAwake = new("keepAwake", "Keep Awake", G.Awake, () => new KeepAwakeView(), KeepAwakeView.Indicator);
    public static readonly Widget Ask = new("ask", "Ask", G.Ask, () => new AskView());
    public static readonly Widget Typer = new("typer", "Typer", G.Keyboard, () => new TyperView(), TyperView.Indicator);

    /// Everything the app has, in default order. A new widget is added here.
    public static readonly Widget[] Registry = [Music, Converter, YouTube, KeepAwake, Ask, Typer];
}

/// Which widgets are switched on, and in what order.
static class WidgetStore
{
    static readonly List<string> order = WidgetOrder.Resolve(Prefs.Get("widgetOrder", new List<string>()), Widget.Registry.Select(w => w.Id).ToList());
    static readonly HashSet<string> disabled = Prefs.Get("disabledWidgets", new HashSet<string>());

    public static IEnumerable<Widget> All => order.Select(id => Widget.Registry.First(w => w.Id == id));
    public static List<Widget> Visible => All.Where(w => !disabled.Contains(w.Id)).ToList();
    public static bool IsEnabled(string id) => !disabled.Contains(id);

    /// A switched-off widget also stops working in the background (no keep-awake, no clipboard prompts).
    public static void SetEnabled(string id, bool on)
    {
        if (on) disabled.Remove(id); else disabled.Add(id);
        Prefs.Set("disabledWidgets", disabled);
        KeepAwake.Shared.Evaluate();
        Ui.Changed();
    }

    public static void Move(string id, int by)
    {
        int from = order.IndexOf(id), to = from + by;
        if (to < 0 || to >= order.Count) return;
        (order[from], order[to]) = (order[to], order[from]);
        Prefs.Set("widgetOrder", order);
        Ui.Changed();
    }
}

/// Windows has no notch, so NotchKit draws one: a small black tab at the top centre of the main screen that
/// opens into the panel on hover. The window is always the full panel size; everything outside the black shape
/// is fully transparent, which Windows treats as click-through, so the apps beneath stay usable.
sealed class NotchWindow : Window
{
    public static NotchWindow Shared { get; private set; } = null!;
    const double ExpandedWidth = 600, IdleWidth = 180, IdleHeight = 7, EarsWidth = 240, EarsHeight = 26, StripHeight = 38, HoverPad = 6;

    public bool Expanded { get; private set; }
    /// Id of the widget on show. Falls back to the first visible one when empty or switched off.
    public string Selected = "";
    double panelHeight = Prefs.Get("panelHeight", 220.0);
    public double PanelHeight
    {
        get => panelHeight;
        set
        {
            panelHeight = value;
            Prefs.Set("panelHeight", value);
            Height = value + HoverPad;
            if (Expanded) Animate();
        }
    }

    // Alpha 1 is invisible but still takes the mouse: a slightly taller hover target than the visible tab.
    readonly Border hit = new()
    {
        Background = new SolidColorBrush(Color.FromArgb(1, 0, 0, 0)), Padding = new Thickness(0, 0, 0, HoverPad), AllowDrop = true,
        HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Top,
    };
    readonly Border shape = new() { Background = Brushes.Black, ClipToBounds = true, Width = IdleWidth, Height = IdleHeight };
    readonly StackPanel indicators = new() { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center };
    readonly DockPanel expanded = new() { Width = ExpandedWidth, VerticalAlignment = VerticalAlignment.Top, Visibility = Visibility.Collapsed };
    readonly StackPanel tabs = new() { Orientation = Orientation.Horizontal, VerticalAlignment = VerticalAlignment.Center };
    readonly TextBlock title = Ui.Label("NotchKit", 12, Ui.Secondary);
    readonly ContentControl body = new() { Margin = new Thickness(16, 4, 16, 14), Foreground = Brushes.White };
    readonly FrameworkElement allOff = Ui.EmptyHint(G.Grid, "Every widget is switched off", "Turn some back on in Settings.");
    bool ears;
    string tabsShown = "";
    int hoverToken;

    public NotchWindow()
    {
        Shared = this;
        Title = "NotchKit";
        WindowStyle = WindowStyle.None;
        AllowsTransparency = true;
        Background = Brushes.Transparent;
        ResizeMode = ResizeMode.NoResize;
        Topmost = true;
        ShowInTaskbar = false;
        ShowActivated = false;
        Width = ExpandedWidth;
        Height = panelHeight + HoverPad;
        Top = 0;
        Left = (SystemParameters.PrimaryScreenWidth - ExpandedWidth) / 2;

        var strip = new DockPanel { Height = StripHeight, Margin = new Thickness(12, 0, 12, 0) };
        var right = Ui.Row(6, title, Ui.IconButton(G.Settings, "Settings", () => SettingsWindow.Open(), 13));
        DockPanel.SetDock(right, Dock.Right);
        strip.Children.Add(right);
        strip.Children.Add(tabs);
        DockPanel.SetDock(strip, Dock.Top);
        expanded.Children.Add(strip);
        expanded.Children.Add(body);
        shape.Child = new Grid { Children = { indicators, expanded } };
        hit.Child = shape;
        Content = hit;

        hit.MouseEnter += (_, _) => Hover(true);
        hit.MouseLeave += (_, _) => Hover(false);
        hit.PreviewMouseLeftButtonDown += (_, _) => Expand();
        hit.DragEnter += (_, _) => Hover(true);
        hit.DragLeave += (_, _) => Hover(false);
        hit.Drop += (_, e) =>
        {
            // Files dropped anywhere on the notch go to the Converter.
            if (e.Data.GetData(DataFormats.FileDrop) is not string[] files) return;
            Selected = Widget.Converter.Id;
            ConverterModel.Shared.Add(files);
            Render();
        };
        // The panel never takes focus by itself, so the app you're in keeps it. Text fields ask for it when clicked.
        PreviewMouseDown += (_, e) => { if (e.OriginalSource is DependencyObject d && IsTextInput(d)) Activate(); };
        SourceInitialized += (_, _) =>
        {
            var handle = new WindowInteropHelper(this).Handle;
            SetWindowLong(handle, GWL_EXSTYLE, GetWindowLong(handle, GWL_EXSTYLE) | WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE);
        };
        Ui.Refresh += Render;
        new DispatcherTimer(TimeSpan.FromSeconds(2), DispatcherPriority.Background, (_, _) => UpdateVisibility(), Dispatcher).Start();
        Render();
    }

    static bool IsTextInput(DependencyObject element)
    {
        for (var d = element; d != null; d = VisualTreeHelper.GetParent(d) ?? LogicalTreeHelper.GetParent(d))
            if (d is TextBoxBase or PasswordBox) return true;
        return false;
    }

    public void Toggle() { if (Expanded) Collapse(); else Expand(); }

    public void Expand()
    {
        hoverToken++;
        if (Expanded) return;
        Expanded = true;
        if (!IsVisible) Show();
        Render();
        Animate();
    }

    public void Collapse()
    {
        if (!Expanded) return;
        Expanded = false;
        Animate();
        UpdateVisibility();
    }

    /// Opens without a hover (a link was copied) and closes again if the cursor never comes over.
    public async void Peek()
    {
        Expand();
        var token = ++hoverToken;
        await Task.Delay(6000);
        if (token == hoverToken && !CursorInside()) Collapse();
    }

    /// Hover (or a drag) entered or left the notch. Opens after the hover delay, closes shortly after leaving.
    async void Hover(bool inside)
    {
        var token = ++hoverToken;
        await Task.Delay(TimeSpan.FromSeconds(inside ? Prefs.Get("hoverDelay", 0.15) : 0.2));
        if (token != hoverToken) return;
        if (inside) Expand();
        // A drop-down, menu or slider drag holds the mouse; look again once it lets go.
        else if (Mouse.Captured != null) Hover(false);
        // Leave events also fire when the shape resizes under a still cursor; only close if it really left.
        else if (!CursorInside()) Collapse();
    }

    bool CursorInside()
    {
        if (!IsVisible || !GetCursorPos(out var cursor)) return false;
        var point = hit.PointFromScreen(new Point(cursor.X, cursor.Y));
        return point.X >= -1 && point.Y >= -1 && point.X <= hit.ActualWidth + 1 && point.Y <= hit.ActualHeight + 1;
    }

    void Animate()
    {
        double width = Expanded ? ExpandedWidth : ears ? EarsWidth : IdleWidth;
        double height = Expanded ? panelHeight : ears ? EarsHeight : IdleHeight;
        var radius = Expanded ? 20 : ears ? 10 : 4;
        shape.CornerRadius = new CornerRadius(0, 0, radius, radius);
        var ease = new CubicEase { EasingMode = EasingMode.EaseOut };
        shape.BeginAnimation(WidthProperty, new DoubleAnimation(width, TimeSpan.FromMilliseconds(260)) { EasingFunction = ease });
        shape.BeginAnimation(HeightProperty, new DoubleAnimation(height, TimeSpan.FromMilliseconds(260)) { EasingFunction = ease });
        expanded.Height = panelHeight;
        expanded.Visibility = Expanded ? Visibility.Visible : Visibility.Collapsed;
        indicators.Visibility = !Expanded && ears ? Visibility.Visible : Visibility.Collapsed;
        if (Expanded) expanded.BeginAnimation(OpacityProperty, new DoubleAnimation(0, 1, TimeSpan.FromMilliseconds(180)));
    }

    void Render()
    {
        var widgets = WidgetStore.Visible;
        var current = widgets.FirstOrDefault(w => w.Id == Selected) ?? widgets.FirstOrDefault();

        // Tabs are rebuilt only when they change, so a click in progress isn't lost to a progress update.
        var key = string.Join(",", widgets.Select(w => w.Id)) + "|" + current?.Id;
        if (key != tabsShown)
        {
            tabsShown = key;
            tabs.Children.Clear();
            foreach (var widget in widgets)
            {
                var tab = Ui.IconButton(widget.Glyph, widget.Title, () => { Selected = widget.Id; Render(); }, 15);
                tab.Width = 32;
                tab.Height = 26;
                tab.Margin = new Thickness(0, 0, 4, 0);
                tab.Background = widget == current ? Ui.Selected : Brushes.Transparent;
                tabs.Children.Add(tab);
            }
        }
        title.Text = current?.Title ?? "NotchKit";
        var view = current?.View ?? allOff;
        if (body.Content != view) body.Content = view;

        indicators.Children.Clear();
        foreach (var widget in widgets)
            if (widget.Indicator() is FrameworkElement indicator)
            {
                indicator.Margin = new Thickness(indicators.Children.Count == 0 ? 0 : 10, 0, 0, 0);
                indicators.Children.Add(indicator);
            }
        var wanted = indicators.Children.Count > 0;
        if (wanted != ears)
        {
            ears = wanted;
            if (!Expanded) Animate();
        }
    }

    /// Hides the collapsed notch over fullscreen apps (games, videos, presentations) when Settings asks for it.
    public void UpdateVisibility()
    {
        var hide = !Expanded && Prefs.Get("hideInFullscreen", false)
            && SHQueryUserNotificationState(out var state) == 0 && state is 2 or 3 or 4;   // busy, D3D fullscreen, presentation
        if (hide && IsVisible) Hide();
        else if (!hide && !IsVisible) Show();
    }

    const int GWL_EXSTYLE = -20, WS_EX_TOOLWINDOW = 0x80, WS_EX_NOACTIVATE = 0x08000000;
    [StructLayout(LayoutKind.Sequential)] struct POINT { public int X, Y; }
    [DllImport("user32.dll")] static extern int GetWindowLong(IntPtr hwnd, int index);
    [DllImport("user32.dll")] static extern int SetWindowLong(IntPtr hwnd, int index, int value);
    [DllImport("user32.dll")] static extern bool GetCursorPos(out POINT point);
    [DllImport("shell32.dll")] static extern int SHQueryUserNotificationState(out int state);
}
