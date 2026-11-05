using System.Globalization;
using System.Text.Json;
using VoxClip.Core.Domain.Autopilot;
using VoxClip.Core.Domain.Clips;
using VoxClip.Core.Domain.Editing;
using VoxClip.Core.Domain.Effects;
using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Domain.VoiceLab;
using VoxClip.Core.Services.LLM;

namespace VoxClip.App.ViewModels;

/// <summary>A run of project changes that undo as one step. While <see cref="OwnsEdits"/> is false (the run waits for Claude) the
/// creator's edits are their own steps; a run change after one of them starts a new step under the group's name.</summary>
internal sealed class EditorUndoGroup(string name)
{
    internal string Name { get; } = name;
    /// <summary>The history entry the group pushed; later changes merge into it while it is still on top.</summary>
    internal object? Top { get; set; }
    internal bool OwnsEdits { get; set; } = true;
    /// <summary>An undo or redo landed while it was open.</summary>
    internal bool Interrupted { get; set; }
}

/// <summary>✦ Make it postable (design §6.7), twin of the Mac <c>EditorModel</c> Make it postable extension.</summary>
public sealed partial class EditorViewModel
{
    private EditorUndoGroup? undoGroup;
    /// <summary>The runs, the series and the services.</summary>
    public MakeItController MakeIt { get; } = new();
    /// <summary>A run or its review changed: the panel redraws.</summary>
    public event EventHandler? MakeItChanged;
    /// <summary>A run started: the page shows the Make it postable panel.</summary>
    public event EventHandler? MakeItShown;
    /// <summary>▶ on a review row: the page seeks to this source time and plays.</summary>
    public event EventHandler<double>? MakeItPlayRequested;
    /// <summary>Change on a row the page owns (captions, rename, a phrase): the page opens that control.</summary>
    public event EventHandler<(MakeItRun Run, MakeItRow Row)>? MakeItChangeRequested;
    /// <summary>A question's other answer for the next request, sent once.</summary>
    private string? makeItNote;

    /// <summary>The clip style Make it postable follows.</summary>
    public MakeItStyle MakeItStyle => MakeItStyle.From(project.ClipStyle);

    private void MakeItNotify() => MakeItChanged?.Invoke(this, EventArgs.Empty);

    // MARK: One undo step over a run

    internal void BeginUndoGroup(string name) => undoGroup = new(name);
    internal void EndUndoGroup() => undoGroup = null;
    internal string? UndoGroupName => undoGroup?.Name;

    /// <summary>Every recorded change goes through here: inside an owning group it joins the group's step while that step is on top.</summary>
    private void PushHistory(string? actionName = null)
    {
        redo.Clear();
        if (undoGroup is { OwnsEdits: true } group)
        {
            if (group.Top is not null && undo.TryPeek(out var top) && ReferenceEquals(top, group.Top)) return;
            var entry = CaptureHistory(group.Name);
            group.Top = entry;
            undo.Push(entry);
            return;
        }
        undo.Push(CaptureHistory(actionName));
    }

    /// <summary>Replaces the project as one step named <paramref name="name"/> (or the open group's), rebuilding the edit state.</summary>
    internal bool ReplaceProject(Project next, string name)
    {
        if (isLeaving || IsReadOnly || state is null || ReferenceEquals(next, project)) return false;
        if (EditingEngine.FromProject(next) is not { } nextState) return false;
        CaptionDrag.Cancel();
        PushHistory(name);
        var modifiedAt = now();
        state = nextState;
        project = next with { ModifiedAt = modifiedAt > project.ModifiedAt ? modifiedAt : project.ModifiedAt.AddTicks(1) };
        Refresh();
        return true;
    }

    // MARK: Price

    /// <summary>The planner's limits, read once per shared root: every row's title asks for the cap.</summary>
    private static readonly System.Collections.Concurrent.ConcurrentDictionary<string, ClipAutopilotLimits> makeItLimits = new(StringComparer.Ordinal);

    /// <summary>The click's upfront cap (design §6.7): the voice for up to the planner's rewrite limit on this clip's length, first
    /// takes plus the same again for automatic fixes. Windows generates no music, so the voice is all. Null when nothing can cost
    /// anything: rewording is off, or no voice can be made.</summary>
    public decimal? MakeItCap(string clipId)
    {
        if (MakeIt.Services is not { SharedRoot: { } root, Prices: { } prices } services || !MakeItStyle.Rewrites || !services.VoiceAvailable()) return null;
        if (ClipSpan(clipId) is not { } span) return null;
        try
        {
            var limits = makeItLimits.GetOrAdd(root, path => ClipAutopilotPrompt.Load(path).Limits);
            var words = Words.Skip(span.First).Take(span.Last - span.First + 1).Where(word => word.Kind == WordKind.Word && state?.CutWordIds.Contains(word.Id) != true).ToArray();
            var limit = Math.Min(limits.MaxRewrites * limits.MaxRewriteTextWords, words.Length);
            if (limit <= 0) return null;
            var average = words.Average(word => (double)DisplayText(word).Length);
            var characters = Math.Ceiling(limit * (average + 1));
            var estimate = VoiceLabPricing.Estimate(VoiceLabPricedOperation.ElevenLabsTextToSpeech, VoiceLabWordingFit.ModelId, characters, 1, null, prices);
            return estimate.Usd is > 0 and var usd ? usd * 2 : null;
        }
        catch (Exception exception) when (exception is VoxClipException or VoiceLabException or IOException or JsonException) { return null; }
    }

    /// <summary>"✦ Make it postable · up to $0.42", or without an amount when nothing can cost anything.</summary>
    public string MakeItTitle(string clipId) => MakeItCap(clipId) is { } cap ? "✦ Make it postable · up to " + MakeItController.Dollars(cap) : "✦ Make it postable";

    // MARK: Entry points

    /// <summary>The clip's word span, or null when its words are gone.</summary>
    private (int First, int Last)? ClipSpan(string clipId)
    {
        if (state?.Clips.FirstOrDefault(clip => clip.Id == clipId) is not { } clip) return null;
        var first = Index(clip.StartWordId);
        var last = Index(clip.EndWordId);
        return first >= 0 && last >= first ? (first, last) : null;
    }

