using System.Globalization;
using VoxClip.Core.Domain.VoiceLab;
using VoxClip.Core.Services.Media;
using VoxClip.Media.Audio;
using VoxClip.Media.VoiceLab;

namespace VoxClip.App.ViewModels;

internal sealed record RewriteTakeAccess(VoiceLabAudition Audition, Func<Guid, VoiceLabTakeScratch?> Scratch,
    Func<Guid, Task> Reject, Func<Guid, DateTimeOffset, CancellationToken, Task<(VoiceLabPublishedTake Take, VoiceConsentRecord Consent)>> Publish,
    Func<Guid, CancellationToken, Task<PreparedVoiceLabAsset?>>? PaidAudio = null);

internal sealed record RewriteAcceptance(VoiceLabSegment Segment, IReadOnlyList<VoiceLabAsset> Assets,
    VoiceLabVoiceReference Voice, Func<bool> IsCurrent);

internal sealed partial class RewriteGeneration
{
    private readonly HashSet<Guid> rejected = [];
    private readonly HashSet<Guid> autoplayed = [];
    private RewriteTakeAccess? takes;
    private bool outputChecked;
    private bool refreshingOutput;
    private bool accepting;
    private bool runStarted;
    private bool runInputRecorded;
    private readonly Dictionary<Guid, VoiceLabTakeInput> takeInputs = [];
    /// <summary>The input a take was made from: its text, tags and window. Null for a take this window did not make.</summary>
    internal VoiceLabTakeInput? InputFor(Guid id) => takeInputs.GetValueOrDefault(id);
    private long selectionRevision;
    private Guid? explicitSelection;
    private long outputRevision;
    private VoiceLabTakeRunEnd? reviewEnd;
    private PreviewTransportCoordinator? transport;
    internal void ConfigureTransport(PreviewTransportCoordinator? coordinator) => transport = coordinator;
    internal Guid? BestTakeId { get; private set; }
    internal VoiceLabTakeRow? Selected => Rows.FirstOrDefault(row => row.Id == SelectedTakeId);
    internal VoiceLabVideoMode? VideoChoice { get; private set; }
    internal bool ReadyToAccept => !closed && !accepting && !IsRunning && current() && ReviewedInputsCurrent &&
        reviewEnd is VoiceLabTakeRunEnd.Completed or VoiceLabTakeRunEnd.EarlyStop &&
        Phase == RewriteGenerationPhase.ReadyToAccept && Selected is { Selectable: true, RequiresJoinAdvisoryAcceptance: false } selected && takes?.Scratch(selected.Id)?.IsValid == true;
    internal string AcceptTitle => "Use Take " + ((Selected?.Index ?? 0) + 1).ToString(CultureInfo.InvariantCulture);
    internal VoiceLabAuditionState? Audition => takes?.Audition.Snapshot;
    internal int PhraseNumber { get; set; } = 1;
    internal bool CanPlay => !closed && !accepting && !IsRunning && current() && outputChecked && !refreshingOutput &&
        Audition?.CanPlay == true && reviewEnd is VoiceLabTakeRunEnd.Completed or VoiceLabTakeRunEnd.EarlyStop or VoiceLabTakeRunEnd.Fatal;
    /// <summary>The selected take's changed-duration choices (Mac VoiceLabVideoDurationOptions); null without a take.</summary>
    internal VoiceLabVideoDurationOptions? VideoOptions => Selected is { } row
        ? new(row, ReviewedInput?.SourceSampleRate ?? 48_000) : null;
    internal bool CanRetime => Selected is { Fits: false } && VideoOptions?.Allows(VoiceLabVideoMode.Retimed) == true;
    internal bool CanCut => Selected is { Fits: false } && VideoOptions?.Allows(VoiceLabVideoMode.Cut) == true;
    internal bool NeedsShorterWording => Selected is { Fits: false } && !CanRetime && !CanCut && !IsRunning;
    internal bool CanPlayTake(Guid id) => CanPlay && Rows.FirstOrDefault(row => row.Id == id) is { Stopped: false } row &&
        (row.Audio is not null ? takes?.Scratch(id)?.IsValid == true : row.Generated is not null && takes?.PaidAudio is not null);
    internal bool CanUseTakeAnyway(Guid id) => !closed && !accepting && !IsRunning && current() &&
        reviewEnd is VoiceLabTakeRunEnd.Completed or VoiceLabTakeRunEnd.EarlyStop &&
        Rows.FirstOrDefault(row => row.Id == id) is { Selectable: true, HasJoinAdvisory: true } && takes?.Scratch(id)?.IsValid == true;
    /// <summary>Use anyway shows only where it can act (Mac smokereal): a passing take whose join still needs listening, not the
    /// take already used, and only when some video duration can carry it.</summary>
    internal bool UseAnywayCanAct(VoiceLabTakeRow row) => row.Selectable && row.RequiresJoinAdvisoryAcceptance && row.Id != SelectedTakeId && DurationAvailable(row);
    internal bool ShowsUseAnyway(Guid id) => CanUseTakeAnyway(id) && Rows.FirstOrDefault(row => row.Id == id) is { } row && UseAnywayCanAct(row);
    internal string KeepSourceCopy => VideoOptions?.UnchangedUnavailableReason ??
        (VideoOptions is { AddedPauseSeconds: > 0 } options
            ? $"Adds {options.AddedPauseSeconds.ToString("F1", CultureInfo.InvariantCulture)} s of natural pauses in your room's sound. Speech keeps its pace."
            : "Uses the verified silence-only fit. Speech is never stretched.");
    internal string CutCopy => $"Removes {(VideoOptions?.RemovedVideoSeconds ?? 0).ToString("F1", CultureInfo.InvariantCulture)} s of video at a pause, like a vlog jump cut. Speech keeps its pace.";
    internal string RetimeCopy => VideoOptions?.ChangedUnavailableReason ??
        $"Keeps this take's natural speech timing, plays source video at {(VideoOptions?.RetimeFactor ?? 1).ToString("F2", CultureInfo.InvariantCulture)}× and crops in 1.12×. Nothing is sent.";
    internal string LengthCopy => Selected is { Audio.Fit: VoiceLabFitResult.ChangedDuration change } row
        ? $"Take {row.Index + 1} runs {Math.Abs(change.ResidualSeconds).ToString("F1", CultureInfo.InvariantCulture)} s {(change.ResidualSeconds >= 0 ? "longer" : "shorter")} than the words it replaces. Choose how the video keeps up." : "";

