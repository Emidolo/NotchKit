using System;
using System.Collections.Generic;
using System.IO;
using System.IO.Pipes;
using System.Linq;
using System.Runtime.InteropServices;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Interop;
using Forms = System.Windows.Forms;

namespace NotchKit;

static class Program
{
    public static readonly string PipeName = "NotchKit-" + Environment.UserName;

    // For checking layouts without a mouse:
    //   NotchKit.exe --open [widget id]     starts expanded
    //   NotchKit.exe --settings [tab]       opens Settings
    //   NotchKit.exe --launch-at-login      same as switching it on in Settings
    // Files passed on the command line (or dropped on the exe) go to the Converter.
    [STAThread]
    static int Main(string[] args)
    {
        args = args.Select(a => File.Exists(a) ? Path.GetFullPath(a) : a).ToArray();
        using var mutex = new Mutex(true, @"Local\NotchKit", out var first);
        // One NotchKit per user: a second launch hands its arguments to the first and leaves.
        if (!first) return Forward(args) ? 0 : 1;
        // A Claude Code hook ran while NotchKit isn't running. There is nobody to tell.
        if (args.FirstOrDefault() == "--claude") return 0;

        var app = new Application { ShutdownMode = ShutdownMode.OnExplicitShutdown, ThemeMode = ThemeMode.Dark };
        app.Startup += (_, _) => AppHost.Start(args);
        app.Exit += (_, _) => AppHost.Stop();
        return app.Run();
    }

    static bool Forward(string[] args)
    {
        try
        {
            using var pipe = new NamedPipeClientStream(".", PipeName, PipeDirection.Out, PipeOptions.CurrentUserOnly);
            pipe.Connect(2000);
            using var writer = new StreamWriter(pipe);
            writer.Write(JsonSerializer.Serialize(args));
            return true;
        }
        catch (Exception e) when (e is IOException or TimeoutException or UnauthorizedAccessException)
        {
            return false;
        }
    }
}

/// The app-wide plumbing: tray icon, global shortcut, clipboard, and arguments from later launches.
static class AppHost
{
    const int WM_HOTKEY = 0x0312, WM_CLIPBOARDUPDATE = 0x031D, MOD_NOREPEAT = 0x4000;
    static HwndSource messages = null!;
    static Forms.NotifyIcon tray = null!;
    /// Windows refused the shortcut, usually because another app has it.
    public static bool ShortcutRefused { get; private set; }

    public static void Start(string[] args)
    {
        new NotchWindow().Show();
        // A message-only window (parent HWND_MESSAGE) for the hotkey and clipboard notifications.
        messages = new HwndSource(new HwndSourceParameters("NotchKit") { ParentWindow = new IntPtr(-3) });
        messages.AddHook(WndProc);
        AddClipboardFormatListener(messages.Handle);
        ApplyShortcut();
        tray = MakeTray();
        KeepAwake.Shared.Start();
        _ = Listen();
        Handle(args);
    }

    public static void Stop()
    {
        KeepAwake.Shared.Stop();
        tray.Visible = false;
        tray.Dispose();
    }

    public static void ApplyShortcut()
    {
        UnregisterHotKey(messages.Handle, 1);
        var shortcut = Shortcut.Current;
        ShortcutRefused = Prefs.Get("shortcutEnabled", true) && !RegisterHotKey(messages.Handle, 1, shortcut.Modifiers | MOD_NOREPEAT, shortcut.Key);
        Ui.Changed();
    }

    static IntPtr WndProc(IntPtr hwnd, int message, IntPtr wParam, IntPtr lParam, ref bool handled)
    {
        if (message == WM_HOTKEY) NotchWindow.Shared.Toggle();
        if (message == WM_CLIPBOARDUPDATE) ClipboardChanged();
        return IntPtr.Zero;
    }

    static async void ClipboardChanged(int attempt = 0)
    {
        string text;
        try
        {
            if (!Clipboard.ContainsText()) return;
            text = Clipboard.GetText();
        }
        catch (COMException)
        {
            // The app that just copied still has the clipboard open.
            if (attempt < 3) { await Task.Delay(100); ClipboardChanged(attempt + 1); }
            return;
        }
        if (text.Length == 0) return;
        YouTubeModel.Shared.Copied(text);
        TyperModel.Shared.Copied(text);
    }