    /// <summary>✦ Make it postable can run on this clip: services are set, nothing else runs, and the clip has words to keep.</summary>
    public bool CanMakeItPostable(string clipId)
    {
        if (MakeIt.Services is null || MakeIt.Active is not null || isLeaving || IsReadOnly || Busy || !HasTranscript || ClipSpan(clipId) is not { } span) return false;
        return Words.Skip(span.First).Take(span.Last - span.First + 1).Any(word => word.Kind == WordKind.Word && state?.CutWordIds.Contains(word.Id) != true);
    }

    /// <summary>"✦ Make top 3 postable" can run: two or more suggestions are waiting and nothing else runs.</summary>
    public bool CanMakeTopPostable => MakeIt.Services is not null && MakeIt.Active is null && !isLeaving && !IsReadOnly && !Busy && HasTranscript && SuggestedClips.Count > 0;

    /// <summary>The click: a suggestion is kept first, in the same undo step as everything the run applies. The click approves the
    /// cap shown on the button; the run never spends past it.</summary>
    public bool MakeItPostable(string clipId)
    {
        if (!CanMakeItPostable(clipId) || MakeIt.Services is not { } services) return false;
        var run = new MakeItRun(clipId, MakeItCap(clipId));
        MakeIt.Insert(run);
        BeginUndoGroup("Make it postable");
        if (Clips.FirstOrDefault(clip => clip.Id == clipId)?.IsSuggested == true) KeepForRowAction(clipId);
        undoGroup!.OwnsEdits = false;
        SetScope(clipId);
        MakeItShown?.Invoke(this, EventArgs.Empty);
        MakeItNotify();
        run.Task = PerformAsync(run, services);
        return true;
    }

    /// <summary>The suggestions "✦ Make top 3" takes, best first: the planner's score, else Find Clips' score, then their order.</summary>
    public IReadOnlyList<ClipRow> RankedSuggestions => SuggestedClips
        .OrderByDescending(clip => MakeIt.Score(clip.Id)?.Score ?? clip.Score ?? 0).ThenBy(clip => clip.Number).ToArray();

    /// <summary>"✦ Make top 3 postable": one request plans the best suggestions at once (on three lanes), then each is applied as its
    /// own run: its own cap, its own undo step, kept first. Claude mode passes the video's <paramref name="budget"/>, shared by the runs.</summary>
    public bool MakeTopPostable(int count = 3, MakeItBudget? budget = null)
    {
        if (!CanMakeTopPostable || MakeIt.Services is not { } services || project.Transcript is not { } transcript) return false;
        var ranked = RankedSuggestions.Take(count).Select(clip => (clip.Id, Span: ClipSpan(clip.Id))).Where(item => item.Span is not null)
            .Select(item => (item.Id, Span: new WordSpan(item.Span!.Value.First, item.Span.Value.Last))).ToArray();
        if (ranked.Length == 0) return false;
        MakeIt.SetSeries(ranked.Select(item => item.Id).ToArray(), budget);
        var runs = ranked.Select(item => new MakeItRun(item.Id, budget?.Cap ?? MakeItCap(item.Id), budget)).ToArray();
        foreach (var run in runs.Reverse()) { MakeIt.Insert(run); run.Line("Waiting for Claude…"); }
        MakeItShown?.Invoke(this, EventArgs.Empty);
        MakeItNotify();
        var request = new ClipAutopilotRequest(transcript, project.Edits, new ClipAutopilotMode.Clips(ranked.Select(item => item.Span).ToArray()))
        { CaptionPreference = MakeItStyle.CaptionPreference, Note = MakeItNoteText(), Tone = MakeItPlannerTone() };
        var task = PerformSeriesAsync(runs, ranked.Select(item => item.Span).ToArray(), request, services);
        foreach (var run in runs) run.Task = task;
        MakeIt.SeriesTask = task;
        return true;
    }

    private async Task PerformSeriesAsync(MakeItRun[] runs, WordSpan[] spans, ClipAutopilotRequest request, MakeItServices services)
    {
        try
        {
            ClipAutopilotSeries series;
            using (var linked = CancellationTokenSource.CreateLinkedTokenSource(runs.Select(run => run.Cancellation.Token).ToArray()))
            {
                try { series = await services.Plan(request, Progress(runs), linked.Token); }
                catch (Exception exception) when (Cancelled(exception)) { foreach (var run in runs) run.Phase = MakeItPhase.Stopped; return; }
                catch (Exception exception) when (exception is not OutOfMemoryException)
                {
                    var message = UiError.Message(exception, "Make it postable");
                    foreach (var run in runs) Fail(run, message.Length == 0 ? "Claude couldn't plan these clips. Nothing was changed." : message);
                    return;
                }
            }
            for (var index = 0; index < runs.Length; index++)
            {
                var run = runs[index];
                if (run.Cancelled) { run.Phase = MakeItPhase.Stopped; continue; }
                // A plan may tighten its span; it stays inside the span it was asked for.
                var plan = series.Plans.FirstOrDefault(plan => spans[index].Contains(plan.StartWord) && spans[index].Contains(plan.EndWord));
                if (plan is null) { Fail(run, "Claude couldn't plan this clip. Nothing was changed."); continue; }
                if (IsReadOnly || isLeaving || state?.Clips.Any(clip => clip.Id == run.ClipId) != true) { Fail(run, "This clip changed. Nothing was changed."); continue; }
                MakeIt.ShownClipId = run.ClipId;
                BeginUndoGroup("Make it postable");
                try
                {
                    if (Clips.FirstOrDefault(clip => clip.Id == run.ClipId)?.IsSuggested == true) KeepForRowAction(run.ClipId);
                    SetScope(run.ClipId);
                    await FinishAsync(run, plan, services);
                }
                finally { EndUndoGroup(); }
                if (run.Phase == MakeItPhase.Stopped)
                {
                    foreach (var later in runs.Where(later => later.Running)) later.Phase = MakeItPhase.Stopped;
                    break;
                }
            }
        }
        finally
        {
            foreach (var run in runs.Where(run => run.Running)) run.Phase = MakeItPhase.Stopped;
            MakeIt.SeriesTask = null;
            MakeItNotify();
        }
    }

    private static bool Cancelled(Exception exception) =>
        exception is OperationCanceledException || exception is LlmException { Error.Kind: LlmErrorKind.Cancelled };

    private void Fail(MakeItRun run, string message) { run.Phase = MakeItPhase.Failed; run.Failure = message; run.Line(message); MakeItNotify(); }

