using System;
using System.IO;
using System.Net.Http;
using System.Net.Http.Headers;
using System.Text;
using System.Text.Json.Nodes;
using System.Threading;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Threading;
using Windows.Security.Credentials;

namespace NotchKit;

sealed class AskModel
{
    public static readonly AskModel Shared = new();
    static readonly HttpClient http = new() { Timeout = Timeout.InfiniteTimeSpan };
    const string Vault = "NotchKit", VaultUser = "OpenAI API key";

    public string Answer { get; private set; } = "";
    public string? Error { get; private set; }
    public bool IsRunning => running != null;
    public string Model
    {
        get => Prefs.Get("askModel", "");
        set => Prefs.Set("askModel", value);
    }
    CancellationTokenSource? running;

    /// Kept in Windows Credential Manager, never in the settings file. Empty when none is saved.
    public static string ApiKey
    {
        get
        {
            try
            {
                var credential = new PasswordVault().Retrieve(Vault, VaultUser);
                credential.RetrievePassword();
                return credential.Password;
            }
            catch (Exception) { return ""; }   // Retrieve throws when there is none
        }
        set
        {
            var vault = new PasswordVault();
            try { vault.Remove(vault.Retrieve(Vault, VaultUser)); } catch (Exception) { }
            if (value.Length > 0) vault.Add(new PasswordCredential(Vault, VaultUser, value));
        }
    }

    /// One question, one answer: asking again replaces what was there.
    public async void Ask(string question)
    {
        var text = question.Trim();
        if (text.Length == 0) return;
        Stop();
        Answer = "";
        Error = null;
        var key = ApiKey.Trim();
        if (key.Length == 0)
        {
            Error = "Add your OpenAI API key in Settings → General.";
            Ui.Changed();
            return;
        }
        var model = Model.Trim();
        var body = new JsonObject
        {
            ["model"] = model.Length == 0 ? AskApi.DefaultModel : model,
            ["stream"] = true,
            ["messages"] = new JsonArray(new JsonObject { ["role"] = "user", ["content"] = text }),
        };
        var request = new HttpRequestMessage(HttpMethod.Post, "https://api.openai.com/v1/chat/completions")
        {
            Content = new StringContent(body.ToJsonString(), Encoding.UTF8, "application/json"),
        };
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", key);
        var cancel = running = new CancellationTokenSource();
        Ui.Changed();
        try
        {
            using var response = await http.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, cancel.Token);
            using var reader = new StreamReader(await response.Content.ReadAsStreamAsync(cancel.Token));
            if (!response.IsSuccessStatusCode)
            {
                Error = AskApi.ErrorMessage(await reader.ReadToEndAsync(cancel.Token), (int)response.StatusCode);
                return;
            }
            while (await reader.ReadLineAsync(cancel.Token) is string line)
                if (AskApi.Delta(line) is string piece)
                {
                    Answer += piece;
                    Ui.Changed();
                }
        }
        catch (OperationCanceledException) { }
        catch (HttpRequestException e) { Error = e.Message; }
        catch (IOException e) { Error = e.Message; }
        finally
        {
            if (running == cancel) running = null;
            Ui.Changed();
        }
    }

    public void Stop()
    {
        running?.Cancel();
        running = null;
        Ui.Changed();
    }
}

sealed class AskView : DockPanel
{
    readonly TextBox question = new() { VerticalContentAlignment = VerticalAlignment.Center };
    readonly TextBlock spinner = Ui.Label("…", 14, Ui.Secondary);
    readonly Button stop, copy;
    readonly TextBlock hint = Ui.Label("", 13, Ui.Secondary);
    readonly TextBox answer = new()
    {
        IsReadOnly = true, TextWrapping = TextWrapping.Wrap, BorderThickness = new Thickness(0), Background = System.Windows.Media.Brushes.Transparent,
        Foreground = System.Windows.Media.Brushes.White, VerticalScrollBarVisibility = ScrollBarVisibility.Auto, Padding = new Thickness(0),
    };

    public AskView()
    {
        var model = AskModel.Shared;
        System.Windows.Automation.AutomationProperties.SetName(question, "Ask anything");
        question.KeyDown += (_, e) => { if (e.Key == Key.Return) model.Ask(question.Text); };
        stop = Ui.IconButton(G.Stop, "Stop", model.Stop);
        copy = Ui.IconButton(G.Copy, "Copy answer", () => Clipboard.SetText(model.Answer));
        var buttons = Ui.Row(4, spinner, stop, copy);
        buttons.Margin = new Thickness(6, 0, 0, 0);
        var top = new DockPanel { Margin = new Thickness(0, 0, 0, 6) };
        DockPanel.SetDock(buttons, Dock.Right);
        top.Children.Add(buttons);
        top.Children.Add(question);
        DockPanel.SetDock(top, Dock.Top);
        Children.Add(top);
        hint.HorizontalAlignment = HorizontalAlignment.Center;
        hint.TextWrapping = TextWrapping.Wrap;
        Children.Add(new Grid { Children = { hint, answer } });
        // Ready to type as soon as the tab shows, like the Mac version.
        IsVisibleChanged += (_, _) =>
        {
            if (IsVisible) Dispatcher.InvokeAsync(() => { NotchWindow.Shared.Activate(); question.Focus(); }, DispatcherPriority.Input);
        };
        Ui.Refresh += Update;
        Update();
    }

    void Update()
    {
        var model = AskModel.Shared;
        spinner.Visibility = stop.Visibility = model.IsRunning ? Visibility.Visible : Visibility.Collapsed;
        copy.Visibility = !model.IsRunning && model.Answer.Length > 0 ? Visibility.Visible : Visibility.Collapsed;
        var showAnswer = model.Error == null && model.Answer.Length > 0;
        answer.Visibility = showAnswer ? Visibility.Visible : Visibility.Collapsed;
        hint.Visibility = showAnswer ? Visibility.Collapsed : Visibility.Visible;
        hint.Foreground = model.Error != null ? Ui.Red : Ui.Secondary;
        hint.Text = model.Error ?? (model.IsRunning ? "Thinking…" : "Type a question and press Enter.");
        if (answer.Text != model.Answer) answer.Text = model.Answer;
    }
}
