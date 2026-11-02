using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using VoxClip.App.Services;
using VoxClip.App.ViewModels;
using VoxClip.Core.Domain.Captions;
using VoxClip.Core.Domain.Transcript;
using VoxClip.Core.Services.Models;
using VoxClip.Core.Services.Project;
using VoxClip.Core.Domain.VoiceLab;
using VoxClip.Core.Services.VoiceLab;
using System.ComponentModel;

namespace VoxClip.App.Controls;

internal sealed class TranscriptionDialog : InlineEditorJob
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
    private readonly EditorWorkflowSnapshot baseline;
    private readonly CheckBox remember = new() { Content = "Remember language for new imports" };
    private readonly CheckBox allowCloud = new() { Content = "Allow this audio to be sent to ElevenLabs with my key" };
    private readonly TextBlock spend = Ui.Text("", "HelperText");
    private decimal? price;
    private bool keySaved;
    private int inputRevision;
    private CancellationTokenSource? transcribing;
    /// <summary>The model whose licence page is showing in place of the setup, after the notice's Download.</summary>
    private TranscriptionModel? confirmingDownload;
    private IReadOnlyList<TranscriptionModel> catalogue = [];
    private bool startingTranscription;
    private bool closed;
    private readonly StackPanel cloudKeyRow = Ui.Stack(8);
    private readonly TextBlock cloudKeyStatus = Ui.Text("Checking ElevenLabs key…", "HelperText");
    private readonly PasswordBox cloudKey = new() { Header = "ElevenLabs API key", PasswordRevealMode = PasswordRevealMode.Hidden, PlaceholderText = "Paste a key to save for your Windows account" };
    private readonly CancellationTokenSource lifetime = new();
    private readonly InlineJobLifetime workers = new();
    private bool stopped;
    /// <summary>The model download running from the licence page; Cancel or Esc stops only it and returns to the setup.</summary>
    private CancellationTokenSource? downloading;
    private readonly string? projectPath;
    private bool running;
    private bool preparing;

    internal TranscriptionDialog(MainWindow owner, EditorViewModel model) : base(model)
    {
        JobLabel = "Transcribe";
        baseline = new(model);
        this.model = model; projectPath = owner.ProjectPath; Title = model.HasTranscript ? "Transcribe again" : "Transcribe video";
        PrimaryButtonText = "Transcribe"; CloseButtonText = "Not now";
        engine.SelectedIndex = App.Services.Get("transcription.engineMode", "local") == "elevenlabs" ? 1 : 0;
        var savedLanguage = App.Services.Get("transcription.language", "auto");
        language.Text = savedLanguage == "auto" ? "" : savedLanguage;
        var body = Ui.Stack(16);
        body.Children.Add(Ui.Text("Choose how to transcribe. There is no automatic cloud fallback."));
        if (model.HasTranscript)
            body.Children.Add(Ui.Text($"This replaces the transcript and removes {model.Summary.CutWordCount + model.Summary.CutPauseCount} cuts, {model.Project.Edits.Corrections.Count} corrections, {model.Clips.Count} clips and the AI suggestions."));
        body.Children.Add(engine); body.Children.Add(flow); body.Children.Add(models); body.Children.Add(language);
        body.Children.Add(remember); body.Children.Add(allowCloud); body.Children.Add(spend);
        allowCloud.IsChecked = App.Services.Get("transcription.cloudConsent.elevenlabs", false);
        cloudKeyRow.Children.Add(cloudKeyStatus); cloudKeyRow.Children.Add(cloudKey);
        var saveCloudKey = Ui.Button("Save key", () => _ = Ui.RunAsync(notice, SaveCloudKeyAsync, "Save key"));
        saveCloudKey.IsEnabled = false;
        cloudKey.PasswordChanged += (_, _) => saveCloudKey.IsEnabled = !string.IsNullOrWhiteSpace(cloudKey.Password);
        cloudKeyRow.Children.Add(saveCloudKey); body.Children.Add(cloudKeyRow);
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(progress, "Transcription progress");
        body.Children.Add(Ui.Button("Manage local models…", () => App.OpenSettings(SettingsSections.LocalModels))); body.Children.Add(progress); body.Children.Add(notice);
        setupContent = new ScrollViewer { Content = body, MaxHeight = 600 };
        Content = setupContent;
        engine.SelectionChanged += (_, _) => InputsChanged();
        language.TextChanged += (_, _) => InputsChanged();
        models.SelectionChanged += (_, _) => InputsChanged();
        allowCloud.Checked += (_, _) => InputsChanged();
        allowCloud.Unchecked += (_, _) => InputsChanged();
        UpdateEngine();
        // Automatic routes each take by its language (transcription §11.2); an installed model can still be chosen by hand.
        models.Items.Add(new ComboBoxItem { Content = TranscriptionRouting.Automatic });
        models.SelectedIndex = 0;
        // A download here or in Settings → Local Models shows up in the list without reopening the dialog.
        void ModelsChanged(object? sender, EventArgs args) { if (!closed) _ = Ui.RunAsync(notice, async () => await LoadModelsAsync(), "Local models"); }
        Opened += async (_, _) => await Ui.RunAsync(notice, async () =>
        {
            using var worker = workers.Enter();
            App.Services.ModelsChanged += ModelsChanged;
            TranscriptionSpendState.Shared.Changed += SpendChanged;
            model.Changed += ProjectChanged; model.PropertyChanged += ProjectPropertyChanged;
            SpendChanged(this, EventArgs.Empty);
            await RefreshCloudKeyAsync();
            if (await LoadModelsAsync() == 0 && engine.SelectedIndex == 0 && CheckLocalRuntime())
            {
                // Nothing to transcribe with yet: offer the download this take's language routes to, before any audio work.
                var route = await RouteAsync(null);
                if (route.Plan is null && route.Detector is null) ShowRoute(route);
            }
            CheckLocalRuntime();
            if (!model.HasTranscript && engine.SelectedIndex == 0 && !running && baseline.IsCurrent &&
                (await RouteAsync(null)) is { } installed && (installed.Plan is not null || installed.Detector is not null)) await RunTranscriptionAsync();
        }, "Local models");
        PrimaryButtonClick += Transcribe;
        // Cancel on the licence page goes back to the setup; while a download runs it cancels only the download, which then
        // returns to the setup, as Settings → Local Models does. "Not now" during a run cancels the run.
        CloseButtonClick += (_, args) => { if (confirmingDownload is not null && !running && !lifetime.IsCancellationRequested) { args.Cancel = true; ShowSetup(); } };
        Closing += (_, args) =>
        {
            if (!running) return;
            if (downloading is { } download) download.Cancel(); else transcribing?.Cancel();
            args.Cancel = true;
        };
        Abandoned += (_, _) => { Stop(); Hide(); };
        Closed += (_, _) =>
        {
            closed = true; Stop();
            App.Services.ModelsChanged -= ModelsChanged; TranscriptionSpendState.Shared.Changed -= SpendChanged;
            model.Changed -= ProjectChanged; model.PropertyChanged -= ProjectPropertyChanged;
        };
    }
    private void Stop()
    {
        if (stopped) return;
        stopped = true;
        lifetime.Cancel(); downloading?.Cancel(); transcribing?.Cancel(); workers.Retire();
        _ = DisposeAfterDrainAsync();
    }
    private async Task DisposeAfterDrainAsync() { await workers.Drained; lifetime.Dispose(); }
    private void ProjectChanged(object? sender, EventArgs args) { if (!baseline.IsCurrent) { Stop(); Hide(); } }
    private void ProjectPropertyChanged(object? sender, PropertyChangedEventArgs args) => ProjectChanged(sender, EventArgs.Empty);
    private void SpendChanged(object? sender, EventArgs args)
    {
        void Refresh() { if (!closed) spend.Text = TranscriptionSpendState.Shared.Copy(DateOnly.FromDateTime(DateTime.Now)); }
        if (DispatcherQueue.HasThreadAccess) Refresh();
        else DispatcherQueue.TryEnqueue(Refresh);
    }
    private void InputsChanged()
    {
        inputRevision++; ResetApprovalFreshness();
        if (running) transcribing?.Cancel();
        UpdateEngine();
    }
    private void UpdateApproval()
    {
        var cloud = engine.SelectedIndex == 1;
        PrimaryButtonVisible = true;
        RequiresExplicitApproval = cloud || model.HasTranscript || confirmingDownload is not null;
        allowCloud.Visibility = cloud ? Visibility.Visible : Visibility.Collapsed;
        if (cloud)
        {
            try
            {
                price = VoiceLabPricing.Estimate(VoiceLabPricedOperation.ElevenLabsSpeechToText, "scribe_v2",
                    baseline.Project.Media.Source.DurationSeconds, 1, null, VoiceLabPrices.Load()).Usd;
                PrimaryButtonText = price is { } amount ? "Upload and Transcribe · " + VoiceLabCostPresentation.Format(amount) : "Price unavailable";
            }
            catch (Exception exception) when (exception is not OutOfMemoryException)
            { price = null; PrimaryButtonText = "Price unavailable"; }
        }
        else if (confirmingDownload is null) PrimaryButtonText = model.HasTranscript ? "Transcribe Again" : "Transcribe";
        IsPrimaryButtonEnabled = !running && !closed && baseline.IsCurrent &&
            (cloud ? keySaved && allowCloud.IsChecked == true && price is not null : App.Services.LocalRuntime.IsSupported);
    }
    /// <summary>List Automatic, then the installed local models by name, keeping the current choice; returns how many are installed.</summary>
    private async Task<int> LoadModelsAsync()
    {
        using var worker = workers.Enter();
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
        PrimaryButtonText = "Download and Transcribe"; CloseButtonText = "Cancel";
        RequiresExplicitApproval = true; ResetApprovalFreshness();
        var page = Ui.Stack(16);
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
        UpdateApproval();
    }
    private async Task DownloadAsync(TranscriptionModel download)
    {
        if (running || closed || model.IsLeaving) return;
        using var worker = workers.Enter();
        var approved = ModelDownloadCopy.Body(download, DownloadDependencies(download));
        Task<bool> Confirm(TranscriptionModel candidate, IReadOnlyList<TranscriptionModel> dependencies, CancellationToken _) =>
            candidate.Id == download.Id && ModelDownloadCopy.Body(candidate, dependencies) == approved ? Task.FromResult(true)
                : throw new InvalidOperationException("The model download no longer matches the licence shown.");
        var install = new TranscriptionModelInstall(download.Id, engine.SelectedIndex == 0, language.Text,
            (models.SelectedItem as ComboBoxItem)?.Tag as string);
        running = true; IsPrimaryButtonEnabled = false;
        engine.IsEnabled = language.IsEnabled = models.IsEnabled = false;
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
        finally
        {
            running = false; downloading = null;
            engine.IsEnabled = language.IsEnabled = models.IsEnabled = true;
        }
        if (closed) return;
        await LoadModelsAsync();
        if (closed) return;
        App.Services.NotifyModelsChanged();
        ShowSetup();
        // A cancelled download returns to the setup with the typed language, the model choice and the prompt's Download.
        if (cancelled) { consentNotice.IsOpen = false; return; }
        ClearRoute();
        Ui.Show(notice, TranscriptionRouting.Installed, InfoBarSeverity.Success);
        var installed = await App.Services.Downloads.ListInstalledAsync(lifetime.Token);
        if (closed || model.IsLeaving || lifetime.IsCancellationRequested) return;
        if (!baseline.IsCurrent) return;
        if (install.Continues(TranscriptionModelChoices.InstalledLocal(catalogue, installed).Any(entry => entry.Id == install.ModelId),
            engine.SelectedIndex == 0, language.Text, (models.SelectedItem as ComboBoxItem)?.Tag as string))
            await RunTranscriptionAsync();
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
        UpdateApproval();
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
        using var worker = workers.Enter();
        var saved = await App.Services.Keys.GetKeyAsync("elevenlabs-api-key", lifetime.Token) is not null;
        keySaved = saved;
        cloudKeyStatus.Text = saved ? "Key saved for your Windows account." : "Add an ElevenLabs key here before uploading this take.";
        cloudKey.PlaceholderText = saved ? "Saved for your Windows account; paste to replace" : "Paste an API key";
        UpdateApproval();
    }
    private async Task SaveCloudKeyAsync()
    {
        using var worker = workers.Enter();
        var secret = cloudKey.Password;
        cloudKey.Password = "";
        if (string.IsNullOrWhiteSpace(secret)) return;
        await App.Services.Keys.SaveAsync("elevenlabs-api-key", secret, lifetime.Token);
        await RefreshCloudKeyAsync();
        Ui.Show(notice, "Key saved securely. Audio is sent only after you confirm and choose Transcribe.");
    }
    private async void Transcribe(object? sender, InlineJobAction args)
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
            else await RunTranscriptionAsync();
        }
        finally
        {
            startingTranscription = false;
            if (!closed && !running) UpdateApproval();
        }
    }
    private async Task RunTranscriptionAsync()
    {
        if (running || preparing || closed || model.Busy || !baseline.IsCurrent || lifetime.IsCancellationRequested) return;
        using var worker = workers.Enter();
        preparing = true;
        var version = inputRevision;
        var local = engine.SelectedIndex == 0;
        var requestedLanguage = language.Text.Trim().ToLowerInvariant();
        var selectedModel = (models.SelectedItem as ComboBoxItem)?.Tag as string;
        var rememberLanguage = remember.IsChecked == true;
        var approvedPrice = price;
        var authorizedCloud = allowCloud.IsChecked == true;
        var service = App.Services.Transcription;
        using var cancellation = CancellationTokenSource.CreateLinkedTokenSource(lifetime.Token);
        var token = cancellation.Token;
        transcribing = cancellation;
        var jobId = Guid.NewGuid();
        var approvedDay = DateOnly.FromDateTime(DateTime.Now);
        var uploadMayHaveStarted = 0;
        var spentPending = false;
        void RequireCurrent()
        {
            token.ThrowIfCancellationRequested();
            baseline.RequireCurrent();
            if (version != inputRevision || !ReferenceEquals(service, App.Services.Transcription)) throw new OperationCanceledException(token);
        }
        async Task<LocalTranscriptionRoute> Route(Func<string, CancellationToken, Task<(string Language, double Probability)>>? detect) =>
            await TranscriptionRouting.RouteAsync(App.Services.Models as ModelCatalog ?? new ModelCatalog(), App.Services.Downloads,
                selectedModel, requestedLanguage, TranscriptionRouting.InstalledMemoryBytes, false, detect, token);
        try
        {
        await Ui.RunAsync(notice, async () =>
        {
            ClearRoute();
            if (!CheckLocalRuntime()) return;
            RequireCurrent();
            var route = local ? await Route(null) : null;
            RequireCurrent();
            if (route is { Plan: null, Detector: null }) { ShowRoute(route); return; }
            if (!local)
            {
                if (!authorizedCloud || approvedPrice is null) return;
                if (await App.Services.Keys.GetKeyAsync("elevenlabs-api-key", token) is null) { keySaved = false; UpdateApproval(); return; }
                RequireCurrent();
                if (!App.Services.Get("transcription.cloudConsent.elevenlabs", false))
                    await App.Services.SetAsync("transcription.cloudConsent.elevenlabs", true, token);
            }
            RequireCurrent();
            if (rememberLanguage) await App.Services.SetAsync("transcription.language", requestedLanguage.Length == 0 ? "auto" : requestedLanguage, token);
            RequireCurrent();
            running = true; model.Busy = true; App.Services.BusyOperations++; IsPrimaryButtonEnabled = false; progress.Visibility = Visibility.Visible;
            CloseButtonText = "Cancel";
            void Cancel() { if (running) cancellation.Cancel(); }
            var announcements = new TranscriptionAnnouncements();
            void Report(MediaTranscriptionStage step, double? fraction)
            {
                if (closed || version != inputRevision || !baseline.IsCurrent) return;
                if (projectPath is not null && running) TranscriptionActivity.Report(projectPath, step, fraction, Cancel);
                if (announcements.Update(step, fraction, !local) is { } text) Ui.Announce(notice, text, "transcription");
            }
            Report(MediaTranscriptionStage.ReadingVideo, null);
            Ui.Show(notice, TranscriptionProgressCopy.ReadingVideo);
            try
            {
                var source = baseline.Project.Media.Source;
                using var sourceRead = new FileStream(source.AbsolutePath, FileMode.Open, FileAccess.Read, FileShare.Read);
                using var entryLease = await App.Services.CacheKeys.LeaseAsync(source.ContentKey, token);
                var media = await App.Services.Probe.ProbeAsync(source.AbsolutePath, token);
                RequireCurrent();
                if (media.Audio is null || Math.Abs(media.DurationSeconds - source.DurationSeconds) > 0.05 ||
                    await App.Services.Projects.ComputeContentKeyAsync(source.AbsolutePath, null, token) != source.ContentKey)
                    throw new InvalidOperationException("This video changed or has no audio. Find the original video before transcribing. Your edits are saved.");
                RequireCurrent();
                Report(MediaTranscriptionStage.ExtractingAudio, null);
                Ui.Show(notice, TranscriptionProgressCopy.ExtractingAudio);
                var audio = await App.Services.Cache.ExtractAudioAsync(App.Services.Audio, media, source.ContentKey, null, token);
                RequireCurrent();
                if (route is { Detector: not null })
                {
                    // Auto with a multilingual model: detect the language, then route it to its model (transcription §9.8).
                    Report(MediaTranscriptionStage.Transcribing, null);
                    progress.IsIndeterminate = true;
                    Ui.Show(notice, TranscriptionRouting.Detecting);
                    route = await Route((detector, detectToken) => App.Services.DetectLanguageAsync(
                        new(new(TranscriptEngine.Whispercpp, detector, new LanguageChoice.Auto(), new()), audio.Audio, source.ContentKey), detectToken));
                    RequireCurrent();
                    if (route.Plan is null) { ShowRoute(route); return; }
                }
                // The local engine only ever runs its routed plan; it never falls through to the cloud (no automatic fallback).
                var plan = local ? route?.Plan ?? throw new InvalidOperationException("Local transcription has no routed model.")
                    : new TranscriptionPlan(TranscriptEngine.Elevenlabs, null,
                        requestedLanguage.Length == 0 || requestedLanguage == "auto" ? new LanguageChoice.Auto() : new LanguageChoice.Forced(requestedLanguage), new());
                var cloud = !local;
                if (cloud && approvedPrice is { } amount) { TranscriptionSpendState.Shared.Begin(jobId, amount); spentPending = true; }
                var request = new TranscriptionRequest(plan, audio.Audio, source.ContentKey)
                {
                    Observe = cloud && approvedPrice is { } capturedEstimate ? evidence =>
                    {
                        if (evidence.Kind == TranscriptionEvidenceKind.UploadStarted) Interlocked.Exchange(ref uploadMayHaveStarted, 1);
                        TranscriptionSpendState.Shared.Observe(jobId, approvedDay, capturedEstimate, evidence);
                    } : null
                };
                var transcript = await service.TranscribeAsync(request, new WorkflowProgress<TranscriptionProgress>(value =>
                {
                    if (cloud && value.Stage == TranscriptionStage.Uploading) Interlocked.Exchange(ref uploadMayHaveStarted, 1);
                }, value =>
                {
                    if (closed || version != inputRevision || !baseline.IsCurrent) return;
                    progress.IsIndeterminate = value.Fraction is null; progress.Value = (value.Fraction ?? 0) * 100;
                    Ui.Show(notice, TranscriptionProgressCopy.Label(value.Stage, value.Fraction, cloud));
                    if (cloud) flow.Text = Volatile.Read(ref uploadMayHaveStarted) != 0
                        ? "ElevenLabs may still bill audio already received. Your video is still here."
                        : "Nothing has been sent yet. Cancel now and nothing is billed.";
                    Report(value.Stage == TranscriptionStage.Aligning ? MediaTranscriptionStage.Aligning : MediaTranscriptionStage.Transcribing, value.Fraction);
                }, action => DispatcherQueue.TryEnqueue(() => action())), token);
                if (cloud && approvedPrice is { } paid)
                    TranscriptionSpendState.Shared.Completed(jobId, approvedDay, paid, transcript.FromCache);
                RequireCurrent();
                model.SetTranscript(transcript);
                if (!closed) Hide();
            }
            catch (OperationCanceledException)
            {
                if (!closed) Ui.Show(notice, local ? "Transcription cancelled. Your media and edits are safe." :
                    "Transcription cancelled. ElevenLabs may still bill audio already received. Your media and edits are safe.");
            }
            catch (Exception exception) when (exception is not OperationCanceledException)
            {
                if (exception is VoxClip.Core.Domain.Shared.VoxClipException { Code: VoxClip.Core.Domain.Shared.VoxClipErrorCode.KeyRejected or VoxClip.Core.Domain.Shared.VoxClipErrorCode.KeyPermissionMissing }) keySaved = false;
                App.Services.Log.Write(VoxClip.Core.Services.Logging.LogLevel.Error, "transcribe",
                    $"dialog failed type={exception.GetType().Name} hresult={exception.HResult}");
                throw;
            }
            finally
            {
                running = false; model.Busy = false; App.Services.BusyOperations--; progress.Visibility = Visibility.Collapsed; CloseButtonText = "Not now";
                if (projectPath is not null) TranscriptionActivity.End(projectPath);
            }
        }, "Transcription");
        }
        finally
        {
            if (spentPending) TranscriptionSpendState.Shared.End(jobId, Volatile.Read(ref uploadMayHaveStarted) != 0);
            preparing = false;
            if (ReferenceEquals(transcribing, cancellation)) transcribing = null;
            if (!closed) UpdateApproval();
        }
    }
}
