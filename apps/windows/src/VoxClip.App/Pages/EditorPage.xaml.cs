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
    private readonly SemaphoreSlim previewChanges = new(1, 1);
    private readonly SemaphoreSlim saves = new(1, 1);
    private string pauseBreath = "natural";
    private double previewWidth = 380;
    public EditorPage() { InitializeComponent(); Loaded += (_, _) => Transcript.Focus(FocusState.Programmatic); }
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
        preview.PlaybackFaulted += PlaybackFaulted;
        ViewModel.Changed += ModelChanged;
        ViewModel.SaveRequested += SaveRequested;
        pauseBreath = App.Services.Get("editing.pauseBreath", "natural");
        App.Services.SettingsChanged += EditorSettingsChanged;
        Transcript.Attach(ViewModel);
        Timeline.Attach(ViewModel);
        Transcript.SeekRequested += (_, _) => _ = RunAsync(() => SeekSourceAsync(ViewModel.SourceTime), "Preview");
        Transcript.MakeClipRequested += (_, _) => ViewModel.MakeClip();
        Transcript.PlayRequested += (_, _) => _ = RunAsync(async () => { await SeekSourceAsync(ViewModel.SourceTime); if (preview is not null) await preview.PlayAsync(lifetime.Token); }, "Preview");
        Timeline.SeekRequested += (_, time) => _ = RunAsync(() => SeekSourceAsync(time), "Preview");
        Untranscribed.Visibility = ViewModel.HasTranscript ? Visibility.Collapsed : Visibility.Visible;
        Bindings.Update();
        Aspect.SelectedIndex = (int)project.Export.Aspect;
        inspector = new(ViewModel, async state => await SnapshotAsync(lifetime.Token, state), lifetime.Token);
        inspector.TabChanged += (_, _) => UpdateFooter();
        InspectorHost.Children.Add(inspector);
        await inspector.InitializeAsync();
        InstallAccelerators();
        if (demo) media = MediaFromProject(project);
        else if (mediaPath is not null) await RunAsync(async () => media = await App.Services.Probe.ProbeAsync(mediaPath, ct), "Preview");
        if (media is null) ViewModel.Notice = $"Can't find {Path.GetFileName(project.Media.Source.AbsolutePath)}. Edits are saved.";
        if (demo)
        {
            ViewModel.Notice = "Demo project · Synthetic preview. Changes are not saved to the fixture.";
            PreviewDescription.Text = "Synthetic preview · source media is not loaded. Caption tiles use the shared renderer.";
        }
        ready = true;
        await RunAsync(async () =>
        {
            if (media is null || preview is null) return;
            await preview.LoadAsync(await SnapshotAsync(ct), null, ct);
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
        ViewModel.RequireLegacyRendering(state);
        var samples = (long)(source.DurationSeconds * rate);
        var plan = new EditPlan(rate, samples, [], [new(0, samples)], samples, []);
        if (!demo && state is not null) plan = EditingEngine.BuildEditPlan(EditingEngine.BuildSegments(state, source.DurationSeconds), source.DurationSeconds, rate, state.PauseKeepSeconds);
        var outputSize = ExportPresets.OutputSize(source.OrientedSize, ViewModel.Project.Export.Aspect);
        var fps = ExportPresets.OutputFrameRate(source.Video?.FrameRate ?? 30);
        CaptionTrack? captions = null;
        if (!demo && state is not null && ViewModel.Project.Captions.StyleId != "off" && inspector?.Styles.FirstOrDefault(style => style.Id == ViewModel.Project.Captions.StyleId) is { } style)
            captions = await CaptionEngine.BuildAsync(new(style, ViewModel.Project.Captions, outputSize, EditingEngine.CaptionWords(state, plan), state.Transcript.Language, plan.Duration), new HarfBuzzGlyphShaper(), null, ct);
        return new(source, plan, captions, new(outputSize, fps, ExportPresets.VideoBitrate(outputSize, ViewModel.Project.Export.Aspect, ViewModel.Project.Export.Quality, fps)));
    }
    private void PositionChanged(PreviewPosition position)
    {
        if (disposed) return;
        var changed = Math.Abs(ViewModel.SourceTime - position.SourceTime) > 0.02;
        ViewModel.SourceTime = position.SourceTime;
        TransportTime.Text = ViewModel.TimeLabel + " / " + EditorViewModel.Timecode(media?.DurationSeconds ?? 0);
        PlayCommand.IsChecked = position.IsPlaying; PlayCommand.Label = position.IsPlaying ? "Pause" : "Play";
        Timeline.Position(position.SourceTime);
        if (changed) Transcript.RefreshVisuals();
    }
    private void PlaybackFaulted(object? sender, Exception exception)
    {
        DispatcherQueue.TryEnqueue(() => { if (!disposed) ViewModel.Notice = UiError.Message(exception, "Preview"); });
    }
    private void UpdateFooter()
    {
        FooterExport.Content = inspector?.ClipsActive == true ? ViewModel.ClipExportLabel : "Export…";
        FooterExport.IsEnabled = ViewModel.CanExport && (inspector?.ClipsActive != true || ViewModel.SelectedClipCount > 0);
    }
    private void ModelChanged(object? sender, EventArgs args)
    {
        if (!ready || disposed) return;
        UpdateFooter();
        Untranscribed.Visibility = ViewModel.HasTranscript ? Visibility.Collapsed : Visibility.Visible;
#if DEBUG
        if (preview is DemoPreviewEngine synthetic) synthetic.SetEdit(ViewModel.State);
#endif
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
        if (disposed) return;
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
        if (preview is null || media is null) return;
        await previewChanges.WaitAsync(lifetime.Token);
        try { await preview.UpdateSnapshotAsync(await SnapshotAsync(lifetime.Token), lifetime.Token); }
        finally { previewChanges.Release(); }
    }
    private async Task SeekSourceAsync(double source)
    {
        if (preview is null) return;
        var snapshot = await SnapshotAsync(lifetime.Token);
        await preview.SeekAsync(demo ? source : snapshot.Plan.MapTime(source), true, lifetime.Token);
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
    private void MakeClipClicked(object sender, RoutedEventArgs args) { ViewModel.MakeClip(); inspector?.SelectTab(true); }
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
        if (file is not null)
        {
            autosave?.Cancel(); await pendingSave;
            await saves.WaitAsync(lifetime.Token);
            try
            {
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
        await new ExportDialog(owner, ViewModel, demo, SnapshotAsync) { XamlRoot = XamlRoot }.ShowAsync();
    }, "Export");
    internal async Task PromptTranscriptionAsync(bool startLocalWhenReady = false) => await RunAsync(async () =>
        await new TranscriptionDialog(owner, ViewModel, startLocalWhenReady) { XamlRoot = XamlRoot }.ShowAsync(), "Transcription");
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
        Add(VirtualKey.K, VirtualKeyModifiers.Control, () => MakeClipClicked(this, new()));
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
        Add(VirtualKey.Number1, VirtualKeyModifiers.Control, () => { InspectorSplit.IsPaneOpen = true; inspector?.SelectTab(false); });
        Add(VirtualKey.Number2, VirtualKeyModifiers.Control, () => { InspectorSplit.IsPaneOpen = true; inspector?.SelectTab(true); });
        Add(VirtualKey.I, VirtualKeyModifiers.Control | VirtualKeyModifiers.Shift, () => InspectorSplit.IsPaneOpen = !InspectorSplit.IsPaneOpen);
        Add(VirtualKey.F1, VirtualKeyModifiers.None, () => ShortcutsClicked(this, new()));
    }
    private async void EditorKeyDown(object sender, KeyRoutedEventArgs args)
    {
        if (!ready) return;
        var focused = FocusManager.GetFocusedElement(XamlRoot);
        if (args.Key == VirtualKey.F6)
        {
            var panes = InspectorSplit.IsPaneOpen ? new Control[] { Transcript, PreviewPlay, Timeline, inspector! } : [Transcript, PreviewPlay, Timeline];
            var current = Array.FindIndex(panes, pane => InputState.DescendsFrom(focused as DependencyObject, pane));
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
            case VirtualKey.Escape: ViewModel.Apply(new EditOperation.SetActiveClip(null)); break;
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
        if (isNarrow != narrow)
        {
            narrow = isNarrow; InspectorSplit.DisplayMode = narrow ? SplitViewDisplayMode.Overlay : SplitViewDisplayMode.Inline; InspectorSplit.IsPaneOpen = !narrow;
            InspectorSplit.PaneBackground = (Microsoft.UI.Xaml.Media.Brush)Application.Current.Resources[narrow ? "AcrylicBackgroundFillColorDefaultBrush" : "LayerFillColorDefaultBrush"];
        }
        var stacked = args.NewSize.Width < 960;
        PreviewColumn.Width = stacked ? new(0) : new(previewWidth);
        ContentPanes.RowDefinitions[0].Height = stacked ? new(2, GridUnitType.Star) : new(1, GridUnitType.Star);
        ContentPanes.RowDefinitions[1].Height = stacked ? new(3, GridUnitType.Star) : new(0);
        Grid.SetColumn(PreviewPane, stacked ? 0 : 2); Grid.SetRow(TranscriptPane, stacked ? 1 : 0);
    }
    internal async Task CloseAsync()
    {
        if (disposed) return;
        disposed = true; autosave?.Cancel(); await lifetime.CancelAsync();
        try { await pendingSave; if (!demo) await SaveAsync(CancellationToken.None); } catch (Exception) { App.Services.Log.Write(Core.Services.Logging.LogLevel.Warn, "import", "project flush failed"); }
        ViewModel.Changed -= ModelChanged; Transcript.Detach(); Timeline.Detach(); inspector?.Detach();
        ViewModel.SaveRequested -= SaveRequested;
        App.Services.SettingsChanged -= EditorSettingsChanged;
        if (preview is not null) preview.PlaybackFaulted -= PlaybackFaulted;
        if (presenter is not null) await presenter.DisposeAsync(); else if (preview is not null) await preview.DisposeAsync();
        lifetime.Dispose(); autosave?.Dispose();
    }
}
