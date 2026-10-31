using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using VoxClip.App.Services;
using VoxClip.App.ViewModels;
using VoxClip.Core.Domain.Captions;
using VoxClip.Core.Domain.Transcript;
using VoxClip.Core.Services.Models;
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
    /// <summary>The model whose licence page is showing in place of the setup, after the notice's Download.</summary>
    private TranscriptionModel? confirmingDownload;
    private IReadOnlyList<TranscriptionModel> catalogue = [];
    private bool startingTranscription;
    private bool closed;
    private readonly StackPanel cloudKeyRow = Ui.Stack(8);
    private readonly TextBlock cloudKeyStatus = Ui.Text("Checking ElevenLabs key…", "HelperText");
    private readonly PasswordBox cloudKey = new() { Header = "ElevenLabs API key", PasswordRevealMode = PasswordRevealMode.Hidden, PlaceholderText = "Paste a key to save for your Windows account" };
    private readonly CancellationTokenSource lifetime = new();
    /// <summary>The model download running from the licence page; Cancel or Esc stops only it and returns to the setup.</summary>
    private CancellationTokenSource? downloading;
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
        body.Children.Add(Ui.Button("Manage local models…", () => App.OpenSettings(SettingsSections.LocalModels))); body.Children.Add(progress); body.Children.Add(notice);
        setupContent = new ScrollViewer { Content = body, MaxHeight = 600 };
        Content = setupContent;
        engine.SelectionChanged += (_, _) => UpdateEngine();
        UpdateEngine();
        // Automatic routes each take by its language (transcription §11.2); an installed model can still be chosen by hand.
        models.Items.Add(new ComboBoxItem { Content = TranscriptionRouting.Automatic });
        models.SelectedIndex = 0;
        // A download here or in Settings → Local Models shows up in the list without reopening the dialog.
        void ModelsChanged(object? sender, EventArgs args) { if (!closed) _ = Ui.RunAsync(notice, async () => await LoadModelsAsync(), "Local models"); }
        Opened += async (_, _) => await Ui.RunAsync(notice, async () =>
        {
            App.Services.ModelsChanged += ModelsChanged;
            await RefreshCloudKeyAsync();
            if (await LoadModelsAsync() == 0 && engine.SelectedIndex == 0 && CheckLocalRuntime())
            {
                // Nothing to transcribe with yet: offer the download this take's language routes to, before any audio work.
                var route = await RouteAsync(null);
                if (route.Plan is null && route.Detector is null) ShowRoute(route);
            }
            CheckLocalRuntime();
        }, "Local models");
        PrimaryButtonClick += Transcribe;
        // Cancel on the licence page goes back to the setup; while a download runs it cancels only the download, which then
        // returns to the setup, as Settings → Local Models does. "Not now" during a run cancels the run.
        CloseButtonClick += (_, args) => { if (confirmingDownload is not null && !running && !lifetime.IsCancellationRequested) { args.Cancel = true; ShowSetup(); } };
        Closing += (_, args) =>
        {
            if (!running) return;
            if (downloading is { } download) download.Cancel(); else lifetime.Cancel();
            args.Cancel = true;
        };
        Closed += (_, _) => { closed = true; App.Services.ModelsChanged -= ModelsChanged; lifetime.Cancel(); lifetime.Dispose(); };
    }
    /// <summary>List Automatic, then the installed local models by name, keeping the current choice; returns how many are installed.</summary>
    private async Task<int> LoadModelsAsync()
    {
        catalogue = await App.Services.Models.GetModelsAsync(lifetime.Token);
        var installed = await App.Services.Downloads.ListInstalledAsync(lifetime.Token);
        if (closed) return 0;
        var chosen = (models.SelectedItem as ComboBoxItem)?.Tag as string;
        var available = TranscriptionModelChoices.InstalledLocal(catalogue, installed);
        while (models.Items.Count > 1) models.Items.RemoveAt(models.Items.Count - 1);
        foreach (var entry in available) models.Items.Add(new ComboBoxItem { Content = ModelDownloadCopy.DisplayName(entry), Tag = entry.Id });
        models.SelectedIndex = Math.Max(0, Array.FindIndex(available, entry => entry.Id == chosen) + 1);
        return available.Length;
    }
    private async Task<LocalTranscriptionRoute> RouteAsync(Func<string, CancellationToken, Task<(string Language, double Probability)>>? detect) =>
        await TranscriptionRouting.RouteAsync(App.Services.Models as ModelCatalog ?? new ModelCatalog(), App.Services.Downloads,
            (models.SelectedItem as ComboBoxItem)?.Tag as string, language.Text, TranscriptionRouting.InstalledMemoryBytes,
            await App.Services.Keys.GetKeyAsync("elevenlabs-api-key", lifetime.Token) is not null, detect, lifetime.Token);
    /// <summary>The route's prompt (transcription §11.3): its message, [Download] when it offers a model and [Use ElevenLabs
    /// instead] when a key exists. Nothing downloads or uploads until the user clicks.</summary>
    private void ShowRoute(LocalTranscriptionRoute route)
    {
        Ui.Show(notice, route.Message, route.AskLanguage ? InfoBarSeverity.Warning : InfoBarSeverity.Informational);
        var actions = Ui.Stack(8);
        actions.Orientation = Orientation.Horizontal;
        if (route.Download is { } download) actions.Children.Add(Ui.Button("Download", () => ShowDownload(download)));
        if (route.OfferCloud) actions.Children.Add(Ui.Button(TranscriptionRouting.UseCloud, () => { ClearRoute(); notice.IsOpen = false; engine.SelectedIndex = 1; }));
        notice.ActionButton = null;
        notice.Content = actions.Children.Count > 0 ? actions : null;
        if (route.AskLanguage) language.Focus(FocusState.Programmatic);
    }
    private void ClearRoute()
    {
        if (notice.Message == LocalRuntimeGuard.Message) return;
        notice.ActionButton = null; notice.Content = null;
    }
    /// <summary>The model's licence and size in place of the setup, as the Settings download confirmation shows them; Download
    /// installs it here. A second dialog can't open over this one.</summary>
    private void ShowDownload(TranscriptionModel download)
    {
        if (running || closed) return;
        confirmingDownload = download;
        Title = ModelDownloadCopy.Title(download);
        PrimaryButtonText = "Download"; CloseButtonText = "Cancel";
        DefaultButton = ContentDialogButton.Primary;
        var page = Ui.Stack(16); page.MinWidth = 400; page.MaxWidth = 480;
        page.Children.Add(Ui.Text(ModelDownloadCopy.Body(download, DownloadDependencies(download))));
        if (ModelDownloadCopy.SourcePage(download) is { } source) page.Children.Add(new HyperlinkButton { Content = "Open source page", NavigateUri = source });
        consentNotice.IsOpen = false;
        page.Children.Add(DetachedConsentNotice());
        Content = new ScrollViewer { Content = page, MaxHeight = 600 };
        IsPrimaryButtonEnabled = true;
    }
    /// <summary>The licence and cloud consent pages share <see cref="consentNotice"/>. A XAML element has one parent, so it
    /// leaves the previous page before a page is shown again (Download, Cancel, Download) or the other page is shown.</summary>
    private InfoBar DetachedConsentNotice()
    {
        if (consentNotice.Parent is Panel previous) previous.Children.Remove(consentNotice);
        return consentNotice;
    }
    private IReadOnlyList<TranscriptionModel> DownloadDependencies(TranscriptionModel download) => ModelDownloadCopy.Dependencies(download, catalogue);
    private void ShowSetup()
    {
        confirmingDownload = null;
        Title = model.HasTranscript ? "Transcribe again" : "Transcribe video";
        PrimaryButtonText = "Transcribe"; CloseButtonText = "Not now";
        Content = setupContent;
        IsPrimaryButtonEnabled = !running && !lifetime.IsCancellationRequested && (engine.SelectedIndex != 0 || App.Services.LocalRuntime.IsSupported);
    }
    private async Task DownloadAsync(TranscriptionModel download)
    {
        if (running || closed || model.IsLeaving) return;
        var approved = ModelDownloadCopy.Body(download, DownloadDependencies(download));
        Task<bool> Confirm(TranscriptionModel candidate, IReadOnlyList<TranscriptionModel> dependencies, CancellationToken _) =>
            candidate.Id == download.Id && ModelDownloadCopy.Body(candidate, dependencies) == approved ? Task.FromResult(true)
                : throw new InvalidOperationException("The model download no longer matches the licence shown.");
        running = true; IsPrimaryButtonEnabled = false;
        using var cancellation = CancellationTokenSource.CreateLinkedTokenSource(lifetime.Token);
        downloading = cancellation;
        var cancelled = false;
        try
        {
            await App.Services.Installer(Confirm).InstallAsync(download.Id, new Progress<ModelDownloadProgress>(value =>
            {
                if (!closed && ReferenceEquals(downloading, cancellation)) Ui.Show(consentNotice, ModelDownloadCopy.Progress(download, value));
            }), cancellation.Token);
        }
        catch (OperationCanceledException) when (cancellation.IsCancellationRequested && !lifetime.IsCancellationRequested) { cancelled = true; }
        finally { running = false; downloading = null; }
        if (closed) return;
        App.Services.NotifyModelsChanged();
        ShowSetup();
        // A cancelled download returns to the setup with the typed language, the model choice and the prompt's Download.
        if (cancelled) { consentNotice.IsOpen = false; return; }
        ClearRoute();
        Ui.Show(notice, TranscriptionRouting.Installed, InfoBarSeverity.Success);
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
            if (confirmingDownload is { } download)
            {
                await Ui.RunAsync(consentNotice, () => DownloadAsync(download), "Model download");
            }
            else if (confirmingCloud)
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
            if (!closed && !running) IsPrimaryButtonEnabled = !lifetime.IsCancellationRequested && (engine.SelectedIndex != 0 || App.Services.LocalRuntime.IsSupported);
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
        consentNotice.IsOpen = false;
        page.Children.Add(DetachedConsentNotice());
        Content = new ScrollViewer { Content = page, MaxHeight = 600 };
    }
    private async Task RunTranscriptionAsync()
    {
        if (running || closed || model.IsLeaving) return;
        await Ui.RunAsync(notice, async () =>
        {
            ClearRoute();
            if (!CheckLocalRuntime()) return;
            var local = engine.SelectedIndex == 0;
            var requestedLanguage = language.Text.Trim().ToLowerInvariant();
            // Route before any audio work, so a missing model or language is asked for at once (transcription §11.2).
            var route = local ? await RouteAsync(null) : null;
            if (closed || model.IsLeaving) return;
            if (route is { Plan: null, Detector: null }) { ShowRoute(route); return; }
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
            Ui.Show(notice, TranscriptionProgressCopy.ReadingVideo);
            try
            {
                var source = model.Project.Media.Source;
                // From extraction to the transcript, eviction leaves this source's cache entry alone (architecture §8.2).
                using var entryLease = await App.Services.CacheKeys.LeaseAsync(source.ContentKey, lifetime.Token);
                App.Services.Log.Write(VoxClip.Core.Services.Logging.LogLevel.Info, "transcribe", "dialog stage=probe");
                await App.Services.Log.FlushAsync(CancellationToken.None);
                var media = await App.Services.Probe.ProbeAsync(source.AbsolutePath, lifetime.Token);
                Report(MediaTranscriptionStage.ExtractingAudio, null);
                Ui.Show(notice, TranscriptionProgressCopy.ExtractingAudio);
                var audio = await App.Services.Cache.ExtractAudioAsync(App.Services.Audio, media, source.ContentKey, null, lifetime.Token);
                App.Services.Log.Write(VoxClip.Core.Services.Logging.LogLevel.Info, "transcribe", "dialog stage=audio-ready");
                await App.Services.Log.FlushAsync(CancellationToken.None);
                if (route is { Detector: not null })
                {
                    // Auto with a multilingual model: detect the language, then route it to its model (transcription §9.8).
                    Report(MediaTranscriptionStage.Transcribing, null);
                    progress.IsIndeterminate = true;
                    Ui.Show(notice, TranscriptionRouting.Detecting);
                    route = await RouteAsync((detector, token) => App.Services.DetectLanguageAsync(
                        new(new(TranscriptEngine.Whispercpp, detector, new LanguageChoice.Auto(), new()), audio.Audio, source.ContentKey), token));
                    if (closed || model.IsLeaving) return;
                    if (route.Plan is null) { ShowRoute(route); return; }
                }
                // The local engine only ever runs its routed plan; it never falls through to the cloud (no automatic fallback).
                var plan = local ? route?.Plan ?? throw new InvalidOperationException("Local transcription has no routed model.")
                    : new TranscriptionPlan(TranscriptEngine.Elevenlabs, null,
                        requestedLanguage.Length == 0 || requestedLanguage == "auto" ? new LanguageChoice.Auto() : new LanguageChoice.Forced(requestedLanguage), new());
                var cloud = !local;
                var transcript = await App.Services.Transcription.TranscribeAsync(new(plan, audio.Audio, source.ContentKey), new Progress<TranscriptionProgress>(value =>
                {
                    progress.IsIndeterminate = value.Fraction is null; progress.Value = (value.Fraction ?? 0) * 100;
                    Ui.Show(notice, TranscriptionProgressCopy.Label(value.Stage, value.Fraction, cloud));
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