    /// <summary>Progress lines from the planner, on each clip's run.</summary>
    private IProgress<ClipAutopilotProgress> Progress(IReadOnlyList<MakeItRun> runs) => new InlineProgress<ClipAutopilotProgress>(progress =>
    {
        switch (progress)
        {
            case ClipAutopilotProgress.PickingMoments: runs[0].Line("Finding the best moments…"); break;
            case ClipAutopilotProgress.Picked picked: runs[0].Line($"Picked {picked.Moments.Count} {(picked.Moments.Count == 1 ? "moment" : "moments")}…"); break;
            case ClipAutopilotProgress.Planning planning when planning.Clip < runs.Count:
                runs[planning.Clip].Line(planning.Of > 1 ? $"Reading clip {planning.Clip + 1} of {planning.Of}…" : "Reading the clip…"); break;
            case ClipAutopilotProgress.Planned planned when planned.Clip < runs.Count:
                runs[planned.Clip].Line(planned.Of > 1 ? $"Planned clip {planned.Clip + 1} of {planned.Of}." : "Planned."); break;
            case ClipAutopilotProgress.Failed failed when failed.Clip < runs.Count:
                runs[failed.Clip].Line(failed.Of > 1 ? $"Clip {failed.Clip + 1} of {failed.Of} couldn't be planned." : "The clip couldn't be planned."); break;
        }
        MakeItNotify();
    });

    /// <summary>Calls back on the caller's thread, unlike <see cref="Progress{T}"/>, so lines land in order.</summary>
    private sealed class InlineProgress<T>(Action<T> report) : IProgress<T>
    {
        public void Report(T value) => report(value);
    }

    /// <summary>Stop: the run ends at its next safe point and keeps what it applied.</summary>
    public void StopMakeIt()
    {
        var running = MakeIt.Running;
        if (running.Count == 0) return;
        foreach (var run in running) { run.Cancelled = true; run.Line("Stopping after this step…"); run.Cancellation.Cancel(); }
        MakeIt.Budget?.Decline();
        MakeItNotify();
    }

    // MARK: The run

    private async Task PerformAsync(MakeItRun run, MakeItServices services)
    {
        try
        {
            run.Line("Reading the clip…");
            MakeItNotify();
            if (MakeItRequest(run.ClipId) is not { } request) { Fail(run, "This clip has no words to plan."); return; }
            ClipAutopilotSeries series;
            try { series = await services.Plan(request, Progress([run]), run.Cancellation.Token); }
            catch (Exception exception) when (Cancelled(exception)) { run.Phase = MakeItPhase.Stopped; return; }
            catch (Exception exception) when (exception is not OutOfMemoryException)
            {
                var message = UiError.Message(exception, "Make it postable");
                Fail(run, message.Length == 0 ? "Claude couldn't plan this clip. Nothing was changed." : message);
                return;
            }
            if (series.Plans.FirstOrDefault() is not { } plan) { Fail(run, "Claude found nothing to keep in this clip. Nothing was changed."); return; }
            await FinishAsync(run, plan, services);
        }
        finally
        {
            EndUndoGroup();
            if (run.Running) run.Phase = MakeItPhase.Stopped;
            MakeItNotify();
        }
    }

    /// <summary>Applies a checked plan as the run's step, inside the undo group the caller opened.</summary>
    private async Task FinishAsync(MakeItRun run, ClipAutopilotPlan plan, MakeItServices services)
    {
        run.Plan = plan;
        MakeIt.Record(plan.Score, plan.Verdict, run.ClipId);
        if (MakeItStopped(run)) { run.Phase = MakeItPhase.Stopped; return; }
        run.Phase = MakeItPhase.Applying;
        if (undoGroup is { } group) group.OwnsEdits = true;
        MakeItNotify();
        await ApplyPlanAsync(plan, run, services);
        if (run.Phase != MakeItPhase.Applying) return;
        var stopped = MakeItStopped(run);
        run.Phase = stopped ? MakeItPhase.Stopped : MakeItPhase.Ready;
        run.Line(stopped ? "Stopped. What was done is kept." : "Ready to post.");
        Announcement?.Invoke(this, stopped ? "Stopped. What was done is kept." : $"Ready to post. Score {plan.Score} of 10.");
        MakeItNotify();
    }

    /// <summary>Stop was pressed, or an undo landed while the run held its step: the run ends at its next safe point.</summary>
    private bool MakeItStopped(MakeItRun run)
    {
        if (undoGroup?.Interrupted == true) run.Cancelled = true;
        return run.Cancelled;
    }

    /// <summary>The planner's request for one clip: its span, the project's edits, the style's captions, note and tone.</summary>
    public ClipAutopilotRequest? MakeItRequest(string clipId)
    {
        if (project.Transcript is not { } transcript || ClipSpan(clipId) is not { } span) return null;
        return new(transcript, project.Edits, new ClipAutopilotMode.Clip(new(span.First, span.Last)))
        { CaptionPreference = MakeItStyle.CaptionPreference, Note = MakeItNoteText(), Tone = MakeItPlannerTone() };
    }

    /// <summary>The planner's tone (ai.md §16.3): the style's. Auto offers the catalogue tones; a tone this PC does not know plans as Auto.</summary>
    public ClipAutopilotTone? MakeItPlannerTone()
    {
        if (MakeIt.Services?.Tones is not { } catalog) return null;
        return MakeItStyle.Tone switch
        {
            "as-said" => new ClipAutopilotTone.AsSaid(),
            null => new ClipAutopilotTone.Auto(catalog.Tones),
            var id => catalog.Find(id, MakeIt.Services.SavedTones) is { } tone ? new ClipAutopilotTone.Fixed(tone) : new ClipAutopilotTone.Auto(catalog.Tones)
        };
    }

    /// <summary>The note to Claude: the style's length and rewording, then a question's other answer (sent once).</summary>
    private string? MakeItNoteText()
    {
        var parts = new[] { MakeItStyle.PlannerNote, makeItNote }.OfType<string>().ToArray();
        makeItNote = null;
        if (parts.Length == 0) return null;
        var text = string.Join(" ", parts);
        return text.Length > 600 ? text[..600] : text;
    }