    /// Arguments from this launch or a later one: files, --claude, --open, --settings, --launch-at-login.
    public static void Handle(string[] args)
    {
        var files = new List<string>();
        for (var i = 0; i < args.Length; i++)
        {
            var next = i + 1 < args.Length && !args[i + 1].StartsWith("--") ? args[i + 1] : null;
            switch (args[i])
            {
                case "--claude":
                    if (next != null && ClaudeHooks.Parse(next) is ClaudeEvent e) KeepAwake.Shared.OnClaude(e);
                    break;
                case "--open":
                    if (next != null) NotchWindow.Shared.Selected = next;
                    NotchWindow.Shared.Expand();
                    break;
                case "--settings":
                    SettingsWindow.Open(next);
                    break;
                case "--launch-at-login":
                    Startup.LaunchAtLogin = true;
                    continue;
                default:
                    if (File.Exists(args[i])) files.Add(args[i]);
                    continue;
            }
            if (next != null) i++;
        }
        if (files.Count == 0) return;
        ConverterModel.Shared.Add(files);
        NotchWindow.Shared.Selected = Widget.Converter.Id;
        NotchWindow.Shared.Expand();
    }

    static async Task Listen()
    {
        while (true)
        {
            try
            {
                using var server = new NamedPipeServerStream(Program.PipeName, PipeDirection.In, 1, PipeTransmissionMode.Byte,
                                                             PipeOptions.Asynchronous | PipeOptions.CurrentUserOnly);
                await server.WaitForConnectionAsync();
                using var reader = new StreamReader(server);
                Handle(JsonSerializer.Deserialize<string[]>(await reader.ReadToEndAsync()) ?? []);
            }
            catch (Exception e) when (e is IOException or JsonException)
            {
                await Task.Delay(1000);
            }
        }
    }

    static Forms.NotifyIcon MakeTray()
    {
        var menu = new Forms.ContextMenuStrip();
        var open = menu.Items.Add("Open Notch", null, (_, _) => NotchWindow.Shared.Toggle());
        menu.Items.Add("Settings…", null, (_, _) => SettingsWindow.Open());
        menu.Items.Add(new Forms.ToolStripSeparator());
        menu.Items.Add("Quit NotchKit", null, (_, _) => Application.Current.Shutdown());
        menu.Opening += (_, _) => open.Text = (NotchWindow.Shared.Expanded ? "Close Notch" : "Open Notch")
            + (Prefs.Get("shortcutEnabled", true) && !ShortcutRefused ? "    " + Shortcut.Current.Label : "");
        var icon = new Forms.NotifyIcon { Icon = TrayIcon(), Text = "NotchKit", ContextMenuStrip = menu, Visible = true };
        icon.MouseClick += (_, e) => { if (e.Button == Forms.MouseButtons.Left) NotchWindow.Shared.Toggle(); };
        return icon;
    }

    /// A screen outline with the notch in it, drawn rather than shipped as a file.
    static System.Drawing.Icon TrayIcon()
    {
        using var bitmap = new System.Drawing.Bitmap(32, 32);
        using (var graphics = System.Drawing.Graphics.FromImage(bitmap))
        {
            graphics.SmoothingMode = System.Drawing.Drawing2D.SmoothingMode.AntiAlias;
            using var pen = new System.Drawing.Pen(System.Drawing.Color.White, 2.5f);
            graphics.DrawRectangle(pen, 3, 6, 26, 20);
            graphics.FillRectangle(System.Drawing.Brushes.White, 10, 6, 12, 6);
        }
        return System.Drawing.Icon.FromHandle(bitmap.GetHicon());
    }

    [DllImport("user32.dll")] static extern bool AddClipboardFormatListener(IntPtr hwnd);
    [DllImport("user32.dll")] static extern bool RegisterHotKey(IntPtr hwnd, int id, uint modifiers, uint key);
    [DllImport("user32.dll")] static extern bool UnregisterHotKey(IntPtr hwnd, int id);
}
