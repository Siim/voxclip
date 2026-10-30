using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using VoxClip.App.Services;
using VoxClip.App.ViewModels;
using VoxClip.Core.Domain.Captions;
using VoxClip.Core.Domain.Transcript;
using VoxClip.Core.Services.Project;

namespace VoxClip.App.Controls;

internal sealed class TranscriptionDialog : ContentDialog
{
    private readonly EditorViewModel model;
    private readonly ComboBox engine = Ui.Choice("Engine", ["Local Whisper · on this computer", "ElevenLabs · sends the audio track"]);
    private readonly ComboBox models = Ui.Choice("Local model", []);
    private readonly TextBox language = new() { Header = "Language", PlaceholderText = "Auto-detect (or a language code, such as en)" };
    private readonly InfoBar notice = Ui.Notice();
    private readonly TextBlock flow = Ui.Text("Audio stays on this computer. No key or account is needed.", "HelperText");
    private readonly ProgressBar progress = new() { Visibility = Visibility.Collapsed };
    private readonly InfoBar consentNotice = Ui.Notice();
    private readonly ScrollViewer setupContent;
    private bool confirmingCloud;
    private bool startingTranscription;
    private bool closed;
    private readonly StackPanel cloudKeyRow = Ui.Stack(8);
    private readonly TextBlock cloudKeyStatus = Ui.Text("Checking ElevenLabs key…", "HelperText");
    private readonly PasswordBox cloudKey = new() { Header = "ElevenLabs API key", PasswordRevealMode = PasswordRevealMode.Hidden, PlaceholderText = "Paste a key to save for your Windows account" };
    private readonly CancellationTokenSource lifetime = new();
    private readonly string? projectPath;
    private bool running;

