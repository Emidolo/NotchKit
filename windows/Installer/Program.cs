using System;
using System.ComponentModel;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.Net;
using System.Windows.Forms;

/// One window, one progress bar: download the real installer, run it without questions, done.
static class Program
{
    // GitHub redirects "latest" to the newest release, so this exe never needs rebuilding for a new version.
    const string SetupUrl = "https://github.com/Emidolo/NotchKit/releases/latest/download/NotchKit-setup.exe";

    [STAThread]
    static void Main()
    {
        // .NET Framework may default to old TLS versions, which GitHub refuses.
        ServicePointManager.SecurityProtocol |= SecurityProtocolType.Tls12;
        Application.EnableVisualStyles();

        var form = new Form
        {
            Text = "NotchKit", ClientSize = new Size(380, 112), FormBorderStyle = FormBorderStyle.FixedDialog,
            MaximizeBox = false, MinimizeBox = false, StartPosition = FormStartPosition.CenterScreen, Font = SystemFonts.MessageBoxFont,
        };
        var label = new Label { Text = "Downloading NotchKit…", Location = new Point(16, 18), AutoSize = true };
        var bar = new ProgressBar { Location = new Point(16, 46), Size = new Size(348, 18) };
        var cancel = new Button { Text = "Cancel", Location = new Point(289, 76), Size = new Size(75, 26) };
        form.Controls.AddRange(new Control[] { label, bar, cancel });

        var setup = Path.Combine(Path.GetTempPath(), "NotchKit-setup.exe");
        var client = new WebClient();
        client.DownloadProgressChanged += (_, e) => bar.Value = e.ProgressPercentage;
        client.DownloadFileCompleted += (_, e) =>
        {
            if (e.Cancelled) { form.Close(); return; }
            if (e.Error != null)
            {
                Fail(form, "NotchKit couldn't be downloaded. Check the internet connection and try again.\n\n" + e.Error.Message);
                return;
            }
            Install(form, setup);
        };
        cancel.Click += (_, _) => client.CancelAsync();
        form.Shown += (_, _) => client.DownloadFileAsync(new Uri(SetupUrl), setup);
        Application.Run(form);
    }

    static void Install(Form form, string setup)
    {
        form.Hide();
        try
        {
            // /SILENT: no questions, just Setup's own progress window. Windows asks for permission first,
            // because the background service has to be registered. NotchKit opens by itself at the end.
            using (var process = Process.Start(new ProcessStartInfo(setup, "/SILENT /SUPPRESSMSGBOXES /NORESTART") { UseShellExecute = true }))
            {
                process.WaitForExit();
                // 2 and 5: the person cancelled Setup, which needs no message.
                if (process.ExitCode != 0 && process.ExitCode != 2 && process.ExitCode != 5)
                {
                    Fail(form, $"NotchKit couldn't be installed (Setup error {process.ExitCode}). Try again, or download NotchKit-setup.exe from GitHub.");
                    return;
                }
            }
        }
        catch (Win32Exception)
        {
            // The permission prompt was declined.
            Fail(form, "NotchKit needs permission to install. Open this again and choose Yes.");
            return;
        }
        finally
        {
            try { File.Delete(setup); } catch (IOException) { }
        }
        form.Close();
    }

    static void Fail(Form form, string message)
    {
        MessageBox.Show(message, "NotchKit", MessageBoxButtons.OK, MessageBoxIcon.Error);
        form.Close();
    }
}