    /// <summary>Applies a plan: cuts, corrections, captions, look, speed, hook and post text in one change; then each rewrite in the
    /// creator's voice. Zooms and music are notes: Windows renders neither yet. Every step stops early once the run is cancelled.</summary>
    private async Task ApplyPlanAsync(ClipAutopilotPlan plan, MakeItRun run, MakeItServices services)
    {
        IReadOnlyList<ClipAutopilotOperation> operations;
        try
        {
            if (services.SharedRoot is not { } root) throw new VoxClipException(VoxClipErrorCode.SharedResourcesMissing, "fonts");
            operations = ClipAutopilotMapping.Operations(plan, run.ClipId, project, ClipAutopilotFonts.Load(root));
        }
        catch (Exception exception) when (exception is VoxClipException or VoiceLabException)
        {
            Fail(run, "This plan no longer fits the clip. Nothing was changed.");
            return;
        }
        var style = MakeItStyle;
        List<MakeItRow> rows = [];
        var cuts = operations.Count(operation => operation.Decision is ClipAutopilotDecision.Cut or ClipAutopilotDecision.PauseCut);
        if (cuts > 0)
        {
            var fillers = plan.Cuts.All(cut => cut.Kind == ClipAutopilotCutKind.Filler) && operations.All(operation => operation.Decision != ClipAutopilotDecision.PauseCut);
            run.Line(fillers ? $"Cutting {cuts} {(cuts == 1 ? "filler" : "fillers")}…" : $"Making {cuts} {(cuts == 1 ? "cut" : "cuts")}…");
            MakeItNotify();
        }
        // The edits the editor applies itself, in one change. The hook's card is timed on the clip they leave; its row goes last.
        var next = project;
        MakeItRow? hookRow = null;
        foreach (var operation in operations)
        {
            MakeItRow? row;
            MakeItInverse? inverse;
            try { (inverse, row) = MakeItStep(operation, plan, ref next, style); }
            catch (Exception exception) when (exception is VoxClipException or VoiceLabException) { continue; }
            if (inverse is not null) run.Inverses[operation.Id] = inverse;
            if (operation.Decision == ClipAutopilotDecision.Hook) hookRow = row;
            else if (row is not null) rows.Add(row);
        }
        ReplaceProject(next, "Make it postable");
        run.PostText = project.Share.Captions.GetValueOrDefault(run.ClipId) ?? "";
        run.Hook = ClipHookTitle.Text(plan.Hook) ?? "";
        run.Seconds = MakeItRenderedSeconds(run.ClipId);
        MakeItNotify();
        // Rewrites, in the creator's voice, each through Rewrite's own takes.
        var rewrites = operations.Where(operation => operation.Decision == ClipAutopilotDecision.Rewrite).ToArray();
        if (rewrites.Length > 0 && !MakeItStopped(run))
        {
            run.Line($"Voicing {rewrites.Length} {(rewrites.Length == 1 ? "fix" : "fixes")}…");
            MakeItNotify();
            foreach (var operation in rewrites)
            {
                if (MakeItStopped(run)) break;
                if (operation.Action is not ClipAutopilotAction.Rewrite rewrite) continue;
                rows.Add(await VoiceStepAsync(operation, rewrite, run, services, style.Rewrites));
                MakeItNotify();
            }
        }
        // Windows renders no zoom and no background music yet: the review names Claude's choice and nothing is applied.
        var zooms = operations.Count(operation => operation.Decision == ClipAutopilotDecision.Zoom);
        if (zooms > 0) rows.Add(new("zooms", $"Claude suggests {zooms} {(zooms == 1 ? "zoom" : "zooms")}") { Kind = MakeItRowKind.Note, Detail = "Zooms render on the Mac for now." });
        if (operations.FirstOrDefault(operation => operation.Action is ClipAutopilotAction.Music) is { Action: ClipAutopilotAction.Music music })
            rows.Add(new("music", $"Claude suggests music “{music.Cue.Picked.Title}”") { Kind = MakeItRowKind.Note, Detail = "Background music renders on the Mac for now." });
        if (hookRow is not null) rows.Add(hookRow);
        for (var index = 0; index < plan.Questions.Count; index++)
        {
            var question = plan.Questions[index];
            rows.Add(new("question-" + index.ToString(CultureInfo.InvariantCulture), question.Text)
            {
                Kind = MakeItRowKind.Question, Detail = $"Claude chose “{question.Answer}”", Change = MakeItChange.Question, Question = index,
                Options = question.Options.Where(option => option != question.Answer).ToArray()
            });
        }
        run.Rows.Clear();
        run.Rows.AddRange(rows);
        run.Seconds = MakeItRenderedSeconds(run.ClipId);
    }

