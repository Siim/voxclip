using System.Globalization;
using VoxClip.Core.Domain.VoiceLab;
using VoxClip.Core.Services.Media;
using VoxClip.Media.Audio;
using VoxClip.Media.VoiceLab;

namespace VoxClip.App.ViewModels;

internal sealed record RewriteTakeAccess(VoiceLabAudition Audition, Func<Guid, VoiceLabTakeScratch?> Scratch,
    Func<Guid, Task> Reject, Func<Guid, DateTimeOffset, CancellationToken, Task<(VoiceLabPublishedTake Take, VoiceConsentRecord Consent)>> Publish);

internal sealed partial class RewriteGeneration
{
    private readonly HashSet<Guid> rejected = [];
    private readonly HashSet<Guid> autoplayed = [];
    private RewriteTakeAccess? takes;
    private bool outputChecked;
    private bool refreshingOutput;
    private bool accepting;
    private bool runStarted;
    private long selectionRevision;
    private long outputRevision;
    private VoiceLabTakeRunEnd? reviewEnd;
    internal Guid? BestTakeId { get; private set; }
    internal VoiceLabTakeRow? Selected => Rows.FirstOrDefault(row => row.Id == SelectedTakeId);
    internal VoiceLabVideoMode? VideoChoice { get; private set; }
    internal bool ReadyToAccept => !closed && !accepting && !IsRunning && current() && ReviewedInputsCurrent &&
        reviewEnd is VoiceLabTakeRunEnd.Completed or VoiceLabTakeRunEnd.EarlyStop &&
        Phase == RewriteGenerationPhase.ReadyToAccept && Selected is { Selectable: true } selected && takes?.Scratch(selected.Id)?.IsValid == true;
    internal string AcceptTitle => "Use Take " + ((Selected?.Index ?? 0) + 1).ToString(CultureInfo.InvariantCulture);
    internal VoiceLabAuditionState? Audition => takes?.Audition.Snapshot;
    internal bool CanPlay => !closed && !accepting && !IsRunning && current() && outputChecked && !refreshingOutput &&
        Audition?.CanPlay == true && reviewEnd is VoiceLabTakeRunEnd.Completed or VoiceLabTakeRunEnd.EarlyStop;
    internal bool CanRetime => false;
    internal bool CanPlayTake(Guid id) => CanPlay && Rows.Any(row => row.Id == id && row.Selectable) && takes?.Scratch(id)?.IsValid == true;
    internal string RetimeCopy => "Retimed source video is not available in this build. Re-record this sentence instead.";
    internal string LengthCopy => Selected is { Audio.Fit: VoiceLabFitResult.ChangedDuration change } row
        ? $"Take {row.Index + 1} runs {Math.Abs(change.ResidualSeconds).ToString("F1", CultureInfo.InvariantCulture)} s {(change.ResidualSeconds >= 0 ? "longer" : "shorter")} than the words it replaces. Choose how the video keeps up." : "";

