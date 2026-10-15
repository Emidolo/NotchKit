using System;
using System.Collections.Generic;
using System.Linq;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Shapes;
using System.Windows.Threading;

namespace NotchKit;

/// Segoe Fluent Icons / Segoe MDL2 Assets code points, which ship with Windows 10 and 11.
static class G
{
    public const string Music = "", Play = "", Pause = "", Previous = "", Next = "",
        Convert = "", Download = "", Awake = "", Ask = "", Keyboard = "",
        Settings = "", Close = "", Add = "", Delete = "", Folder = "", Reveal = "",
        Copy = "", Stop = "", More = "", Warning = "", Film = "", Photo = "",
        Document = "", Grid = "", Check = "", Bolt = "", Up = "", Down = "";
}

/// Small shared pieces of UI, and the one change signal every view listens to.
static class Ui
{
    /// Raised on the UI thread, at most once per dispatcher pass, after any model called Changed().
    /// Views re-read their model when it fires; there is no per-property binding.
    public static event Action? Refresh;
    static bool queued;

    public static void Changed()
    {
        if (queued) return;
        queued = true;
        Application.Current?.Dispatcher.InvokeAsync(() => { queued = false; Refresh?.Invoke(); }, DispatcherPriority.Background);
    }

    static Brush Solid(byte a, byte r, byte g, byte b)
    {
        var brush = new SolidColorBrush(Color.FromArgb(a, r, g, b));
        brush.Freeze();
        return brush;
    }

    public static readonly Brush Secondary = Solid(0x99, 0xFF, 0xFF, 0xFF), Faint = Solid(0x1A, 0xFF, 0xFF, 0xFF),
        Selected = Solid(0x26, 0xFF, 0xFF, 0xFF), Orange = Solid(0xFF, 0xFF, 0x9F, 0x0A), Red = Solid(0xFF, 0xFF, 0x45, 0x3A),
        Green = Solid(0xFF, 0x30, 0xD1, 0x58), Yellow = Solid(0xFF, 0xFF, 0xD6, 0x0A);
    public static readonly FontFamily IconFont = new("Segoe Fluent Icons, Segoe MDL2 Assets");

    public static TextBlock Icon(string glyph, double size = 14, Brush? color = null) => new()
    {
        Text = glyph, FontFamily = IconFont, FontSize = size, Foreground = color ?? Brushes.White,
        VerticalAlignment = VerticalAlignment.Center, HorizontalAlignment = HorizontalAlignment.Center,
    };

    public static TextBlock Label(string text, double size = 13, Brush? color = null, bool bold = false) => new()
    {
        Text = text, FontSize = size, Foreground = color ?? Brushes.White, FontWeight = bold ? FontWeights.SemiBold : FontWeights.Normal,
        TextTrimming = TextTrimming.CharacterEllipsis, VerticalAlignment = VerticalAlignment.Center,
    };

    /// Small borderless icon button used in widget rows and toolbars.
    public static Button IconButton(string glyph, string label, Action action, double size = 14)
    {
        var button = new Button
        {
            Content = Icon(glyph, size), ToolTip = label, Padding = new Thickness(5), MinWidth = 0, MinHeight = 0,
            Background = Brushes.Transparent, BorderThickness = new Thickness(0), VerticalAlignment = VerticalAlignment.Center,
        };
        AutomationProperties.SetName(button, label);
        button.Click += (_, _) => action();
        return button;
    }

    public static Button TextButton(string text, Action action, string? tip = null, bool accent = false)
    {
        var button = new Button { Content = text, ToolTip = tip, Padding = new Thickness(10, 3, 10, 4), MinHeight = 0, VerticalAlignment = VerticalAlignment.Center };
        if (accent && Application.Current.TryFindResource("AccentButtonStyle") is Style style) button.Style = style;
        button.Click += (_, _) => action();
        return button;
    }

    public static StackPanel Row(double gap, params UIElement[] items) => Stack(Orientation.Horizontal, gap, items);
    public static StackPanel Column(double gap, params UIElement[] items) => Stack(Orientation.Vertical, gap, items);

