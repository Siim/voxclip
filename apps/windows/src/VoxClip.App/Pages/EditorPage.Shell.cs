using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using VoxClip.App.Controls;
using VoxClip.App.Services;
using VoxClip.App.ViewModels;
using VoxClip.Core.Domain.Editing;
using Windows.System;

namespace VoxClip.App.Pages;

public sealed partial class EditorPage
{
    internal EditorTabStrip Tabs { get; } = new();
    internal bool CorrectionOpen => Transcript.CorrectionOpen;
    private readonly ShellInputSession askInput = new();
    private readonly Dictionary<string, string> scopeInstructions = new(StringComparer.Ordinal);
    private ShellJobBindings? shellJobs;
    private Action<bool>? timelineShowCuts;
    private bool askCompositionJustEnded;
    private bool timelineVisible = true;
    private string? askScope;
    private bool shellInitialized;
    private bool ShellReady => ready && !disposed && !ViewModel.IsLeaving;
    private bool ShellEditable => ShellReady && !ViewModel.IsReadOnly && !ViewModel.Busy;
    internal string ShellStatus => ViewModel.Notice.Length > 0 ? ViewModel.Notice
        : shellJobs?.Status?.Invoke() is { Length: > 0 } activity ? activity
        : FindClips.Running is { } finding ? $"Finding clips · {finding}"
        : ViewModel.LlmRuns.IsBusy ? "AI request running"
        : ViewModel.Busy ? "Working…"
        : $"{ViewModel.SummaryLine} · {ViewModel.TimeLabel}" + (aiStatus.Length > 0 ? " · " + aiStatus : "") + (ViewModel.IsReadOnly ? " · Read-only" : "");
    /// <summary>The chosen AI, its model and the effort AI decisions send: "Claude Code · Opus (latest) · extra high"; empty with
    /// no AI chosen.</summary>
    private string aiStatus = "";
    private async Task RefreshAiStatusAsync()
    {
        var selected = App.Services.Get("llm.connector", "");
        var entry = selected.Length == 0 ? null : (await ProviderCatalog.ReadAsync(lifetime.Token)).FirstOrDefault(item => item.WireId == selected);
        aiStatus = entry is null ? "" : AiEffortLabel.Status(entry.ShortName, entry.Metadata, App.Services.Get("llm.model." + entry.WireId, entry.DefaultModel));
    }

    public void ConfigureShellJobs(ShellJobBindings? bindings)
    {
        if (disposed) return;
        shellJobs = bindings;
        if (ready) UpdateShellChrome();
    }

    public void ConfigureTimelineShell(Action<bool>? setShowCuts)
    {
        if (disposed) return;
        timelineShowCuts = setShowCuts;
        timelineShowCuts?.Invoke(ShowCuts.IsChecked == true);
    }

    public void RefreshShellPresentation() { if (ready && !disposed) owner.RefreshShellChrome(); }

    internal void RevealOutline(int wordIndex)
    {
        if (!ShellReady || wordIndex < 0 || wordIndex >= ViewModel.Words.Count) return;
        ViewModel.Select(wordIndex);
        Transcript.RevealWord(wordIndex);
        _ = RunAsync(() => SeekSourceAsync(ViewModel.SourceTime), "Preview");
    }

    private void InitializeShell()
    {
        Tabs.ScopeRequested += (_, clipId) => owner.ShowScope(clipId, keepSelection: true);
        ShellAsk.TextCompositionStarted += (_, _) => askInput.CompositionStarted();
        ShellAsk.TextCompositionEnded += (_, _) => { askInput.CompositionEnded(); askCompositionJustEnded = true; };
        ShellAsk.AddHandler(UIElement.KeyUpEvent, new KeyEventHandler((_, _) => askCompositionJustEnded = false), true);
        shellInitialized = true;
        UpdateShellChrome();
        DisplayChanged(this, new());
    }