    /// <summary>One pure operation applied to <paramref name="next"/>, with how to take it back and its review row; nothing for the
    /// operations a later step owns (rewrites) or Windows doesn't render (zooms, music).</summary>
    private (MakeItInverse? Inverse, MakeItRow? Row) MakeItStep(ClipAutopilotOperation operation, ClipAutopilotPlan plan, ref Project next, MakeItStyle style)
    {
        var words = next.Transcript?.Words ?? [];
        double? Start(IEnumerable<string> ids) => ids.Select(id => words.FirstOrDefault(word => word.Id == id)?.Start).OfType<double>().DefaultIfEmpty(double.NaN).Min() is var start && double.IsFinite(start) ? start : null;
        switch (operation.Action)
        {
            case ClipAutopilotAction.Edit { Operation: var edit }:
            {
                var before = next;
                var beforeState = EditingEngine.FromProject(before) ?? throw new VoiceLabException(VoiceLabErrorKind.InvalidInput);
                var afterState = reduce(beforeState, edit);
                if (afterState == beforeState) return (null, null);
                next = EditingEngine.ApplyToProject(before, afterState);
                switch (edit)
                {
                    case EditOperation.Correct correct:
                    {
                        var original = words.FirstOrDefault(word => word.Id == correct.Id);
                        var previous = beforeState.Corrections.GetValueOrDefault(correct.Id) ?? original?.Text ?? "";
                        return (new MakeItInverse.Edits([new EditOperation.Correct(correct.Id, previous)]),
                            new(operation.Id, $"Corrected “{previous}” → “{correct.Text}”") { Detail = operation.Reason, Play = original is null ? null : Math.Max(0, original.Start - 1), Undoable = true });
                    }
                    case EditOperation.SetWordCuts cut:
                    {
                        var added = cut.Ids.Where(id => !beforeState.CutWordIds.Contains(id)).ToArray();
                        var text = string.Join(" ", added.Select(id => words.FirstOrDefault(word => word.Id == id)).OfType<TimedWord>()
                            .Select(word => beforeState.Corrections.GetValueOrDefault(word.Id) ?? word.Text));
                        return (new MakeItInverse.Edits([new EditOperation.SetWordCuts(added, false)]),
                            new(operation.Id, $"Cut “{text}”") { Detail = operation.Reason, Play = Start(added) is { } start ? Math.Max(0, start - 1.5) : null, Undoable = true });
                    }
                    case EditOperation.SetPauseCuts pause:
                    {
                        var found = beforeState.Pauses.FirstOrDefault(item => pause.Ids.Contains(item.Id));
                        return (new MakeItInverse.Edits([new EditOperation.SetPauseCuts(pause.Ids, false)]),
                            new(operation.Id, "Tightened a pause") { Detail = operation.Reason, Play = found is null ? null : Math.Max(0, found.Start - 1.5), Undoable = true });
                    }
                    case EditOperation.UpdateClip update when beforeState.Clips.FirstOrDefault(clip => clip.Id == update.Id) is { } old:
                    {
                        var lower = beforeState.Transcript.Words.ToList().FindIndex(word => word.Id == old.StartWordId);
                        var upper = beforeState.Transcript.Words.ToList().FindIndex(word => word.Id == old.EndWordId);
                        if (lower < 0 || upper < lower) return (null, null);
                        var seconds = ClipAutopilotMapping.EditedSeconds(plan, afterState);
                        return (new MakeItInverse.Edits([new EditOperation.UpdateClip(update.Id, lower, upper)]),
                            new(operation.Id, "Tightened the clip to " + Duration(seconds)) { Play = words.ElementAtOrDefault(plan.StartWord)?.Start, Undoable = true });
                    }
                    case EditOperation.RenameClip rename:
                    {
                        var old = beforeState.Clips.FirstOrDefault(clip => clip.Id == rename.Id)?.Title;
                        return (new MakeItInverse.Edits([new EditOperation.RenameClip(rename.Id, old)]),
                            new(operation.Id, $"Claude chose the title “{rename.Title}”") { Kind = MakeItRowKind.Choice, Undoable = true, Change = MakeItChange.Rename });
                    }
                    case EditOperation.AddClip add:
                        return (new MakeItInverse.Edits([new EditOperation.RemoveClip(add.Clip.Id)]), new(operation.Id, "Added the clip") { Undoable = true });
                    default:
                        return (null, null);
                }
            }
            case ClipAutopilotAction.Captions captions:
            {
                // Captions Off in the clip style: the project's captions stay as they are.
                if (!style.Captions) return (null, null);
                var previous = next.Captions;
                next = next with { Captions = captions.Settings };
                var name = CaptionStyleName(captions.Settings.StyleId);
                var casing = plan.CaptionChoice.TextCase switch { ClipAutopilotCaptionCase.Upper => "UPPER", ClipAutopilotCaptionCase.Lower => "lower", _ => "as said" };
                var font = captions.PendingFont is { } pending ? $" · {pending.Family} {pending.Weight} once bundled" : "";
                return (new MakeItInverse.Captions(previous), new(operation.Id, $"Claude chose {name} captions, {casing}, {plan.CaptionChoice.WordsPerCaption} per line{font}")
                { Kind = MakeItRowKind.Choice, Undoable = true, Change = MakeItChange.Captions });
            }
            case ClipAutopilotAction.ShareText share:
            {
                var previous = next.Share.Captions.GetValueOrDefault(share.ClipId);
                next = next with { Share = new(new Dictionary<string, string>(next.Share.Captions) { [share.ClipId] = share.Text }) };
                return (new MakeItInverse.Share(share.ClipId, previous), null);
            }
            case ClipAutopilotAction.Look look:
            {
                // The clip's look (design §6.9), set by the clip controls' own rule in this same step.
                var previous = ClipControlsProject.Controls(look.ClipId, next)?.Look ?? ClipLook.Original;
                if (look.Choice.Id == ClipLook.Original && previous == ClipLook.Original) return (null, null);
                next = ClipControlsProject.SettingLook(look.Choice.Id, look.ClipId, next);
                var applied = previous != look.Choice.Id;
                return (applied ? new MakeItInverse.Look(look.ClipId, previous) : null,
                    new(operation.Id, $"Claude chose the {MakeItController.LookName(look.Choice.Id)} look")
                    { Kind = MakeItRowKind.Choice, Detail = look.Choice.Reason, Play = ClipPlay(look.ClipId, next), Undoable = applied, Change = MakeItChange.Look, Options = MakeItController.LookOptions(look.Choice.Id) });
            }
            case ClipAutopilotAction.Speed speed:
            {
                // The whole clip's speed, pitch kept (design §6.9), normalised as the clip controls are.
                var previous = ClipControlsProject.Controls(speed.ClipId, next)?.Speed ?? 1;
                var changed = ClipControlsProject.SettingSpeed(speed.Choice.Rate, speed.ClipId, next);
                var rate = ClipControlsProject.Controls(speed.ClipId, changed)?.Speed ?? 1;
                if (rate == 1 && previous == 1) return (null, null);
                next = changed;
                var applied = previous != rate;
                return (applied ? new MakeItInverse.Speed(speed.ClipId, previous) : null,
                    new(operation.Id, $"Claude chose {MakeItController.SpeedLabel(rate)} speed")
                    { Kind = MakeItRowKind.Choice, Detail = speed.Choice.Reason, Play = ClipPlay(speed.ClipId, next), Undoable = applied, Change = MakeItChange.Speed, Options = MakeItController.SpeedOptions(rate) });
            }
            case ClipAutopilotAction.Hook hook:
            {
                // The hook as the clip's title card over its first ~2 s (design §6.7), replacing a card an earlier run made.
                var previous = ClipHookTitle.Existing(hook.ClipId, next);
                if (ClipHookTitle.Effect(hook.Text, hook.ClipId, next) is not { } card) return (null, null);
                next = ClipEffects.Adding([card], next);
                var text = card.TryGetProperty("text", out var value) ? value.GetString() ?? hook.Text : hook.Text;
                return (new MakeItInverse.Effect(card.GetProperty("id").GetString()!, previous),
                    new(operation.Id, MakeItController.HookRowText(text, "Claude")) { Kind = MakeItRowKind.Choice, Detail = MakeItController.HookDetail, Play = ClipPlay(hook.ClipId, next), Undoable = true, Change = MakeItChange.Hook });
            }
            default:
                return (null, null);
        }
    }

