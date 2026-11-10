using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using VoxClip.App.Controls;
using VoxClip.App.Services;
using VoxClip.App.ViewModels;
using VoxClip.Core.Domain.Shared;

namespace VoxClip.App.Pages;

public sealed partial class EditorPage
{
    private Controls.PreviewPane? viewerHost;
    private readonly MediaRelinkBanner relinkBanner = new();
    private PreviewTransportCoordinator? transportCoordinator;
    private bool timelineMaximized;
    private readonly List<Task> retiredRewriteWork = [];

    private void InitializeIntegratedEditor()
    {
        TranscriptionSpendState.Shared.ConfigurePersistence(Path.Combine(App.Services.Data.Root, "transcription-spend.json"));
        transportCoordinator = new(
            token => preview is null ? Task.CompletedTask : preview.PauseAsync(token),
            _ => rewrite?.StopCandidatesAsync() ?? Task.CompletedTask);
        rightContent!.SourcePlaybackRequested += SourcePlaybackRequested;
        viewerHost = new();
        PreviewPane.Children.Remove(PreviewStage);
        PreviewPane.Children.Remove(TransportRow);
        Grid.SetRow(PreviewStage, 0); Grid.SetColumn(PreviewStage, 0);
        Grid.SetRow(TransportRow, 0); Grid.SetColumn(TransportRow, 0);
        viewerHost.Attach(PreviewStage, TransportRow);
        PreviewPane.Children.Add(viewerHost);
        relinkBanner.VerticalAlignment = VerticalAlignment.Top;
        viewerHost.Children.Add(relinkBanner);
        ConfigureTimelineShell(value => Timeline.ShowsCuts = value);
        Timeline.ShowsCutsChanged += (_, value) =>
        {
            ShowCuts.IsChecked = value;
            Transcript.SetDisplay(value, ShowPauses.IsChecked == true);
            owner.RefreshShellChrome();
        };
        Transcript.ShowCutsChanged += (_, _) =>
        {
            ShowCuts.IsChecked = Transcript.ShowCuts;
            Timeline.ShowsCuts = Transcript.ShowCuts;
        };
        Transcript.ChangeFocused += ordinal => rewrite?.FocusChange(ordinal);
        Timeline.PreferredPanelHeightChanged += (_, _) => UpdateTimelineHeight();
        Timeline.TrackSize = Math.Clamp(App.Services.Get("ui.timelineTrackSize", 1), 0, 2);
        Timeline.TrackSizeChanged += (_, size) => _ = RunAsync(() => App.Services.SetAsync("ui.timelineTrackSize", size, lifetime.Token), "Timeline");
        Timeline.SetPanelCommands(ToggleShellTimeline, () =>
        {
            timelineMaximized = !timelineMaximized;
            UpdateTimelineHeight();
        });
        UpdateTimelineHeight();
        ConfigureShellJobs(new(IntegratedJobAvailable, OpenIntegratedJobAsync, IntegratedStatus));
        TranscriptionSpendState.Shared.Changed += WorkflowStatusChanged;
        WorkflowSpendCache.Changed += WorkflowStatusChanged;
    }

    private bool IntegratedJobAvailable(ShellJobRequest request) => ShellReady && !ViewModel.Busy &&
        ReferenceEquals(request.Snapshot, ViewModel.Project) && (request.Job switch
        {
            ShellJob.Export => ViewModel.ExportBlocked(demo, MediaPath is null || media is null, request.ClipId) is null,
            ShellJob.Rewrite => ShellEditable && ViewModel.HasTranscript && request.WordIds.Count > 0,
            ShellJob.Hook or ShellJob.FindClips => ShellEditable && ViewModel.CanFindClips,
            _ => false
        });

    private async Task OpenIntegratedJobAsync(ShellJobRequest request)
    {
        if (!IntegratedJobAvailable(request)) return;
        SetViewerVisible(true);
        switch (request.Job)
        {
            case ShellJob.Rewrite: await OpenRewriteAsync(false, request.Instruction); break;
            case ShellJob.Hook: await FindClips.ShowAsync(HookCommand, hooks: true); break;
            case ShellJob.FindClips: await FindClips.ShowAsync(FindClipsCommand); break;
            case ShellJob.Export: await ExportAsync(request.ClipId); break;
        }
    }

    private string? IntegratedStatus()
    {
        if (rewrite is { IsOpen: true, IsProposing: true }) return "Rewriting · AI request running";
        if (rewrite?.GenerationWindows.FirstOrDefault(window => window.IsRunning) is { } generation) return generation.ProgressCopy;
        if (FindClips.Running is not null || ViewModel.LlmRuns.IsBusy || ViewModel.Busy) return null;
        var spend = TranscriptionSpendState.Shared;
        if (spend.HasPending || spend.HasActivity)
            return spend.Copy(DateOnly.FromDateTime(DateTime.Now));
        return null;
    }

    private void WorkflowStatusChanged(object? sender, EventArgs args) => DispatcherQueue.TryEnqueue(() =>
    {
        if (!disposed) owner.RefreshShellChrome();
    });

    private void UpdateTimelineHeight()
    {
        TimelineRow.MinHeight = timelineVisible ? Timeline.PreferredPanelHeight : 0;
        TimelineRow.Height = new(timelineVisible ? timelineMaximized
            ? Math.Max(Timeline.PreferredPanelHeight, EditorRoot.ActualHeight * 0.6) : Timeline.PreferredPanelHeight : 0);
    }

    private void SourcePlaybackRequested(object? sender, EventArgs args) => _ = RunAsync(TogglePlaybackAsync, "Preview");
    private Task SourceTransportAsync(Func<CancellationToken, Task> action) => transportCoordinator is { } transport
        ? transport.SourceAsync(action, lifetime.Token) : action(lifetime.Token);

    private void RetireRewrite()
    {
        var previous = rewrite;
        rewrite = null;
        Transcript.AttachProposal(null);
        Transcript.KeepChangeRequested = null;
        Transcript.ExcludeChangeRequested = null;
        previous?.Dispose();
        if (previous is not null) retiredRewriteWork.Add(previous.GenerationCleanup);
    }

    private void AttachRewriteProposal(RewriteSession session)
    {
        session.RevealChange = ordinal => Transcript.FocusChange(ordinal);
        session.EditReviewChange = ordinal => Transcript.OpenThread(ordinal);
        Transcript.AttachProposal(session);
        void Publish(object? sender, EventArgs args)
        {
            if (!ReferenceEquals(rewrite, session)) return;
            Transcript.SetProposal(session.IsOpen ? session.Review : null, session.Source, session.InsertionAfter, session.ChangeStates);
            owner.RefreshShellChrome();
        }
        session.Changed += Publish;
        Transcript.KeepChangeRequested = ordinal => session.KeepChange(ordinal);
        Transcript.ExcludeChangeRequested = ordinal => session.UndoChange(ordinal);
        // Keep and Undo move the focus to the next waiting change; "Kept change {i}" is what Narrator reads, not the move.
        session.ReviewFocusMoved = ordinal => Transcript.FocusChange(ordinal, announce: false);
        Publish(this, EventArgs.Empty);
    }

}
