using Microsoft.UI.Xaml;
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
    private bool narrow;
    private CancellationTokenSource? autosave;
    private Task pendingSave = Task.CompletedTask;
    private ProjectLeaveBoundary leave = null!;
    private readonly SemaphoreSlim previewChanges = new(1, 1);
    private readonly SemaphoreSlim saves = new(1, 1);
    private string pauseBreath = "natural";
    private double previewWidth = 380;
    private double previewDuration;
    private string? previewClipId;
    private Control? focusAfterPaneClose;
    public EditorPage()
    {
        InitializeComponent();
        Loaded += (_, _) => Transcript.Focus(FocusState.Programmatic);
        InspectorSplit.PaneClosed += (_, _) =>
        {
            if (!narrow) return;
            var target = focusAfterPaneClose ?? Transcript;
            focusAfterPaneClose = null;
            DispatcherQueue.TryEnqueue(() => target.Focus(FocusState.Keyboard));
        };
    }
    public static bool HasText(string? text) => !string.IsNullOrEmpty(text);

    internal async Task OpenAsync(MainWindow window, Project project, string? mediaPath, bool demoMode, CancellationToken ct)
    {
        owner = window;
        demo = demoMode;
#if DEBUG
        ViewModel = demo ? new(project, DemoProject.Reduce, DemoProject.Summarize) : new(project);
        preview = demo ? new DemoPreviewEngine() : new PreviewEngine();
#else
        ViewModel = new(project);
        preview = new PreviewEngine();
#endif
        leave = new(ViewModel);
        preview.PlaybackFaulted += PlaybackFaulted;
        preview.AudioStatusChanged += AudioStatusChanged;
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
        Untranscribed.Visibility = ViewModel.HasTranscript ? Visibility.Collapsed : Visibility.Visible;
        UpdateClipContext();
        Bindings.Update();
        Aspect.SelectedIndex = (int)project.Export.Aspect;
        inspector = new(ViewModel, async state => await SnapshotAsync(lifetime.Token, state), lifetime.Token);
        inspector.TabChanged += (_, _) => UpdateFooter();
        inspector.PreviewRequested += _ =>
        {
            if (narrow) { focusAfterPaneClose = PreviewPlay; InspectorSplit.IsPaneOpen = false; }
            PreviewPlay.Focus(FocusState.Keyboard);
        };
        InspectorHost.Children.Add(inspector);
        await inspector.InitializeAsync();
        InstallAccelerators();
        if (demo) media = MediaFromProject(project);
        else if (mediaPath is not null) await RunAsync(async () => media = await App.Services.Probe.ProbeAsync(mediaPath, ct), "Preview");
        if (mediaPath is null) ViewModel.Notice = $"Can't find {Path.GetFileName(project.Media.Source.AbsolutePath)}. Edits are saved.";
        if (demo)
        {
            ViewModel.Notice = "Demo project · Synthetic preview. Changes are not saved to the fixture.";
            PreviewDescription.Text = "Synthetic preview · source media is not loaded. Caption tiles use the shared renderer.";
        }
        ready = true;
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
                preview.AudioStatusChanged -= AudioStatusChanged;
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
        PlayCommand.IsChecked = position.IsPlaying; PlayCommand.Label = position.IsPlaying ? "Pause" : "Play";
        Timeline.Position(position.SourceTime);
        if (changed) Transcript.RefreshVisuals();
    }
    private void PlaybackFaulted(object? sender, Exception exception)
    {
        DispatcherQueue.TryEnqueue(() => { if (!disposed) ViewModel.Notice = UiError.Message(exception, "Preview"); });
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
    private void UpdateFooter()
    {
        FooterExport.Content = inspector?.ClipsActive == true ? ViewModel.ClipExportLabel : "Export…";
        FooterExport.IsEnabled = ViewModel.CanExport && (inspector?.ClipsActive != true || ViewModel.SelectedClipCount > 0);
    }
    private void SelectionChanged(object? sender, EventArgs args) => UpdateClipContext();
    private void UpdateClipContext()
    {
        if (ViewModel is null) return;
        var active = ViewModel.Clips.FirstOrDefault(clip => clip.Id == ViewModel.State?.ActiveClipId);
        ClipContext.Text = !ViewModel.HasTranscript ? "Choose transcription first. Your source video stays untouched."
            : active is not null ? $"Previewing {active.Title} · {ViewModel.Clips.Count} {ClipNoun(ViewModel.Clips.Count)} in this take"
            : ViewModel.HasSelection ? $"{ViewModel.SelectionEnd - ViewModel.SelectionStart + 1} words selected · {ViewModel.Clips.Count} {ClipNoun(ViewModel.Clips.Count)} in this take"
            : ViewModel.Clips.Count == 0 ? "Select words in the transcript or find clips with AI."
            : $"{ViewModel.Clips.Count} {ClipNoun(ViewModel.Clips.Count)} in this take · Select words to make another.";
    }
    private static string ClipNoun(int count) => count == 1 ? "clip" : "clips";
    private void ModelChanged(object? sender, EventArgs args)
    {
        if (!ready || disposed) return;
        UpdateFooter();
        UpdateClipContext();
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
                preview.AudioStatusChanged += AudioStatusChanged;
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
            if (preview is not null) { preview.PlaybackFaulted -= PlaybackFaulted; preview.AudioStatusChanged -= AudioStatusChanged; }
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
    private void MakeClipAndReveal()
    {
        if (ViewModel.MakeClip()) ShowClipsPane();
    }
    private void MakeClipClicked(object sender, RoutedEventArgs args) => MakeClipAndReveal();
    private void FindClipsClicked(object sender, RoutedEventArgs args)
    {
        InspectorSplit.IsPaneOpen = true;
        inspector?.ShowFind();
    }
    private void CaptionsClicked(object sender, RoutedEventArgs args)
    {
        InspectorSplit.IsPaneOpen = true;
        inspector?.SelectTab(false);
    }
    private void ShowClipsPane()
    {
        InspectorSplit.IsPaneOpen = true;
        inspector?.SelectTab(true);
    }
    private async void PlayClicked(object sender, RoutedEventArgs args) => await RunAsync(TogglePlaybackAsync, "Preview");
    private async Task TogglePlaybackAsync()
    {
        if (preview is null) return;
        if (preview.Position.IsPlaying) await preview.PauseAsync(lifetime.Token); else await preview.PlayAsync(lifetime.Token);
    }
    private void InspectorClicked(object sender, RoutedEventArgs args) => InspectorSplit.IsPaneOpen = !InspectorSplit.IsPaneOpen;
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
    private async void ExportClicked(object sender, RoutedEventArgs args) => await RunAsync(async () =>
    {
        if (!ViewModel.CanExport) return;
        var selectedClips = ReferenceEquals(sender, FooterExport) && inspector?.ClipsActive == true && ViewModel.SelectedClipCount > 0;
        await new ExportDialog(owner, ViewModel, demo, SnapshotAsync, selectedClips) { XamlRoot = XamlRoot }.ShowAsync();
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
    private async void ShortcutsClicked(object sender, RoutedEventArgs args) => await new ContentDialog { XamlRoot = XamlRoot, Title = "Keyboard shortcuts", CloseButtonText = "Done", Content = new TextBlock { Text = "Space  Play / pause\nJ / K / L  Back / stop / forward\nDelete  Cut or restore selected words\nEnter  Correct spelling\nCtrl+Z / Ctrl+Y  Undo / redo\nCtrl+K  Make a clip (no key needed)\nCtrl+1 / Ctrl+2  Captions / Clips\nCtrl+E  Export\nCtrl+F  Find\nCtrl+,  Settings\nF6  Next pane\n\nEditor keys never run while typing in a text field.", TextWrapping = TextWrapping.Wrap } }.ShowAsync();
    private void AspectChanged(object sender, SelectionChangedEventArgs args) { if (ready) ViewModel.SetExport(ViewModel.Project.Export with { Aspect = (ExportAspect)Math.Max(0, Aspect.SelectedIndex) }); }
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
        Add(VirtualKey.Number1, VirtualKeyModifiers.Control, () => CaptionsClicked(this, new()));
        Add(VirtualKey.Number2, VirtualKeyModifiers.Control, ShowClipsPane);
        Add(VirtualKey.I, VirtualKeyModifiers.Control | VirtualKeyModifiers.Shift, () => InspectorSplit.IsPaneOpen = !InspectorSplit.IsPaneOpen);
        Add(VirtualKey.F1, VirtualKeyModifiers.None, () => ShortcutsClicked(this, new()));
    }
    private async void EditorKeyDown(object sender, KeyRoutedEventArgs args)
    {
        if (!ready) return;
        var focused = FocusManager.GetFocusedElement(XamlRoot);
        if (args.Key == VirtualKey.F6)
        {
            var panes = InspectorSplit.IsPaneOpen ? new Control[] { Transcript, PreviewPlay, Timeline.FocusTarget, inspector!.FocusTarget } : [Transcript, PreviewPlay, Timeline.FocusTarget];
            var regions = InspectorSplit.IsPaneOpen ? new FrameworkElement[] { TranscriptPane, PreviewPane, Timeline, InspectorHost } : [TranscriptPane, PreviewPane, Timeline];
            var current = Array.FindIndex(regions, pane => InputState.DescendsFrom(focused as DependencyObject, pane));
            panes[(current + (InputState.Down(VirtualKey.Shift) ? -1 : 1) + panes.Length) % panes.Length].Focus(FocusState.Keyboard); args.Handled = true; return;
        }
        if (args.Key == VirtualKey.Escape && narrow && InspectorSplit.IsPaneOpen)
        {
            InspectorSplit.IsPaneOpen = false;
            Transcript.Focus(FocusState.Keyboard);
            args.Handled = true;
            return;
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
            case VirtualKey.Escape:
                if (ViewModel.State?.ActiveClipId is { } activeClipId)
                {
                    ViewModel.Apply(new EditOperation.SetActiveClip(null));
                    if (narrow) InspectorSplit.IsPaneOpen = true;
                    inspector?.FocusClip(activeClipId);
                }
                break;
            case VirtualKey.I: ViewModel.SetClipEdgeAtCaret(true); break;
            case VirtualKey.O: ViewModel.SetClipEdgeAtCaret(false); break;
            case (VirtualKey)219: ViewModel.CycleClip(-1); break;
            case (VirtualKey)221: ViewModel.CycleClip(1); break;
            default: handled = false; break;
        }
        args.Handled = handled;
    }
    private void SplitterDragged(object sender, DragDeltaEventArgs args) { previewWidth = Math.Clamp(PreviewColumn.ActualWidth - args.HorizontalChange, 300, 560); PreviewColumn.Width = new(previewWidth); }
    private void EditorSizeChanged(object sender, SizeChangedEventArgs args)
    {
        if (InspectorSplit is null || ContentPanes is null) return;
        var isNarrow = args.NewSize.Width < 1200;
        PanelsButton.Visibility = isNarrow ? Visibility.Visible : Visibility.Collapsed;
        if (isNarrow != narrow)
        {
            narrow = isNarrow; InspectorSplit.DisplayMode = narrow ? SplitViewDisplayMode.Overlay : SplitViewDisplayMode.Inline; InspectorSplit.IsPaneOpen = !narrow;
            InspectorSplit.PaneBackground = (Microsoft.UI.Xaml.Media.Brush)Application.Current.Resources[narrow ? "AcrylicBackgroundFillColorDefaultBrush" : "LayerFillColorDefaultBrush"];
        }
        var stacked = args.NewSize.Width < 960;
        PreviewColumn.Width = stacked ? new(0) : new(previewWidth);
        ContentPanes.ColumnDefinitions[1].Width = new(stacked ? 0 : 4);
        PaneSplitter.Visibility = stacked ? Visibility.Collapsed : Visibility.Visible;
        PreviewStage.MinHeight = stacked ? 120 : 180;
        Aspect.Visibility = stacked ? Visibility.Collapsed : Visibility.Visible;
        PreviewDescription.Visibility = stacked ? Visibility.Collapsed : Visibility.Visible;
        ContentPanes.RowDefinitions[0].Height = stacked ? new(1, GridUnitType.Star) : new(1, GridUnitType.Star);
        ContentPanes.RowDefinitions[1].Height = stacked ? new(1, GridUnitType.Star) : new(0);
        Grid.SetColumn(PreviewPane, stacked ? 0 : 2); Grid.SetRow(TranscriptPane, stacked ? 1 : 0);
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
            if (preview is not null) { preview.PlaybackFaulted -= PlaybackFaulted; preview.AudioStatusChanged -= AudioStatusChanged; }
            if (presenter is not null) await presenter.DisposeAsync(); else if (preview is not null) await preview.DisposeAsync();
            presenter = null; preview = null;
        }
        finally { previewChanges.Release(); }
        lifetime.Dispose(); autosave?.Dispose();
    }
}