    internal void UpdateShellChrome()
    {
        if (!shellInitialized || disposed) return;
        var active = ViewModel.State?.ActiveClipId;
        Tabs.Sync(ViewModel.Clips, active);
        if (askScope != active)
        {
            scopeInstructions[askScope ?? ""] = ShellAsk.Text;
            askScope = active;
            ShellAsk.Text = scopeInstructions.GetValueOrDefault(active ?? "", "");
        }
        var clip = ViewModel.Clips.FirstOrDefault(clip => clip.Id == active);
        AutomationProperties.SetHelpText(Commands, clip is null ? "Full take" : $"Clip {clip.Number}: {clip.Title}");
        TightenCommand.IsEnabled = ShellEditable && (ViewModel.Summary.CanCutFillers || ViewModel.Summary.CanTighten);
        MakeClipCommand.IsEnabled = ShellEditable && ViewModel.HasSelection;
        AskButton.IsEnabled = ShellJobAvailable(ShellJob.Rewrite);
        HookCommand.IsEnabled = ShellJobAvailable(ShellJob.Hook);
        UpdateMakeItCommand();
        ToolTipService.SetToolTip(HookCommand, "Find hooks in the full take");
        ShellAsk.IsEnabled = ShellEditable && ViewModel.HasTranscript;
        UpdateFindClips();
        UpdateExport();
    }

    private ShellJobRequest ShellRequest(ShellJob job, string instruction = "")
    {
        var active = job is ShellJob.Hook or ShellJob.FindClips ? null : ViewModel.State?.ActiveClipId;
        var clip = ViewModel.Clips.FirstOrDefault(clip => clip.Id == active);
        var selection = job == ShellJob.Rewrite && ViewModel.HasSelection;
        var first = selection ? ViewModel.SelectionStart : clip is null ? 0 : ViewModel.Index(clip.Clip.StartWordId);
        var last = selection ? ViewModel.SelectionEnd : clip is null ? ViewModel.Words.Count - 1 : ViewModel.Index(clip.Clip.EndWordId);
        return new(job, ViewModel.Project, active, ViewModel.Words.Skip(Math.Max(0, first)).Take(Math.Max(0, last - first + 1)).Select(word => word.Id).ToArray(), instruction);
    }

    private bool ShellJobAvailable(ShellJob job)
    {
        if (!ShellReady || ViewModel.Busy) return false;
        if (job == ShellJob.Export && ViewModel.ExportBlocked(demo, MediaPath is null || media is null, ViewModel.State?.ActiveClipId) is not null) return false;
        if (job != ShellJob.Export && !ShellEditable) return false;
        if (job is ShellJob.FindClips or ShellJob.Hook && !ViewModel.CanFindClips) return false;
        var request = ShellRequest(job, ShellAsk.Text);
        if (shellJobs is { } bindings) return bindings.Available(request);
        return job switch
        {
            ShellJob.Rewrite => ShellEditable && ViewModel.HasTranscript,
            ShellJob.FindClips => ViewModel.CanFindClips,
            ShellJob.Export => ViewModel.ExportBlocked(demo, MediaPath is null || media is null, request.ClipId) is null,
            _ => false
        };
    }

    private async Task OpenShellJobAsync(ShellJob job, string instruction = "", FrameworkElement? anchor = null)
    {
        if (job == ShellJob.Export) { await OpenExportTargetAsync(ViewModel.State?.ActiveClipId); return; }
        if (!ShellJobAvailable(job)) return;
        var request = ShellRequest(job, instruction);
        if (shellJobs is { } bindings)
        {
            if (bindings.Available(request)) await bindings.OpenAsync(request);
            return;
        }
        switch (job)
        {
            case ShellJob.Rewrite:
                if (!ViewModel.HasSelection && request.WordIds.Count > 0)
                {
                    ViewModel.Select(ViewModel.Index(request.WordIds[0]));
                    ViewModel.Select(ViewModel.Index(request.WordIds[^1]), true);
                }
                await OpenRewriteAsync(false, instruction);
                break;
            case ShellJob.FindClips: await FindClips.ShowAsync(anchor ?? (FindClipsCommand.IsInOverflow ? Commands : FindClipsCommand)); break;
        }
    }