    static StackPanel Stack(Orientation orientation, double gap, UIElement[] items)
    {
        var stack = new StackPanel { Orientation = orientation, VerticalAlignment = VerticalAlignment.Center };
        foreach (var item in items)
        {
            if (stack.Children.Count > 0 && item is FrameworkElement element)
                element.Margin = orientation == Orientation.Horizontal ? new Thickness(gap, 0, 0, 0) : new Thickness(0, gap, 0, 0);
            stack.Children.Add(item);
        }
        return stack;
    }

    /// The standard indicator: a ring that fills as work completes.
    public static FrameworkElement ProgressRing(double fraction)
    {
        fraction = Math.Clamp(fraction, 0.03, 0.999);
        const double radius = 5.75;   // (14 - stroke) / 2
        var grid = new Grid { Width = 14, Height = 14, VerticalAlignment = VerticalAlignment.Center };
        grid.Children.Add(new Ellipse { Stroke = Selected, StrokeThickness = 2.5 });
        var angle = fraction * 2 * Math.PI;
        var figure = new PathFigure { StartPoint = new Point(7, 7 - radius) };
        figure.Segments.Add(new ArcSegment(new Point(7 + radius * Math.Sin(angle), 7 - radius * Math.Cos(angle)), new Size(radius, radius),
                                           0, fraction > 0.5, SweepDirection.Clockwise, true));
        grid.Children.Add(new Path
        {
            Data = new PathGeometry([figure]), Stroke = Brushes.White, StrokeThickness = 2.5,
            StrokeStartLineCap = PenLineCap.Round, StrokeEndLineCap = PenLineCap.Round,
        });
        AutomationProperties.SetName(grid, $"{(int)(fraction * 100)} percent");
        return grid;
    }

    /// Compact empty state.
    public static FrameworkElement EmptyHint(string glyph, string title, string detail)
    {
        var heading = Label(title, 14, bold: true);
        var body = Label(detail, 12, Secondary);
        body.TextWrapping = TextWrapping.Wrap;
        body.TextAlignment = TextAlignment.Center;
        var column = Column(3, Icon(glyph, 22, Secondary), heading, body);
        foreach (FrameworkElement child in column.Children) child.HorizontalAlignment = HorizontalAlignment.Center;
        column.HorizontalAlignment = HorizontalAlignment.Center;
        return column;
    }

    /// A drop-down of (label, value) pairs. Rebuilding the options doesn't call `changed`.
    public static ComboBox Picker(string name, Action<string> changed)
    {
        var box = new ComboBox { MinWidth = 0, VerticalAlignment = VerticalAlignment.Center };
        AutomationProperties.SetName(box, name);
        box.SelectionChanged += (_, _) =>
        {
            if (box.Tag is not "quiet" && box.SelectedItem is ComboBoxItem { Tag: string value }) changed(value);
        };
        return box;
    }

    public static void SetOptions(ComboBox box, IEnumerable<(string Label, string Value)> options, string selected)
    {
        var list = options.ToList();
        var current = box.Items.OfType<ComboBoxItem>().Select(i => ((string)i.Content, (string)i.Tag)).ToList();
        box.Tag = "quiet";
        if (!current.SequenceEqual(list))
        {
            box.Items.Clear();
            foreach (var (label, value) in list) box.Items.Add(new ComboBoxItem { Content = label, Tag = value });
        }
        box.SelectedIndex = list.FindIndex(o => o.Value == selected);
        box.Tag = null;
    }

    public static Slider Slider(string name, double min, double max, double value, Action<double> changed)
    {
        var slider = new Slider { Minimum = min, Maximum = max, Value = value, VerticalAlignment = VerticalAlignment.Center };
        AutomationProperties.SetName(slider, name);
        slider.ValueChanged += (_, e) => changed(e.NewValue);
        return slider;
    }

    /// Opens Explorer with `path` selected.
    public static void Reveal(string path) =>
        System.Diagnostics.Process.Start("explorer.exe", $"/select,\"{path}\"");
}