    /// <summary>The caption style's display name, from the page's library; the id when it isn't known.</summary>
    public Func<string, string?>? CaptionStyleNames { get; set; }
    private string CaptionStyleName(string id) => CaptionStyleNames?.Invoke(id) ?? id;

    /// <summary>▶ on a clip-wide decision: just before the clip starts.</summary>
    private static double? ClipPlay(string clipId, Project snapshot) => ClipControlsProject.SourceSpan(clipId, snapshot) is { } span ? Math.Max(0, span.Start - 0.5) : null;

    /// <summary>The clip's rendered length: its edited length divided by its speed, as the export renders it (design §6.9).</summary>
    public double MakeItRenderedSeconds(string clipId)
    {
        if (Clips.FirstOrDefault(clip => clip.Id == clipId) is not { } row) return 0;
        var speed = ClipControlsProject.Controls(clipId, project)?.Speed ?? 1;
        return speed > 0 ? row.DurationSeconds / speed : row.DurationSeconds;
    }

    private async Task<MakeItRow> VoiceStepAsync(ClipAutopilotOperation operation, ClipAutopilotAction.Rewrite rewrite, MakeItRun run, MakeItServices services, bool allowed)
    {
        var text = rewrite.Text;
        var play = Words.ElementAtOrDefault(rewrite.Words.Start) is { } word ? Math.Max(0, word.Start - 1) : (double?)null;
        var row = new MakeItRow(operation.Id, $"Rewrote “{text}”") { Detail = operation.Reason, Play = play, Change = MakeItChange.Phrase, Words = (rewrite.Words.Start, rewrite.Words.End) };
        if (!allowed) return row with { Kind = MakeItRowKind.Note, Text = $"Claude suggests “{text}”", Detail = "This clip style keeps your words." };
        if (run.Budget is { PaidAllowed: false })
            return row with { Kind = MakeItRowKind.Note, Text = $"Claude suggests “{text}”", Detail = "Spend is $0 per video, so your words stay. Change voices it in Rewrite." };
        if (!services.VoiceAvailable())
            return row with { Kind = MakeItRowKind.Note, Text = $"Claude suggests “{text}”", Detail = "Turn on Voice Lab and make your voice to voice rewrites. Nothing was sent." };
        // The run's owned edits go on while Rewrite applies the take, so it lands in the run's one step.
        var outcome = await VoiceAsync();
        // Claude mode stops at the video's cap and asks for exactly the shortfall; Continue voices it, Stop keeps the words.
        while (outcome.Result is MakeItRewriteResult.OverCap { NextUsd: { } nextUsd } && run.Budget is { } budget && !MakeItStopped(run))
        {
            var shortfall = nextUsd - budget.Remaining;
            if (shortfall <= 0 || !await WaitAtCapAsync(run, budget, shortfall) || MakeItStopped(run)) break;
            outcome = await VoiceAsync();
        }
        switch (outcome.Result)
        {
            case MakeItRewriteResult.Voiced { Segments.Count: 0 }:
                // Only cuts or corrections: applied in the run's step, which Undo all takes back.
                return row with { Detail = "Your words changed without new audio." };
            case MakeItRewriteResult.Voiced voiced:
                run.Inverses[operation.Id] = new MakeItInverse.Voice(voiced.Segments);
                return row with { Undoable = true, Text = $"Voiced “{text}” in your voice", Detail = outcome.JoinNotes.Count > 0 ? "Join may sound slightly louder · ▶" : row.Detail };
            case MakeItRewriteResult.OverCap over:
                var price = over.NextUsd is { } usd ? MakeItController.Dollars(usd) : "price unknown";
                return row with { Kind = MakeItRowKind.Note, Text = $"Kept your words for “{text}”",
                    Detail = $"The next take ({price}) would pass this {(run.Budget is null ? "click" : "video")}'s cap. Your paid takes stay in Rewrite." };
            case MakeItRewriteResult.NeedsYou needs:
                return row with { Kind = MakeItRowKind.Note, Text = $"“{text}” needs you", Detail = needs.Reason };
            case MakeItRewriteResult.Unavailable unavailable:
                return row with { Kind = MakeItRowKind.Note, Text = $"Claude suggests “{text}”", Detail = unavailable.Reason };
            default:
                return row;
        }

        async Task<MakeItRewriteOutcome> VoiceAsync()
        {
            MakeItRewriteOutcome result;
            try { result = await services.Voice(new(rewrite.Words.Start, rewrite.Words.End, text, run.ClipId, run.Remaining), run.Cancellation.Token); }
            catch (Exception exception) when (Cancelled(exception)) { result = new(new MakeItRewriteResult.NeedsYou("Stopped before this fix was voiced.")); }
            run.Charge(result.Spent);
            run.VoiceSpent += result.Spent;
            return result;
        }
    }

    /// <summary>Claude mode at the cap: the run waits for Continue (exactly the shortfall) or Stop. The creator's edits meanwhile
    /// are their own undo steps, not the run's.</summary>
    private async Task<bool> WaitAtCapAsync(MakeItRun run, MakeItBudget budget, decimal shortfall)
    {
        if (!budget.PaidAllowed || shortfall <= 0) return false;
        run.Line($"Needs about {MakeItController.Dollars(shortfall)} more…");
        MakeItNotify();
        var group = undoGroup;
        var owned = group?.OwnsEdits;
        if (group is not null) group.OwnsEdits = false;
        var approved = await budget.AskAsync(shortfall);
        if (group is not null && owned is { } value) group.OwnsEdits = value;
        MakeItNotify();
        return approved;
    }

    // MARK: The review's actions

    /// <summary>▶: jumps to the decision and plays.</summary>
    public void MakeItPlay(MakeItRow row)
    {
        if (row.Play is { } time) MakeItPlayRequested?.Invoke(this, time);
    }

    /// <summary>Undo on one row: takes back that decision only, as its own undo step.</summary>
    public bool MakeItUndo(string rowId, MakeItRun run)
    {
        var index = run.Rows.FindIndex(row => row.Id == rowId);
        if (run.Running || index < 0 || run.Rows[index].Undone || !run.Inverses.TryGetValue(rowId, out var inverse)) return false;
        var opened = undoGroup is null;
        if (opened) BeginUndoGroup("Undo " + run.Rows[index].Text);
        try { if (!UndoInverse(inverse)) return false; }
        finally { if (opened) EndUndoGroup(); }
        run.Rows[index] = run.Rows[index] with { Undone = true };
        run.Inverses.Remove(rowId);
        run.Seconds = MakeItRenderedSeconds(run.ClipId);
        if (rowId == "hook") run.Hook = "";
        Announcement?.Invoke(this, "Undone.");
        MakeItNotify();
        return true;
    }

