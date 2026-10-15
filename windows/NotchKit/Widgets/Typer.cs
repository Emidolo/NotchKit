using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Threading;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;

namespace NotchKit;

/// Types copied text into whatever app has the cursor.
sealed class TyperModel
{
    public static readonly TyperModel Shared = new();
    /// Seconds between the copy and the first key, to get the cursor where the text should go.
    public const int Delay = 3;

    /// Never saved: a relaunch must not come back typing.
    public bool Armed { get; private set; }
    /// Seconds left before typing starts; null when nothing is waiting.
    public int? Countdown { get; private set; }
    /// How much of the text has been typed; null when not typing.
    public double? Progress { get; private set; }
    public double Speed
    {
        get => Prefs.Get("typerSpeed", 40.0);
        set => Prefs.Set("typerSpeed", value);
    }
    CancellationTokenSource? running;

    public void SetArmed(bool on)
    {
        Stop();
        Armed = on;
        Ui.Changed();
    }

    /// Stops the countdown or the typing; Typer stays on for the next copy.
    public void Stop()
    {
        running?.Cancel();
        running = null;
        Countdown = null;
        Progress = null;
        Ui.Changed();
    }

    /// Text landed on the clipboard.
    public async void Copied(string text)
    {
        if (!Armed || !WidgetStore.IsEnabled(Widget.Typer.Id)) return;
        Stop();
        var keys = Typer.Keystrokes(text);
        var cancel = (running = new CancellationTokenSource()).Token;
        try
        {
            var clock = Stopwatch.StartNew();
            while (clock.Elapsed.TotalSeconds < Delay)
            {
                Countdown = Delay - (int)clock.Elapsed.TotalSeconds;
                Ui.Changed();
                await Tick(cancel);
            }
            Countdown = null;
            // Keys go out in step with the clock rather than one per timer tick, which Windows rounds up to ~15 ms.
            clock.Restart();
            var sent = 0;
            while (sent < keys.Count)
            {
                var due = Math.Min(keys.Count, (int)(clock.Elapsed.TotalSeconds * Speed) + 1);
                while (sent < due) Post(keys[sent++]);
                Progress = (double)sent / keys.Count;
                Ui.Changed();
                await Tick(cancel);
            }
            running = null;
            Progress = null;
            Ui.Changed();
        }
        catch (OperationCanceledException) { }
    }

    /// Esc anywhere stops it. Checked between keys, so there's no keyboard hook running while Typer waits.
    async Task Tick(CancellationToken cancel)
    {
        if ((GetAsyncKeyState(0x1B) & 0x8000) != 0)
        {
            Stop();
            throw new OperationCanceledException();
        }
        await Task.Delay(10, cancel);
    }

    // ponytail: Windows won't let a normal app type into one running as administrator (UIPI); those keys just vanish.
    static void Post((ushort Key, string Text) keystroke)
    {
        var inputs = new List<INPUT>();
        if (keystroke.Key != 0)
        {
            inputs.Add(Key(keystroke.Key, 0, 0));
            inputs.Add(Key(keystroke.Key, 0, KEYEVENTF_KEYUP));
        }
        else
            foreach (var unit in keystroke.Text)
            {
                inputs.Add(Key(0, unit, KEYEVENTF_UNICODE));
                inputs.Add(Key(0, unit, KEYEVENTF_UNICODE | KEYEVENTF_KEYUP));
            }
        SendInput((uint)inputs.Count, inputs.ToArray(), Marshal.SizeOf<INPUT>());
    }

    static INPUT Key(ushort key, ushort unit, uint flags) =>
        new() { Type = 1, Union = new InputUnion { Keyboard = new KEYBDINPUT { VirtualKey = key, Scan = unit, Flags = flags } } };