    internal static async Task PausePreviewAsync(IPreviewEngine? preview, CancellationToken ct)
    {
        ct.ThrowIfCancellationRequested();
        if (preview is not null) await preview.PauseAsync(ct);
    }
    internal Task PendingSelectionChange { get; private set; } = Task.CompletedTask;
    internal async Task StopForSourceAsync()
    {
        selectionRevision++;
        if (takes is not null) await takes.Audition.StopAsync();
    }
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
        BestTakeId = result.End is VoiceLabTakeRunEnd.Completed or VoiceLabTakeRunEnd.EarlyStop && !LeftOut ? AutomaticTake()?.Id : null;
        var retained = explicitSelection is { } chosen && Rows.Any(row => row.Id == chosen && row.Selectable && !row.RequiresJoinAdvisoryAcceptance) ? explicitSelection : null;
        core.SelectTake(retained ?? BestTakeId);
        AutoChooseVideo();
        Phase = result.End switch
        {
            VoiceLabTakeRunEnd.Cancelled or VoiceLabTakeRunEnd.Invalidated => RewriteGenerationPhase.Cancelled,
            VoiceLabTakeRunEnd.Fatal => RewriteGenerationPhase.Failed,
            _ => ReviewPhase()
        };
        Announcement = !Rows.Any(row => row.Selectable) ? TakeRowPresentation.NonePassed :
            TakeRowPresentation.Completion(Rows.Count, Selected is { Fits: true, AutomaticallySelectable: true } row ? row.Index + 1 : null, Rows.Count(row => !row.Selectable && !row.Stopped));
        Notify();
    }
    /// <summary>Automatic fixes (voice-lab.md §8.2.2): later runs add their takes beside these, so no paid take is replaced
    /// (Mac <c>ClipTakePlan.keepsEveryTake</c>).</summary>
    internal bool KeepsEveryTake { get; private set; }
    internal void KeepEveryTake()
    {
        KeepsEveryTake = true;
        core.KeepsEarlierTakes = true;
        if (takeRunner is VoxClip.Media.VoiceLab.VoiceLabTakeRun run) run.KeepsEarlierTakes = true;
    }
    /// <summary>The phrase keeps its original words (Keep original words, or the last automatic round): no take is used and
    /// every take stays listed (Mac <c>ClipTakePlan.leaveOut</c>). <see cref="Restore"/> undoes it.</summary>
    internal bool LeftOut { get; private set; }
    internal bool LeaveOut()
    {
        if (closed || accepting || IsRunning || LeftOut) return false;
        selectionRevision++;
        if (takes is not null) _ = takes.Audition.StopAsync();
        LeftOut = true; explicitSelection = null; BestTakeId = null; core.SelectTake(null); VideoChoice = null;
        Phase = ReviewPhase(); Notify();
        return true;
    }
    /// <summary>Undo of <see cref="LeaveOut"/>: the automatic take is used again, if there is one.</summary>
    internal bool Restore()
    {
        if (closed || !LeftOut) return false;
        LeftOut = false;
        BestTakeId = AutomaticTake()?.Id;
        core.SelectTake(BestTakeId); VideoChoice = null; AutoChooseVideo();
        Phase = ReviewPhase(); Notify();
        return true;
    }
    /// <summary>The slot the take was made for: its window's source length, in seconds.</summary>
    internal double? Slot(VoiceLabTakeRow row) => (InputFor(row.Id) ?? ReviewedInput)?.Window is { } window ? window.End - window.Start : null;
    /// <summary>A take's fitted length, passing or not (a failed take is measured from its own fit).</summary>
    internal static double? Length(VoiceLabTakeRow row) => row.Audio is { SampleRate: > 0 } audio ? audio.Fit.Plan.OutputFrames / (double)audio.SampleRate : null;
    private VoiceLabVideoDurationOptions Options(VoiceLabTakeRow row) =>
        new(row.Audio?.Fit, (InputFor(row.Id) ?? ReviewedInput)?.SourceSampleRate ?? 48_000, row.Audio?.SampleRate ?? 0);
    /// <summary>Mac <c>lengthFits</c>: keep source or a cut carries the take, selected or not.</summary>
    internal bool LengthFits(VoiceLabTakeRow row) => Options(row) is var options && (options.Allows(VoiceLabVideoMode.Source) || options.Allows(VoiceLabVideoMode.Cut));
    /// <summary>Mac <c>durationAvailable</c>: some video duration (keep source, cut or match) carries this passing take.</summary>
    internal bool DurationAvailable(VoiceLabTakeRow row) => row.Selectable && Options(row) is var options &&
        (options.Allows(VoiceLabVideoMode.Source) || options.Allows(VoiceLabVideoMode.Cut) || options.Allows(VoiceLabVideoMode.Retimed));
    /// <summary>The order passing takes are offered in (design.md R2, Mac <c>ranked</c>): one a video duration can carry first,
    /// the best score among those, else the one closest to the slot.</summary>
    internal IReadOnlyList<VoiceLabTakeRow> Ranked(IEnumerable<VoiceLabTakeRow> candidates) => candidates
        .Select(row => (Row: row, Usable: DurationAvailable(row), Distance: Length(row) is { } length && Slot(row) is { } slot ? Math.Abs(length - slot) : double.PositiveInfinity,
            Score: row.Score ?? 0))
        .OrderByDescending(item => item.Usable).ThenBy(item => item.Usable ? -item.Score : item.Distance)
        .ThenBy(item => item.Usable ? item.Distance : -item.Score).ThenBy(item => item.Row.Index).Select(item => item.Row).ToArray();
    /// <summary>The take chosen automatically (Mac <c>ClipTakePlan.automaticTake</c>): passing takes with no join to listen to and a
    /// measured voice, never a rejected one, ranked by <see cref="Ranked"/>.</summary>
    internal VoiceLabTakeRow? AutomaticTake() => Ranked(Rows.Where(row => row.AutomaticallySelectable && !rejected.Contains(row.Id) &&
        !beforeExpression.Contains(row.Id) && row.Qa?.SpeakerScore is { } score && double.IsFinite(score))).FirstOrDefault();
    /// <summary>The passing take a phrase with none chosen offers for one click ([Choose Take N], Mac <c>offeredTake</c>): one the
    /// automatic choice may not pick, such as a take whose voice couldn't be measured (ADR-R37). Takes with a join to listen to
    /// are offered by their row's Use anyway instead.</summary>
    internal VoiceLabTakeRow? OfferedTake()
    {
        if (closed || LeftOut || Selected is not null) return null;
        var passing = Rows.Where(row => row.Selectable && !row.RequiresJoinAdvisoryAcceptance && !rejected.Contains(row.Id)).ToArray();
        var current = passing.Where(row => !beforeExpression.Contains(row.Id)).ToArray();
        return Ranked(current.Length > 0 ? current : passing).FirstOrDefault();
    }
    /// <summary>ADR-R37: this phrase's take runs share the Rewrite plan's voice-check session, so a short retry can borrow its
    /// earlier generated speech.</summary>
    internal void ShareVoiceChecks(VoxClip.Media.VoiceLab.VoiceLabVoiceCheckSession checks, int phrase)
    {
        if (takeRunner is not VoxClip.Media.VoiceLab.VoiceLabTakeRun run) return;
        run.VoiceChecks = checks; run.PhraseId = phrase;
    }
    /// <summary>Whether this phrase's takes are voice-checked by Media's runs (a stub runner checks its own).</summary>
    internal bool PoolsShortTakes => takeRunner is VoxClip.Media.VoiceLab.VoiceLabTakeRun;
    /// <summary>The approved batch's pool for this phrase's run; null after the batch.</summary>
    internal void UseShortTakePool(VoxClip.Media.VoiceLab.VoiceLabShortTakePool? pool)
    {
        if (takeRunner is VoxClip.Media.VoiceLab.VoiceLabTakeRun run) run.ShortTakePool = pool;
    }
    /// <summary>ADR-R37: the batch's pooled voice check settles this phrase's waiting takes. A measured passing take is chosen
    /// automatically as after a run; an unmeasured one waits for [Choose Take N]; a valid explicit choice stays.</summary>
    internal bool ApplyVoiceChecks(IReadOnlyDictionary<Guid, VoiceLabTakeRow> checkedRows)
    {
        if (closed) return false;
        if (takeRunner is VoxClip.Media.VoiceLab.VoiceLabTakeRun run) run.ApplyVoiceChecks(checkedRows);
        if (!core.ApplyVoiceChecks(checkedRows)) return false;
        if (!LeftOut && reviewEnd is VoiceLabTakeRunEnd.Completed or VoiceLabTakeRunEnd.EarlyStop)
        {
            BestTakeId = AutomaticTake()?.Id;
            var retained = explicitSelection is { } chosen && Rows.Any(row => row.Id == chosen && row.Selectable && !row.RequiresJoinAdvisoryAcceptance) ? explicitSelection : null;
            if ((retained ?? BestTakeId) is var target && target != SelectedTakeId) { core.SelectTake(target); VideoChoice = null; }
            AutoChooseVideo();
            Announcement = !Rows.Any(row => row.Selectable) ? TakeRowPresentation.NonePassed :
                TakeRowPresentation.Completion(Rows.Count, Selected is { Fits: true, AutomaticallySelectable: true } row ? row.Index + 1 : null, Rows.Count(row => !row.Selectable && !row.Stopped));
        }
        Phase = ReviewPhase(); Notify();
        return true;
    }
    private readonly HashSet<Guid> beforeExpression = [];
    /// <summary>Takes made before this phrase's expression changed (design.md R2 "Expressions"): listed as "Before expression",
    /// never chosen automatically; a new take with the expression is made beside them.</summary>
    internal bool IsBeforeExpression(Guid id) => beforeExpression.Contains(id);
    internal void MarkBeforeExpression() { beforeExpression.UnionWith(Rows.Select(row => row.Id)); Notify(); }
    /// <summary>The duration choices the selected passing take allows, in the panel's order (keep source, cut, match); a
    /// choice that can't act is never shown.</summary>
    internal IReadOnlyList<VoiceLabVideoMode> ValidVideoChoices => Selected is not { Selectable: true } selected ? []
        : selected.Fits ? [VoiceLabVideoMode.Source]
        : new[] { CanCut ? VoiceLabVideoMode.Cut : (VoiceLabVideoMode?)null, CanRetime ? VoiceLabVideoMode.Retimed : null }
            .Where(mode => mode is not null).Select(mode => mode!.Value).ToArray();
    /// <summary>Mac <c>autoChooseVideo</c>: a selected passing take gets the first valid video duration (cut, then match) at
    /// once; the panel shows it as one line with [Change].</summary>
    private void AutoChooseVideo()
    {
        if (VideoChoice is not null || Selected is not { Selectable: true, Fits: false }) return;
        var valid = ValidVideoChoices;
        VideoChoice = valid.Count > 0 ? valid[0] : null;
    }
    /// <summary>The chosen duration in a few words, for the card's one line.</summary>
    internal string VideoChoiceLine => VideoChoice switch
    {
        VoiceLabVideoMode.Cut => "Video: cut to this take · " + CutCopy,
        VoiceLabVideoMode.Retimed => "Video: matched to this take · " + RetimeCopy,
        _ => Selected is { Fits: true } ? "Video: keeps its duration · " + KeepSourceCopy : ""
    };
    /// <summary>The selected take in one line: its number, length and how the video keeps up.</summary>
    internal string TakeDetail => Selected is not { Audio: not null } selected ? Rows.Count == 0 ? "No take yet." : "No take chosen yet."
        : $"Take {selected.Index + 1} · {(Length(selected) ?? 0).ToString("F1", CultureInfo.InvariantCulture)} s · " +
          (selected.Fits ? "fits" : VideoChoice == VoiceLabVideoMode.Cut ? "video cut to fit" : VideoChoice == VoiceLabVideoMode.Retimed ? "video matched" : "doesn't fit yet");

    internal async Task<bool> SelectTakeAsync(Guid id)
    {
        if (closed || accepting || IsRunning || !current() || reviewEnd is not (VoiceLabTakeRunEnd.Completed or VoiceLabTakeRunEnd.EarlyStop) ||
            Rows.FirstOrDefault(row => row.Id == id) is not { Selectable: true, RequiresJoinAdvisoryAcceptance: false }) return false;
        if (SelectedTakeId == id) { explicitSelection = id; return true; }
        var version = ++selectionRevision;
        if (takes is not null) await takes.Audition.TakeChangedAsync(id);
        if (closed || version != selectionRevision || !current() || !Rows.Any(row => row.Id == id)) return false;
        explicitSelection = id; LeftOut = false; core.SelectTake(id); VideoChoice = null; AutoChooseVideo(); Phase = ReviewPhase(); Notify();
        if (pendingInput is { } input && RetryPace(input) != input.Pace) await InputsChangedAsync(preserveReview: true);
        return true;
    }
    internal async Task<bool> UseTakeAnywayAsync(Guid id)
    {
        if (!CanUseTakeAnyway(id) || takes is null || Rows.FirstOrDefault(row => row.Id == id) is not { } row) return false;
        var version = ++selectionRevision;
        await takes.Audition.TakeChangedAsync(id);
        if (closed || version != selectionRevision || !current() || !Rows.Contains(row)) return false;
        core.UseTakeAnyway(id, clock.GetUtcNow());
        explicitSelection = id; LeftOut = false; VideoChoice = null; AutoChooseVideo(); Phase = ReviewPhase();
        Announcement = TakeRowPresentation.From(row, BestTakeId, PhraseNumber).Copy;
        Notify();
        return true;
    }
    internal async Task PlayTakeAsync(Guid id)
    {
        if (takes is null || closed || accepting || IsRunning || !current() ||
            reviewEnd is not (VoiceLabTakeRunEnd.Completed or VoiceLabTakeRunEnd.EarlyStop or VoiceLabTakeRunEnd.Fatal) ||
            Rows.FirstOrDefault(row => row.Id == id) is not { Stopped: false } row) return;
        if (takes.Audition.Snapshot is { IsPlaying: true } playing && playing.TakeId == id)
        { selectionRevision++; await takes.Audition.StopAsync(); return; }
        if (row.Selectable && !row.HasJoinAdvisory && !await SelectTakeAsync(id)) return;
        var version = ++selectionRevision;
        bool Current() => !closed && !accepting && !IsRunning && version == selectionRevision && current() &&
            Rows.Any(candidate => candidate.Id == id) && (!row.Selectable || row.HasJoinAdvisory || SelectedTakeId == id);
        try
        {
            await takes.Audition.StopAsync();
            await takes.Audition.RefreshAvailabilityAsync(lifetime.Token);
            if (!Current()) return;
            outputChecked = true;
            if (!takes.Audition.Snapshot.CanPlay) return;
            if (row.Audio is not null && takes.Scratch(id) is { IsValid: true } scratch)
            {
                Task Start(CancellationToken token)
                {
                    token.ThrowIfCancellationRequested();
                    return Current() && scratch.IsValid
                        ? takes.Audition.PlayAsync(scratch, id, id.ToString("D"), token) : Task.CompletedTask;
                }
                if (transport is null) await Start(lifetime.Token);
                else await transport.CandidateAsync(Start, lifetime.Token);
            }
            else if (row.Audio is null && row.Generated is not null && takes.PaidAudio is { } prepare)
            {
                var paid = await prepare(id, lifetime.Token);
                if (paid is null) return;
                var transferred = false;
                try
                {
                    Task Start(CancellationToken token)
                    {
                        token.ThrowIfCancellationRequested();
                        if (!Current() || !paid.IsValid) return Task.CompletedTask;
                        transferred = true;
                        return takes.Audition.PlayAsync(paid, id, id.ToString("D"), token);
                    }
                    if (transport is null) await Start(lifetime.Token);
                    else await transport.CandidateAsync(Start, lifetime.Token);
                }
                finally { if (!transferred) await paid.InvalidateAsync(); }
            }
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
        BestTakeId = reviewEnd is VoiceLabTakeRunEnd.Completed or VoiceLabTakeRunEnd.EarlyStop && !LeftOut ? AutomaticTake()?.Id : null;
        if (SelectedTakeId == id) { explicitSelection = null; core.SelectTake(BestTakeId); VideoChoice = null; AutoChooseVideo(); }
        Phase = ReviewPhase();
        Announcement = Selected is { } next ? $"Rejected Take {row.Index + 1}. Take {next.Index + 1} selected." : TakeRowPresentation.NonePassed;
        Notify();
    }
    internal bool ChooseVideo(VoiceLabVideoMode choice)
    {
        if (closed || accepting || Phase is not (RewriteGenerationPhase.LengthChanged or RewriteGenerationPhase.ReadyToAccept) ||
            Selected is not { Selectable: true, Fits: false } || !(choice == VoiceLabVideoMode.Retimed ? CanRetime : choice == VoiceLabVideoMode.Cut && CanCut)) return false;
        VideoChoice = choice; Phase = ReviewPhase(); Notify(); return true;
    }
    internal async Task<bool> AcceptAsync(EditorViewModel editor, IReadOnlyList<Core.Domain.Editing.EditOperation>? localOperations = null)
    {
        var project = editor.Project;
        var prepared = await PrepareAcceptanceAsync(editor, project, localOperations);
        if (prepared is null || !prepared.IsCurrent()) return false;
        var scope = project.Edits.ActiveClipId is { } clipId ? VoiceLabOutputScope.Clip(clipId) : VoiceLabOutputScope.Full;
        var action = project.Edits.ActiveClipId is { } id ? $"Rewrite clip {editor.Clips.First(clip => clip.Id == id).Number}" : "Rewrite full take";
        return editor.ApplyVoiceLab([prepared.Segment], prepared.Assets, prepared.Voice, scope, action, project, localOperations);
    }

    internal async Task<RewriteAcceptance?> PrepareAcceptanceAsync(EditorViewModel editor, Core.Domain.Shared.Project project,
        IReadOnlyList<Core.Domain.Editing.EditOperation>? localOperations = null)
    {
        if (!ReadyToAccept || takes is null || ReviewedInput is not { } reviewed || Selected is not { } selected ||
            !ReferenceEquals(project, editor.Project)) return null;
        var input = InputFor(selected.Id) ?? reviewed;
        VoiceLabTakeInput Made(VoiceLabTakeRow row) => InputFor(row.Id) ?? reviewed;
        var version = revision; var selection = selectionRevision;
        bool Current() => !closed && revision == version && selectionRevision == selection && current() &&
            ReferenceEquals(project, editor.Project) && ReferenceEquals(ReviewedInput, reviewed) && SelectedTakeId == selected.Id;
        accepting = true; Notify();
        try
        {
            await takes.Audition.StopAsync();
            var scope = project.Edits.ActiveClipId is { } clipId ? VoiceLabOutputScope.Clip(clipId) : VoiceLabOutputScope.Full;
            var combined = editor.ProjectWithLocalOperations(project, localOperations ?? []);
            var fit = selected.Audio!.Fit.Plan;
            var window = input.Window with { Start = fit.WindowStartSample / (double)input.SourceSampleRate, End = fit.WindowEndSample / (double)input.SourceSampleRate,
                StartSample = fit.WindowStartSample, EndSample = fit.WindowEndSample };
            VoiceLabRenderContract.ValidatePlacement(combined, scope, window);
            List<VoiceLabCandidate> candidates = []; List<VoiceLabAsset> assets = [];
            VoiceLabVoiceReference? voice = null; int? selectedIndex = null;
            var date = clock.GetUtcNow();
            foreach (var row in Rows.Where(row => row.Selectable && !row.RequiresJoinAdvisoryAcceptance && (row.Fits || row.Id == selected.Id) &&
                Made(row).Text == input.Text && Made(row).RequestText == input.RequestText &&
                row.Audio!.Fit.Plan.WindowStartSample == selected.Audio!.Fit.Plan.WindowStartSample &&
                row.Audio.Fit.Plan.WindowEndSample == selected.Audio.Fit.Plan.WindowEndSample))
            {
                var (published, record) = await takes.Publish(row.Id, date, lifetime.Token);
                if (!Current()) return null;
                var rowInput = Made(row) with { ModelId = row.Receipt?.ModelId ?? input.ModelId, Pace = row.Receipt?.Pace ?? row.Quote?.Synthesis.Review.Pace ?? 1 };
                var candidate = VoiceLabRecipeBuilder.Candidate(row, rowInput, published, record, date, row.Id == selected.Id ? VideoChoice : null);
                if (row.Id == selected.Id) selectedIndex = candidates.Count;
                candidates.Add(candidate);
                foreach (var asset in published.Assets)
                {
                    if (assets.Any(existing => existing.Id == asset.Id && existing != asset)) throw new VoiceLabException(VoiceLabErrorKind.InvalidAudio);
                    if (!assets.Any(existing => existing.Id == asset.Id)) assets.Add(asset);
                }
                voice = new(record.RecordId, record.Provider, record.VoiceId!, record.RecordId, record.VoiceName, VoiceLabVoiceStatus.Active);
            }
            if (!Current() || selectedIndex is null || voice is null) return null;
            var segment = VoiceLabRecipeBuilder.Segment(Guid.NewGuid().ToString("D"), candidates, selectedIndex.Value, input, selected.Audio!.Fit.Plan);
            return new(segment, assets, voice, Current);
        }
        catch (OperationCanceledException) { }
        catch (Exception error) when (error is not OutOfMemoryException) { if (!closed && revision == version) { Problem = RewriteSession.Refusal(error); Announcement = Problem; } }
        finally { accepting = false; Notify(); }
        return null;
    }
}
