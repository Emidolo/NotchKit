using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.IO.Pipes;
using System.Linq;
using System.Media;
using System.Runtime.InteropServices;
using System.Text.Encodings.Web;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Threading;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Threading;
using Microsoft.Win32;
using Forms = System.Windows.Forms;

namespace NotchKit;

sealed class KeepAwake
{
    public static readonly KeepAwake Shared = new();
    public record Session(DateTime Start, DateTime End, string Reason);

    /// Change a property, then call SaveRules.
    public KeepAwakeRules Rules { get; } = Prefs.Get("keepAwakeRules", new KeepAwakeRules());
    /// When the manual session ends; DateTime.MaxValue means until turned off. null: no manual session.
    public DateTime? ManualUntil { get; private set; }
    /// Why the PC is being kept awake. Empty: it isn't.
    public List<string> Reasons { get; private set; } = [];
    /// What stopped keep-awake although something asked for it (low battery).
    public string? Blocked { get; private set; }
    public (ClaudeEvent Event, DateTime At)? Claude { get; private set; }
    public List<Session> Log { get; } = Prefs.Get("keepAwakeLog", new List<Session>());
    /// Why closed-lid mode can't work right now.
    public string? LidNote { get; private set; }
    public bool IsActive => Reasons.Count > 0;

    const uint ES_CONTINUOUS = 0x80000000, ES_SYSTEM_REQUIRED = 0x1, ES_DISPLAY_REQUIRED = 0x2;
    uint applied = ES_CONTINUOUS;
    DateTime? sessionStart;
    string sessionReason = "";
    CancellationTokenSource? manualTimer, claudeTimer;
    DispatcherTimer? processTimer;
    HashSet<string> processes = new(StringComparer.OrdinalIgnoreCase);
    int ticks;

    /// Hooks up what the rules react to: power and display events, and a process poll only while a process rule is on.
    public void Start()
    {
        // SystemEvents call back on their own thread.
        SystemEvents.PowerModeChanged += (_, _) => Application.Current.Dispatcher.InvokeAsync(Evaluate);
        SystemEvents.DisplaySettingsChanged += (_, _) => Application.Current.Dispatcher.InvokeAsync(Evaluate);
        WatchProcesses();
        // Once a second for the countdown on show; the battery level is rechecked every 30.
        new DispatcherTimer(TimeSpan.FromSeconds(1), DispatcherPriority.Background, (_, _) =>
        {
            if (++ticks % 30 == 0) Evaluate();
            else if (ManualUntil is DateTime until && until != DateTime.MaxValue) Ui.Changed();
        }, Application.Current.Dispatcher).Start();
        Evaluate();
    }

    public void Stop()
    {
        SetThreadExecutionState(ES_CONTINUOUS);
        ServiceLink.Close();
    }

    public void SaveRules()
    {
        Prefs.Set("keepAwakeRules", Rules);
        WatchProcesses();
        Evaluate();
    }

    /// null keeps awake until turned off.
    public async void TurnOn(int? minutes)
    {
        manualTimer?.Cancel();
        ManualUntil = minutes is int m ? DateTime.Now.AddMinutes(m) : DateTime.MaxValue;
        Evaluate();
        if (minutes is not int length) return;
        var cancel = (manualTimer = new CancellationTokenSource()).Token;
        try { await Task.Delay(TimeSpan.FromMinutes(length), cancel); }
        catch (TaskCanceledException) { return; }
        TurnOff();
    }

    public void TurnOff()
    {
        manualTimer?.Cancel();
        ManualUntil = null;
        Evaluate();
    }

    public void OnClaude(ClaudeEvent e)
    {
        claudeTimer?.Cancel();
        if (e == ClaudeEvent.Ended)
        {
            Claude = null;
            Evaluate();
            return;
        }
        Claude = (e, DateTime.Now);
        if (Rules.ClaudeSound && e != ClaudeEvent.Working) (e == ClaudeEvent.Finished ? SystemSounds.Asterisk : SystemSounds.Exclamation).Play();
        Expire(e, (claudeTimer = new CancellationTokenSource()).Token);
        Evaluate();
    }

