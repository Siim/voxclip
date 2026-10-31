using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using Microsoft.UI.Xaml.Input;
using VoxClip.App.Controls;
using VoxClip.App.Services;
using VoxClip.App.ViewModels;
using VoxClip.Core.Domain.Captions;
using VoxClip.Core.Domain.Editing;
using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Domain.VoiceLab;
using VoxClip.Core.Services.Speech;
using VoxClip.Core.Services.VoiceLab;
using VoxClip.Core.Services.Media;
using VoxClip.Media.Pipeline;
using VoxClip.Media.Captions;
using VoxClip.Media.VoiceLab;
using Windows.System;
using System.Runtime.InteropServices.WindowsRuntime;
using Microsoft.UI.Xaml.Media.Imaging;

namespace VoxClip.App.Pages;

public sealed partial class EditorPage : Page
{
    public EditorViewModel ViewModel { get; private set; } = null!;
    private readonly CancellationTokenSource lifetime = new();
    private MainWindow owner = null!;
    private IPreviewEngine? preview;
    private PreviewPresenter? presenter;
    private CaptionsPanel? captions;
    private Controls.RightColumn? rightContent;
    private RewriteSession? rewrite;
    private ElevenLabsRegion? rewriteGenerationRegion;
    private long rewriteOpenRevision;
    private MediaInfo? media;
    private EditorMediaState mediaState;
    private long standInGeneration;
    private Task pendingStandIn = Task.CompletedTask;
    private bool demo;
    private bool ready;
    private readonly TaskCompletionSource aspectLoaded = new(TaskCreationOptions.RunContinuationsAsynchronously);
    private bool disposed;
    /// <summary>The viewer collapsed because the transcript would drop below its minimum; it returns when there is room.</summary>
    private bool viewerSqueezed;
    /// <summary>The user showed the viewer where the transcript has no room; it stays until they hide it or the window grows.</summary>
    private bool viewerForced;
    private CancellationTokenSource? autosave;
    private Task pendingSave = Task.CompletedTask;
    private PendingProjectSave projectWrites = null!;
    private Task pendingWaveform = Task.CompletedTask;
    private CancellationTokenSource? waveformRequest;
    private ProjectLeaveBoundary leave = null!;
    /// <summary>This editor's lease on its project's cache entry, from opening to closing (architecture §8.2).</summary>
    private OpenProjectCacheLease? cacheLease;
    private readonly SemaphoreSlim previewChanges = new(1, 1);
    private readonly SemaphoreSlim saves = new(1, 1);
    private string pauseBreath = "natural";
    private double previewDuration;
    private double? previewStop;
    private string? previewClipId;
    // Home keeps this page alive and re-inserts it, so Loaded moves no focus: a chosen sidebar row keeps it (design C15).
    // Opening a project focuses the transcript once, at the end of OpenAsync.
    public EditorPage()
    {
        InitializeComponent();
        Aspect.Loaded += AspectLoaded;
        SearchText.GotFocus += (_, _) => Transcript.HideSelectionFlyout();
        PreviewStandIn.SizeChanged += (_, _) => PositionStageMessage();
        FrameRow.SizeChanged += (_, _) => { if (ready) SizeStage(); };
        TransportRow.SizeChanged += (_, _) => { if (ready) SizeStage(); };
    }
    public static bool HasText(string? text) => !string.IsNullOrEmpty(text);
    private void AspectLoaded(object sender, RoutedEventArgs args)
    {
        Aspect.Loaded -= AspectLoaded;
        aspectLoaded.TrySetResult();
    }
    /// <summary>The take's resolved video, or null when it can't be found or the project is a demo fixture.</summary>
    internal string? MediaPath { get; private set; }
    internal bool IsDemo => demo;
    /// <summary>Find clips in this take: its flyout, and the "Finding clips…" row and callout it puts in the pane.</summary>
    internal FindClipsFlyout FindClips { get; private set; } = null!;

    internal async Task OpenAsync(MainWindow window, Project project, string? mediaPath, bool demoMode, CancellationToken ct)
    {
        owner = window;
        demo = demoMode;
        mediaState = demo ? EditorMediaState.Demo : mediaPath is null ? EditorMediaState.Missing : project.Media.Source.Video is null ? EditorMediaState.AudioOnly : EditorMediaState.Ready;
        MediaPath = demoMode ? null : mediaPath;
#if DEBUG
        ViewModel = demo ? new(project, DemoProject.Reduce, DemoProject.Summarize) : new(project);
        preview = demo ? new DemoPreviewEngine() : new PreviewEngine();
#else
        ViewModel = new(project);
        preview = new PreviewEngine();
#endif
        ViewModel.SetMediaUnavailable(!demo && mediaPath is null);
        // Eviction never strips or removes the entry of a project open in any window, and opening it marks it used.
        if (!demo) { cacheLease = new(App.Services.Cache); cacheLease.Hold(project.Media.Source.ContentKey); }
        projectWrites = new(project, ViewModel.MarkSaved);
        ViewModel.SetVoiceLabLabelPosition(VoiceLabSettingsState.LabelPosition(App.Services.Settings.GetString("voiceLab.labelPosition")));
        ViewModel.SetExportRecords(App.Services.ExportLedger.Records);
        App.Services.ExportLedger.Changed += LedgerChanged;
        LocateMedia.Visibility = ViewModel.IsReadOnly ? Visibility.Visible : Visibility.Collapsed;
        leave = new(ViewModel);
        FindClips = new(ViewModel, lifetime.Token);
        FindClips.Announcement += (_, text) => Transcript.Announce(text);
        preview.PlaybackFaulted += PlaybackFaulted;
        preview.AudioStatusChanged += AudioStatusChanged;
        ViewModel.Changed += ModelChanged;
        ViewModel.SelectionChanged += SelectionChanged;
        ViewModel.SaveRequested += SaveRequested;
        pauseBreath = App.Services.Get("editing.pauseBreath", "natural");
        App.Services.SettingsChanged += EditorSettingsChanged;
        Transcript.Attach(ViewModel);
        Transcript.RewriteRequested += (_, _) => _ = RunAsync(() => OpenRewriteAsync(false), "Rewrite");
        Transcript.InsertWordsRequested += (_, _) => _ = RunAsync(() => OpenRewriteAsync(true), "Rewrite");
        Timeline.Attach(ViewModel);
        CaptionDrag.Attach(ViewModel);
        Transcript.SeekRequested += (_, _) => _ = RunAsync(() => SeekSourceAsync(ViewModel.SourceTime), "Preview");
        Transcript.MakeClipRequested += (_, _) => MakeClipAndReveal();
        Transcript.PlayRequested += (_, _) => _ = RunAsync(async () => { if (ViewModel.IsReadOnly || ViewModel.Busy) return; await SeekSourceAsync(ViewModel.SourceTime); if (preview is not null) await preview.PlayAsync(lifetime.Token); }, "Preview");
        Transcript.PreviewCutRequested += (_, _) => _ = RunAsync(PreviewCutAsync, "Preview");
        Timeline.SeekRequested += (_, time) => _ = RunAsync(() => SeekSourceAsync(time), "Preview");
        Timeline.PlayRequested += (_, _) => _ = RunAsync(TogglePlaybackAsync, "Preview");
        ViewModel.PropertyChanged += (_, args) =>
        {
            if (args.PropertyName == nameof(EditorViewModel.CanExport)) UpdateExport();
            if (args.PropertyName == nameof(EditorViewModel.IsReadOnly)) { UpdateAiTag(); SizeStage(); }
            if (args.PropertyName is nameof(EditorViewModel.Busy) or nameof(EditorViewModel.CanFindClips)) UpdateFindClips();
        };
        Untranscribed.Visibility = ViewModel.HasTranscript ? Visibility.Collapsed : Visibility.Visible;
        UpdateFindClips();
        Bindings.Update();
        await EditorInitialSelection.ApplyAsync(project.Export.Aspect, aspectLoaded.Task, index => Aspect.SelectedIndex = index, ct);
        captions = new(ViewModel, () => MediaPath, lifetime.Token);
        captions.FitChanged += (_, _) => SizeStage();
        rightContent = new(captions);
        CaptionsHost.Children.Add(rightContent);
        SelectionChanged(this, EventArgs.Empty);
        await captions.InitializeAsync();
        InstallAccelerators();
        if (demo) media = MediaFromProject(project);
        else if (mediaPath is not null)
        {
            try { media = await App.Services.Probe.ProbeAsync(mediaPath, ct); }
            catch (OperationCanceledException) when (ct.IsCancellationRequested) { throw; }
            catch (Exception exception) { PreviewFailed(exception); }
        }
        if (mediaPath is null || demo) ViewModel.Notice = EditorMediaPresentation.Notice(mediaState, EditorMediaPresentation.FileName(project.Media.Source.AbsolutePath));
        ready = true;
        projectWrites.Mark(ViewModel.Project);
        UpdateAiTag();
        UpdateExport();
        ShowViewer(true);
        FitViewer(ActualWidth);
        await RunAsync(async () =>
        {
            if (media is null || preview is null) return;
            try
            {
                var snapshot = await SnapshotAsync(ct);
                previewDuration = snapshot.Timeline.Duration;
                await preview.LoadAsync(snapshot, null, ct);
                CaptionDrag.Update(snapshot.Captions, 0);
            }
            catch (Exception exception)
            {
                preview.PlaybackFaulted -= PlaybackFaulted;
                preview.AudioStatusChanged -= AudioStatusChanged;
                await preview.DisposeAsync();
                preview = null;
                PreviewImage.Source = null;
                PreviewStandIn.Visibility = Visibility.Visible;
                ViewModel.SetMediaUnavailable(true);
                LocateMedia.Visibility = Visibility.Visible;
                captions?.MediaUnavailable();
                PreviewFailed(exception);
                return;
            }
            presenter = new(PreviewImage, preview, PositionChanged, PreviewFailed, demo ? frame => captions?.UpdateStill(frame) : null);
            presenter.Start(); PreviewStandIn.Visibility = Visibility.Collapsed;
        }, "Preview");
        RequestWaveform();
        if (ViewModel.IsReadOnly) pendingStandIn = RenderUnavailableCaptionsAsync();
        Transcript.Focus(FocusState.Programmatic);
    }