    /// <summary>Undo all: every decision still applied, taken back as one undo step, the post text included.</summary>
    public void MakeItUndoAll(MakeItRun run)
    {
        if (run.Running) return;
        BeginUndoGroup("Undo Make it postable");
        try
        {
            foreach (var row in run.Rows.Where(row => !row.Undone && run.Inverses.ContainsKey(row.Id)).Reverse().ToArray()) MakeItUndo(row.Id, run);
            // Inverses without a row (the post text) go too.
            foreach (var (id, inverse) in run.Inverses.ToArray()) { UndoInverse(inverse); run.Inverses.Remove(id); }
        }
        finally { EndUndoGroup(); }
        MakeIt.Forget(run.ClipId);
        Announcement?.Invoke(this, "Make it postable undone.");
        MakeItNotify();
    }

    private bool UndoInverse(MakeItInverse inverse)
    {
        try
        {
            switch (inverse)
            {
                case MakeItInverse.Edits edits: return ApplyBatch(edits.Operations);
                case MakeItInverse.Captions captions: return ReplaceProject(project with { Captions = captions.Previous }, "Undo captions");
                case MakeItInverse.Share share:
                {
                    // Post texts sit outside undo history on Windows (SetShareCaption): restore it directly.
                    var texts = new Dictionary<string, string>(project.Share.Captions);
                    if (share.Previous is { } previous) texts[share.ClipId] = previous; else texts.Remove(share.ClipId);
                    project = project with { Share = new(texts), ModifiedAt = now() };
                    SaveRequested?.Invoke(this, EventArgs.Empty);
                    return true;
                }
                case MakeItInverse.Voice voice:
                    var any = false;
                    foreach (var id in voice.Segments) any |= ApplyVoiceLab(new VoiceLabEditCommand.SetEnabled(id, false));
                    return any;
                case MakeItInverse.Look look:
                    return ReplaceProject(ClipControlsProject.SettingLook(look.Previous, look.ClipId, project), "Undo look") || true;
                case MakeItInverse.Speed speed:
                    return ReplaceProject(ClipControlsProject.SettingSpeed(speed.Previous, speed.ClipId, project), "Undo speed") || true;
                case MakeItInverse.Effect effect:
                {
                    var next = effect.Previous is { } previous ? ClipEffects.Adding([previous], project)
                        : project with { ClipEffects = project.ClipEffects.Where(item => item.GetProperty("id").GetString() != effect.Id).ToArray() };
                    ReplaceProject(next, "Undo hook");
                    return true;
                }
                default: return false;
            }
        }
        catch (Exception exception) when (exception is VoxClipException or VoiceLabException)
        {
            Notice = UiError.Message(exception, "Undo");
            return false;
        }
    }

    /// <summary>Change: the look, speed and hook rows open inline; a question shows its answers; the rest open their own control.</summary>
    public void MakeItChangeRow(string rowId, MakeItRun run)
    {
        if (run.Running || run.Rows.FirstOrDefault(row => row.Id == rowId) is not { } row) return;
        switch (row.Change)
        {
            case MakeItChange.Look or MakeItChange.Speed or MakeItChange.Hook or MakeItChange.Question:
                run.OpenChoice = run.OpenChoice == row.Id ? null : row.Id;
                MakeItNotify();
                break;
            case MakeItChange.Captions or MakeItChange.Rename or MakeItChange.Phrase:
                SetScope(run.ClipId);
                MakeItChangeRequested?.Invoke(this, (run, row));
                break;
        }
    }

    /// <summary>A chip on the look or speed row: applies it to the clip at once, as one undo step, and the row names the creator's
    /// choice. The row's Undo still goes back to the clip before the run.</summary>
    public bool MakeItChoose(string option, string rowId, MakeItRun run)
    {
        var index = run.Rows.FindIndex(row => row.Id == rowId);
        if (run.Running || index < 0 || run.Rows[index].Undone) return false;
        var controls = ClipControlsProject.Controls(run.ClipId, project);
        var row = run.Rows[index];
        switch (row.Change)
        {
            case MakeItChange.Look:
            {
                if (Enum.GetValues<ClipLook>().Where(look => MakeItController.LookName(look) == option).Cast<ClipLook?>().FirstOrDefault() is not { } look) return false;
                var previous = controls?.Look ?? ClipLook.Original;
                if (!ReplaceProject(ClipControlsProject.SettingLook(look, run.ClipId, project), "Change look")) return false;
                run.Inverses.TryAdd(rowId, new MakeItInverse.Look(run.ClipId, previous));
                run.Rows[index] = row with { Text = $"You chose the {option} look", Options = MakeItController.LookOptions(look), Undoable = true, Detail = "" };
                break;
            }
            case MakeItChange.Speed:
            {
                if (MakeItController.SpeedPresets.Where(rate => MakeItController.SpeedLabel(rate) == option).Cast<double?>().FirstOrDefault() is not { } rate) return false;
                var previous = controls?.Speed ?? 1;
                if (!ReplaceProject(ClipControlsProject.SettingSpeed(rate, run.ClipId, project), "Change speed")) return false;
                run.Inverses.TryAdd(rowId, new MakeItInverse.Speed(run.ClipId, previous));
                run.Rows[index] = row with { Text = $"You chose {option} speed", Options = MakeItController.SpeedOptions(rate), Undoable = true, Detail = "" };
                run.Seconds = MakeItRenderedSeconds(run.ClipId);
                break;
            }
            default: return false;
        }
        run.OpenChoice = null;
        MakeItNotify();
        return true;
    }