    async void Expire(ClaudeEvent e, CancellationToken cancel)
    {
        // "Working" with no follow-up means the session died; give up on it eventually.
        // ponytail: one status for all Claude sessions, latest event wins. Track session ids if that confuses.
        try { await Task.Delay(TimeSpan.FromMinutes(e == ClaudeEvent.Working ? 120 : Rules.ClaudeGraceMinutes), cancel); }
        catch (TaskCanceledException) { return; }
        // "Needs input" stays on show until answered; the others have run their course.
        if (e != ClaudeEvent.Input) Claude = null;
        Evaluate();
    }

    bool ClaudeKeepsAwake => Claude is (ClaudeEvent e, DateTime at)
        && (e == ClaudeEvent.Working || DateTime.Now - at < TimeSpan.FromMinutes(Rules.ClaudeGraceMinutes));

    public void Evaluate()
    {
        var power = Forms.SystemInformation.PowerStatus;
        var onAC = power.PowerLineStatus != Forms.PowerLineStatus.Offline;
        int? battery = power.BatteryChargeStatus.HasFlag(Forms.BatteryChargeStatus.NoSystemBattery) || power.BatteryLifePercent > 1
            ? null : (int)Math.Round(power.BatteryLifePercent * 100);
        // ponytail: "external display" means more than one screen, so a closed laptop on one monitor doesn't count.
        var inputs = new KeepAwakeInputs(ManualUntil != null, processes, ConverterModel.Shared.IsRunning || YouTubeModel.Shared.Progress != null,
                                         onAC, battery, Forms.Screen.AllScreens.Length > 1, ClaudeKeepsAwake);
        var (reasons, blocked) = WidgetStore.IsEnabled(Widget.KeepAwake.Id) ? Rules.Decide(inputs) : (new List<string>(), null);
        // A manual session stopped by low battery stays stopped, rather than resuming when the charger returns.
        if (blocked != null && ManualUntil != null)
        {
            manualTimer?.Cancel();
            ManualUntil = null;
        }
        var wasActive = IsActive;
        Reasons = reasons;
        Blocked = blocked;
        // NotchKitService does the work when it is installed. Without it the app keeps the PC awake itself,
        // but can't change the lid action (that needs the service's rights) or clean up after a crash.
        var state = new PowerState(IsActive, IsActive && !Rules.AllowDisplaySleep, IsActive && Rules.ClosedLid);
        var viaService = ServiceLink.Send(state);
        LidNote = state.Lid && !viaService ? "Closed-lid mode needs NotchKit Service, which isn't running. See the README to install it." : null;
        var wanted = viaService || !IsActive ? ES_CONTINUOUS : ES_CONTINUOUS | ES_SYSTEM_REQUIRED | (Rules.AllowDisplaySleep ? 0 : ES_DISPLAY_REQUIRED);
        // Per thread: always called on the UI thread, which lives as long as the app.
        if (wanted != applied && SetThreadExecutionState(wanted) != 0) applied = wanted;
        if (IsActive && !wasActive)
        {
            sessionStart = DateTime.Now;
            sessionReason = Reasons[0];
        }
        else if (!IsActive && wasActive && sessionStart is DateTime start)
        {
            Log.Insert(0, new Session(start, DateTime.Now, sessionReason));
            if (Log.Count > 100) Log.RemoveRange(100, Log.Count - 100);
            Prefs.Set("keepAwakeLog", Log);
            sessionStart = null;
        }
        Ui.Changed();
    }

    void WatchProcesses()
    {
        var needed = Rules.WhileProcesses && Rules.Processes.Any(p => p.Enabled);
        if (needed == (processTimer != null)) return;
        processTimer?.Stop();
        processTimer = null;
        processes = new(StringComparer.OrdinalIgnoreCase);
        if (!needed) return;
        // There is no process-started event without WMI, and one list every 10 seconds costs next to nothing.
        processTimer = new DispatcherTimer(TimeSpan.FromSeconds(10), DispatcherPriority.Background, (_, _) => PollProcesses(), Application.Current.Dispatcher);
        processTimer.Start();
        PollProcesses();
    }