    private Task OpenExportTargetAsync(string? clipId) => RunAsync(async () =>
    {
        if (!ShellReady) return;
        if (ViewModel.ExportBlocked(demo, MediaPath is null || media is null, clipId) is { } reason)
        {
            if (ViewModel.Notice.Length == 0) ViewModel.Notice = reason;
            Transcript.Announce(reason);
            return;
        }
        if (shellJobs is { } bindings)
        {
            var target = ViewModel.Clips.FirstOrDefault(clip => clip.Id == clipId);
            var first = target is null ? 0 : ViewModel.Index(target.Clip.StartWordId);
            var last = target is null ? ViewModel.Words.Count - 1 : ViewModel.Index(target.Clip.EndWordId);
            var request = ShellRequest(ShellJob.Export) with { ClipId = clipId,
                WordIds = ViewModel.Words.Skip(Math.Max(0, first)).Take(Math.Max(0, last - first + 1)).Select(word => word.Id).ToArray() };
            if (bindings.Available(request)) await bindings.OpenAsync(request);
        }
        else await ExportAsync(clipId);
    }, "Export");

    /// <summary>A row's "Captions": the right column shows, and focus goes to the open scope's Captions panel.</summary>
    internal void ShowCaptions()
    {
        if (Viewer.IsChecked != true) SetViewerVisible(true);
        captions?.FocusTarget.Focus(FocusState.Programmatic);
    }

