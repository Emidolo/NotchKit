using System.Diagnostics;
using System.IO.Pipes;
using System.Runtime.InteropServices;
using System.Security.AccessControl;
using System.Security.Principal;
using System.Text.Json;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Hosting;
using NotchKit;

var builder = Host.CreateApplicationBuilder(args);
builder.Services.AddWindowsService(options => options.ServiceName = "NotchKitService");
builder.Services.AddHostedService<PowerService>();
builder.Build().Run();

/// Runs as LocalSystem in session 0, where nothing visual works, so it does only the power side: a power request
/// that keeps the system (and optionally the display) awake, and the lid action. The tray app tells it what it wants
/// over a named pipe; when the app quits or crashes the pipe breaks and everything goes back to normal.
sealed class PowerService : BackgroundService
{
    static readonly string savedLid = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData), "NotchKit", "lid-saved.json");
    readonly IntPtr request = PowerCreateRequest(new REASON_CONTEXT { Flags = 1, Reason = "NotchKit Keep Awake" });
    PowerState applied = PowerState.Off;

    protected override async Task ExecuteAsync(CancellationToken stop)
    {
        // A crash or power cut may have left the lid action switched off.
        Apply(PowerState.Off, force: true);
        while (!stop.IsCancellationRequested)
        {
            try
            {
                using var pipe = NamedPipeServerStreamAcl.Create(PowerState.PipeName, PipeDirection.In, 1, PipeTransmissionMode.Byte,
                                                                 PipeOptions.Asynchronous, 0, 0, Security());
                await pipe.WaitForConnectionAsync(stop);
                using var reader = new StreamReader(pipe);
                while (await reader.ReadLineAsync(stop) is string line)
                {
                    PowerState? state = null;
                    try { state = JsonSerializer.Deserialize<PowerState>(line); } catch (JsonException) { }
                    if (state != null) Apply(state);
                }
            }
            catch (OperationCanceledException) { }
            catch (IOException) { }
            finally { Apply(PowerState.Off); }   // the app is gone: let the PC sleep again
        }
    }

    /// Only people signed in at this PC may talk to the service.
    // ponytail: any interactive user can ask it to keep the PC awake; check the caller against the console session if that matters.
    static PipeSecurity Security()
    {
        var security = new PipeSecurity();
        security.AddAccessRule(new PipeAccessRule(new SecurityIdentifier(WellKnownSidType.LocalSystemSid, null), PipeAccessRights.FullControl, AccessControlType.Allow));
        security.AddAccessRule(new PipeAccessRule(new SecurityIdentifier(WellKnownSidType.InteractiveSid, null), PipeAccessRights.ReadWrite, AccessControlType.Allow));
        return security;
    }

    void Apply(PowerState state, bool force = false)
    {
        if (state.Awake != applied.Awake) Set(PowerRequestSystemRequired, state.Awake);
        if (state.Display != applied.Display) Set(PowerRequestDisplayRequired, state.Display);
        if (state.Lid != applied.Lid || force) SyncLid(state.Lid);
        applied = state;
    }

    void Set(int type, bool on)
    {
        if (on) PowerSetRequest(request, type); else PowerClearRequest(request, type);
    }

    /// With the lid "on", closing it does nothing. The previous values are saved to a file first,
    /// so they come back even after a crash.
    static void SyncLid(bool on)
    {
        int[]? saved = null;
        try { if (File.Exists(savedLid)) saved = JsonSerializer.Deserialize<int[]>(File.ReadAllText(savedLid)); }
        catch (JsonException) { File.Delete(savedLid); }
        if (on == (saved != null)) return;
        if (on)
        {
            if (PowerCfg.LidAction(RunPowerCfg("/q", "SCHEME_CURRENT", "SUB_BUTTONS", "LIDACTION")) is not (int ac, int dc)) return;
            Directory.CreateDirectory(Path.GetDirectoryName(savedLid)!);
            File.WriteAllText(savedLid, JsonSerializer.Serialize(new[] { ac, dc }));
            SetLid(0, 0);
        }
        else
        {
            // The file sits in ProgramData, so only values powercfg means are used.
            if (saved is [var ac, var dc] && PowerCfg.IsLidAction(ac) && PowerCfg.IsLidAction(dc)) SetLid(ac, dc);
            File.Delete(savedLid);
        }
    }

    static void SetLid(int ac, int dc)
    {
        RunPowerCfg("/setacvalueindex", "SCHEME_CURRENT", "SUB_BUTTONS", "LIDACTION", ac.ToString());
        RunPowerCfg("/setdcvalueindex", "SCHEME_CURRENT", "SUB_BUTTONS", "LIDACTION", dc.ToString());
        RunPowerCfg("/setactive", "SCHEME_CURRENT");
    }

    static string RunPowerCfg(params string[] arguments)
    {
        var info = new ProcessStartInfo("powercfg") { UseShellExecute = false, CreateNoWindow = true, RedirectStandardOutput = true };
        foreach (var argument in arguments) info.ArgumentList.Add(argument);
        using var process = Process.Start(info)!;
        var output = process.StandardOutput.ReadToEnd();
        process.WaitForExit();
        return output;
    }

    public override void Dispose()
    {
        Apply(PowerState.Off);
        CloseHandle(request);
        base.Dispose();
    }

    const int PowerRequestDisplayRequired = 0, PowerRequestSystemRequired = 1;
    // Only the simple-string form of the context is used, which needs just these three fields.
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct REASON_CONTEXT { public uint Version; public uint Flags; [MarshalAs(UnmanagedType.LPWStr)] public string Reason; }
    [DllImport("kernel32.dll", SetLastError = true)] static extern IntPtr PowerCreateRequest(in REASON_CONTEXT context);
    [DllImport("kernel32.dll")] static extern bool PowerSetRequest(IntPtr request, int type);
    [DllImport("kernel32.dll")] static extern bool PowerClearRequest(IntPtr request, int type);
    [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr handle);
}