    void PollProcesses()
    {
        var names = new HashSet<string>(Process.GetProcesses().Select(p => { using (p) return p.ProcessName; }), StringComparer.OrdinalIgnoreCase);
        if (names.SetEquals(processes)) return;
        processes = names;
        Evaluate();
    }

    /// Adds or removes the hooks in ~/.claude/settings.json. Returns what to tell the user.
    public static string InstallHooks(bool install)
    {
        var path = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".claude", "settings.json");
        try
        {
            var settings = File.Exists(path) ? JsonNode.Parse(File.ReadAllText(path)) as JsonObject : new JsonObject();
            if (settings == null) return $"{path} doesn't look like a Claude Code settings file. Nothing was changed.";
            ClaudeHooks.Apply(settings, install, Environment.ProcessPath!);
            Directory.CreateDirectory(Path.GetDirectoryName(path)!);
            if (File.Exists(path)) File.Copy(path, path + ".notchkit-backup", true);
            var temporary = path + ".notchkit-tmp";
            var options = new JsonSerializerOptions { WriteIndented = true, Encoder = JavaScriptEncoder.UnsafeRelaxedJsonEscaping };
            File.WriteAllText(temporary, settings.ToJsonString(options) + "\n");
            File.Move(temporary, path, true);
            return install ? "Hooks installed. New Claude Code sessions will report to NotchKit." : "Hooks removed.";
        }
        catch (JsonException) { return $"{path} isn't valid JSON. Nothing was changed."; }
        catch (InvalidDataException) { return $"{path} doesn't look like a Claude Code settings file. Nothing was changed."; }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException) { return e.Message; }
    }

    [DllImport("kernel32.dll")] static extern uint SetThreadExecutionState(uint flags);
}

/// The pipe to NotchKitService. One JSON line per Evaluate; the service resets everything when the pipe closes.
static class ServiceLink
{
    static NamedPipeClientStream? pipe;
    static StreamWriter? writer;
    static DateTime nextTry;

    public static bool Send(PowerState state)
    {
        if (writer == null)
        {
            // Not installed is the normal case for some people: don't block the UI thread on every check.
            if (DateTime.Now < nextTry) return false;
            nextTry = DateTime.Now.AddSeconds(30);
            try
            {
                pipe = new NamedPipeClientStream(".", PowerState.PipeName, PipeDirection.Out);
                pipe.Connect(100);
                writer = new StreamWriter(pipe) { AutoFlush = true };
            }
            catch (Exception e) when (e is IOException or TimeoutException or UnauthorizedAccessException)
            {
                Close();
                return false;
            }
        }
        try
        {
            writer.WriteLine(JsonSerializer.Serialize(state));
            return true;
        }
        catch (IOException)
        {
            // The service restarted. It comes back on the next try.
            Close();
            return false;
        }
    }

    public static void Close()
    {
        writer = null;
        pipe?.Dispose();
        pipe = null;
    }
}

sealed class KeepAwakeView : DockPanel
{
    readonly Border circle = new() { Width = 60, Height = 60, CornerRadius = new CornerRadius(30) };
    readonly Button toggle;
    readonly TextBlock headline = Ui.Label("", 15, bold: true);
    readonly TextBlock countdown = Ui.Label("", 15, Ui.Orange, bold: true);
    readonly TextBlock detail = Ui.Label("", 12);
    readonly ContentControl claude = new();
    readonly CheckBox displaySleep = new() { Content = "Allow display sleep", ToolTip = "Keep the system awake but let the screen turn off." };

    static string ClaudeGlyph(ClaudeEvent e) => e switch { ClaudeEvent.Working => G.Bolt, ClaudeEvent.Input => G.Ask, _ => G.Check };
    static Brush ClaudeColor(ClaudeEvent e) => e switch { ClaudeEvent.Working => Ui.Orange, ClaudeEvent.Input => Ui.Yellow, _ => Ui.Green };