    internal IReadOnlyList<ShellCommand> ShellCommands()
    {
        var blocked = ViewModel.IsReadOnly ? "Locate the original video first. Your edits are safe."
            : ViewModel.IsLeaving ? "The project is closing." : "Finish the current task first.";
        ShellCommand Command(string id, string title, string shortcut, Func<bool> available, Action action, string? reason = null) =>
            new(id, title, shortcut, () => ShellReady && available(), action, reason ?? blocked);
        return [
            Command("scope.full", "Open Full take", "Ctrl+2", () => true, () => owner.ShowScope(null)),
            Command("clip.make", "Make clip from selection", "Ctrl+Alt+K", () => ShellEditable && ViewModel.HasSelection, MakeClipAndReveal, "Select transcript words in an editable project first."),
            Command("edit.undo", "Undo", "Ctrl+Z", () => ShellEditable && ViewModel.CanUndo, ViewModel.Undo),
            Command("edit.redo", "Redo", "Ctrl+Y", () => ShellEditable && ViewModel.CanRedo, ViewModel.Redo),
            Command("edit.tighten", "Tighten scope (local)", "", () => ShellEditable && (ViewModel.Summary.CanCutFillers || ViewModel.Summary.CanTighten), TightenScope),
            Command("edit.fillers", "Cut fillers", "Ctrl+Shift+U", () => ShellEditable && ViewModel.Summary.CanCutFillers, () => FillersClicked(this, new())),
            Command("edit.pauses", "Tighten pauses", "Ctrl+Shift+P", () => ShellEditable && ViewModel.Summary.CanTighten, () => PausesClicked(this, new())),
            Command("edit.restore", "Restore cuts", "Ctrl+Shift+R", () => ShellEditable && ViewModel.Summary.HasEdits, () => RestoreClicked(this, new())),
            Command("job.rewrite", "Rewrite…", "Ctrl+R", () => ShellJobAvailable(ShellJob.Rewrite), () => _ = RunAsync(() => OpenShellJobAsync(ShellJob.Rewrite, ShellAsk.Text), "Rewrite"), "Rewrite needs an editable transcript and the current right-panel capability."),
            Command("clip.makeIt", ViewModel.State?.ActiveClipId is { } makeItClip ? ViewModel.MakeItTitle(makeItClip) : "✦ Make it postable", "",
                () => ViewModel.State?.ActiveClipId is { } clip && ViewModel.CanMakeItPostable(clip), () => MakeItPostable(ViewModel.State!.ActiveClipId!),
                "Open a clip with words to keep, and finish the current task first."),
            Command("clips.makeTop", $"✦ Make top {Math.Min(3, ViewModel.SuggestedClips.Count)} postable", "", () => ViewModel.CanMakeTopPostable, () => MakeTopPostable(),
                "Find clips first, and finish the current task first."),
            Command("job.hook", "Find hooks", "", () => ShellJobAvailable(ShellJob.Hook), () => _ = RunAsync(() => OpenShellJobAsync(ShellJob.Hook), "Hook"), "Transcribe the video and finish the current task first."),
            Command("job.find", "Find clips…", "Ctrl+Shift+K", () => ShellJobAvailable(ShellJob.FindClips), () => _ = RunAsync(() => OpenShellJobAsync(ShellJob.FindClips), "Find clips"), "Transcribe the video and finish the current task first."),
            Command("job.export", ViewModel.State?.ActiveClipId is null ? "Export video…" : "Export clip…", "Ctrl+E", () => ShellJobAvailable(ShellJob.Export), () => _ = RunAsync(() => OpenShellJobAsync(ShellJob.Export), "Export"), ViewModel.ExportBlocked(demo, MediaPath is null || media is null, ViewModel.State?.ActiveClipId)),
            Command("view.cuts", ShowCuts.IsChecked == true ? "Hide cuts" : "Show cuts", "Ctrl+Alt+C", () => ViewModel.HasTranscript, ToggleShellCuts),
            Command("view.timeline", timelineVisible ? "Hide timeline" : "Show timeline", "Ctrl+J", () => true, ToggleShellTimeline),
            Command("view.viewer", Viewer.IsChecked == true ? "Hide viewer" : "Show viewer", "Ctrl+Shift+I", () => true, () => SetViewerVisible(Viewer.IsChecked != true)),
            Command("view.find", "Find transcript words", "Ctrl+F", () => ViewModel.HasTranscript, () => FindClicked(this, new())),
            Command("tab.pin", "Keep preview tab open", "", () => Tabs.Model.ActiveClipId is not null && Tabs.Model.Items.Any(tab => !tab.Pinned), Tabs.PinActive),
            Command("project.saveAs", "Save project as…", "", () => !demo && !ViewModel.IsLeaving && !ViewModel.Busy, () => SaveAsClicked(this, new())),
            Command("project.reveal", "Show project file", "", () => owner.ProjectPath is not null, () => ShowProjectClicked(this, new())),
            Command("project.locate", "Locate original video…", "", () => ViewModel.IsReadOnly && !demo && !ViewModel.Busy, () => _ = LocateAsync())
        ];
    }

    private void TightenScope()
    {
        if (!ShellEditable) return;
        if (ViewModel.ApplyBatch([new EditOperation.CutFillers(), new EditOperation.TightenPauses()]))
            Transcript.Announce("Tightened this scope. Undo restores the cuts.");
    }
    private void HandleShellAskKeyDown(object sender, KeyRoutedEventArgs args)
    {
        if (args.Key != VirtualKey.Enter || !askInput.MaySubmit(askCompositionJustEnded)) return;
        args.Handled = true;
        ShellAskClicked(sender, new());
    }
    internal void ToggleShellCuts() { ShowCuts.IsChecked = ShowCuts.IsChecked != true; DisplayChanged(this, new()); }
    internal void ToggleShellTimeline()
    {
        var inside = InputState.DescendsFrom(FocusManager.GetFocusedElement(XamlRoot) as DependencyObject, TimelineHost);
        timelineVisible = !timelineVisible;
        TimelineHost.Visibility = timelineVisible ? Visibility.Visible : Visibility.Collapsed;
        UpdateTimelineHeight();
        viewerHost?.SetPlayback(ViewModel.SourceTime, preview?.Position.IsPlaying == true, timelineVisible);
        if (!timelineVisible && inside) FocusTranscript();
        owner.RefreshShellChrome();
    }
}