    const uint KEYEVENTF_KEYUP = 0x2, KEYEVENTF_UNICODE = 0x4;
    [StructLayout(LayoutKind.Sequential)] struct INPUT { public uint Type; public InputUnion Union; }
    // The union is as large as its largest member, MOUSEINPUT, so that is declared too.
    [StructLayout(LayoutKind.Explicit)] struct InputUnion { [FieldOffset(0)] public MOUSEINPUT Mouse; [FieldOffset(0)] public KEYBDINPUT Keyboard; }
    [StructLayout(LayoutKind.Sequential)] struct MOUSEINPUT { public int X, Y; public uint Data, Flags, Time; public IntPtr Extra; }
    [StructLayout(LayoutKind.Sequential)] struct KEYBDINPUT { public ushort VirtualKey, Scan; public uint Flags, Time; public IntPtr Extra; }
    [DllImport("user32.dll")] static extern uint SendInput(uint count, INPUT[] inputs, int size);
    [DllImport("user32.dll")] static extern short GetAsyncKeyState(int key);
}

sealed class TyperView : DockPanel
{
    readonly Button toggle;
    readonly Border circle = new() { Width = 60, Height = 60, CornerRadius = new CornerRadius(30) };
    readonly TextBlock headline = Ui.Label("", 15, bold: true);
    readonly Button stop;
    readonly TextBlock detail = Ui.Label("", 12, Ui.Secondary);
    readonly TextBlock speedLabel = Ui.Label("", 12, Ui.Secondary);

    public static FrameworkElement? Indicator()
    {
        var typer = TyperModel.Shared;
        if (!typer.Armed) return null;
        if (typer.Progress is double progress) return Ui.ProgressRing(progress);
        if (typer.Countdown is int countdown) return Ui.Label(countdown.ToString(), 11, bold: true);
        return Ui.Icon(G.Keyboard, 12);
    }

    public TyperView()
    {
        var typer = TyperModel.Shared;
        circle.Child = Ui.Icon(G.Keyboard, 24);
        toggle = new Button { Content = circle, Padding = new Thickness(0), Background = Brushes.Transparent, BorderThickness = new Thickness(0), VerticalAlignment = VerticalAlignment.Center };
        toggle.Click += (_, _) => typer.SetArmed(!typer.Armed);
        DockPanel.SetDock(toggle, Dock.Left);
        Children.Add(toggle);

        stop = Ui.TextButton("Stop", typer.Stop, "Stop this text. Esc does the same.");
        detail.TextWrapping = TextWrapping.Wrap;
        var speed = Ui.Slider("Typing speed", 5, 200, typer.Speed, v => { typer.Speed = v; ShowSpeed(v); });
        speed.MaxWidth = 320;
        speed.HorizontalAlignment = HorizontalAlignment.Left;
        speed.Width = 320;
        ShowSpeed(typer.Speed);
        var column = Ui.Column(4, Ui.Row(8, headline, stop), detail, speedLabel, speed);
        column.Margin = new Thickness(14, 0, 0, 0);
        Children.Add(column);
        Ui.Refresh += Update;
        Update();
    }

    void ShowSpeed(double value) => speedLabel.Text = $"{(int)value} characters a second";

    void Update()
    {
        var typer = TyperModel.Shared;
        circle.Background = typer.Armed ? Ui.Orange : Ui.Faint;
        toggle.ToolTip = typer.Armed ? "Stop typing copied text" : "Type whatever is copied next";
        System.Windows.Automation.AutomationProperties.SetName(toggle, typer.Armed ? "Turn Typer off" : "Turn Typer on");
        headline.Text = typer.Countdown is int c ? $"Typing in {c}…" : typer.Progress is double p ? $"Typing… {(int)(p * 100)}%" : typer.Armed ? "Waiting for a copy" : "Off";
        stop.Visibility = typer.Countdown != null || typer.Progress != null ? Visibility.Visible : Visibility.Collapsed;
        detail.Text = typer.Armed
            ? $"Copy text, click where it should go, and it is typed after {TyperModel.Delay} seconds. Esc stops it."
            : "Turn on, then copy text to have it typed wherever the cursor is.";
    }
}