    static string Remaining(DateTime until)
    {
        var left = until - DateTime.Now;
        if (left < TimeSpan.Zero) left = TimeSpan.Zero;
        return left.TotalHours >= 1 ? left.ToString(@"h\:mm\:ss") : left.ToString(@"m\:ss");
    }

    public static FrameworkElement? Indicator()
    {
        var keepAwake = KeepAwake.Shared;
        if (!keepAwake.IsActive && keepAwake.Claude == null) return null;
        var row = new StackPanel { Orientation = Orientation.Horizontal, VerticalAlignment = VerticalAlignment.Center };
        if (keepAwake.Claude is (ClaudeEvent e, _))
        {
            var icon = Ui.Icon(ClaudeGlyph(e), 11, ClaudeColor(e));
            icon.ToolTip = KeepAwakeRules.ClaudeLabel(e);
            icon.Margin = new Thickness(0, 0, 5, 0);
            row.Children.Add(icon);
        }
        if (keepAwake.ManualUntil is DateTime until && until != DateTime.MaxValue) row.Children.Add(Ui.Label(Remaining(until), 11, bold: true));
        else if (keepAwake.IsActive) row.Children.Add(Ui.Icon(G.Awake, 12));
        return row;
    }

    public KeepAwakeView()
    {
        var keepAwake = KeepAwake.Shared;
        circle.Child = Ui.Icon(G.Awake, 24);
        toggle = new Button { Content = circle, Padding = new Thickness(0), Background = Brushes.Transparent, BorderThickness = new Thickness(0), VerticalAlignment = VerticalAlignment.Center };
        toggle.Click += (_, _) => { if (keepAwake.ManualUntil == null) keepAwake.TurnOn(null); else keepAwake.TurnOff(); };
        DockPanel.SetDock(toggle, Dock.Left);
        Children.Add(toggle);

        displaySleep.Click += (_, _) => { keepAwake.Rules.AllowDisplaySleep = displaySleep.IsChecked == true; keepAwake.SaveRules(); };
        var side = Ui.Column(8, displaySleep, Ui.TextButton("Rules…", () => SettingsWindow.Open("keepAwake"), "Automatic rules, closed-lid mode, Claude Code and the session log"));
        side.VerticalAlignment = VerticalAlignment.Center;
        ((FrameworkElement)side.Children[1]).HorizontalAlignment = HorizontalAlignment.Right;
        DockPanel.SetDock(side, Dock.Right);
        Children.Add(side);

        var custom = new TextBox { Width = 48, ToolTip = "Custom duration in minutes, then Enter" };
        System.Windows.Automation.AutomationProperties.SetName(custom, "Minutes");
        custom.KeyDown += (_, e) =>
        {
            if (e.Key != Key.Return) return;
            if (int.TryParse(custom.Text, out var minutes) && minutes is >= 1 and <= 1440) keepAwake.TurnOn(minutes);
            custom.Text = "";
        };
        var durations = Ui.Row(4, new[] { 15, 30, 60, 120 }
            .Select(m => (UIElement)Ui.TextButton(m < 60 ? $"{m}m" : $"{m / 60}h", () => keepAwake.TurnOn(m), $"Keep awake for {m} minutes"))
            .Append(custom).ToArray());
        var column = Ui.Column(4, Ui.Row(8, headline, countdown), detail, durations, claude);
        column.Margin = new Thickness(14, 0, 8, 0);
        Children.Add(column);
        Ui.Refresh += Update;
        Update();
    }