    internal TranscriptionDialog(MainWindow owner, EditorViewModel model)
    {
        this.model = model; projectPath = owner.ProjectPath; Title = model.HasTranscript ? "Transcribe again" : "Transcribe video";
        PrimaryButtonText = "Transcribe"; CloseButtonText = "Not now";
        engine.SelectedIndex = App.Services.Get("transcription.engineMode", "local") == "elevenlabs" ? 1 : 0;
        var savedLanguage = App.Services.Get("transcription.language", "auto");
        language.Text = savedLanguage == "auto" ? "" : savedLanguage;
        var body = Ui.Stack(16); body.MinWidth = 400;
        body.Children.Add(Ui.Text("Choose how to transcribe. There is no automatic cloud fallback."));
        body.Children.Add(engine); body.Children.Add(flow); body.Children.Add(models); body.Children.Add(language);
        cloudKeyRow.Children.Add(cloudKeyStatus); cloudKeyRow.Children.Add(cloudKey);
        var saveCloudKey = Ui.Button("Save key", () => _ = Ui.RunAsync(notice, SaveCloudKeyAsync, "Save key"));
        saveCloudKey.IsEnabled = false;
        cloudKey.PasswordChanged += (_, _) => saveCloudKey.IsEnabled = !string.IsNullOrWhiteSpace(cloudKey.Password);
        cloudKeyRow.Children.Add(saveCloudKey); body.Children.Add(cloudKeyRow);
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(progress, "Transcription progress");
        body.Children.Add(Ui.Button("Manage local models…", App.OpenSettings)); body.Children.Add(progress); body.Children.Add(notice);
        setupContent = new ScrollViewer { Content = body, MaxHeight = 600 };
        Content = setupContent;
        engine.SelectionChanged += (_, _) => UpdateEngine();
        UpdateEngine();
        Opened += async (_, _) => await Ui.RunAsync(notice, async () =>
        {
            await RefreshCloudKeyAsync();
            var catalogue = await App.Services.Models.GetModelsAsync(lifetime.Token);
            var installed = await App.Services.Downloads.ListInstalledAsync(lifetime.Token);
            var requestedLanguage = language.Text.Trim().ToLowerInvariant();
            var available = TranscriptionModelChoices.InstalledLocal(catalogue, installed);
            foreach (var entry in available) models.Items.Add(entry.Id);
            if (available.Length > 0)
            {
                var routed = requestedLanguage.Length == 0
                    ? available.FirstOrDefault(entry => entry.Languages.Contains("*"))
                    : available.FirstOrDefault(entry => entry.ForcedLanguage == requestedLanguage)
                        ?? available.FirstOrDefault(entry => entry.Languages.Contains(requestedLanguage) || entry.Languages.Contains("*"));
                models.SelectedIndex = Math.Max(0, Array.FindIndex(available, entry => entry.Id == routed?.Id));
                if (requestedLanguage.Length > 0 && routed is null && engine.SelectedIndex == 0)
                    Ui.Show(notice, "No installed local model supports this language. Choose another model or download one in Settings → Local Models.", InfoBarSeverity.Warning);
            }
            else if (engine.SelectedIndex == 0) Ui.Show(notice, "No local model installed. Download one in Settings → Local Models.");
            CheckLocalRuntime();
        }, "Local models");
        PrimaryButtonClick += Transcribe;
        Closing += (_, args) => { if (running) { lifetime.Cancel(); args.Cancel = true; } };
        Closed += (_, _) => { closed = true; lifetime.Cancel(); lifetime.Dispose(); };
    }
    private void UpdateEngine()
    {
        var cloud = engine.SelectedIndex == 1;
        models.Visibility = cloud ? Visibility.Collapsed : Visibility.Visible;
        cloudKeyRow.Visibility = cloud ? Visibility.Visible : Visibility.Collapsed;
        flow.Text = cloud
            ? "ElevenLabs Scribe uploads this take's audio track with your key. ElevenLabs stores it under its terms and may use it to improve its services unless you opt out in your ElevenLabs account. No video is sent."
            : "Audio stays on this computer. No key or account is needed.";
        CheckLocalRuntime();
    }
    private bool CheckLocalRuntime()
    {
        if (engine.SelectedIndex != 0)
        {
            notice.ActionButton = null;
            notice.Content = null;
            if (notice.Message == LocalRuntimeGuard.Message) notice.IsOpen = false;
            IsPrimaryButtonEnabled = !running;
            return true;
        }
        if (App.Services.LocalRuntime.IsSupported) return true;
        IsPrimaryButtonEnabled = false;
        Ui.Show(notice, LocalRuntimeGuard.Message, InfoBarSeverity.Warning);
        var architecture = System.Runtime.InteropServices.RuntimeInformation.ProcessArchitecture.ToString().ToLowerInvariant();
        notice.Content = new HyperlinkButton { Content = "Microsoft Visual C++ downloads",
            NavigateUri = new Uri("https://learn.microsoft.com/en-us/cpp/windows/latest-supported-vc-redist") };
        notice.ActionButton = new HyperlinkButton { Content = "Download for " + architecture.ToUpperInvariant(),
            NavigateUri = new Uri($"https://aka.ms/vc14/vc_redist.{architecture}.exe") };
        return false;
    }
    private async Task RefreshCloudKeyAsync()
    {
        var saved = await App.Services.Keys.GetKeyAsync("elevenlabs-api-key", lifetime.Token) is not null;
        cloudKeyStatus.Text = saved ? "Key saved for your Windows account." : "Add an ElevenLabs key here before uploading this take.";
        cloudKey.PlaceholderText = saved ? "Saved for your Windows account; paste to replace" : "Paste an API key";
    }
    private async Task SaveCloudKeyAsync()
    {
        var secret = cloudKey.Password;
        cloudKey.Password = "";
        if (string.IsNullOrWhiteSpace(secret)) return;
        await App.Services.Keys.SaveAsync("elevenlabs-api-key", secret, lifetime.Token);
        await RefreshCloudKeyAsync();
        Ui.Show(notice, "Key saved securely. Audio is sent only after you confirm and choose Transcribe.");
    }
    private async void Transcribe(ContentDialog sender, ContentDialogButtonClickEventArgs args)
    {
        args.Cancel = true;
        if (startingTranscription || closed || model.IsLeaving) return;
        startingTranscription = true;
        try
        {
            if (confirmingCloud)
            {
                IsPrimaryButtonEnabled = false;
                var token = lifetime.Token;
                await Ui.RunAsync(consentNotice, async () =>
                {
                    await App.Services.SetAsync("transcription.cloudConsent.elevenlabs", true, token);
                    if (closed || model.IsLeaving || token.IsCancellationRequested) return;
                    confirmingCloud = false;
                    Title = model.HasTranscript ? "Transcribe again" : "Transcribe video";
                    PrimaryButtonText = "Transcribe"; CloseButtonText = "Not now";
                    Content = setupContent;
                    await RunTranscriptionAsync();
                }, "Save consent");
            }
            else await RunTranscriptionAsync();
        }
        finally
        {
            startingTranscription = false;
            if (!closed && !running) IsPrimaryButtonEnabled = engine.SelectedIndex != 0 || App.Services.LocalRuntime.IsSupported;
        }
    }
    private void ShowCloudConsent()
    {
        confirmingCloud = true;
        Title = "Transcribe with ElevenLabs?";
        PrimaryButtonText = "Continue"; CloseButtonText = "Cancel";
        DefaultButton = ContentDialogButton.Primary;
        var page = Ui.Stack(16); page.MinWidth = 400; page.MaxWidth = 480;
        page.Children.Add(Ui.Text("ElevenLabs Scribe uploads this take's audio track with your key. ElevenLabs stores it under its terms and may use it to improve its services unless you opt out in your ElevenLabs account. No video is sent."));
        page.Children.Add(consentNotice);
        Content = new ScrollViewer { Content = page, MaxHeight = 600 };
    }
    private async Task RunTranscriptionAsync()
    {
        if (running || closed || model.IsLeaving) return;
        await Ui.RunAsync(notice, async () =>
        {
            if (!CheckLocalRuntime()) return;
            var local = engine.SelectedIndex == 0;
            var selectedModel = models.SelectedItem as string;
            var requestedLanguage = language.Text.Trim().ToLowerInvariant();
            if (local && selectedModel is null) { Ui.Show(notice, "Download a local model first. Your video is still here."); return; }
            if (!local)
            {
                if (await App.Services.Keys.GetKeyAsync("elevenlabs-api-key", lifetime.Token) is null) { Ui.Show(notice, "Add an ElevenLabs key here before uploading this take."); cloudKey.Focus(FocusState.Programmatic); return; }
                if (!App.Services.Get("transcription.cloudConsent.elevenlabs", false)) { ShowCloudConsent(); return; }
            }
            if (model.IsLeaving) return;
            running = true; model.Busy = true; App.Services.BusyOperations++; IsPrimaryButtonEnabled = false; progress.Visibility = Visibility.Visible;
            // Home tiles in any window show this run's stage and can cancel it, as "Not now" does (design §5.4.4 d).
            void Cancel() { if (running) lifetime.Cancel(); }
            var announcements = new TranscriptionAnnouncements();
            void Report(MediaTranscriptionStage step, double? fraction)
            {
                if (projectPath is not null && running) TranscriptionActivity.Report(projectPath, step, fraction, Cancel);
                if (announcements.Update(step, fraction, engine.SelectedIndex != 0) is { } text) Ui.Announce(notice, text, "transcription");
            }
            Report(MediaTranscriptionStage.ReadingVideo, null);
            try
            {
                var source = model.Project.Media.Source;
                App.Services.Log.Write(VoxClip.Core.Services.Logging.LogLevel.Info, "transcribe", "dialog stage=probe");
                await App.Services.Log.FlushAsync(CancellationToken.None);
                var media = await App.Services.Probe.ProbeAsync(source.AbsolutePath, lifetime.Token);
                Report(MediaTranscriptionStage.ExtractingAudio, null);
                var audio = await new CacheIndex(App.Services.Data.Cache).ExtractAudioAsync(App.Services.Audio, media, source.ContentKey, null, lifetime.Token);
                App.Services.Log.Write(VoxClip.Core.Services.Logging.LogLevel.Info, "transcribe", "dialog stage=audio-ready");
                await App.Services.Log.FlushAsync(CancellationToken.None);
                var plan = new TranscriptionPlan(local ? TranscriptEngine.Whispercpp : TranscriptEngine.Elevenlabs,
                    selectedModel, requestedLanguage.Length == 0 || requestedLanguage == "auto" ? new LanguageChoice.Auto() : new LanguageChoice.Forced(requestedLanguage), new());
                var transcript = await App.Services.Transcription.TranscribeAsync(new(plan, audio.Audio, source.ContentKey), new Progress<TranscriptionProgress>(value =>
                {
                    progress.IsIndeterminate = value.Fraction is null; progress.Value = (value.Fraction ?? 0) * 100; Ui.Show(notice, value.Stage.ToString());
                    Report(value.Stage == TranscriptionStage.Aligning ? MediaTranscriptionStage.Aligning : MediaTranscriptionStage.Transcribing, value.Fraction);
                }), lifetime.Token);
                if (model.IsLeaving) return;
                model.SetTranscript(transcript);
            }
            catch (Exception exception) when (exception is not OperationCanceledException)
            {
                App.Services.Log.Write(VoxClip.Core.Services.Logging.LogLevel.Error, "transcribe",
                    $"dialog failed type={exception.GetType().Name} hresult={exception.HResult}");
                throw;
            }
            finally
            {
                running = false; model.Busy = false; App.Services.BusyOperations--; IsPrimaryButtonEnabled = !lifetime.IsCancellationRequested; progress.Visibility = Visibility.Collapsed;
                if (projectPath is not null) TranscriptionActivity.End(projectPath);
            }
            Hide();
        }, "Transcription");
    }
}
