using VoxClip.Core.Domain.VoiceLab;
using VoxClip.Media.VoiceLab;

namespace VoxClip.App.ViewModels;

/// <summary>The user's own recorded takes in a phrase's one take list (design.md §6.3.8 "Say it myself", voice-lab.md §8.13; Mac
/// <c>ClipTakePlan.addMicrophoneTake</c>). They are free, never chosen automatically (no speaker score), used only by [Use your take],
/// and accepted as Core's <c>recorded</c> segment, with no voice reference or consent record.</summary>
internal sealed partial class RewriteGeneration
{
    private readonly Dictionary<Guid, VoiceLabRecordedPhraseTake> recordedTakes = [];
    private readonly List<VoiceLabTakeRow> recordedRows = [];
    private Guid? recordedSelection;

    /// <summary>The user's own take <paramref name="id"/>; null for a generated take.</summary>
    internal VoiceLabRecordedPhraseTake? RecordedTake(Guid id) => recordedTakes.GetValueOrDefault(id);
    internal bool IsRecorded(Guid id) => recordedTakes.ContainsKey(id);
    /// <summary>Only the user's own takes are in use, or none at all: the footer's Use carries no AI label.</summary>
    internal bool UsesOwnTake => Selected is { } selected && IsRecorded(selected.Id);

    private void Select(Guid? id)
    {
        if (id is { } own && recordedTakes.ContainsKey(own)) { recordedSelection = own; core.SelectTake(null); }
        else { recordedSelection = null; core.SelectTake(id); }
    }
    private VoiceLabTakeScratch? ScratchFor(Guid id) => recordedTakes.TryGetValue(id, out var own) ? own.Scratch : takes?.Scratch(id);

    /// <summary>The phrase's input as planned, for a recording: its window, source, room tone and words to say. It is built with the
    /// phrase's voice and model when they are known; nothing is priced or sent.</summary>
    internal async Task<VoiceLabTakeInput?> RecordingInputAsync(CancellationToken ct)
    {
        if (closed || !current()) return null;
        if (pendingInput is { } pending) return pending;
        if (ReviewedInput is { } reviewed) return reviewed;
        return await buildInput(VoiceId ?? "own", ModelId ?? FixedModelId ?? VoiceLabWordingFit.ModelId, 0, ct);
    }

    /// <summary>Lists the user's own take beside the phrase's other takes, never in place of a generated one. Record again replaces the
    /// previous own take when it is not the one in use. Returns false when the phrase no longer takes it (its scratch is dropped).</summary>
    internal async Task<bool> AddRecordedTakeAsync(VoiceLabRecordedPhraseTake take, VoiceLabTakeInput planned, Guid? replacing)
    {
        if (closed || accepting || IsRunning || !current())
        {
            await take.Scratch.InvalidateAsync();
            return false;
        }
        selectionRevision++;
        if (takes is not null) await takes.Audition.StopAsync();
        KeepEveryTake();
        VoiceLabRecordedPhraseTake? old = null;
        var at = replacing is { } previous && previous != SelectedTakeId ? recordedRows.FindIndex(row => row.Id == previous) : -1;
        var row = take.Row with { Index = at >= 0 ? recordedRows[at].Index : Rows.Select(existing => existing.Index + 1).DefaultIfEmpty(0).Max() };
        var stored = take with { Row = row };
        if (at >= 0)
        {
            recordedTakes.Remove(recordedRows[at].Id, out old);
            takeInputs.Remove(recordedRows[at].Id);
            recordedRows[at] = row;
        }
        else recordedRows.Add(row);
        recordedTakes[row.Id] = stored;
        takeInputs[row.Id] = stored.Input;
        // A phrase with only its own take reviews the phrase as planned.
        if (ReviewedInput is null) { ReviewedInput = planned; ReviewedInputsCurrent = true; }
        reviewEnd ??= VoiceLabTakeRunEnd.Completed;
        Phase = ReviewPhase();
        Announcement = $"Your take for phrase {PhraseNumber} is listed as Take {row.Index + 1}.";
        Notify();
        if (old is not null) await old.Scratch.InvalidateAsync();
        return true;
    }

    private void UseRecordedAnyway(Guid id, DateTimeOffset acceptedAt)
    {
        var at = recordedRows.FindIndex(row => row.Id == id);
        if (at < 0) return;
        var accepted = recordedRows[at].AcceptingJoinAdvisory(acceptedAt);
        recordedRows[at] = accepted;
        recordedTakes[id] = recordedTakes[id] with { Row = accepted };
        Select(id);
    }

    private async Task<bool> RemoveRecordedAsync(Guid id)
    {
        if (!recordedTakes.Remove(id, out var take)) return false;
        recordedRows.RemoveAll(row => row.Id == id);
        takeInputs.Remove(id);
        await take.Scratch.InvalidateAsync();
        return true;
    }

    /// <summary>Use for the user's own take: its audio becomes a project asset and the phrase a <c>recorded</c> segment (Core
    /// <c>VoiceLabRecordedTake</c>). It is free, so nothing is confirmed, and it has no voice reference.</summary>
    private async Task<RewriteAcceptance?> PrepareRecordedAcceptanceAsync(EditorViewModel editor, Core.Domain.Shared.Project project,
        IReadOnlyList<Core.Domain.Editing.EditOperation>? localOperations, VoiceLabTakeRow selected)
    {
        var take = recordedTakes[selected.Id] with { Row = selected };
        var version = revision; var selection = selectionRevision;
        bool Current() => !closed && revision == version && selectionRevision == selection && current() &&
            ReferenceEquals(project, editor.Project) && SelectedTakeId == selected.Id && recordedTakes.ContainsKey(selected.Id);
        accepting = true; Notify();
        try
        {
            if (takes is not null) await takes.Audition.StopAsync();
            var scope = project.Edits.ActiveClipId is { } clipId ? VoiceLabOutputScope.Clip(clipId) : VoiceLabOutputScope.Full;
            var combined = editor.ProjectWithLocalOperations(project, localOperations ?? []);
            var fit = selected.Audio!.Fit.Plan;
            var input = take.Input;
            var window = input.Window with { Start = fit.WindowStartSample / (double)input.SourceSampleRate, End = fit.WindowEndSample / (double)input.SourceSampleRate,
                StartSample = fit.WindowStartSample, EndSample = fit.WindowEndSample };
            VoiceLabRenderContract.ValidatePlacement(combined, scope, window);
            var date = clock.GetUtcNow();
            var published = await Task.Run(() => MicrophoneTakeMaker.Publish(take, date, lifetime.Token), lifetime.Token);
            if (!Current()) return null;
            var candidate = VoiceLabRecordedTake.Candidate(selected, input, published, take.Model, date, VideoChoice);
            var segment = VoiceLabRecordedTake.Segment(Guid.NewGuid().ToString("D"), candidate, input, fit);
            return new(segment, published.Assets, null, Current);
        }
        catch (OperationCanceledException) { }
        catch (Exception error) when (error is not OutOfMemoryException) { if (!closed && revision == version) { Problem = RewriteSession.Refusal(error); Announcement = Problem; } }
        finally { accepting = false; Notify(); }
        return null;
    }
}