    void Update()
    {
        var keepAwake = KeepAwake.Shared;
        circle.Background = keepAwake.IsActive ? Ui.Orange : Ui.Faint;
        var label = keepAwake.ManualUntil == null ? "Keep awake until turned off" : "Stop keeping awake";
        toggle.ToolTip = label;
        System.Windows.Automation.AutomationProperties.SetName(toggle, label);
        headline.Text = keepAwake.IsActive ? "Keeping awake" : "Sleep allowed";
        countdown.Text = keepAwake.ManualUntil is DateTime until && until != DateTime.MaxValue ? Remaining(until) : "";
        detail.Foreground = keepAwake.Blocked == null ? Ui.Secondary : Ui.Orange;
        detail.Text = keepAwake.Blocked ?? keepAwake.Reasons.Count switch
        {
            0 => "Turn on, or pick a duration.",
            1 => keepAwake.Reasons[0],
            var n => $"{keepAwake.Reasons[0]} (+{n - 1} more)",
        };
        detail.ToolTip = string.Join("\n", keepAwake.Reasons);
        displaySleep.IsChecked = keepAwake.Rules.AllowDisplaySleep;
        claude.Content = keepAwake.Claude is (ClaudeEvent e, _)
            ? Ui.Row(5, Ui.Icon(ClaudeGlyph(e), 12, ClaudeColor(e)), Ui.Label(KeepAwakeRules.ClaudeLabel(e), 12, ClaudeColor(e)))
            : null;
    }