    internal static async Task PausePreviewAsync(IPreviewEngine? preview, CancellationToken ct)
    {
        ct.ThrowIfCancellationRequested();
        if (preview is not null) await preview.PauseAsync(ct);
    }
    internal Task PendingSelectionChange { get; private set; } = Task.CompletedTask;
    internal Task SelectionChangedAsync(string selection) => PendingSelectionChange = takes?.Audition.SelectionChangedAsync(selection) ?? Task.CompletedTask;
    internal async Task ConfigureTakesAsync(RewriteTakeAccess access)
    {
        if (closed || takes is not null) throw new InvalidOperationException("Take playback already configured or closed.");
        takes = access;
        access.Audition.Changed += AuditionChanged;
        await RefreshOutputAsync();
    }
    private void AuditionChanged(object? sender, EventArgs args) => _ = onUi(() =>
    {
        if (closed) return;
        var id = takes?.Audition.Snapshot is { IsPlaying: true } state ? state.TakeId : null;
        if (id is null || core.Rows.Any(row => row.Id == id)) core.AuditionTake(id);
        Notify();
    });
    internal async Task RefreshOutputAsync()
    {
        if (closed || takes is null) return;
        var version = ++outputRevision;
        selectionRevision++;
        refreshingOutput = true; outputChecked = false; Notify();
        try
        {
            await takes.Audition.StopAsync();
            await takes.Audition.RefreshAvailabilityAsync(lifetime.Token);
            await onUi(() => { if (version == outputRevision) { outputChecked = true; refreshingOutput = false; Notify(); } });
        }
        catch (OperationCanceledException) when (closed) { }
        catch (ObjectDisposedException) when (closed) { }
    }
    private void FinishTakes(VoiceLabTakeRunResult result)
    {
        reviewEnd = result.End;
        VideoChoice = null;
        BestTakeId = TakeRowPresentation.Preselect(result, rejected);
        core.SelectTake(BestTakeId);
        Phase = result.End switch
        {
            VoiceLabTakeRunEnd.Cancelled or VoiceLabTakeRunEnd.Invalidated => RewriteGenerationPhase.Cancelled,
            VoiceLabTakeRunEnd.Fatal => RewriteGenerationPhase.Failed,
            _ => ReviewPhase()
        };
        Announcement = BestTakeId is null ? TakeRowPresentation.NonePassed :
            TakeRowPresentation.Completion(Rows.Count, Selected is { Fits: true } row ? row.Index + 1 : null, Rows.Count(row => !row.Selectable));
        Notify();
    }
    internal async Task<bool> SelectTakeAsync(Guid id)
    {
        if (closed || accepting || IsRunning || !current() || reviewEnd is not (VoiceLabTakeRunEnd.Completed or VoiceLabTakeRunEnd.EarlyStop) ||
            Rows.FirstOrDefault(row => row.Id == id) is not { Selectable: true }) return false;
        if (SelectedTakeId == id) return true;
        var version = ++selectionRevision;
        if (takes is not null) await takes.Audition.TakeChangedAsync(id);
        if (closed || version != selectionRevision || !current() || !Rows.Any(row => row.Id == id)) return false;
        core.SelectTake(id); VideoChoice = null; Phase = ReviewPhase(); Notify();
        return true;
    }
    internal async Task PlayTakeAsync(Guid id)
    {
        if (takes is null || closed || accepting || IsRunning || !current()) return;
        if (takes.Audition.Snapshot is { IsPlaying: true } playing && playing.TakeId == id)
        { await takes.Audition.StopAsync(); return; }
        if (!await SelectTakeAsync(id)) return;
        var version = selectionRevision;
        try
        {
            await takes.Audition.RefreshAvailabilityAsync(lifetime.Token);
            if (closed || version != selectionRevision || SelectedTakeId != id || !current()) return;
            outputChecked = true;
            if (takes.Audition.Snapshot.CanPlay && takes.Scratch(id) is { IsValid: true } scratch)
                await takes.Audition.PlayAsync(scratch, id, id.ToString("D"), lifetime.Token);
        }
        catch (OperationCanceledException) { }
        catch (Exception error) when (error is not OutOfMemoryException) { if (!closed) Problem = RewriteSession.Refusal(error); }
        Notify();
    }
    internal async Task RejectTakeAsync(Guid id)
    {
        if (closed || accepting || IsRunning || Rows.FirstOrDefault(row => row.Id == id) is not { Selectable: true } row) return;
        selectionRevision++;
        if (takes is not null)
        {
            await takes.Audition.StopAsync();
            await takes.Audition.RejectAsync(id);
            await takes.Reject(id);
        }
        if (closed) return;
        rejected.Add(id);
        BestTakeId = TakeRowPresentation.Preselect(new(Rows, reviewEnd ?? VoiceLabTakeRunEnd.Invalidated), rejected);
        if (SelectedTakeId == id) { core.SelectTake(BestTakeId); VideoChoice = null; }
        Phase = ReviewPhase();
        Announcement = Selected is { } next ? $"Rejected Take {row.Index + 1}. Take {next.Index + 1} selected." : TakeRowPresentation.NonePassed;
        Notify();
    }
    internal bool ChooseVideo(VoiceLabVideoMode choice)
    {
        if (closed || accepting || Phase != RewriteGenerationPhase.LengthChanged || Selected is not { Selectable: true } ||
            choice != VoiceLabVideoMode.Retimed || !CanRetime) return false;
        VideoChoice = choice; Phase = ReviewPhase(); Notify(); return true;
    }
    internal async Task<bool> AcceptAsync(EditorViewModel editor, IReadOnlyList<Core.Domain.Editing.EditOperation>? localOperations = null)
    {
        if (!ReadyToAccept || takes is null || ReviewedInput is not { } input || Selected is not { } selected) return false;
        var version = revision; var project = editor.Project; var selection = selectionRevision;
        accepting = true; Notify();
        try
        {
            await takes.Audition.StopAsync();
            List<VoiceLabCandidate> candidates = []; List<VoiceLabAsset> assets = [];
            VoiceLabVoiceReference? voice = null; int? selectedIndex = null;
            var date = clock.GetUtcNow();
            foreach (var row in Rows.Where(row => row.Selectable && (row.Fits || row.Id == selected.Id) &&
                row.Audio!.Fit.Plan.WindowStartSample == selected.Audio!.Fit.Plan.WindowStartSample &&
                row.Audio.Fit.Plan.WindowEndSample == selected.Audio.Fit.Plan.WindowEndSample))
            {
                var (published, record) = await takes.Publish(row.Id, date, lifetime.Token);
                if (closed || revision != version || selectionRevision != selection || !current() || !ReferenceEquals(project, editor.Project)) return false;
                var candidate = VoiceLabRecipeBuilder.Candidate(row, input, published, record, date, row.Id == selected.Id ? VideoChoice : null);
                if (row.Id == selected.Id) selectedIndex = candidates.Count;
                candidates.Add(candidate);
                foreach (var asset in published.Assets)
                {
                    if (assets.Any(existing => existing.Id == asset.Id && existing != asset)) throw new VoiceLabException(VoiceLabErrorKind.InvalidAudio);
                    if (!assets.Any(existing => existing.Id == asset.Id)) assets.Add(asset);
                }
                voice = new(record.RecordId, record.Provider, record.VoiceId!, record.RecordId, record.VoiceName, VoiceLabVoiceStatus.Active);
            }
            if (closed || revision != version || selectionRevision != selection || !current() || selectedIndex is null || voice is null) return false;
            var segment = VoiceLabRecipeBuilder.Segment(Guid.NewGuid().ToString("D"), candidates, selectedIndex.Value, input, selected.Audio!.Fit.Plan);
            return editor.ApplyVoiceLab(new VoiceLabEditCommand.Accept(segment, assets, voice), project, localOperations);
        }
        catch (OperationCanceledException) { }
        catch (Exception error) when (error is not OutOfMemoryException) { if (!closed && revision == version) { Problem = RewriteSession.Refusal(error); Announcement = Problem; } }
        finally { accepting = false; Notify(); }
        return false;
    }
}