    private void RequestWaveform()
    {
        waveformRequest?.Cancel();
        Timeline.SetWaveform([]);
        if (disposed || demo || ViewModel.IsReadOnly || media is not { Audio: not null } source) return;
        var request = CancellationTokenSource.CreateLinkedTokenSource(lifetime.Token);
        waveformRequest = request;
        pendingWaveform = LoadWaveformAsync(source, ViewModel.Project.Media.Source.ContentKey, request, pendingWaveform);
    }
    private async Task LoadWaveformAsync(MediaInfo source, string contentKey, CancellationTokenSource request, Task previous)
    {
        try
        {
            await previous;
            var levels = await App.Services.Waveform.GetAsync(source, contentKey, request.Token);
            if (!disposed && !request.IsCancellationRequested && ReferenceEquals(waveformRequest, request)) Timeline.SetWaveform(levels);
        }
        catch (OperationCanceledException) when (request.IsCancellationRequested) { }
        catch (Exception exception)
        {
            App.Services.Log.Write(Core.Services.Logging.LogLevel.Warn, "waveform", UiError.Message(exception, "Waveform"));
        }
        finally
        {
            if (ReferenceEquals(waveformRequest, request)) waveformRequest = null;
            request.Dispose();
        }
    }

    private static MediaInfo MediaFromProject(Project project)
        => ExportRenderInput.Media(project);
    private async Task<ComposeSnapshot> SnapshotAsync(CancellationToken ct, EditState? stateOverride = null, Project? projectOverride = null)
    {
        var source = media ?? MediaFromProject(projectOverride ?? ViewModel.Project);
        var state = projectOverride is null ? stateOverride ?? ViewModel.State : stateOverride;
        var project = projectOverride ?? ViewModel.ScopedProject(state);
        var scope = project.Edits.ActiveClipId is { } id ? VoiceLabOutputScope.Clip(id) : VoiceLabOutputScope.Full;
        VoiceLabRenderInput? voice = null;
        if (project.SchemaVersion == 3)
        {
            var prepared = VoiceLabRenderContract.Prepare(project, scope, VoiceLabSettingsState.LabelPosition(App.Services.Settings.GetString("voiceLab.labelPosition")));
            if (prepared.OutputPlan.RequiresSyntheticRendering)
                voice = VoiceLabRenderInput.Capture(project, prepared, Path.Combine(App.Services.Data.Root, "VoiceLab"));
        }
        else VoiceLabProject.RequireLegacyRendering(project, scope);
        var plan = ExportRenderInput.Plan(source, state);
        var output = ExportRenderInput.Output(source, project.Export);
        var outputSize = output.Size;
        CaptionTrack? captions = null;
        if (!demo && state is not null && project.Captions.StyleId != "off" && this.captions?.Styles.FirstOrDefault(style => style.Id == project.Captions.StyleId) is { } style)
            captions = await CaptionEngine.BuildAsync(new(style, project.Captions, outputSize,
                voice?.Prepared.OutputPlan.Captions ?? EditingEngine.CaptionWords(state, plan), state.Transcript.Language,
                voice?.Prepared.OutputPlan.Duration ?? plan.Duration), new HarfBuzzGlyphShaper(), null, ct);
        var snapshot = new ComposeSnapshot(source, plan, captions, output) { VoiceLab = voice };
        return voice?.CaptureSnapshot(snapshot) ?? snapshot;
    }
    private void PositionChanged(PreviewPosition position)
    {
        if (disposed) return;
        var sourceTime = position.SourceTime;
        if (ViewModel.State?.ActiveClipId is { } clipId && position.EditedTime >= previewDuration &&
            ViewModel.Clips.FirstOrDefault(clip => clip.Id == clipId) is { } active &&
            ViewModel.Words.FirstOrDefault(word => word.Id == active.Clip.EndWordId) is { } endWord)
            sourceTime = endWord.End;
        var changed = Math.Abs(ViewModel.SourceTime - sourceTime) > 0.02;
        ViewModel.SourceTime = sourceTime;
        var (elapsed, total) = PreviewClockLabel.Parts(position.EditedTime, previewDuration);
        TransportElapsed.Text = elapsed;
        TransportTotal.Text = " / " + total;
        PlayGlyph.Symbol = position.IsPlaying ? Symbol.Pause : Symbol.Play;
        AutomationProperties.SetName(PreviewPlay, PlaybackPresentation.Name(position.IsPlaying));
        ToolTipService.SetToolTip(PreviewPlay, PlaybackPresentation.Hint(position.IsPlaying));
        Timeline.SetTransport(elapsed, total, position.IsPlaying);
        Timeline.Position(position.SourceTime);
        CaptionDrag.Position(position.EditedTime);
        captions?.UpdatePosition(position.EditedTime, sourceTime);
        if (previewStop is { } stop && sourceTime >= stop && preview is not null)
        { previewStop = null; _ = RunAsync(() => preview.PauseAsync(lifetime.Token), "Preview"); }
        if (changed) Transcript.RefreshVisuals();
    }
    private void PlaybackFaulted(object? sender, Exception exception)
    {
        DispatcherQueue.TryEnqueue(() => { if (!disposed) PreviewFailed(exception); });
    }
    private void PreviewFailed(Exception exception)
    {
        if (disposed) return;
        ViewModel.SetMediaUnavailable(true);
        mediaState = EditorMediaState.Corrupt;
        PreviewImage.Source = null;
        LocateMedia.Visibility = Visibility.Visible;
        captions?.MediaUnavailable();
        ViewModel.Notice = EditorMediaPresentation.Notice(mediaState, EditorMediaPresentation.FileName(ViewModel.Project.Media.Source.AbsolutePath));
        App.Services.Log.Write(Core.Services.Logging.LogLevel.Warn, "preview", UiError.Message(exception, "Preview"));
        SizeStage();
        pendingStandIn = RenderUnavailableCaptionsAsync();
        UpdateExport();
    }
    private void AudioStatusChanged(object? sender, PreviewAudioStatus status)
    {
        const string noDevice = "No audio output device. Playing without sound.", inUse = "Another app is using the audio output. Playing without sound.";
        DispatcherQueue.TryEnqueue(() =>
        {
            if (disposed) return;
            if (status != PreviewAudioStatus.Available) ViewModel.Notice = status == PreviewAudioStatus.OutputInUse ? inUse : noDevice;
            else if (ViewModel.Notice is noDevice or inUse) ViewModel.Notice = "";
        });
    }
    /// <summary>Make clip needs words selected (design §6.2).</summary>
    private void SelectionChanged(object? sender, EventArgs args)
    {
        MakeClipCommand.IsEnabled = ViewModel.HasSelection;
        PreviewCutCommand.IsEnabled = ViewModel.CanPreviewCut;
        UpdateRewriteCommand();
        if (ready && ViewModel.IsReadOnly) pendingStandIn = RenderUnavailableCaptionsAsync();
    }
    private void UpdateRewriteCommand()
    {
        RewriteCommand.Visibility = App.Services.VoiceLabEnabled ? Visibility.Visible : Visibility.Collapsed;
        RewriteCommand.IsEnabled = App.Services.VoiceLabEnabled && Transcript.CanRewrite;
    }
    private async Task RenderUnavailableCaptionsAsync()
    {
        var previous = pendingStandIn;
        var generation = ++standInGeneration;
        try
        {
            await previous;
            if (disposed || !ViewModel.IsReadOnly || generation != standInGeneration) return;
            var snapshot = await SnapshotAsync(lifetime.Token);
            var track = snapshot.Captions;
            var editedTime = snapshot.Timeline.MapTime(ViewModel.SourceTime);
            PixelBuffer? pixels = null;
            if (track is not null)
            {
                var scale = (PreviewStage.ActualWidth > 0 ? PreviewStage.ActualWidth : 320) / track.Frame.Width;
                pixels = await Task.Run(() => new SkiaCaptionRasterizer().RenderAsync(new(track, editedTime, ReduceMotion: true, Scale: scale), lifetime.Token), lifetime.Token);
            }
            if (disposed || !ViewModel.IsReadOnly || generation != standInGeneration) return;
            CaptionDrag.Update(track, editedTime);
            if (pixels is not { } frame) { PreviewImage.Source = null; return; }
            var image = new WriteableBitmap(frame.Width, frame.Height);
            using (var stream = image.PixelBuffer.AsStream()) stream.Write(frame.Pixels.Span);
            image.Invalidate(); PreviewImage.Source = image;
        }
        catch (OperationCanceledException) { }
        catch (Exception exception) { App.Services.Log.Write(Core.Services.Logging.LogLevel.Warn, "preview-card", UiError.Message(exception, "Preview")); }
    }
    private void ModelChanged(object? sender, EventArgs args)
    {
        if (!ready || disposed) return;
        UpdateExport();
        SizeStage();
        UpdateAiTag();
        Untranscribed.Visibility = ViewModel.HasTranscript ? Visibility.Collapsed : Visibility.Visible;
        UpdateFindClips();
        _ = RunAsync(UpdatePreviewAsync, "Preview");
        if (ViewModel.IsReadOnly) pendingStandIn = RenderUnavailableCaptionsAsync();
        if (!ViewModel.IsRelinking) SaveRequested(sender, args);
    }
    private void SaveRequested(object? sender, EventArgs args)
    {
        if (ready && !disposed && !demo && !ViewModel.IsRelinking)
        {
            projectWrites.Mark(ViewModel.Project);
            autosave?.Cancel(); autosave?.Dispose();
            autosave = CancellationTokenSource.CreateLinkedTokenSource(lifetime.Token);
            pendingSave = SaveAfterDelayAsync(autosave.Token);
        }
    }
    private void EditorSettingsChanged(object? sender, EventArgs args)
    {
        if (disposed || ViewModel.IsLeaving) return;
        if (ViewModel.SetVoiceLabLabelPosition(VoiceLabSettingsState.LabelPosition(App.Services.Settings.GetString("voiceLab.labelPosition"))))
            _ = RunAsync(UpdatePreviewAsync, "Preview label position");
        rewriteOpenRevision++;
        if (App.Services.VoiceLabEnabled && rewrite is { IsOpen: true, Generation: { } previous } session &&
            rewriteGenerationRegion != ElevenLabsRegions.FromSettings(App.Services.Settings, App.Services.Log))
        {
            var rediscover = previous.HasStartedDiscovery;
            ConfigureRewriteGeneration(session);
            if (rediscover) _ = RediscoverRewriteAsync(session, previous, session.Generation!);
        }
        rewrite?.SettingsChanged(App.Services.VoiceLabEnabled);
        Transcript.ApplySettings();
        SelectionChanged(this, EventArgs.Empty);
        captions?.RefreshSamples();
        var next = App.Services.Get("editing.pauseBreath", "natural");
        if (next == pauseBreath) return;
        pauseBreath = next;
        ViewModel.Apply(new EditOperation.SetPauseKeep(next switch { "tight" => 0.05, "relaxed" => 0.30, _ => 0.15 }));
    }
    private async Task SaveAfterDelayAsync(CancellationToken ct)
    {
        try { await Task.Delay(500, ct); await SaveAsync(ct); }
        catch (OperationCanceledException) { }
        catch (Exception exception) { ViewModel.Notice = UiError.Message(exception, "Save project"); }
    }
    private async Task SaveAsync(CancellationToken ct)
    {
        if (demo) return;
        await saves.WaitAsync(ct);
        try
        {
            var path = owner.ProjectPath;
            if (path is not null) await projectWrites.FlushAsync((project, token) => App.Services.Projects.SaveAsync(project, path, token), ct);
        }
        finally { saves.Release(); }
    }
    private void LedgerChanged(object? sender, EventArgs args) => DispatcherQueue.TryEnqueue(() =>
    {
        if (!disposed) ViewModel.SetExportRecords(App.Services.ExportLedger.Records);
    });
    private async void LocateClicked(object sender, RoutedEventArgs args) => await LocateAsync();
    internal async Task LocateAsync() => await RunAsync(async () =>
    {
        if (owner.ProjectPath is not { } projectPath || demo) return;
        autosave?.Cancel();
        await pendingSave;
        MediaInfo? selectedMedia = null;
        var relinked = await ViewModel.RelinkAsync(App.Services.Projects, projectPath, async () =>
        {
            var locate = new ContentDialog { XamlRoot = XamlRoot, Title = "Locate video", Content = new TextBlock
                { Text = ViewModel.Project.Media.Source.AbsolutePath.Replace('/', (char)92), TextWrapping = TextWrapping.Wrap },
                PrimaryButtonText = "Choose video…", CloseButtonText = "Cancel", DefaultButton = ContentDialogButton.Close };
            if (await locate.ShowAsync() != ContentDialogResult.Primary) return null;
            var picker = new Windows.Storage.Pickers.FileOpenPicker();
            WinRT.Interop.InitializeWithWindow.Initialize(picker, WinRT.Interop.WindowNative.GetWindowHandle(owner));
            foreach (var extension in new[] { ".mp4", ".mov", ".m4v", ".mkv", ".webm", ".avi" }) picker.FileTypeFilter.Add(extension);
            return (await picker.PickSingleFileAsync())?.Path;
        }, async selected => selectedMedia = await App.Services.Probe.ProbeAsync(selected, lifetime.Token), async () =>
        {
            var dialog = new ContentDialog { XamlRoot = XamlRoot, Title = "This file looks different. Use it anyway?",
                Content = new TextBlock { Text = ViewModel.Project.Media.Source.AbsolutePath, TextWrapping = TextWrapping.Wrap },
                PrimaryButtonText = "Use it", CloseButtonText = "Choose another", DefaultButton = ContentDialogButton.Close };
            return await dialog.ShowAsync() == ContentDialogResult.Primary;
        }, lifetime.Token);
        if (!relinked) return;
        // Another file may have another content key: the lease moves with the project.
        cacheLease?.Hold(ViewModel.Project.Media.Source.ContentKey);
        projectWrites = new(ViewModel.Project, ViewModel.MarkSaved);
        MediaPath = ViewModel.Project.Media.Source.AbsolutePath;
        media = selectedMedia;
        mediaState = media?.Video is null ? EditorMediaState.AudioOnly : EditorMediaState.Ready;
        LocateMedia.Visibility = Visibility.Collapsed;
        if (preview is not null)
        {
            preview.PlaybackFaulted -= PlaybackFaulted;
            preview.AudioStatusChanged -= AudioStatusChanged;
            if (presenter is not null) await presenter.DisposeAsync();
            else await preview.DisposeAsync();
        }
        presenter = null;
        preview = null;
        await UpdatePreviewAsync();
        RequestWaveform();
        UpdateExport();
    }, "Locate video");
    private async Task UpdatePreviewAsync()
    {
        if (media is null || ViewModel.IsReadOnly) return;
        await previewChanges.WaitAsync(lifetime.Token);
        try
        {
            var state = ViewModel.State;
            var snapshot = await SnapshotAsync(lifetime.Token, state);
            var clipChanged = previewClipId != state?.ActiveClipId;
            previewClipId = state?.ActiveClipId;
            previewDuration = snapshot.Timeline.Duration;
            if (preview is null)
            {
                preview = new PreviewEngine();
                preview.PlaybackFaulted += PlaybackFaulted;
                preview.AudioStatusChanged += AudioStatusChanged;
                await preview.LoadAsync(snapshot, null, lifetime.Token);
                presenter = new(PreviewImage, preview, PositionChanged,
                    PreviewFailed);
                presenter.Start(); PreviewStandIn.Visibility = Visibility.Collapsed;
            }
            else await preview.UpdateSnapshotAsync(snapshot, lifetime.Token);
            CaptionDrag.Update(snapshot.Captions, preview.Position.EditedTime);
            if (clipChanged && previewClipId is not null) await preview.SeekAsync(0, true, lifetime.Token);
        }
        catch (Exception exception)
        {
            if (preview is not null) { preview.PlaybackFaulted -= PlaybackFaulted; preview.AudioStatusChanged -= AudioStatusChanged; }
            if (presenter is not null) { await presenter.DisposeAsync(); presenter = null; }
            else if (preview is not null) await preview.DisposeAsync();
            preview = null;
            if (!disposed) { PreviewImage.Source = null; PreviewStandIn.Visibility = Visibility.Visible; PreviewFailed(exception); }
        }
        finally { previewChanges.Release(); }
    }
    private async Task SeekSourceAsync(double source)
    {
        previewStop = null;
        if (preview is null || ViewModel.IsReadOnly)
        {
            if (ViewModel.IsReadOnly) pendingStandIn = RenderUnavailableCaptionsAsync();
            return;
        }
        var snapshot = await SnapshotAsync(lifetime.Token);
        await preview.SeekAsync(snapshot.Timeline.MapTime(source), true, lifetime.Token);
    }
    private async Task RunAsync(Func<Task> action, string label)
    {
        try { await action(); }
        catch (OperationCanceledException) { }
        catch (Exception exception) { if (!disposed) ViewModel.Notice = UiError.Message(exception, label); }
    }
    private void FillersClicked(object sender, RoutedEventArgs args) => ViewModel.Apply(new EditOperation.CutFillers());
    private void PausesClicked(object sender, RoutedEventArgs args) => ViewModel.Apply(new EditOperation.TightenPauses());
    private void RestoreClicked(object sender, RoutedEventArgs args) => ViewModel.Apply(new EditOperation.RestoreCuts());
    private void UndoClicked(object sender, RoutedEventArgs args) => ViewModel.Undo();
    private void RedoClicked(object sender, RoutedEventArgs args) => ViewModel.Redo();
    /// <summary>Make a clip, then select its pane row; the transcript keeps its selection (design §6.2).</summary>
    private void MakeClipAndReveal()
    {
        if (ViewModel.MakeClip() is { } id) owner.RevealClip(id);
    }
    private void MakeClipClicked(object sender, RoutedEventArgs args) => MakeClipAndReveal();
    private async void RewriteClicked(object sender, RoutedEventArgs args)
    {
        if (!App.Services.VoiceLabEnabled) return;
        await RunAsync(() => { Transcript.RequestRewrite(); return Task.CompletedTask; }, "Rewrite");
    }
    private async Task OpenRewriteAsync(bool insertion)
    {
        if (!App.Services.VoiceLabEnabled ||
            ViewModel.IsReadOnly || ViewModel.Busy || ViewModel.IsLeaving || rightContent is null ||
            (insertion ? Transcript.InsertionAfterIndex < 0 : !ViewModel.HasSelection)) return;
        rewrite?.Dispose();
        var opening = ++rewriteOpenRevision;
        ViewModel.CaptionDrag.Cancel();
        var project = ViewModel.Project;
        var after = insertion ? Transcript.InsertionAfterIndex : (int?)null;
        var passage = new RewriteOpening(ViewModel, after);
        var envelope = !demo && media is not null ? await App.Services.Waveform.GetEnvelopeAsync(media, project.Media.Source.ContentKey, lifetime.Token) : null;
#if DEBUG
        if (envelope is null && Environment.GetEnvironmentVariable("VOXCLIP_DEBUG_REWRITE_TAKES")?.StartsWith("fixtures:", StringComparison.Ordinal) == true)
            envelope = new(project.Media.Source.Audio?.SampleRate ?? 48_000, 0.01,
                Enumerable.Repeat(0.01f, checked((int)Math.Floor(project.Media.Source.DurationSeconds / 0.01))).ToArray());
#endif
        bool CurrentOpening() => opening == rewriteOpenRevision && passage.IsCurrent && !disposed &&
            !ViewModel.IsLeaving && !ViewModel.IsReadOnly && !ViewModel.Busy && App.Services.VoiceLabEnabled;
        if (!CurrentOpening()) return;
        var entry = (await ProviderCatalog.ReadAsync(lifetime.Token)).FirstOrDefault(item => item.WireId == App.Services.Get("llm.connector", ""));
        if (!CurrentOpening()) return;
        var selectedConnector = entry is null ? null : App.Services.Connector(entry.Id);
        if (entry is not null) await ProviderCatalog.ProbeAsync(entry, selectedConnector!, lifetime.Token);
        var connector = entry is null ? null : new RewriteConnector(selectedConnector!,
            App.Services.Get("llm.model." + entry.WireId, entry.DefaultModel), entry.ShortName,
            entry.Cloud ? "apiKey" : entry.Cli ? "cli" : "local", entry.Id == VoxClip.Core.Services.LLM.ConnectorId.ClaudeCode ? "Claude plan" : "ChatGPT plan");
        var connectorWireId = App.Services.Get("llm.connector", "");
        if (!CurrentOpening()) return;
        rewrite = new(ViewModel, passage.First, passage.Last, envelope, connector, passage.InsertionAfter,
            prices: VoiceLabPrices.Load(), synthesisModel: "eleven_multilingual_v2",
            consent: async token => entry is not null && await ProviderCatalog.ConsentAsync(entry, XamlRoot, ConnectorConsentAction.Rewrite,
                ViewModel.Words.Skip(passage.First).Take(passage.Last - passage.First + 1).Count(word => word.Kind == WordKind.Word),
                selectedConnector!, await ProviderCatalog.ProbeAsync(entry, selectedConnector!, token), token),
            connectorIsCurrent: () => App.Services.VoiceLabEnabled && App.Services.Get("llm.connector", "") == connectorWireId &&
                (entry is null || App.Services.Get("llm.model." + entry.WireId, entry.DefaultModel) == connector?.Model));
        ConfigureRewriteGeneration(rewrite);
        var panel = new RewritePanel(rewrite, () => Transcript.CorrectionOpen, owner);
        panel.Closed += (_, _) =>
        {
            var insidePanel = InputState.DescendsFrom(FocusManager.GetFocusedElement(XamlRoot) as DependencyObject, panel);
            if (FocusCycle.RestoreRewriteFocus(insidePanel, panel.ReturnFocusOnClose, disposed)) FocusTranscript();
            rightContent.CloseRewrite();
            SizeStage();
        };
        SetViewerVisible(true);
        rightContent.ShowRewrite(panel);
        SizeStage();
        await rewrite.SetInstructionAsync("");
    }
    private static async Task RediscoverRewriteAsync(RewriteSession session, RewriteGeneration previous, RewriteGeneration next)
    {
        await previous.Cleanup;
        if (session.IsOpen && ReferenceEquals(session.Generation, next)) await next.DiscoverAsync();
    }
    private void ConfigureRewriteGeneration(RewriteSession session)
    {
        var region = ElevenLabsRegions.FromSettings(App.Services.Settings, App.Services.Log);
        rewriteGenerationRegion = region;
        var consenting = false;
        Task OnUi(Action action)
        {
            if (DispatcherQueue.HasThreadAccess) { action(); return Task.CompletedTask; }
            var completion = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
            if (!DispatcherQueue.TryEnqueue(() =>
            {
                try { action(); completion.SetResult(); }
                catch (Exception error) { completion.SetException(error); }
            })) completion.SetException(new OperationCanceledException());
            return completion.Task;
        }
        bool Current() => session.GenerationIsCurrent && App.Services.VoiceLabEnabled &&
            ElevenLabsRegions.FromSettings(App.Services.Settings, App.Services.Log) == region;
        var backend = new RewriteGenerationBackend(App.Services.Data, App.Services.Keys, App.Services.Log,
            VoiceLabPrices.Load(), region, session.Project.Id, Current, OnUi);
        IVoiceLabTakeRunner runner = backend.Runner;
        Func<CancellationToken, Task<RewriteGenerationChoices>> discover = ct => backend.DiscoverAsync(session.Project.Transcript?.Language ?? "en", ct);
        Func<CancellationToken, Task<float[]>> readSource = ct => RewriteGenerationBackend.ReadSourceAsync(media?.Path ?? "",
            RewriteSourceLimit.Frames(session.Project), session.Project.Media.Source.Audio?.SampleRate ?? 0, ct);
        Func<Guid, VoiceLabTakeScratch?> scratch = backend.Runner.Scratch;
        Func<Guid, Task> reject = backend.Runner.RejectAsync;
        async Task<(VoiceLabPublishedTake Take, VoiceConsentRecord Consent)> Publish(Guid id, DateTimeOffset date, CancellationToken ct)
        {
            var (published, record) = await backend.Runner.PublishForAcceptanceAsync(id, date, ct);
            return (new(published.Assets, published.Audio, published.OutDuration, published.Words, published.Chunks), record);
        }
        Func<Guid, DateTimeOffset, CancellationToken, Task<(VoiceLabPublishedTake Take, VoiceConsentRecord Consent)>> publish = Publish;
        Action releaseRunner = backend.Dispose;
        var watchKeys = true;
#if DEBUG
        var fixtures = Environment.GetEnvironmentVariable("VOXCLIP_DEBUG_REWRITE_TAKES");
        var fake = fixtures?.StartsWith("fixtures:", StringComparison.Ordinal) == true
            ? new DebugRewriteTakeRunner(fixtures[9..], storage: new(session.Project.Id, Path.Combine(App.Services.Data.Root, "VoiceLab"),
                Path.Combine(App.Services.Data.Root, "VoiceLabScratch"))) : null;
        if (fake is not null) fake.State = Environment.GetEnvironmentVariable("VOXCLIP_DEBUG_REWRITE_STATE") ?? "ready";
        if (fake is not null)
        {
            runner = fake; discover = fake.DiscoverAsync;
            readSource = _ => Task.FromResult(new float[checked((int)Math.Floor(session.Project.Media.Source.DurationSeconds *
                (session.Project.Media.Source.Audio?.SampleRate ?? 48_000) + 0.5))]);
            scratch = fake.Scratch; reject = fake.RejectAsync; publish = fake.PublishAsync;
            releaseRunner = () => { backend.Dispose(); fake.Dispose(); };
            watchKeys = false;
        }
#endif
        async Task<bool> Consent(CancellationToken ct)
        {
            if (App.Services.Get("voiceLab.providerConsent.elevenlabs", false)) return true;
            consenting = true;
            try
            {
                if (!await Ui.ConfirmAsync(XamlRoot, "Use ElevenLabs?", VoiceLabCopy.ProviderConsent, "Continue", ct) || !Current()) return false;
                await App.Services.SetAsync("voiceLab.providerConsent.elevenlabs", true, ct);
                return Current();
            }
            finally { consenting = false; }
        }
        RewriteGeneration? generation = null;
        FileSystemWatcher? keyChanges = null;
        void ConsentRecordsChanged(object? sender, EventArgs args)
        {
            if (generation is { IsRequestingConsent: false } && session.IsOpen) _ = generation.DiscoveryInputsChangedAsync();
        }
        void KeyChanged(object? sender, FileSystemEventArgs args)
        {
            _ = OnUi(() =>
            {
                if (session.IsOpen && ReferenceEquals(session.Generation, generation)) _ = generation!.DiscoveryInputsChangedAsync();
            });
        }
        void OutputChanged(object sender, Windows.Media.Devices.DefaultAudioRenderDeviceChangedEventArgs args)
        {
            _ = OnUi(() =>
            {
                if (session.IsOpen && ReferenceEquals(session.Generation, generation)) _ = generation!.RefreshOutputAsync();
            });
        }
        generation = new RewriteGeneration(runner,
            discover,
            (voice, model, seed, ct) => session.GenerationInputAsync(voice, model, seed,
                App.Services.Get("voiceLab.providerConsent.elevenlabs", false), readSource, ct),
            Consent, async ct =>
            {
                decimal? cap = null;
                await OnUi(() => { ct.ThrowIfCancellationRequested(); cap = App.Services.Settings.GetVoiceLabMonthlyCap("elevenlabs"); });
                return cap;
            }, () => Current() && !consenting, OnUi, () =>
            {
                App.Services.VoiceLab.Changed -= ConsentRecordsChanged;
                Windows.Media.Devices.MediaDevice.DefaultAudioRenderDeviceChanged -= OutputChanged;
                keyChanges?.Dispose();
                releaseRunner();
            });
        App.Services.VoiceLab.Changed += ConsentRecordsChanged;
        session.ConfigureGeneration(generation);
        var audition = new VoxClip.Media.Audio.VoiceLabAudition(ct => RewriteGeneration.PausePreviewAsync(preview, ct));
        _ = generation.ConfigureTakesAsync(new(audition, scratch, reject, publish));
        Windows.Media.Devices.MediaDevice.DefaultAudioRenderDeviceChanged += OutputChanged;
        if (watchKeys && Directory.Exists(App.Services.Data.Root))
        {
            keyChanges = new(App.Services.Data.Root, "elevenlabs-api-key.bin")
            {
                IncludeSubdirectories = true,
                NotifyFilter = NotifyFilters.FileName | NotifyFilters.LastWrite | NotifyFilters.CreationTime
            };
            keyChanges.Changed += KeyChanged; keyChanges.Created += KeyChanged;
            keyChanges.Deleted += KeyChanged; keyChanges.Renamed += KeyChanged;
            keyChanges.EnableRaisingEvents = true;
        }
    }
    private void CutSelectionClicked(object sender, RoutedEventArgs args) => ViewModel.CutSelection();
    private void RestoreSelectionClicked(object sender, RoutedEventArgs args) => ViewModel.CutSelection(true);
    private void CorrectClicked(object sender, RoutedEventArgs args) => Transcript.BeginCorrection();
    private async void PreviewCutClicked(object sender, RoutedEventArgs args) => await RunAsync(PreviewCutAsync, "Preview");
    private async void PlayFromHereClicked(object sender, RoutedEventArgs args) => await RunAsync(PlayFromHereAsync, "Preview");
    private async Task PlayFromHereAsync()
    {
        if (preview is null || ViewModel.IsReadOnly || ViewModel.Busy) return;
        previewStop = null;
        if (ViewModel.HasSelection) ViewModel.SourceTime = ViewModel.Words[ViewModel.SelectionStart].Start;
        await SeekSourceAsync(ViewModel.SourceTime); await preview.PlayAsync(lifetime.Token);
    }
    private void FindClipsClicked(object sender, RoutedEventArgs args) => ShowFindClips(sender as FrameworkElement);
    /// <summary>The sidebar's "New clip from selection" action.</summary>
    internal void MakeClipFromPane() => MakeClipAndReveal();
    /// <summary>Open Find clips at the control that asked for it: the pane action, its callout or the page's button.</summary>
    internal void ShowFindClips(FrameworkElement? anchor) =>
        _ = RunAsync(() => FindClips.ShowAsync(anchor ?? (FindClipsCommand.IsInOverflow ? Commands : FindClipsCommand)), "Find clips");
    /// <summary>The F6 regions after the sidebar (design §16): the command row, the transcript, the viewer (with its splitter
    /// and frame row) and Captions while the right column shows, then the timeline. MainWindow runs the cycle.</summary>
    internal IEnumerable<(FrameworkElement[] Areas, Func<Control?> Target)> FocusRegions()
    {
        foreach (var region in FocusCycle.Regions(RightPane.Visibility == Visibility.Visible).Skip(1))
        {
            switch (region)
            {
                case EditorFocusRegion.CommandBar: yield return ([CommandRow], () => FocusManager.FindFirstFocusableElement(Commands) as Control ?? ExportButton); break;
                case EditorFocusRegion.Transcript: yield return ([TranscriptPane], () => Transcript); break;
                case EditorFocusRegion.Viewer: yield return ([ViewerSplitter, PreviewPane, FrameRow], () => PreviewPlay); break;
                case EditorFocusRegion.Captions: if (rightContent is { } column) yield return ([CaptionsHost], () => column.FocusTarget); break;
                case EditorFocusRegion.Timeline: yield return ([Timeline], () => Timeline.FocusTarget); break;
            }
        }
    }
    internal void FocusTranscript() => Transcript.Focus(FocusState.Programmatic);
    /// <summary>Say the editor's notice again, for a refused leave seen from Home.</summary>
    internal void AnnounceNotice() { if (ViewModel.Notice.Length > 0) Transcript.Announce(ViewModel.Notice); }
    /// <summary>Find clips needs a transcript; the pane actions carry the same reason (design §7.1).</summary>
    private void UpdateFindClips()
    {
        FindClipsCommand.IsEnabled = ViewModel.CanFindClips;
        FindClipsBusy.IsActive = ViewModel.LlmRuns.IsBusy;
        FindClipsBusyHost.Visibility = ViewModel.LlmRuns.IsBusy ? Visibility.Visible : Visibility.Collapsed;
        UpdateRewriteCommand();
        ToolTipService.SetToolTip(FindClipsCommand, ViewModel.HasTranscript ? "Find clips (Ctrl+Shift+K)" : ShellViewModel.TranscribeFirst);
    }
    /// <summary>Home pauses playback and keeps this page alive; design §2.</summary>
    internal void PausePlayback() => _ = RunAsync(async () => { if (preview?.Position.IsPlaying == true) await preview.PauseAsync(lifetime.Token); }, "Preview");
    /// <summary>A sidebar row sets the scope through the existing setActiveClip step; a clip also selects its first word unless
    /// the transcript keeps its selection, as after making a clip.</summary>
    internal void SelectScope(string? clipId, bool keepSelection = false)
    {
        ViewModel.Apply(new EditOperation.SetActiveClip(clipId));
        if (!keepSelection && clipId is not null && ViewModel.State?.ActiveClipId == clipId && ViewModel.Clips.FirstOrDefault(clip => clip.Id == clipId) is { } row)
        {
            ViewModel.Select(ViewModel.Index(row.Clip.StartWordId));
            Transcript.RevealWord(ViewModel.SelectionStart);
        }
    }
    private async void PlayClicked(object sender, RoutedEventArgs args) => await RunAsync(TogglePlaybackAsync, "Preview");
    private async void BackClicked(object sender, RoutedEventArgs args) => await RunAsync(() => SeekSourceAsync(Math.Max(0, ViewModel.SourceTime - 3)), "Preview");
    private async void ForwardClicked(object sender, RoutedEventArgs args) =>
        await RunAsync(() => SeekSourceAsync(Math.Min(ViewModel.Project.Media.Source.DurationSeconds, ViewModel.SourceTime + 3)), "Preview");
    private async Task TogglePlaybackAsync()
    {
        if (preview is null || ViewModel.IsReadOnly) return;
        previewStop = null;
        if (preview.Position.IsPlaying) await preview.PauseAsync(lifetime.Token); else await preview.PlayAsync(lifetime.Token);
    }
    private async Task PreviewCutAsync()
    {
        if (preview is null || ViewModel.PreviewCutRange() is not { } range) return;
        await SeekSourceAsync(range.Start);
        previewStop = range.End;
        await preview.PlayAsync(lifetime.Token);
    }
    private void DisplayChanged(object sender, RoutedEventArgs args) => Transcript.SetDisplay(ShowCuts.IsChecked == true, ShowPauses.IsChecked == true);
    private void FindClicked(object sender, RoutedEventArgs args) { FindBar.Visibility = Visibility.Visible; SearchText.Focus(FocusState.Programmatic); }
    private void CloseFindClicked(object sender, RoutedEventArgs args) { FindBar.Visibility = Visibility.Collapsed; Transcript.Focus(FocusState.Programmatic); }
    private IReadOnlyList<string> Matches() => string.IsNullOrWhiteSpace(SearchText.Text) ? [] : ViewModel.Words.Where(word => ViewModel.DisplayText(word).Contains(SearchText.Text, StringComparison.OrdinalIgnoreCase)).Select(word => word.Id).ToArray();
    private void SearchChanged(object sender, TextChangedEventArgs args) { if (ready) CutMatches.Content = $"Cut all {Matches().Count}"; }
    private void CutMatchesClicked(object sender, RoutedEventArgs args) => ViewModel.Apply(new EditOperation.SetWordCuts(Matches(), true));
    private async void SaveAsClicked(object sender, RoutedEventArgs args) => await RunAsync(async () =>
    {
        if (demo) { ViewModel.Notice = "Demo fixtures are read-only. Open a real project to save changes."; return; }
        var picker = new Windows.Storage.Pickers.FileSavePicker { SuggestedFileName = ViewModel.Title };
        picker.FileTypeChoices.Add("VoxClip project", [".voxclip"]);
        WinRT.Interop.InitializeWithWindow.Initialize(picker, WinRT.Interop.WindowNative.GetWindowHandle(owner));
        var file = await picker.PickSaveFileAsync();
        if (file is not null && !ViewModel.IsLeaving)
        {
            ViewModel.CaptionDrag.Cancel();
            autosave?.Cancel(); await pendingSave;
            await saves.WaitAsync(lifetime.Token);
            try
            {
                if (ViewModel.IsLeaving) return;
                var previous = owner.ProjectPath;
                var snapshot = ViewModel.Project;
                await App.Services.Projects.SaveAsync(snapshot, file.Path, lifetime.Token);
                ViewModel.MarkSaved(snapshot);
                owner.SetProjectPath(file.Path);
                if (previous is not null && !previous.Equals(file.Path, StringComparison.OrdinalIgnoreCase) && Path.GetDirectoryName(previous)?.TrimEnd(Path.DirectorySeparatorChar).Equals(App.Services.Data.Autosave.TrimEnd(Path.DirectorySeparatorChar), StringComparison.OrdinalIgnoreCase) == true) File.Delete(previous);
            }
            finally { saves.Release(); }
        }
    }, "Save project");
    private void ShowProjectClicked(object sender, RoutedEventArgs args) { if (owner.ProjectPath is { } path) ShareHelpers.Reveal(path); }
    /// <summary>Export video… for Full take; Export clip… opens Export with only the active clip chosen (design §2 step 7).</summary>
    private async void ExportClicked(object sender, RoutedEventArgs args) => await ExportAsync(ViewModel.State?.ActiveClipId);
    /// <summary>A kept clip row's "Export clip…": Export opens with only that clip chosen (design §6.2).</summary>
    internal Task ExportClipAsync(string clipId) => ExportAsync(clipId);
    internal Task RetryExportAsync(string? clipId) => ExportAsync(clipId);
    private Task ExportAsync(string? clipId) => RunAsync(async () =>
    {
        // Ctrl+E and the row's Export clip… stop where the button is disabled, and say why. A row's clip need not be the
        // active one, so the reason is also shown unless a notice (the missing file's name, say) is already showing.
        if (ViewModel.ExportBlocked(demo, MediaPath is null || media is null, clipId) is { } reason)
        {
            if (ViewModel.Notice.Length == 0) ViewModel.Notice = reason;
            Transcript.Announce(reason);
            return;
        }
        await new ExportDialog(owner, ViewModel, demo, (project, state, ct) => SnapshotAsync(ct, state, project), clipId) { XamlRoot = XamlRoot }.ShowAsync();
    }, "Export");
    internal async Task PromptTranscriptionAsync() => await RunAsync(async () =>
    {
        if (ViewModel.IsLeaving) return;
        await new TranscriptionDialog(owner, ViewModel) { XamlRoot = XamlRoot }.ShowAsync();
    }, "Transcription");
    private async void TranscribeClicked(object sender, RoutedEventArgs args) => await PromptTranscriptionAsync();
    private async void TranscribeAgainClicked(object sender, RoutedEventArgs args)
    {
        var confirmation = new ContentDialog { XamlRoot = XamlRoot, Title = "Transcribe again?", Content = $"Transcribe again? This replaces the transcript and removes {ViewModel.Summary.CutWordCount + ViewModel.Summary.CutPauseCount} cuts, {ViewModel.Project.Edits.Corrections.Count} corrections, {ViewModel.Clips.Count} clips and the AI suggestions.", PrimaryButtonText = "Transcribe Again", CloseButtonText = "Cancel", DefaultButton = ContentDialogButton.Close };
        if (await confirmation.ShowAsync() == ContentDialogResult.Primary) TranscribeClicked(sender, args);
    }
    private async void ShortcutsClicked(object sender, RoutedEventArgs args) => await owner.ShowKeyboardHelpAsync();
    private void AspectChanged(object sender, SelectionChangedEventArgs args)
    {
        if (!ready || Aspect.SelectedIndex < 0) return;
        ViewModel.SetExport(ViewModel.Project.Export with { Aspect = EditorLayout.Frames[Aspect.SelectedIndex] });
        SizeStage();
    }
    /// <summary>The editor's accelerator actions by gesture, so the window can hand it the ones that act from the pane.</summary>
    private readonly Dictionary<string, Action> shortcuts = new(StringComparer.Ordinal);
    /// <summary>A shortcut pressed while focus is in the sidebar pane (design §11.1). MainWindow forwards only
    /// ShortcutPolicy.PaneGestures, and runs the same action as the editor's own accelerator.</summary>
    internal bool InvokeFromPane(string gesture)
    {
        if (!ready || !ShortcutPolicy.PaneForwards(gesture) || !shortcuts.TryGetValue(gesture, out var action)) return false;
        action();
        return true;
    }
    private void InstallAccelerators()
    {
        void Add(VirtualKey key, VirtualKeyModifiers modifiers, Action action)
        {
            var accelerator = new KeyboardAccelerator { Key = key, Modifiers = modifiers, ScopeOwner = EditorRoot };
            accelerator.Invoked += (_, args) =>
            {
                if (!ShortcutPolicy.EditorMayHandle(InputState.IsTextFocus(FocusManager.GetFocusedElement(XamlRoot)), Transcript.CorrectionOpen, InputState.Down(VirtualKey.Control), InputState.Down(VirtualKey.Menu), true)) return;
                action(); args.Handled = true;
            };
            EditorRoot.KeyboardAccelerators.Add(accelerator);
            shortcuts[ShortcutPolicy.Gesture(key.ToString(), modifiers.HasFlag(VirtualKeyModifiers.Control), modifiers.HasFlag(VirtualKeyModifiers.Shift))] = action;
        }
        Add(VirtualKey.Z, VirtualKeyModifiers.Control, ViewModel.Undo);
        Add(VirtualKey.Y, VirtualKeyModifiers.Control, ViewModel.Redo);
        Add(VirtualKey.Z, VirtualKeyModifiers.Control | VirtualKeyModifiers.Shift, ViewModel.Redo);
        Add(VirtualKey.K, VirtualKeyModifiers.Control, MakeClipAndReveal);
        Add(VirtualKey.R, VirtualKeyModifiers.Control, Transcript.RequestRewrite);
        Add(VirtualKey.U, VirtualKeyModifiers.Control | VirtualKeyModifiers.Shift, () => ViewModel.Apply(new EditOperation.CutFillers()));
        Add(VirtualKey.P, VirtualKeyModifiers.Control | VirtualKeyModifiers.Shift, () => ViewModel.Apply(new EditOperation.TightenPauses()));
        Add(VirtualKey.R, VirtualKeyModifiers.Control | VirtualKeyModifiers.Shift, () => ViewModel.Apply(new EditOperation.RestoreCuts()));
        Add(VirtualKey.E, VirtualKeyModifiers.Control, () => ExportClicked(this, new()));
        Add(VirtualKey.F, VirtualKeyModifiers.Control, () => FindClicked(this, new()));
        Add(VirtualKey.A, VirtualKeyModifiers.Control, () => { ViewModel.Select(0); ViewModel.Select(ViewModel.Words.Count - 1, true); Transcript.SelectionMovedByKeyboard(reveal: false); });
        Add(VirtualKey.C, VirtualKeyModifiers.Control, () => ShareHelpers.Copy(ViewModel.SelectionText));
        Add(VirtualKey.H, VirtualKeyModifiers.Control | VirtualKeyModifiers.Shift, () => { ShowCuts.IsChecked = ShowCuts.IsChecked != true; DisplayChanged(this, new()); });
        Add((VirtualKey)187, VirtualKeyModifiers.Control, () => Transcript.Zoom(1));
        Add((VirtualKey)189, VirtualKeyModifiers.Control, () => Transcript.Zoom(-1));
        Add(VirtualKey.Number0, VirtualKeyModifiers.Control, () => Transcript.Zoom(0, true));
        Add(VirtualKey.Left, VirtualKeyModifiers.Control, () => { ViewModel.MoveSentence(-1); Transcript.SelectionMovedByKeyboard(); _ = RunAsync(() => SeekSourceAsync(ViewModel.SourceTime), "Preview"); });
        Add(VirtualKey.Right, VirtualKeyModifiers.Control, () => { ViewModel.MoveSentence(1); Transcript.SelectionMovedByKeyboard(); _ = RunAsync(() => SeekSourceAsync(ViewModel.SourceTime), "Preview"); });
        Add(VirtualKey.Home, VirtualKeyModifiers.Control, () => { ViewModel.Select(0); Transcript.SelectionMovedByKeyboard(); });
        Add(VirtualKey.End, VirtualKeyModifiers.Control, () => { ViewModel.Select(ViewModel.Words.Count - 1); Transcript.SelectionMovedByKeyboard(); });
        Add(VirtualKey.K, VirtualKeyModifiers.Control | VirtualKeyModifiers.Shift, () => ShowFindClips(null));
        Add(VirtualKey.I, VirtualKeyModifiers.Control | VirtualKeyModifiers.Shift, () => { Viewer.IsChecked = Viewer.IsChecked != true; ViewerClicked(this, new()); });
        Add(VirtualKey.F1, VirtualKeyModifiers.None, () => ShortcutsClicked(this, new()));
    }
    private async void EditorKeyDown(object sender, KeyRoutedEventArgs args)
    {
        if (!ready || args.Key == VirtualKey.F6) return;
        if (args.Key == VirtualKey.Escape && CaptionDrag.IsDragging) { CaptionDrag.Cancel(); args.Handled = true; return; }
        var focused = FocusManager.GetFocusedElement(XamlRoot);
        var editorFocus = InputState.DescendsFrom(focused as DependencyObject, Transcript) || InputState.DescendsFrom(focused as DependencyObject, PreviewPane) || InputState.DescendsFrom(focused as DependencyObject, Timeline);
        var control = InputState.Down(VirtualKey.Control);
        if (!ShortcutPolicy.EditorMayHandle(InputState.IsTextFocus(focused), Transcript.CorrectionOpen, control, InputState.Down(VirtualKey.Menu), editorFocus) || control) return;
        var handled = true;
        switch (args.Key)
        {
            case VirtualKey.Space: await RunAsync(InputState.Down(VirtualKey.Shift) ? PlayFromHereAsync : TogglePlaybackAsync, "Preview"); break;
            case VirtualKey.K: previewStop = null; if (preview is not null) await RunAsync(() => preview.PauseAsync(lifetime.Token), "Preview"); break;
            case VirtualKey.L: previewStop = null; if (preview is not null && !ViewModel.IsReadOnly) await RunAsync(() => preview.PlayAsync(lifetime.Token), "Preview"); break;
            case VirtualKey.J: await RunAsync(() => SeekSourceAsync(Math.Max(0, ViewModel.SourceTime - 3)), "Preview"); break;
            case VirtualKey.P: await RunAsync(PreviewCutAsync, "Preview"); break;
            case VirtualKey.Back: case VirtualKey.Delete: ViewModel.CutSelection(InputState.Down(VirtualKey.Shift)); break;
            case VirtualKey.Left: case VirtualKey.Right: ViewModel.Step(args.Key == VirtualKey.Right ? 1 : -1, InputState.Down(VirtualKey.Shift)); Transcript.SelectionMovedByKeyboard(); await RunAsync(() => SeekSourceAsync(ViewModel.SourceTime), "Preview"); break;
            case VirtualKey.Home: ViewModel.Select(0); Transcript.SelectionMovedByKeyboard(); break;
            case VirtualKey.End: ViewModel.Select(ViewModel.Words.Count - 1); Transcript.SelectionMovedByKeyboard(); break;
            case VirtualKey.Enter: case VirtualKey.C: Transcript.BeginCorrection(); break;
            case VirtualKey.Escape: if (InputState.DescendsFrom(focused as DependencyObject, Transcript) && ViewModel.State?.ActiveClipId is not null) owner.ShowScope(null, keepSelection: true); else handled = false; break;
            case VirtualKey.I: ViewModel.SetClipEdgeAtCaret(true); break;
            case VirtualKey.O: ViewModel.SetClipEdgeAtCaret(false); break;
            case (VirtualKey)219: if (!InputState.Down(VirtualKey.Shift)) ViewModel.CycleClip(-1); else handled = false; break;
            case (VirtualKey)221: if (!InputState.Down(VirtualKey.Shift)) ViewModel.CycleClip(1); else handled = false; break;
            default: handled = false; break;
        }
        args.Handled = handled;
    }
    /// <summary>Export video… or Export clip… for the scope, disabled with its reason as tooltip and description (delta §3.5,
    /// placeholder spec §5.4.4). The name says when the scope contains AI-modified speech.</summary>
    private void UpdateExport()
    {
        PreviewCutCommand.IsEnabled = ViewModel.CanPreviewCut;
        var active = ViewModel.Clips.FirstOrDefault(clip => clip.Id == ViewModel.State?.ActiveClipId);
        var label = active is null ? "Export video…" : "Export clip…";
        var reason = ViewModel.ExportBlocked(demo, MediaPath is null || media is null, active?.Id);
        ExportButton.Content = label;
        ExportButton.IsEnabled = reason is null;
        ToolTipService.SetToolTip(ExportHost, reason ?? $"{label} (Ctrl+E)");
        AutomationProperties.SetName(ExportButton, VoiceLabDisclosure.AccessibleName(label, ViewModel.ContainsAiSpeech(ViewModel.State?.ActiveClipId)));
        AutomationProperties.SetHelpText(ExportButton, reason ?? "");
    }
    private void ViewerClicked(object sender, RoutedEventArgs args)
        => SetViewerVisible(Viewer.IsChecked == true);
    private void SetViewerVisible(bool visible)
    {
        viewerSqueezed = false;
        viewerForced = visible && !TranscriptFits(ActualWidth);
        ShowViewer(visible);
        // Showing the viewer where the transcript would drop below its minimum hides the pane to make room (delta §3.7).
        if (viewerForced) owner.CloseNavigationPane();
    }
    /// <summary>The right column and its splitter, or the compact transport in the timeline while it is collapsed.</summary>
    private void ShowViewer(bool visible)
    {
        Viewer.IsChecked = visible;
        TranscriptColumn.MinWidth = viewerForced ? 0 : Token("VcLayoutTranscriptMinWidth");
        RightPane.Visibility = ViewerSplitter.Visibility = visible ? Visibility.Visible : Visibility.Collapsed;
        RightColumn.MinWidth = visible ? Token("VcSizeRightColumnMin") : 0;
        RightColumn.Width = new(visible ? StoredRightWidth() ?? DefaultRightWidth() : 0);
        Timeline.ShowsTransport = !visible;
    }
    private static double Token(string key) => (double)Application.Current.Resources[key];
    private double DefaultRightWidth() => EditorLayout.RightColumnWidth(XamlRoot?.Size.Width ?? 1280, Token("VcSizeRightColumnMin"), Token("VcSizeRightColumnMax"));
    private double? StoredRightWidth() => owner.RightColumnWidth(Token("VcSizeRightColumnMin"), Token("VcSizeRightColumnMax"));
    private bool TranscriptFits(double pageWidth) =>
        EditorLayout.TranscriptFits(pageWidth, ViewerSplitter.Width, StoredRightWidth() ?? DefaultRightWidth(), Token("VcLayoutTranscriptMinWidth"));
    private void EditorSizeChanged(object sender, SizeChangedEventArgs args) { if (ready) FitViewer(args.NewSize.Width); }
    /// <summary>The right column collapses first when the transcript would drop below 588 and returns when there is room.</summary>
    private void FitViewer(double pageWidth)
    {
        var fits = TranscriptFits(pageWidth);
        if (fits && viewerForced) { viewerForced = false; ShowViewer(true); }
        else if (Viewer.IsChecked == true && !fits && !viewerForced) { viewerSqueezed = true; ShowViewer(false); }
        else if (viewerSqueezed && fits) { viewerSqueezed = false; ShowViewer(true); }
        else if (Viewer.IsChecked == true && StoredRightWidth() is null) RightColumn.Width = new(DefaultRightWidth());
    }
    /// <summary>Enter collapses the viewer; the splitter's arrow keys step 16 (delta §3.3).</summary>
    private void SplitterKeyDown(object sender, KeyRoutedEventArgs args)
    {
        if (args.Key != VirtualKey.Enter) return;
        args.Handled = true;
        viewerSqueezed = viewerForced = false;
        ShowViewer(false);
        Transcript.Focus(FocusState.Keyboard);
    }
    private void SplitterKeyUp(object sender, KeyRoutedEventArgs args) { if (args.Key is VirtualKey.Left or VirtualKey.Right) RememberRightWidth(); }
    private void SplitterDragged(object sender, ManipulationCompletedRoutedEventArgs args) => RememberRightWidth();
    /// <summary>Only moving the splitter, by drag or arrow keys, stores a width (ui.rightColumnWidth).</summary>
    private void RememberRightWidth() => owner.RememberRightColumnWidth(RightColumn.ActualWidth, Token("VcSizeRightColumnMin"), Token("VcSizeRightColumnMax"));
    private void RightPaneSizeChanged(object sender, SizeChangedEventArgs args)
    {
        AutomationProperties.SetItemStatus(ViewerSplitter, $"{Math.Round(args.NewSize.Width)} px");
        SizeStage();
    }
    /// <summary>Size the stage for the frame and the column (delta §5.1) and name it for the scope.</summary>
    private void SizeStage()
    {
        var oriented = media?.OrientedSize ?? MediaFromProject(ViewModel.Project).OrientedSize;
        var inner = RightPane.ActualWidth - RightPane.BorderThickness.Left - 32;
        var compact = EditorLayout.CompactStage(rewrite is { IsOpen: true }, RightPane.ActualHeight);
        if (Grid.GetColumn(TransportRow) != (compact ? 1 : 0))
        {
            TransportRow.Children.Clear();
            TransportRow.Children.Add(compact ? TransportMeta : TransportButtons);
            TransportRow.Children.Add(compact ? TransportButtons : TransportMeta);
            TransportMeta.Children.Clear();
            TransportMeta.Children.Add(compact ? TransportTime : AiModified);
            TransportMeta.Children.Add(compact ? AiModified : TransportTime);
        }
        Grid.SetRow(TransportRow, compact ? 0 : 1);
        Grid.SetColumn(TransportRow, compact ? 1 : 0);
        TransportMeta.Orientation = compact ? Orientation.Vertical : Orientation.Horizontal;
        TransportRow.VerticalAlignment = compact ? VerticalAlignment.Top : VerticalAlignment.Stretch;
        PreviewStage.VerticalAlignment = compact ? VerticalAlignment.Top : VerticalAlignment.Stretch;
        TransportRow.Margin = compact ? new Thickness(8, 0, 0, 0) : new Thickness(0);
        TransportTime.Measure(new(double.PositiveInfinity, double.PositiveInfinity));
        AiModified.Measure(new(double.PositiveInfinity, double.PositiveInfinity));
        var rail = Math.Max(112, Math.Max(TransportTime.DesiredSize.Width, AiModified.DesiredSize.Width));
        TransportRow.Width = compact ? rail : double.NaN;
        (PreviewStage.Width, PreviewStage.Height) = compact
            ? EditorLayout.RewriteStage(inner, ViewModel.Project.Export.Aspect, oriented, rail)
            : EditorLayout.Stage(inner, ViewModel.Project.Export.Aspect, oriented);
        var chrome = PreviewPane.Padding.Top + PreviewPane.Padding.Bottom + PreviewPane.RowSpacing +
            FrameRow.Margin.Top + FrameRow.Margin.Bottom + CaptionsHost.BorderThickness.Top + CaptionsHost.BorderThickness.Bottom;
        // Prefer the full header with an 80-high stage; short columns scroll it in the existing details viewport.
        captions?.ConstrainHeight(RightPane.ActualHeight - FrameRow.ActualHeight - TransportRow.ActualHeight - chrome - 80);
        var maximum = EditorLayout.StageHeightBudget(RightPane.ActualHeight, FrameRow.ActualHeight,
            TransportRow.ActualHeight, chrome, captions?.MinimumContentHeight ?? 160);
        if (!compact && PreviewStage.Height > maximum)
        {
            PreviewStage.Width *= maximum / PreviewStage.Height;
            PreviewStage.Height = maximum;
        }
        var clip = ViewModel.Clips.FirstOrDefault(clip => clip.Id == ViewModel.State?.ActiveClipId);
        var name = EditorMediaPresentation.Accessible(mediaState, clip?.Number, ViewModel.ContainsAiSpeech(ViewModel.State?.ActiveClipId));
        AutomationProperties.SetName(PreviewStage, name); AutomationProperties.SetName(PreviewImage, name);
        PreviewEmpty.Text = EditorMediaPresentation.Title(mediaState);
        PreviewFile.Text = mediaState is EditorMediaState.Missing or EditorMediaState.Corrupt ? EditorMediaPresentation.FileName(ViewModel.Project.Media.Source.AbsolutePath) : "";
        PreviewStateGlyph.Glyph = ((char)(mediaState == EditorMediaState.Corrupt ? 0xE7BA : 0xE714)).ToString();
        PreviewStateGlyphHost.Visibility = mediaState is EditorMediaState.Missing or EditorMediaState.Corrupt ? Visibility.Visible : Visibility.Collapsed;
        PreviewMissingStrike.Visibility = mediaState == EditorMediaState.Missing ? Visibility.Visible : Visibility.Collapsed;
        PreviewStandIn.Visibility = mediaState is EditorMediaState.Missing or EditorMediaState.Corrupt ? Visibility.Visible : Visibility.Collapsed;
        if (PreviewPlay.Parent is Grid playback)
            foreach (var button in playback.Children.OfType<Button>()) button.IsEnabled = !ViewModel.IsReadOnly;
        PositionStageMessage();
    }
    private void PositionStageMessage()
    {
        if (ViewModel is null) return;
        var fraction = EditorMediaPresentation.MessageFraction(PreviewStage.Width * 10 < PreviewStage.Height * 9);
        PreviewStandIn.Margin = new(20, Math.Max(0, PreviewStage.Height * fraction - PreviewStandIn.ActualHeight / 2), 20, 0);
    }
    private void UpdateAiTag()
    {
        AiModified.Visibility = ViewModel.ContainsAiSpeech(ViewModel.State?.ActiveClipId) ? Visibility.Visible : Visibility.Collapsed;
    }
    internal async Task<bool> TrySaveBeforeLeavingAsync()
    {
        if (ViewModel.Busy)
        {
            EditorNotice.Severity = InfoBarSeverity.Warning;
            ViewModel.Notice = "Finish or cancel the current task before leaving this project. Your edits are still here.";
            return false;
        }
        try
        {
            await leave.BeginAsync(async () =>
            {
                autosave?.Cancel();
                await pendingSave;
                await SaveAsync(CancellationToken.None);
            });
            return true;
        }
        catch (Exception)
        {
            EditorSettingsChanged(this, EventArgs.Empty);
            EditorNotice.Severity = InfoBarSeverity.Error;
            ViewModel.Notice = "Couldn't save this project. Your edits are still open. Check the folder or use Save project as…, then try again.";
            App.Services.Log.Write(Core.Services.Logging.LogLevel.Warn, "project", "save before navigation failed");
            return false;
        }
    }
    internal void ResumeAfterFailedLeave()
    {
        leave.Resume();
        EditorSettingsChanged(this, EventArgs.Empty);
        ViewModel.Notice = "This project is still open. You can keep editing.";
    }
    internal async Task CloseAsync()
    {
        if (disposed) return;
        disposed = true; autosave?.Cancel();
        // Work still reading the entry, such as a waveform load, holds its own lease.
        cacheLease?.Dispose();
        await lifetime.CancelAsync();
        await pendingSave;
        await pendingWaveform;
        await pendingStandIn;
        if (ViewModel is not null)
        {
            ViewModel.Changed -= ModelChanged;
            ViewModel.SelectionChanged -= SelectionChanged;
            ViewModel.SaveRequested -= SaveRequested;
        }
        Transcript.Detach(); Timeline.Detach(); captions?.Detach();
        FindClips.Close();
        CaptionDrag.Cancel();
        rewrite?.Dispose();
        App.Services.SettingsChanged -= EditorSettingsChanged;
        App.Services.ExportLedger.Changed -= LedgerChanged;
        await previewChanges.WaitAsync();
        try
        {
            if (preview is not null) { preview.PlaybackFaulted -= PlaybackFaulted; preview.AudioStatusChanged -= AudioStatusChanged; }
            if (presenter is not null) await presenter.DisposeAsync(); else if (preview is not null) await preview.DisposeAsync();
            presenter = null; preview = null;
        }
        finally { previewChanges.Release(); }
        lifetime.Dispose(); autosave?.Dispose();
    }
}