    /// The Keep Awake tab of the Settings window.
    public static FrameworkElement Settings()
    {
        var keepAwake = KeepAwake.Shared;
        var rules = keepAwake.Rules;
        CheckBox Rule(string label, Func<bool> get, Action<bool> set) =>
            SettingsWindow.Check(label, get(), on => { set(on); keepAwake.SaveRules(); });

        var processList = new StackPanel { Margin = new Thickness(24, 0, 0, 0) };
        var add = new TextBox();
        System.Windows.Automation.AutomationProperties.SetName(add, "Add a process name");
        void ShowProcesses()
        {
            processList.Children.Clear();
            processList.Visibility = rules.WhileProcesses ? Visibility.Visible : Visibility.Collapsed;
            foreach (var process in rules.Processes)
            {
                var row = new DockPanel();
                var remove = Ui.IconButton(G.Delete, $"Remove {process.Name}", () => { rules.Processes.Remove(process); keepAwake.SaveRules(); ShowProcesses(); }, 12);
                DockPanel.SetDock(remove, Dock.Right);
                row.Children.Add(remove);
                row.Children.Add(Rule(process.Name, () => process.Enabled, on => process.Enabled = on));
                processList.Children.Add(row);
            }
            processList.Children.Add(add);
            processList.Children.Add(SettingsWindow.Note("Type a process name (as in Task Manager's Details tab, without .exe) and press Enter. Checked every 10 seconds."));
        }
        add.KeyDown += (_, e) =>
        {
            if (e.Key != Key.Return) return;
            var name = add.Text.Trim();
            if (name.EndsWith(".exe", StringComparison.OrdinalIgnoreCase)) name = name[..^4];
            if (name.Length > 0 && !rules.Processes.Any(p => p.Name.Equals(name, StringComparison.OrdinalIgnoreCase)))
            {
                rules.Processes.Add(new KeepAwakeRules.Proc { Name = name });
                keepAwake.SaveRules();
            }
            add.Text = "";
            ShowProcesses();
            add.Focus();
        };
        ShowProcesses();

        var graceLabel = new TextBlock();
        var grace = new Slider { Minimum = 1, Maximum = 60, Value = rules.ClaudeGraceMinutes, IsSnapToTickEnabled = true, TickFrequency = 1 };
        void ShowGrace() => graceLabel.Text = $"Stay awake {rules.ClaudeGraceMinutes} min after it finishes";
        grace.ValueChanged += (_, e) => { rules.ClaudeGraceMinutes = (int)e.NewValue; keepAwake.SaveRules(); ShowGrace(); };
        ShowGrace();
        var hooksNote = SettingsWindow.Note("Adds hooks to ~/.claude/settings.json so Claude Code reports to the notch.");
        var hooks = Ui.Row(6,
            Ui.TextButton("Install Hooks", () => hooksNote.Text = KeepAwake.InstallHooks(true)),
            Ui.TextButton("Remove Hooks", () => hooksNote.Text = KeepAwake.InstallHooks(false)));

        var floorLabel = new TextBlock();
        var floor = new Slider { Minimum = 5, Maximum = 90, Value = rules.BatteryFloor, IsSnapToTickEnabled = true, TickFrequency = 5 };
        void ShowFloor() => floorLabel.Text = $"Battery level: {rules.BatteryFloor}%";
        floor.ValueChanged += (_, e) => { rules.BatteryFloor = (int)e.NewValue; keepAwake.SaveRules(); ShowFloor(); };
        ShowFloor();

        var lidNote = new TextBlock { Foreground = Ui.Red, FontSize = 12, TextWrapping = TextWrapping.Wrap };
        var log = new StackPanel();
        void ShowDynamic()
        {
            lidNote.Text = keepAwake.LidNote ?? "";
            lidNote.Visibility = keepAwake.LidNote == null ? Visibility.Collapsed : Visibility.Visible;
            log.Children.Clear();
            if (keepAwake.Log.Count == 0) log.Children.Add(SettingsWindow.Note("Nothing yet."));
            foreach (var session in keepAwake.Log.Take(20))
            {
                var row = new DockPanel();
                var reason = new TextBlock { Text = session.Reason, Opacity = 0.7 };
                DockPanel.SetDock(reason, Dock.Right);
                row.Children.Add(reason);
                var length = session.End - session.Start;
                row.Children.Add(new TextBlock { Text = $"{session.Start:g}   {(int)length.TotalHours}h {length.Minutes}m {length.Seconds}s" });
                log.Children.Add(row);
            }
        }
        ShowDynamic();

        var warning = SettingsWindow.Note($"A closed laptop cannot cool itself well. Never put it in a bag like this. Sleep comes back when keep-awake ends, " +
                                          $"on battery below {rules.BatteryFloor}% (if that limit is on), and when NotchKit quits.");
        warning.Foreground = Ui.Orange;
        warning.Opacity = 1;

        var panel = Ui.Column(0,
            SettingsWindow.Section("Keep awake automatically",
                Rule("While a download or conversion is running", () => rules.WhileBusy, on => rules.WhileBusy = on),
                Rule("While on AC power", () => rules.WhileOnAC, on => rules.WhileOnAC = on),
                Rule("While an external display is connected", () => rules.WhileExternalDisplay, on => rules.WhileExternalDisplay = on),
                Rule("While these apps or processes are running", () => rules.WhileProcesses, on => { rules.WhileProcesses = on; ShowProcesses(); }),
                processList),
            SettingsWindow.Section("Claude Code",
                Rule("While Claude Code is working", () => rules.WhileClaude, on => rules.WhileClaude = on),
                graceLabel, grace,
                Rule("Play a sound when Claude finishes or needs input", () => rules.ClaudeSound, on => rules.ClaudeSound = on),
                hooks, hooksNote),
            SettingsWindow.Section("Battery and display",
                Rule("Stop keeping awake on battery below the level below", () => rules.BatteryFloorEnabled, on => rules.BatteryFloorEnabled = on),
                floorLabel, floor,
                Rule("Allow display sleep while keeping the system awake", () => rules.AllowDisplaySleep, on => rules.AllowDisplaySleep = on)),
            SettingsWindow.Section("Closed lid",
                SettingsWindow.Note("Normally closing the lid puts a laptop to sleep. With this on, closing it does nothing while keep-awake is active " +
                                    "(NotchKit Service sets the power plan's lid action to \"Do nothing\" and puts it back afterwards, even after a crash)."),
                warning,
                Rule("Stay awake with the lid closed", () => rules.ClosedLid, on => rules.ClosedLid = on),
                lidNote),
            SettingsWindow.Section("Recent sessions", log));
        Action refresh = ShowDynamic;
        panel.Loaded += (_, _) => Ui.Refresh += refresh;
        panel.Unloaded += (_, _) => Ui.Refresh -= refresh;
        return panel;
    }
}
