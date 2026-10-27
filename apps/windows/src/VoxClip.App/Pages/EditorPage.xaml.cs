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
using VoxClip.Core.Services.Media;
using VoxClip.Media.Pipeline;
using VoxClip.Media.Captions;
using Windows.System;

namespace VoxClip.App.Pages;

public sealed partial class EditorPage : Page
{
    public EditorViewModel ViewModel { get; private set; } = null!;
    private readonly CancellationTokenSource lifetime = new();
    private MainWindow owner = null!;
    private IPreviewEngine? preview;
    private PreviewPresenter? presenter;
    private InspectorView? inspector;
    private MediaInfo? media;
    private bool demo;
    private bool ready;
    private bool disposed;
    /// <summary>The viewer collapsed because the transcript would drop below its minimum; it returns when there is room.</summary>
    private bool viewerSqueezed;
    /// <summary>The user showed the viewer where the transcript has no room; it stays until they hide it or the window grows.</summary>
    private bool viewerForced;
    private CancellationTokenSource? autosave;
    private Task pendingSave = Task.CompletedTask;
    private ProjectLeaveBoundary leave = null!;
    private readonly SemaphoreSlim previewChanges = new(1, 1);
    private readonly SemaphoreSlim saves = new(1, 1);
    private string pauseBreath = "natural";
    private double previewDuration;
    private string? previewClipId;
    public EditorPage()
    {
        InitializeComponent();
        Loaded += (_, _) => Transcript.Focus(FocusState.Programmatic);
    }
    public static bool HasText(string? text) => !string.IsNullOrEmpty(text);
    /// <summary>The take's resolved video, or null when it can't be found or the project is a demo fixture.</summary>
    internal string? MediaPath { get; private set; }
    internal bool IsDemo => demo;
    /// <summary>Find clips in this take: its flyout, and the "Finding clips…" row and callout it puts in the pane.</summary>
    internal FindClipsFlyout FindClips { get; private set; } = null!;

