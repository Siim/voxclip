using System.Net.Http;
using System.Runtime.InteropServices;
using CommunityToolkit.WinUI.Controls;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using VoxClip.App.Controls;
using VoxClip.App.Services;
using VoxClip.App.ViewModels;
using VoxClip.Core.Services.LLM;
using VoxClip.Core.Services.Models;

namespace VoxClip.App;

public sealed partial class SettingsWindow : Window
{
    private readonly CancellationTokenSource lifetime = new();
    private readonly InfoBar notice = Ui.Notice();
    private readonly List<Func<bool>> textCommits = [];
    private CancellationTokenSource? download;
    private bool preparing;
    private int keyWrites;
    private int sensitiveActions;
#if DEBUG
    internal bool DebugNavigationEnabled => Navigation.IsEnabled;
    internal bool DebugSetLanguageText(string value)
    {
        Navigation.SelectedItem = Navigation.MenuItems[1];
        var field = Body.Children.OfType<TextBox>().FirstOrDefault(item => item.Header?.ToString() == "Language for new imports");
        if (field is null) return false;
        if (!field.Focus(FocusState.Programmatic)) return false;
        field.Text = value;
        return true;
    }
#endif
    public SettingsWindow()
    {
        InitializeComponent(); Title = "VoxClip Settings"; SystemBackdrop = new MicaBackdrop();
        ExtendsContentIntoTitleBar = true; SetTitleBar(SettingsTitleBar);
        var scale = GetDpiForWindow(WinRT.Interop.WindowNative.GetWindowHandle(this)) / 96.0;
        AppWindow.Resize(new Windows.Graphics.SizeInt32((int)(760 * scale), (int)(600 * scale)));
        if (AppWindow.Presenter is Microsoft.UI.Windowing.OverlappedPresenter presenter) { presenter.PreferredMinimumWidth = (int)(560 * scale); presenter.PreferredMinimumHeight = (int)(480 * scale); }
        AppWindow.SetIcon(Path.Combine(AppContext.BaseDirectory, "Assets", "VoxClip.ico"));
        App.Services.ApplyTheme(Root); App.Services.SettingsChanged += SettingsChanged;
        Navigation.SelectedItem = Navigation.MenuItems[0];
        AppWindow.Closing += (_, args) => { if (App.Restart.IsPreparing) args.Cancel = true; };
        Closed += (_, _) => { lifetime.Cancel(); download?.Cancel(); App.Services.SettingsChanged -= SettingsChanged; };
    }
    [DllImport("user32.dll")]
    private static extern uint GetDpiForWindow(IntPtr window);
    internal void ShowSection(string tag)
    {
        if (Navigation.MenuItems.OfType<NavigationViewItem>().FirstOrDefault(item => (string)item.Tag == tag) is { } item) Navigation.SelectedItem = item;
    }
    private void SettingsChanged(object? sender, EventArgs args) => App.Services.ApplyTheme(Root);
    private async void PaneChanged(NavigationView sender, NavigationViewSelectionChangedEventArgs args)
    {
        if (args.SelectedItem is not NavigationViewItem item || Body is null) return;
        textCommits.Clear();
        Body.Children.Clear(); notice.IsOpen = false;
        Body.Children.Add(Ui.Text((string)item.Tag, "TitleTextBlockStyle")); Body.Children.Add(notice);
        await Ui.RunAsync(notice, async () =>
        {
            switch ((string)item.Tag)
            {
                case "General": General(); break;
                case "Transcription": await TranscriptionAsync(); break;
                case "Providers & Keys": await ProvidersAsync(); break;
                case "Local Models": await ModelsAsync(); break;
                case "Export": Export(); break;
                case "Accounts": Body.Children.Add(Ui.Text("VoxConvo sharing is coming later. No account is needed to cut, caption or export.")); break;
                case "About": await AboutAsync(); break;
            }
        }, "Settings");
    }
    private void Save(string key, object value)
    {
        if (preparing) return;
        _ = Ui.RunAsync(notice, () => App.Services.SetAsync(key, value, lifetime.Token), "Save settings");
    }
    private void RunSensitive(Func<Task> action, string feature)
    {
        if (preparing) return;
        sensitiveActions++;
        _ = CompleteAsync();
        async Task CompleteAsync()
        {
            try { await Ui.RunAsync(notice, action, feature); }
            finally { sensitiveActions--; }
        }
    }
    private void TrackTextField(TextBox field, Func<bool> save)
    {
        var committed = field.Text;
        bool Commit()
        {
            if (field.Text == committed) return true;
            if (!save()) return false;
            committed = field.Text;
            return true;
        }
        field.LostFocus += (_, _) => { if (!preparing) Commit(); };
        textCommits.Add(Commit);
    }
    internal RestartPreparation PrepareForRestart()
    {
        if (download is not null || keyWrites != 0 || sensitiveActions != 0) return RestartPreparation.Busy;
        if (preparing) return RestartPreparation.TransitionActive;
        foreach (var commit in textCommits)
            if (!commit()) return RestartPreparation.SaveFailed;
        preparing = true;
        Navigation.IsEnabled = false;
        return RestartPreparation.Ready;
    }
    internal void ResumeAfterRestart()
    {
        preparing = false;
        Navigation.IsEnabled = true;
    }
    private void AddSetting(FrameworkElement content) => Body.Children.Add(content);
    private void General()
    {
        var appearance = Ui.Choice("Appearance", ["System", "Light", "Dark"], Array.IndexOf(new[] { "system", "light", "dark" }, App.Services.Get("general.appearance", "system")));
        appearance.SelectionChanged += (_, _) => Save("general.appearance", new[] { "system", "light", "dark" }[appearance.SelectedIndex]); AddSetting(appearance);
        var reopen = new ToggleSwitch { Header = "Open the last project at launch", IsOn = App.Services.Get("general.openLastProject", false) };
        reopen.Toggled += (_, _) => Save("general.openLastProject", reopen.IsOn); AddSetting(reopen);
        var textSize = new Slider { Header = "Transcript text size", Minimum = 13, Maximum = 28, StepFrequency = 1, Value = App.Services.Get("general.transcriptTextSize", TranscriptView.DefaultFontSize) };
        textSize.ValueChanged += (_, _) => Save("general.transcriptTextSize", textSize.Value); AddSetting(textSize);
        var confidence = new ToggleSwitch { Header = "Mark low-confidence words", IsOn = App.Services.Get("general.showLowConfidence", false) };
        confidence.Toggled += (_, _) => Save("general.showLowConfidence", confidence.IsOn); AddSetting(confidence);
        // Caption cards (design §5.4.2).
        var placeholders = new ToggleSwitch { Header = "Show transcript words on placeholders", IsOn = App.Services.ShowPlaceholderWords };
        placeholders.Toggled += (_, _) => Save("general.showPlaceholderWords", placeholders.IsOn); AddSetting(placeholders);
        const string placeholderHelp = "When off, placeholders show the project title instead of its first words.";
        AutomationProperties.SetHelpText(placeholders, placeholderHelp);
        Body.Children.Add(Ui.Text(placeholderHelp, "HelperText"));
        var breath = Ui.Choice("Breath kept in tightened pauses", ["Tight · 0.05 s", "Natural · 0.15 s", "Relaxed · 0.30 s"], Array.IndexOf(new[] { "tight", "natural", "relaxed" }, App.Services.Get("editing.pauseBreath", "natural")));
        breath.SelectionChanged += (_, _) => Save("editing.pauseBreath", new[] { "tight", "natural", "relaxed" }[breath.SelectedIndex]); AddSetting(breath);
        Body.Children.Add(Ui.Text("New-project defaults only. Existing projects keep their choices.", "HelperText"));
        var updates = new ToggleSwitch { Header = "Check for updates automatically", IsOn = App.Services.Get("update.autoCheck", true) };
        updates.Toggled += (_, _) => Save("update.autoCheck", updates.IsOn); AddSetting(updates);
        var cacheSizes = new[] { 2, 5, 10, 20 };
        var cache = Ui.Choice("Cache limit", cacheSizes.Select(size => size + " GB"), Array.IndexOf(cacheSizes, App.Services.Get("cache.limitGB", 5)));
        cache.SelectionChanged += (_, _) => Save("cache.limitGB", cacheSizes[cache.SelectedIndex]); AddSetting(cache);
        Body.Children.Add(Ui.Text("Local first. No telemetry. No account wall. Your source media is never changed.", "HelperText"));
        Body.Children.Add(Ui.Button("Show data folder", () => ShareHelpers.Reveal(App.Services.Data.Logs)));
    }
    private async Task TranscriptionAsync()
    {
        var modes = new[] { "local", "elevenlabs", "ask" };
        var current = App.Services.Get("transcription.engineMode", "local");
        var engine = Ui.Choice("Engine for new imports", ["On this PC", "ElevenLabs Scribe", "Ask each time"], Math.Max(0, Array.IndexOf(modes, current)));
        engine.SelectionChanged += (_, _) => Save("transcription.engineMode", modes[engine.SelectedIndex]); AddSetting(engine);
        var language = new TextBox { Header = "Language for new imports", Text = App.Services.Get("transcription.language", "auto"), PlaceholderText = "auto or language code, such as en" };
        TrackTextField(language, () =>
        {
            var code = language.Text.Trim().ToLowerInvariant();
            if (code == "auto" || code.Length is >= 2 and <= 3 && code.All(char.IsAsciiLetterLower)) { Save("transcription.language", code); return true; }
            Ui.Show(notice, "Enter auto or a two or three letter language code.", InfoBarSeverity.Warning); return false;
        });
        AddSetting(language);
        var regions = new[] { "default", "us", "eu", "in", "sg" };
        var region = Ui.Choice("ElevenLabs region", ["Default", "US", "EU", "India", "Singapore"], Math.Max(0, Array.IndexOf(regions, App.Services.Get("transcription.elevenlabs.region", "default"))));
        region.SelectionChanged += (_, _) => Save("transcription.elevenlabs.region", regions[region.SelectedIndex]); AddSetting(region);
        Body.Children.Add(Ui.Text("Residency regions are for ElevenLabs Enterprise workspaces with data residency, which have their own keys. Most accounts use Default.", "HelperText"));
        await ProviderRowAsync("ElevenLabs", "Sends the audio track to ElevenLabs, which keeps it under its terms. You confirm each take before upload.", "elevenlabs-api-key", null);
        Body.Children.Add(Ui.Button("Manage local models…", () => Navigation.SelectedItem = Navigation.MenuItems.OfType<NavigationViewItem>().First(item => (string)item.Tag == "Local Models")));
        Body.Children.Add(Ui.Text("Models download only after you confirm. Local transcription runs entirely on this PC.", "HelperText"));
    }
    private async Task ProvidersAsync()
    {
        Body.Children.Add(Ui.Text("Keys are encrypted for your Windows account using DPAPI. Saved keys are never shown and never stored in settings or logs.", "HelperText"));
        var entries = await ProviderCatalog.ReadAsync(lifetime.Token);
        var selected = Ui.Choice("Default connector for AI clips", ["None · manual clips still work", .. entries.Select(entry => entry.Label)]);
        selected.SelectedIndex = Math.Max(0, entries.ToList().FindIndex(entry => entry.WireId == App.Services.Get("llm.connector", "")) + 1);
        selected.SelectionChanged += (_, _) => Save("llm.connector", selected.SelectedIndex == 0 ? "" : entries[selected.SelectedIndex - 1].WireId); Body.Children.Add(selected);
        var snap = new ToggleSwitch { Header = "Snap clip edges to sentence boundaries", IsOn = App.Services.Get("llm.clips.snapToLines", true) };
        snap.Toggled += (_, _) => Save("llm.clips.snapToLines", snap.IsOn); Body.Children.Add(snap);
        await ProviderRowAsync("ElevenLabs", "Sends the audio track to ElevenLabs. No video is sent.", "elevenlabs-api-key", null);
        foreach (var entry in entries) await ProviderRowAsync(entry.Label, entry.DataFlow, entry.Account, entry);
    }
    private async Task ProviderRowAsync(string label, string dataFlow, string? account, ProviderEntry? entry)
    {
        var panel = Ui.Stack(12); panel.Children.Add(Ui.Text(dataFlow, "HelperText"));
        var hasKey = false;
        var keyUnreadable = false;
        if (account is not null)
        {
            try { hasKey = await App.Services.Keys.GetKeyAsync(account, lifetime.Token) is not null; }
            catch (Exception exception) when (exception is not OperationCanceledException) { keyUnreadable = true; hasKey = true; }
        }
        var status = Ui.Text(keyUnreadable ? "This saved key can't be read. Forget it, then save a new key. Your media and edits are still here." : hasKey ? "Key saved securely." : account is null ? "Check detects availability; Test sends only a connection test." : "No key saved.", "HelperText");
        panel.Children.Add(status);
        var model = new TextBox { Header = "Model ID", Text = App.Services.Get("llm.model." + entry?.WireId, entry?.DefaultModel ?? "") };
        if (entry is not null) { panel.Children.Add(model); TrackTextField(model, () => { if (model.Text.Trim().Length == 0) { Ui.Show(notice, "Enter a model ID.", InfoBarSeverity.Warning); return false; } Save("llm.model." + entry.WireId, model.Text.Trim()); return true; }); }
        if (entry?.Cli == true)
        {
            var path = new TextBox { Header = "CLI path (optional override)", Text = App.Services.Get("llm.cliPath." + entry.WireId, ""), PlaceholderText = "Find the installed CLI automatically" };
            TrackTextField(path, () => { Save("llm.cliPath." + entry.WireId, path.Text.Trim()); return true; }); panel.Children.Add(path);
            panel.Children.Add(Ui.Text("VoxClip does not read CLI sign-in files. Install, update and sign in in your terminal.", "HelperText"));
        }
        if (entry?.Group == "local")
        {
            var endpoint = new TextBox { Header = "Local server URL", Text = App.Services.Get("llm.baseUrl." + entry.WireId, entry.WireId == "ollama" ? "http://localhost:11434" : "http://localhost:1234") };
            TrackTextField(endpoint, () => { if (Uri.TryCreate(endpoint.Text, UriKind.Absolute, out var address) && address.IsLoopback && address.Scheme is "http" or "https") { Save("llm.baseUrl." + entry.WireId, endpoint.Text); return true; } Ui.Show(notice, "Use a loopback HTTP or HTTPS address.", InfoBarSeverity.Warning); return false; }); panel.Children.Add(endpoint);
        }
        if (account is not null)
        {
            var key = new PasswordBox { Header = "New API key", PasswordRevealMode = PasswordRevealMode.Hidden, PlaceholderText = hasKey ? "Saved for your Windows account; paste to replace" : "Paste an API key" };
            panel.Children.Add(key);
            Button? forget = null;
            var save = Ui.Button("Save key", () => _ = Ui.RunAsync(notice, async () =>
            {
                if (preparing) return;
                var secret = key.Password; key.Password = "";
                if (string.IsNullOrWhiteSpace(secret)) return;
                keyWrites++;
                try
                {
                    await App.Services.Keys.SaveAsync(account, secret, lifetime.Token); status.Text = "Key saved securely."; key.PlaceholderText = "Saved for your Windows account; paste to replace";
                    if (forget is not null) forget.Visibility = Visibility.Visible;
                }
                finally { keyWrites--; }
            }, "Save key"));
            save.IsEnabled = false; key.PasswordChanged += (_, _) => save.IsEnabled = !string.IsNullOrWhiteSpace(key.Password); panel.Children.Add(save);
            forget = Ui.Button("Forget key", () => _ = Ui.RunAsync(notice, async () =>
            {
                if (preparing) return;
                keyWrites++;
                try { key.Password = ""; await App.Services.Keys.SaveAsync(account, "", lifetime.Token); status.Text = "Key forgotten."; key.PlaceholderText = "Paste an API key"; if (forget is not null) forget.Visibility = Visibility.Collapsed; }
                finally { keyWrites--; }
            }, "Forget key"));
            forget.Visibility = hasKey ? Visibility.Visible : Visibility.Collapsed; panel.Children.Add(forget);
        }
        if (entry is not null)
        {
            status.Text = ProviderCatalog.Status(await ProviderCatalog.ProbeAsync(entry, App.Services.Connector(entry.Id), lifetime.Token));
            panel.Children.Add(Ui.Button("Check status", () => _ = Ui.RunAsync(notice, async () => status.Text = ProviderCatalog.Status(await ProviderCatalog.ProbeAsync(entry, App.Services.Connector(entry.Id), lifetime.Token)), "Connector status")));
            panel.Children.Add(Ui.Button("Test", () => RunSensitive(async () =>
            {
                var selectedConnector = App.Services.Connector(entry.Id);
                var connectorStatus = await ProviderCatalog.ProbeAsync(entry, selectedConnector, lifetime.Token);
                status.Text = ProviderCatalog.Status(connectorStatus);
                if (connectorStatus is not ConnectorStatus.Ready) return;
                try
                {
                    var result = await ProviderCatalog.TestAsync(entry, model.Text.Trim(),
                        token => ProviderCatalog.ConsentAsync(entry, Root.XamlRoot, ConnectorConsentAction.Test, 0, selectedConnector, connectorStatus, token), lifetime.Token);
                    if (result is null) return;
                    status.Text = ConnectorTestPresentation.Text(result);
                    status.Foreground = Ui.ThemeBrush(status, result.Passed ? "VcStatusSuccessBrush" : "VcStatusWarningBrush");
                }
                catch (OperationCanceledException) { }
                catch (Exception error) when (error is not OutOfMemoryException)
                {
                    status.Text = ConnectorTestPresentation.Failure(error);
                    status.Foreground = Ui.ThemeBrush(status, "VcStatusWarningBrush");
                }
            }, "Connection test")));
        }
        else panel.Children.Add(Ui.Button("Test", () => _ = Ui.RunAsync(notice, async () =>
        {
            using var transcriber = VoxClip.Core.Services.Speech.ElevenLabsTranscriber.FromSettings(App.Services.Keys, App.Services.Settings, App.Services.Log);
            var result = await transcriber.TestKeyAsync(lifetime.Token);
            status.Text = result.Message;
        }, "Connection test")));
        var group = new SettingsExpander { Header = label, HorizontalAlignment = HorizontalAlignment.Stretch };
        group.Items.Add(new SettingsCard { Content = panel, HorizontalContentAlignment = HorizontalAlignment.Stretch }); Body.Children.Add(group);
    }
    private async Task ModelsAsync()
    {
        Body.Children.Add(Ui.Text("Models stay on this computer. Downloads start only when you choose Download and confirm the licence.", "HelperText"));
        var catalogue = await App.Services.Models.GetModelsAsync(lifetime.Token);
        var installed = await App.Services.Downloads.ListInstalledAsync(lifetime.Token);
        if (catalogue.Count == 0) Body.Children.Add(Ui.Text("No models are available in this build."));
        foreach (var model in catalogue.Where(entry => entry.Listed))
        {
            var panel = Ui.Stack(12); var available = installed.Any(entry => entry.Id == model.Id && entry.Verified);
            panel.Children.Add(Ui.Text($"{model.Engine} · {model.TotalBytes / 1_000_000d:0} MB · {model.License}", "HelperText"));
            panel.Children.Add(Ui.Text(available ? "Installed and verified." : "Not installed.", "HelperText"));
            var bar = new ProgressBar { Visibility = Visibility.Collapsed }; panel.Children.Add(bar);
            AutomationProperties.SetName(bar, (available ? "Removing " : "Downloading ") + model.Id);
            panel.Children.Add(Ui.Button(available ? "Remove" : "Download", () => RunSensitive(async () =>
            {
                if (preparing) return;
                if (download is not null) { Ui.Show(notice, "A model download is already running."); return; }
                if (available && !await Ui.ConfirmAsync(Root.XamlRoot, "Remove model?", $"Remove {model.Id}? Your projects and source videos stay here.", "Remove")) return;
                if (preparing) return;
                download = CancellationTokenSource.CreateLinkedTokenSource(lifetime.Token); bar.Visibility = available ? Visibility.Visible : Visibility.Collapsed;
                try
                {
                    if (available) await App.Services.Downloads.RemoveAsync(model.Id, download.Token);
                    else await App.Services.Installer(ConfirmDownloadAsync).InstallAsync(model.Id, new Progress<ModelDownloadProgress>(value => { bar.Visibility = Visibility.Visible; bar.IsIndeterminate = value.TotalBytes is null; bar.Value = value.TotalBytes > 0 ? value.BytesReceived * 100d / value.TotalBytes.Value : 0; Ui.Show(notice, ModelDownloadCopy.Progress(model, value)); }), download.Token);
                    Ui.Show(notice, available ? "Model removed." : "Model installed and verified. Reopen Local Models to refresh.");
                }
                catch (OperationCanceledException) when (!lifetime.IsCancellationRequested) { notice.IsOpen = false; throw; }
                finally { download.Dispose(); download = null; bar.Visibility = Visibility.Collapsed; }
            }, "Local models")));
            panel.Children.Add(Ui.Button("Cancel download", () => download?.Cancel()));
            var group = new SettingsExpander { Header = model.Id, HorizontalAlignment = HorizontalAlignment.Stretch };
            group.Items.Add(new SettingsCard { Content = panel, HorizontalContentAlignment = HorizontalAlignment.Stretch }); Body.Children.Add(group);
        }
    }
    private Task<bool> ConfirmDownloadAsync(TranscriptionModel model, IReadOnlyList<TranscriptionModel> dependencies, CancellationToken ct) =>
        Ui.OnUiThreadAsync(DispatcherQueue, async () => !preparing && await Ui.ConfirmDownloadAsync(Root.XamlRoot, model, dependencies, ct) && !preparing);
    private void Export()
    {
        var aspects = new[] { "source", "16:9", "9:16", "1:1" };
        var aspect = Ui.Choice("Default aspect", ["Source", "16:9", "9:16", "1:1"], Array.IndexOf(aspects, App.Services.Get("export.defaultAspect", "source")));
        aspect.SelectionChanged += (_, _) => Save("export.defaultAspect", aspects[aspect.SelectedIndex]); Body.Children.Add(aspect);
        var quality = Ui.Choice("Quality", ["Standard", "High"], App.Services.Get("export.quality", "standard") == "high" ? 1 : 0);
        quality.SelectionChanged += (_, _) => Save("export.quality", quality.SelectedIndex == 1 ? "high" : "standard"); Body.Children.Add(quality);
        var srt = new ToggleSwitch { Header = "Save an SRT sidecar", IsOn = App.Services.Get("export.srt", false) };
        srt.Toggled += (_, _) => Save("export.srt", srt.IsOn); Body.Children.Add(srt);
        var folder = new TextBox { Header = "Default destination folder", Text = App.Services.Get("export.folder", Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.MyVideos), "VoxClip")) };
        TrackTextField(folder, () => { if (Path.IsPathFullyQualified(folder.Text)) { Save("export.folder", folder.Text); return true; } Ui.Show(notice, "Choose an absolute folder path.", InfoBarSeverity.Warning); return false; }); Body.Children.Add(folder);
        var pattern = new TextBox { Header = "File name pattern", Text = App.Services.Get("export.fileNamePattern", "{project}-{clip}-{aspect}"), MaxLength = 200 };
        TrackTextField(pattern, () => { if (string.IsNullOrWhiteSpace(pattern.Text)) { Ui.Show(notice, "Enter a file name pattern.", InfoBarSeverity.Warning); return false; } Save("export.fileNamePattern", pattern.Text); return true; }); Body.Children.Add(pattern);
        var openFolder = new ToggleSwitch { Header = "Open destination folder after export", IsOn = App.Services.Get("export.openFolderAfter", false) };
        openFolder.Toggled += (_, _) => Save("export.openFolderAfter", openFolder.IsOn); Body.Children.Add(openFolder);
        Body.Children.Add(Ui.Text("VoxClip uses H.264 hardware encoding when available and the Windows software encoder when needed. GPL encoders are never used.", "HelperText"));
    }
    private async Task AboutAsync()
    {
        Body.Children.Add(Ui.Text("VoxClip " + AppServices.Version, "SubtitleTextBlockStyle"));
        Body.Children.Add(Ui.Text("A fast way to cut, because we already know where every word sits.\nOpen source · MIT · No telemetry."));
        Body.Children.Add(Ui.Button("Check for updates", () => RunSensitive(async () => { if (App.Windows.FirstOrDefault() is { } window) { await window.CheckUpdatesAsync(true);  } }, "Updates")));
        Body.Children.Add(Ui.Text("What leaves this device: local transcription and editing stay here. ElevenLabs receives audio only after consent. AI connectors receive transcript text only, never video or audio. Automatic update checks contact GitHub and download available updates in the background; restarting to apply an update is your choice. Model downloads contact their publishers only when you choose Download. Posting happens only when you choose to share.", "HelperText"));
        Body.Children.Add(Ui.Button("Welcome tour", () => RunSensitive(async () => { if (App.Windows.FirstOrDefault() is { } window) await window.ShowOnboardingAsync(); }, "Welcome tour")));
        Body.Children.Add(Ui.Button("Reveal logs", () => ShareHelpers.Reveal(Path.Combine(App.Services.Data.Logs, "voxclip.log"))));
        Body.Children.Add(Ui.Button("Copy diagnostics", () => _ = Ui.RunAsync(notice, async () => { var lines = await App.Services.Log.ReadRecentAsync(200, lifetime.Token); ShareHelpers.Copy($"VoxClip {AppServices.Version}\n{System.Runtime.InteropServices.RuntimeInformation.OSArchitecture}\n" + string.Join('\n', lines)); Ui.Show(notice, "Redacted diagnostics copied. No transcript text or keys are included."); }, "Diagnostics")));
        Body.Children.Add(Ui.Text("Licences", "SubtitleTextBlockStyle"));
        Body.Children.Add(Ui.Text("This software uses libraries from the FFmpeg project under the LGPL. The FFmpeg DLLs are dynamically linked. You may replace those DLLs with compatible versions and reverse engineer them to debug changes.", "HelperText"));
        Body.Children.Add(new HyperlinkButton { Content = "FFmpeg corresponding source for VoxClip " + AppServices.Version,
            NavigateUri = new Uri("https://github.com/Siim/voxclip/releases/download/v" + AppServices.Version + "/VoxClip-win-ffmpeg-source.tar.xz") });
        Body.Children.Add(Ui.Text("FFmpeg.AutoGen 9.0.1.1 is MIT-licensed. Its notice is included with the other third-party licences below.", "HelperText"));
        var path = Path.Combine(AppContext.BaseDirectory, "THIRD_PARTY_NOTICES.md");
        Body.Children.Add(new TextBox { Text = await File.ReadAllTextAsync(path, lifetime.Token), IsReadOnly = true, AcceptsReturn = true, TextWrapping = TextWrapping.Wrap, MaxHeight = 420, FontFamily = new FontFamily("Cascadia Mono"), FontSize = 12 });
    }
}