    /// <summary>The hook row's Change, committed from its inline field: the card's text becomes <paramref name="text"/> as one undo
    /// step ("Change hook"), the row reads "You chose the hook …", and the post text carries the new hook.</summary>
    public bool MakeItSetHook(string text, string rowId, MakeItRun run)
    {
        var index = run.Rows.FindIndex(row => row.Id == rowId);
        if (run.Running || index < 0 || run.Rows[index].Change != MakeItChange.Hook || run.Rows[index].Undone ||
            run.Inverses.GetValueOrDefault(rowId) is not MakeItInverse.Effect effect || ClipHookTitle.Text(text) is not { } hook) return false;
        run.OpenChoice = null;
        if (project.ClipEffects.FirstOrDefault(item => item.GetProperty("id").GetString() == effect.Id) is not { ValueKind: JsonValueKind.Object } card) { MakeItNotify(); return false; }
        if (card.TryGetProperty("text", out var current) && current.GetString() == hook) { MakeItNotify(); return false; }
        var node = System.Text.Json.Nodes.JsonNode.Parse(card.GetRawText())!.AsObject();
        node["text"] = hook;
        using var document = JsonDocument.Parse(node.ToJsonString());
        if (!ReplaceProject(ClipEffects.Adding([document.RootElement.Clone()], project), "Change hook")) return false;
        run.Hook = hook;
        run.Rows[index] = run.Rows[index] with { Text = MakeItController.HookRowText(hook, "You") };
        Announcement?.Invoke(this, "Hook changed.");
        MakeItNotify();
        return true;
    }

    /// <summary>A question's other answer: this clip's decisions are taken back and Claude plans it again with that answer.</summary>
    public bool MakeItAnswer(string answer, int question, MakeItRun run)
    {
        if (run.Running || run.Plan is not { } plan || question < 0 || question >= plan.Questions.Count) return false;
        var text = plan.Questions[question].Text;
        MakeItUndoAll(run);
        makeItNote = $"For “{text}” the creator chose “{answer}”.";
        return MakeItPostable(run.ClipId);
    }

    /// <summary>The post text as it is copied and shown: the hook first, unless the post already says it.</summary>
    public static string MakeItPostCopy(MakeItRun run)
    {
        var hook = run.Hook.Trim();
        var carries = hook.Length == 0 || run.PostText.Contains(hook, StringComparison.CurrentCultureIgnoreCase);
        return string.Join("\n\n", (carries ? new[] { run.PostText } : new[] { hook, run.PostText }).Where(part => part.Length > 0));
    }

    /// <summary>Copy: the post text on the clipboard.</summary>
    public bool CopyMakeItPostText(MakeItRun run)
    {
        var text = MakeItPostCopy(run);
        if (text.Length == 0 || MakeIt.Services?.Copy is not { } copy) return false;
        copy(text);
        run.Copied = true;
        Announcement?.Invoke(this, "Post text copied.");
        MakeItNotify();
        return true;
    }

    /// <summary>Export: one click, in the style's shapes, with the post text copied and saved beside each file.</summary>
    public async Task<bool> MakeItExportAsync(MakeItRun run)
    {
        if (run.Running || run.Exporting || MakeIt.Services?.Export is not { } export || ExportBlocked(false, false, run.ClipId) is not null) return false;
        CopyMakeItPostText(run);
        run.Exporting = true;
        run.Line("Exporting " + string.Join(" and ", MakeItStyle.Shapes.Select(ShapeName)) + "…");
        MakeItNotify();
        try
        {
            var files = await export(run.ClipId, MakeItStyle.Shapes, CancellationToken.None);
            var post = MakeItPostCopy(run);
            foreach (var file in files)
            {
                run.Exported.Add(file);
                if (post.Length > 0) await File.WriteAllTextAsync(Path.ChangeExtension(file, ".txt"), post);
            }
            run.Line(files.Count == 1 ? "Exported 1 video." : $"Exported {files.Count} videos.");
            return files.Count > 0;
        }
        catch (Exception exception) when (exception is not OutOfMemoryException)
        {
            var message = UiError.Message(exception, "Export");
            run.Line(message.Length == 0 ? "Export stopped." : message);
            return false;
        }
        finally
        {
            run.Exporting = false;
            MakeItNotify();
        }
    }

    /// <summary>"16:9", "9:16", "1:1".</summary>
    public static string ShapeName(ExportAspect aspect) => aspect switch
    {
        ExportAspect.Landscape => "16:9", ExportAspect.Portrait => "9:16", ExportAspect.Square => "1:1", _ => "source"
    };

    /// <summary>"Export · 16:9 + 9:16".</summary>
    public string MakeItExportTitle => "Export · " + string.Join(" + ", MakeItStyle.Shapes.Select(ShapeName));

    /// <summary>Under the headline: Claude's finished length and anything the plan flags, or a clip longer than the style allows.</summary>
    public IReadOnlyList<string> MakeItLengthNotes(MakeItRun run)
    {
        if (run.Plan is not { } plan || run.Running) return [];
        List<string> notes = [];
        if (plan.Seconds > 0)
            notes.Add("Claude's cut: " + Duration(plan.Seconds) + " finished" + (plan.SpeedChoice is { } speed ? " at " + MakeItController.SpeedLabel(ClipControlsProject.NormalizedSpeed(speed.Rate)) : ""));
        notes.AddRange(plan.Flags.Select(flag => "⚠ " + flag.Detail));
        if (MakeItStyle.MaxSeconds is { } limit && run.Seconds > limit + 0.5) notes.Add($"⚠ Longer than this clip style's {limit} s");
        return notes;
    }

    /// <summary>The review's headline: "Ready to post · 0:46 · score 8/10".</summary>
    public string MakeItHeadline(MakeItRun run) => run.Phase switch
    {
        MakeItPhase.Planning => $"Claude is making {Clips.FirstOrDefault(clip => clip.Id == run.ClipId)?.Title ?? "this clip"} postable…",
        MakeItPhase.Applying => "Applying Claude's decisions…",
        MakeItPhase.Stopped => "Stopped · what was done is kept",
        MakeItPhase.Failed => "Nothing was changed",
        _ => "Ready to post · " + Duration(run.Seconds) + (run.Plan is { } plan ? $" · score {plan.Score}/10" : "")
    };

    /// <summary>The footer's next step.</summary>
    public static string MakeItNextStep(MakeItRun run) => run.Phase switch
    {
        MakeItPhase.Planning or MakeItPhase.Applying => "Next: wait, or Stop to keep what's done.",
        MakeItPhase.Failed => "Next: try again, or edit the clip yourself.",
        _ when run.Exporting => "Next: wait for the export.",
        _ when run.Exported.Count > 0 => "Next: paste the post text where you post.",
        _ => "Next: Export. The post text is copied with it."
    };
}