    internal async Task OpenAsync(MainWindow window, Project project, string? mediaPath, bool demoMode, CancellationToken ct)
    {
        owner = window;
        demo = demoMode;
        MediaPath = demoMode ? null : mediaPath;
#if DEBUG
        ViewModel = demo ? new(project, DemoProject.Reduce, DemoProject.Summarize) : new(project);
        preview = demo ? new DemoPreviewEngine() : new PreviewEngine();
#else
        ViewModel = new(project);
        preview = new PreviewEngine();
#endif
        leave = new(ViewModel);
        FindClips = new(ViewModel, lifetime.Token);
        FindClips.Announcement += (_, text) => Transcript.Announce(text);
        preview.PlaybackFaulted += PlaybackFaulted;
        ViewModel.Changed += ModelChanged;
        ViewModel.SelectionChanged += SelectionChanged;
        ViewModel.SaveRequested += SaveRequested;
        pauseBreath = App.Services.Get("editing.pauseBreath", "natural");
        App.Services.SettingsChanged += EditorSettingsChanged;
        Transcript.Attach(ViewModel);
        Timeline.Attach(ViewModel);
        Transcript.SeekRequested += (_, _) => _ = RunAsync(() => SeekSourceAsync(ViewModel.SourceTime), "Preview");
        Transcript.MakeClipRequested += (_, _) => MakeClipAndReveal();
        Transcript.PlayRequested += (_, _) => _ = RunAsync(async () => { await SeekSourceAsync(ViewModel.SourceTime); if (preview is not null) await preview.PlayAsync(lifetime.Token); }, "Preview");
        Timeline.SeekRequested += (_, time) => _ = RunAsync(() => SeekSourceAsync(time), "Preview");
        Timeline.PlayRequested += (_, _) => _ = RunAsync(TogglePlaybackAsync, "Preview");
        ViewModel.PropertyChanged += (_, args) => { if (args.PropertyName == nameof(EditorViewModel.CanExport)) UpdateExport(); };
        Untranscribed.Visibility = ViewModel.HasTranscript ? Visibility.Collapsed : Visibility.Visible;
        Bindings.Update();
        Aspect.SelectedIndex = EditorLayout.Frames.ToList().IndexOf(project.Export.Aspect);
        inspector = new(ViewModel, async state => await SnapshotAsync(lifetime.Token, state), lifetime.Token);
        InspectorHost.Children.Add(inspector);
        await inspector.InitializeAsync();
        InstallAccelerators();
        if (demo) media = MediaFromProject(project);
        else if (mediaPath is not null) await RunAsync(async () => media = await App.Services.Probe.ProbeAsync(mediaPath, ct), "Preview");
        if (mediaPath is null) ViewModel.Notice = $"Can't find {Path.GetFileName(project.Media.Source.AbsolutePath)}. Edits are saved.";
        if (demo) ViewModel.Notice = "Demo project · Synthetic preview. Changes are not saved to the fixture.";
        ready = true;
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
            }
            catch
            {
                preview.PlaybackFaulted -= PlaybackFaulted;
                await preview.DisposeAsync();
                preview = null;
                PreviewImage.Source = null;
                PreviewEmpty.Visibility = Visibility.Visible;
                throw;
            }
            presenter = new(PreviewImage, preview, PositionChanged, exception => ViewModel.Notice = UiError.Message(exception, "Preview"), frame => inspector?.UpdateStill(frame));
            presenter.Start(); PreviewEmpty.Visibility = Visibility.Collapsed;
        }, "Preview");
        Transcript.Focus(FocusState.Programmatic);
    }

    private static MediaInfo MediaFromProject(Project project)
    {
        var source = project.Media.Source;
        return new(source.AbsolutePath, source.DurationSeconds, source.Video, source.Audio, new(source.Video?.Width ?? 1920, source.Video?.Height ?? 1080), null, null, false, 0, source.Audio is null ? -1 : 0, 0);
    }
    private async Task<ComposeSnapshot> SnapshotAsync(CancellationToken ct, EditState? stateOverride = null)
    {
        var source = media ?? throw new InvalidOperationException("No media is open.");
        var rate = source.Audio?.SampleRate ?? 48000;
        var state = stateOverride ?? ViewModel.State;
        var project = ViewModel.ScopedProject(state);
        var scope = project.Edits.ActiveClipId is { } id ? VoiceLabOutputScope.Clip(id) : VoiceLabOutputScope.Full;
        VoiceLabRenderInput? voice = null;
        if (project.SchemaVersion == 3)
        {
            var prepared = VoiceLabRenderContract.Prepare(project, scope, VoiceLabLabelPosition.TopRight);
            if (prepared.OutputPlan.RequiresSyntheticRendering)
                voice = VoiceLabRenderInput.Capture(project, prepared, Path.Combine(App.Services.Data.Root, "VoiceLab"));
        }
        else VoiceLabProject.RequireLegacyRendering(project, scope);
        var samples = checked((long)Math.Floor(source.DurationSeconds * rate + 0.5));
        var plan = new EditPlan(rate, samples, [], [new(0, samples)], samples, []);
        if (state is not null) plan = EditingEngine.BuildEditPlan(EditingEngine.BuildSegments(state, source.DurationSeconds), source.DurationSeconds, rate, state.PauseKeepSeconds);
        var outputSize = ExportPresets.OutputSize(source.OrientedSize, ViewModel.Project.Export.Aspect);
        var fps = ExportPresets.OutputFrameRate(source.Video?.FrameRate ?? 30);
        CaptionTrack? captions = null;
        if (!demo && state is not null && ViewModel.Project.Captions.StyleId != "off" && inspector?.Styles.FirstOrDefault(style => style.Id == ViewModel.Project.Captions.StyleId) is { } style)
            captions = await CaptionEngine.BuildAsync(new(style, project.Captions, outputSize,
                voice?.Prepared.OutputPlan.Captions ?? EditingEngine.CaptionWords(state, plan), state.Transcript.Language,
                voice?.Prepared.OutputPlan.Duration ?? plan.Duration), new HarfBuzzGlyphShaper(), null, ct);
        var snapshot = new ComposeSnapshot(source, plan, captions,
            new(outputSize, fps, ExportPresets.VideoBitrate(outputSize, project.Export.Aspect, project.Export.Quality, fps))) { VoiceLab = voice };
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
        TransportTime.Text = PreviewClockLabel.Format(position.EditedTime, previewDuration, ViewModel.State?.ActiveClipId is not null);
        PlayGlyph.Symbol = position.IsPlaying ? Symbol.Pause : Symbol.Play;
        Timeline.SetTransport(TransportTime.Text, position.IsPlaying);
        Timeline.Position(position.SourceTime);
        if (changed) Transcript.RefreshVisuals();
    }
    private void PlaybackFaulted(object? sender, Exception exception)
    {
        DispatcherQueue.TryEnqueue(() => { if (!disposed) ViewModel.Notice = UiError.Message(exception, "Preview"); });
    }
    /// <summary>Make clip needs words selected (design §6.2).</summary>
    private void SelectionChanged(object? sender, EventArgs args) => MakeClipCommand.IsEnabled = ViewModel.HasSelection;
    private void ModelChanged(object? sender, EventArgs args)
    {
        if (!ready || disposed) return;
        UpdateExport();
        SizeStage();
        Untranscribed.Visibility = ViewModel.HasTranscript ? Visibility.Collapsed : Visibility.Visible;
        _ = RunAsync(UpdatePreviewAsync, "Preview");
        SaveRequested(sender, args);
    }
    private void SaveRequested(object? sender, EventArgs args)
    {
        if (ready && !disposed && !demo)
        {
            autosave?.Cancel(); autosave?.Dispose();
            autosave = CancellationTokenSource.CreateLinkedTokenSource(lifetime.Token);
            pendingSave = SaveAfterDelayAsync(autosave.Token);
        }
    }
    private void EditorSettingsChanged(object? sender, EventArgs args)
    {
        if (disposed || ViewModel.IsLeaving) return;
        Transcript.ApplySettings();
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
        if (demo || owner.ProjectPath is null) return;
        await saves.WaitAsync(ct);
        try { await App.Services.Projects.SaveAsync(ViewModel.Project, owner.ProjectPath, ct); }
        finally { saves.Release(); }
    }
    private async Task UpdatePreviewAsync()
    {
        if (media is null) return;
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
                await preview.LoadAsync(snapshot, null, lifetime.Token);
                presenter = new(PreviewImage, preview, PositionChanged,
                    exception => ViewModel.Notice = UiError.Message(exception, "Preview"), frame => inspector?.UpdateStill(frame));
                presenter.Start(); PreviewEmpty.Visibility = Visibility.Collapsed;
            }
            else await preview.UpdateSnapshotAsync(snapshot, lifetime.Token);
            if (clipChanged && previewClipId is not null) await preview.SeekAsync(0, true, lifetime.Token);
        }
        catch
        {
            if (preview is not null) preview.PlaybackFaulted -= PlaybackFaulted;
            if (presenter is not null) { await presenter.DisposeAsync(); presenter = null; }
            else if (preview is not null) await preview.DisposeAsync();
            preview = null;
            if (!disposed) { PreviewImage.Source = null; PreviewEmpty.Visibility = Visibility.Visible; }
            throw;
        }
        finally { previewChanges.Release(); }
    }
    private async Task SeekSourceAsync(double source)
    {
        if (preview is null) return;
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
    private void FindClipsClicked(object sender, RoutedEventArgs args) => ShowFindClips(sender as FrameworkElement);
    /// <summary>The sidebar's "New clip from selection" action.</summary>
    internal void MakeClipFromPane() => MakeClipAndReveal();
    /// <summary>Open Find clips at the control that asked for it: the pane action, its callout or the page's button.</summary>
    internal void ShowFindClips(FrameworkElement? anchor) =>
        _ = RunAsync(() => FindClips.ShowAsync(anchor ?? (FindClipsCommand.IsInOverflow ? Commands : FindClipsCommand)), "Find clips");
    /// <summary>Home pauses playback and keeps this page alive; design §2.</summary>
    internal void PausePlayback() => _ = RunAsync(async () => { if (preview?.Position.IsPlaying == true) await preview.PauseAsync(lifetime.Token); }, "Preview");
    /// <summary>A sidebar row sets the scope through the existing setActiveClip step; a clip also selects its first word unless
    /// the transcript keeps its selection, as after making a clip.</summary>
    internal void SelectScope(string? clipId, bool keepSelection = false)
    {
        ViewModel.Apply(new EditOperation.SetActiveClip(clipId));
        if (!keepSelection && clipId is not null && ViewModel.State?.ActiveClipId == clipId && ViewModel.Clips.FirstOrDefault(clip => clip.Id == clipId) is { } row)
            ViewModel.Select(ViewModel.Index(row.Clip.StartWordId));
    }
    private async void PlayClicked(object sender, RoutedEventArgs args) => await RunAsync(TogglePlaybackAsync, "Preview");
    private async void BackClicked(object sender, RoutedEventArgs args) => await RunAsync(() => SeekSourceAsync(Math.Max(0, ViewModel.SourceTime - 3)), "Preview");
    private async void ForwardClicked(object sender, RoutedEventArgs args) =>
        await RunAsync(() => SeekSourceAsync(Math.Min(ViewModel.Project.Media.Source.DurationSeconds, ViewModel.SourceTime + 3)), "Preview");
    private async Task TogglePlaybackAsync()
    {
        if (preview is null) return;
        if (preview.Position.IsPlaying) await preview.PauseAsync(lifetime.Token); else await preview.PlayAsync(lifetime.Token);
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
            autosave?.Cancel(); await pendingSave;
            await saves.WaitAsync(lifetime.Token);
            try
            {
                if (ViewModel.IsLeaving) return;
                var previous = owner.ProjectPath;
                await App.Services.Projects.SaveAsync(ViewModel.Project, file.Path, lifetime.Token); owner.SetProjectPath(file.Path);
                if (previous is not null && !previous.Equals(file.Path, StringComparison.OrdinalIgnoreCase) && Path.GetDirectoryName(previous)?.TrimEnd(Path.DirectorySeparatorChar).Equals(App.Services.Data.Autosave.TrimEnd(Path.DirectorySeparatorChar), StringComparison.OrdinalIgnoreCase) == true) File.Delete(previous);
            }
            finally { saves.Release(); }
        }
    }, "Save project");
    private void ShowProjectClicked(object sender, RoutedEventArgs args) { if (owner.ProjectPath is { } path) ShareHelpers.Reveal(path); }
    /// <summary>Export video… for Full take; Export clip… opens Export with the kept clips chosen until the single-clip scope
    /// arrives with the export dialog (step 12).</summary>
    private async void ExportClicked(object sender, RoutedEventArgs args) => await ExportAsync(ViewModel.State?.ActiveClipId is not null);
    /// <summary>A clip row's "Export kept clips…": Export opens with the kept clips chosen.</summary>
    internal Task ExportKeptClipsAsync() => ExportAsync(true);
    private Task ExportAsync(bool keptClips) => RunAsync(async () =>
    {
        if (!ViewModel.CanExport) return;
        await new ExportDialog(owner, ViewModel, demo, SnapshotAsync, keptClips && ViewModel.SelectedClipCount > 0) { XamlRoot = XamlRoot }.ShowAsync();
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
    private async void ShortcutsClicked(object sender, RoutedEventArgs args) => await new ContentDialog { XamlRoot = XamlRoot, Title = "Keyboard shortcuts", CloseButtonText = "Done", Content = new TextBlock { Text = "Space  Play / pause\nJ / K / L  Back / stop / forward\nDelete  Cut or restore selected words\nEnter  Correct spelling\nCtrl+Z / Ctrl+Y  Undo / redo\nCtrl+K  Make a clip (no key needed)\nCtrl+Shift+K  Find clips\nCtrl+Shift+I  Show or hide the viewer\nCtrl+1 / Ctrl+2  Home / Full take\nCtrl+E  Export\nCtrl+F  Find\nCtrl+,  Settings\nF6  Next pane\n\nEditor keys never run while typing in a text field.", TextWrapping = TextWrapping.Wrap } }.ShowAsync();
    private void AspectChanged(object sender, SelectionChangedEventArgs args)
    {
        if (!ready || Aspect.SelectedIndex < 0) return;
        ViewModel.SetExport(ViewModel.Project.Export with { Aspect = EditorLayout.Frames[Aspect.SelectedIndex] });
        SizeStage();
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
        }
        Add(VirtualKey.Z, VirtualKeyModifiers.Control, ViewModel.Undo);
        Add(VirtualKey.Y, VirtualKeyModifiers.Control, ViewModel.Redo);
        Add(VirtualKey.Z, VirtualKeyModifiers.Control | VirtualKeyModifiers.Shift, ViewModel.Redo);
        Add(VirtualKey.K, VirtualKeyModifiers.Control, MakeClipAndReveal);
        Add(VirtualKey.U, VirtualKeyModifiers.Control | VirtualKeyModifiers.Shift, () => ViewModel.Apply(new EditOperation.CutFillers()));
        Add(VirtualKey.P, VirtualKeyModifiers.Control | VirtualKeyModifiers.Shift, () => ViewModel.Apply(new EditOperation.TightenPauses()));
        Add(VirtualKey.R, VirtualKeyModifiers.Control | VirtualKeyModifiers.Shift, () => ViewModel.Apply(new EditOperation.RestoreCuts()));
        Add(VirtualKey.E, VirtualKeyModifiers.Control, () => ExportClicked(this, new()));
        Add(VirtualKey.F, VirtualKeyModifiers.Control, () => FindClicked(this, new()));
        Add(VirtualKey.A, VirtualKeyModifiers.Control, () => { ViewModel.Select(0); ViewModel.Select(ViewModel.Words.Count - 1, true); });
        Add(VirtualKey.C, VirtualKeyModifiers.Control, () => ShareHelpers.Copy(ViewModel.SelectionText));
        Add(VirtualKey.H, VirtualKeyModifiers.Control | VirtualKeyModifiers.Shift, () => { ShowCuts.IsChecked = ShowCuts.IsChecked != true; DisplayChanged(this, new()); });
        Add((VirtualKey)187, VirtualKeyModifiers.Control, () => Transcript.Zoom(1));
        Add((VirtualKey)189, VirtualKeyModifiers.Control, () => Transcript.Zoom(-1));
        Add(VirtualKey.Number0, VirtualKeyModifiers.Control, () => Transcript.Zoom(0, true));
        Add(VirtualKey.Left, VirtualKeyModifiers.Control, () => { ViewModel.MoveSentence(-1); _ = RunAsync(() => SeekSourceAsync(ViewModel.SourceTime), "Preview"); });
        Add(VirtualKey.Right, VirtualKeyModifiers.Control, () => { ViewModel.MoveSentence(1); _ = RunAsync(() => SeekSourceAsync(ViewModel.SourceTime), "Preview"); });
        Add(VirtualKey.Home, VirtualKeyModifiers.Control, () => ViewModel.Select(0));
        Add(VirtualKey.End, VirtualKeyModifiers.Control, () => ViewModel.Select(ViewModel.Words.Count - 1));
        Add(VirtualKey.K, VirtualKeyModifiers.Control | VirtualKeyModifiers.Shift, () => ShowFindClips(null));
        Add(VirtualKey.I, VirtualKeyModifiers.Control | VirtualKeyModifiers.Shift, () => { Viewer.IsChecked = Viewer.IsChecked != true; ViewerClicked(this, new()); });
        Add(VirtualKey.F1, VirtualKeyModifiers.None, () => ShortcutsClicked(this, new()));
    }
    private async void EditorKeyDown(object sender, KeyRoutedEventArgs args)
    {
        if (!ready) return;
        var focused = FocusManager.GetFocusedElement(XamlRoot);
        if (args.Key == VirtualKey.F6)
        {
            var viewer = RightPane.Visibility == Visibility.Visible;
            var panes = viewer ? new Control[] { Transcript, PreviewPlay, Timeline.FocusTarget, inspector!.FocusTarget } : [Transcript, Timeline.FocusTarget];
            var regions = viewer ? new FrameworkElement[] { TranscriptPane, PreviewPane, Timeline, InspectorHost } : [TranscriptPane, Timeline];
            var current = Array.FindIndex(regions, pane => InputState.DescendsFrom(focused as DependencyObject, pane));
            panes[(current + (InputState.Down(VirtualKey.Shift) ? -1 : 1) + panes.Length) % panes.Length].Focus(FocusState.Keyboard); args.Handled = true; return;
        }
        var editorFocus = InputState.DescendsFrom(focused as DependencyObject, Transcript) || InputState.DescendsFrom(focused as DependencyObject, PreviewPane) || InputState.DescendsFrom(focused as DependencyObject, Timeline);
        var control = InputState.Down(VirtualKey.Control);
        if (!ShortcutPolicy.EditorMayHandle(InputState.IsTextFocus(focused), Transcript.CorrectionOpen, control, InputState.Down(VirtualKey.Menu), editorFocus) || control) return;
        var handled = true;
        switch (args.Key)
        {
            case VirtualKey.Space: await RunAsync(TogglePlaybackAsync, "Preview"); break;
            case VirtualKey.K: if (preview is not null) await RunAsync(() => preview.PauseAsync(lifetime.Token), "Preview"); break;
            case VirtualKey.L: if (preview is not null) await RunAsync(() => preview.PlayAsync(lifetime.Token), "Preview"); break;
            case VirtualKey.J: await RunAsync(() => SeekSourceAsync(Math.Max(0, ViewModel.SourceTime - 3)), "Preview"); break;
            case VirtualKey.Back: case VirtualKey.Delete: ViewModel.CutSelection(InputState.Down(VirtualKey.Shift)); break;
            case VirtualKey.Left: case VirtualKey.Right: ViewModel.Select((ViewModel.HasSelection ? ViewModel.SelectionEnd : 0) + (args.Key == VirtualKey.Right ? 1 : -1), InputState.Down(VirtualKey.Shift)); await RunAsync(() => SeekSourceAsync(ViewModel.SourceTime), "Preview"); break;
            case VirtualKey.Home: ViewModel.Select(0); break;
            case VirtualKey.End: ViewModel.Select(ViewModel.Words.Count - 1); break;
            case VirtualKey.Enter: case VirtualKey.C: Transcript.BeginCorrection(); break;
            case VirtualKey.Escape: if (ViewModel.State?.ActiveClipId is not null) owner.ShowScope(null, keepSelection: true); break;
            case VirtualKey.I: ViewModel.SetClipEdgeAtCaret(true); break;
            case VirtualKey.O: ViewModel.SetClipEdgeAtCaret(false); break;
            case (VirtualKey)219: ViewModel.CycleClip(-1); break;
            case (VirtualKey)221: ViewModel.CycleClip(1); break;
            default: handled = false; break;
        }
        args.Handled = handled;
    }
    /// <summary>Export video… or Export clip… for the scope, disabled with its reason as tooltip and description (delta §3.5,
    /// placeholder spec §5.4.4). The name says when the scope contains AI-modified speech.</summary>
    private void UpdateExport()
    {
        var active = ViewModel.Clips.FirstOrDefault(clip => clip.Id == ViewModel.State?.ActiveClipId);
        var label = active is null ? "Export video…" : "Export clip…";
        var reason = EditorLayout.ExportBlocked(demo, MediaPath is null || media is null, ViewModel.CanExport, active?.IsSuggested == true);
        ExportButton.Content = label;
        ExportButton.IsEnabled = reason is null;
        ToolTipService.SetToolTip(ExportHost, reason ?? $"{label} (Ctrl+E)");
        AutomationProperties.SetName(ExportButton, ScopeHasAiSpeech() ? label + ", contains AI-modified speech" : label);
        AutomationProperties.SetHelpText(ExportButton, reason ?? "");
    }
    private bool ScopeHasAiSpeech()
    {
        var project = ViewModel.ScopedProject(ViewModel.State);
        if (project.SchemaVersion != 3) return false;
        var scope = project.Edits.ActiveClipId is { } id ? VoiceLabOutputScope.Clip(id) : VoiceLabOutputScope.Full;
        try { return VoiceLabRenderContract.Prepare(project, scope, VoiceLabLabelPosition.TopRight).OutputPlan.RequiresSyntheticRendering; }
        catch (Exception exception) when (exception is not OutOfMemoryException) { return false; }
    }
    private void ViewerClicked(object sender, RoutedEventArgs args)
    {
        var visible = Viewer.IsChecked == true;
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
        RightColumn.Width = new(visible ? owner.RightColumnWidth ?? DefaultRightWidth() : 0);
        Timeline.ShowsTransport = !visible;
    }
    private static double Token(string key) => (double)Application.Current.Resources[key];
    private double DefaultRightWidth() => EditorLayout.RightColumnWidth(XamlRoot?.Size.Width ?? 1280, Token("VcSizeRightColumnMin"), Token("VcSizeRightColumnMax"));
    private bool TranscriptFits(double pageWidth) =>
        EditorLayout.TranscriptFits(pageWidth, ViewerSplitter.Width, owner.RightColumnWidth ?? DefaultRightWidth(), Token("VcLayoutTranscriptMinWidth"));
    private void EditorSizeChanged(object sender, SizeChangedEventArgs args) { if (ready) FitViewer(args.NewSize.Width); }
    /// <summary>The right column collapses first when the transcript would drop below 588 and returns when there is room.</summary>
    private void FitViewer(double pageWidth)
    {
        var fits = TranscriptFits(pageWidth);
        if (fits && viewerForced) { viewerForced = false; ShowViewer(true); }
        else if (Viewer.IsChecked == true && !fits && !viewerForced) { viewerSqueezed = true; ShowViewer(false); }
        else if (viewerSqueezed && fits) { viewerSqueezed = false; ShowViewer(true); }
        else if (Viewer.IsChecked == true && owner.RightColumnWidth is null) RightColumn.Width = new(DefaultRightWidth());
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
    /// <summary>A width the user chose stays with the window across projects; settings.schema.json has no key for it.</summary>
    private void RememberRightWidth() => owner.RightColumnWidth = RightColumn.ActualWidth;
    private void RightPaneSizeChanged(object sender, SizeChangedEventArgs args)
    {
        AutomationProperties.SetItemStatus(ViewerSplitter, $"{Math.Round(args.NewSize.Width)} px");
        SizeStage();
    }
    /// <summary>Size the stage for the frame and the column (delta §5.1) and name it for the scope.</summary>
    private void SizeStage()
    {
        var oriented = media?.OrientedSize ?? new PixelSize(ViewModel.Project.Media.Source.Video?.Width ?? 16, ViewModel.Project.Media.Source.Video?.Height ?? 9);
        (PreviewStage.Width, PreviewStage.Height) = EditorLayout.Stage(RightPane.ActualWidth - RightPane.BorderThickness.Left - 32, ViewModel.Project.Export.Aspect, oriented);
        AutomationProperties.SetName(PreviewImage, ViewModel.State?.ActiveClipId is { } id && ViewModel.Clips.FirstOrDefault(clip => clip.Id == id) is { } clip
            ? $"Video preview, clip {clip.Number}" : "Video preview, full take");
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
            ViewModel.Notice = "Could not save this project. It is still open with your edits. Use Save project as… or check the folder, then try again.";
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
        disposed = true; autosave?.Cancel(); await lifetime.CancelAsync();
        await pendingSave;
        if (ViewModel is not null)
        {
            ViewModel.Changed -= ModelChanged;
            ViewModel.SelectionChanged -= SelectionChanged;
            ViewModel.SaveRequested -= SaveRequested;
        }
        Transcript.Detach(); Timeline.Detach(); inspector?.Detach();
        App.Services.SettingsChanged -= EditorSettingsChanged;
        await previewChanges.WaitAsync();
        try
        {
            if (preview is not null) preview.PlaybackFaulted -= PlaybackFaulted;
            if (presenter is not null) await presenter.DisposeAsync(); else if (preview is not null) await preview.DisposeAsync();
            presenter = null; preview = null;
        }
        finally { previewChanges.Release(); }
        lifetime.Dispose(); autosave?.Dispose();
    }
}
