using VoxClip.Core.Domain.Editing;
using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Domain.VoiceLab;

namespace VoxClip.App.ViewModels;

internal enum RewriteDiffKind { Equal, Removed, Inserted, Bridge }
internal sealed record RewriteDiffRun(string Text, RewriteDiffKind Kind, string? SourceId = null);
internal sealed record RewriteHunkReview(VoiceLabDiffHunk Hunk, VoiceLabWindow? Window, string? PatchText,
    VoiceLabFitMeterResult? Meter, string? Refusal);

internal sealed record RewriteReview(VoiceLabWordDiffResult Diff, VoiceLabPatchBudgetResult Budget,
    IReadOnlyList<RewriteDiffRun> Runs, string AccessibleDescription, IReadOnlyList<RewriteHunkReview> VoiceHunks,
    VoiceLabDiffSummaryResult? Summary, string ChangeSummary)
{
    internal static RewriteReview Build(RewriteSession session, VoiceLabPriceCatalog? prices, string? model)
    {
        var diff = session.ReviewDiff();
        var included = diff.Hunks.Where((_, index) => session.ChangeStates.GetValueOrDefault(index + 1) != TranscriptChangeState.Excluded).ToArray();
        var budget = VoiceLabPatchBudget.Evaluate(diff with { Hunks = included }, session.Transcript);
        var voice = included.Where(hunk => hunk.Kind == VoiceLabDiffHunkKind.Voice).ToArray();
        List<RewriteHunkReview> reviews = [];
        var placements = session.Envelope is null ? [] : VoiceLabWindowPlanner.PlaceAll(session.Project, session.Scope, session.Envelope, included);
        foreach (var placement in session.Envelope is null
            ? voice.Select(hunk => (PlacedOrRefused)new PlacedOrRefused.Refused(0, hunk,
                new VoiceLabWindowRefusal.Geometry(new(VoiceLabGeometryErrorCode.InvalidInput)))).ToArray() : placements)
        {
            var hunk = placement is PlacedOrRefused.Placed placedHunk ? placedHunk.Hunk : ((PlacedOrRefused.Refused)placement).Hunk;
            try
            {
                if (placement is PlacedOrRefused.Refused refused)
                    throw refused.Reason is VoiceLabWindowRefusal.Geometry geometry ? geometry.Error : new VoiceLabGeometryException(VoiceLabGeometryErrorCode.InvalidInput);
                var window = ((PlacedOrRefused.Placed)placement).Window;
                var silence = VoiceLabWindowPlanner.LendableSilence(session.Project, session.Scope, window);
                var newWords = string.Join(" ", hunk.NewTokens);
                string Text(string id) => session.Transcript.First(word => word.Id == id).Text;
                var patch = string.Join(" ", window.LeftBridgeWordIds.Select(Text).Append(newWords).Concat(window.RightBridgeWordIds.Select(Text)));
                var rate = VoiceLabLengthBudget.Rate(session.Transcript).CharactersPerSecond;
                var meter = VoiceLabFitMeter.Measure(patch, window, silence.Incoming, silence.Outgoing, rate, newWords, voice.Length > 1);
                reviews.Add(new(hunk, window, patch, meter, null));
            }
            catch (Exception exception) when (exception is VoiceLabGeometryException or VoiceLabLengthBudgetException or VoiceLabProjectException)
            {
                reviews.Add(new(hunk, null, null, null, RewriteSession.Refusal(exception)));
            }
        }
        VoiceLabDiffSummaryResult? summary = reviews.All(review => review.Meter is not null)
            ? VoiceLabDiffSummary.Make(diff with { Hunks = included }, reviews.Select(review => review.Meter!).ToArray(), prices, model,
                patchTexts: reviews.Select(review => review.PatchText).ToArray()) : null;
        var runs = DiffRuns(diff, session.Source, session.Transcript, reviews);
        var inserted = diff.Ops.Count(op => op.Kind == VoiceLabDiffOpKind.Insert);
        var removed = diff.Ops.Count(op => op.Kind == VoiceLabDiffOpKind.Delete);
        var changeSummary = $"{inserted} new, {removed} removed" +
            (summary is null ? "" : " · about " + EditingFormat.ToFixed1(summary.EstimateSeconds) + " s");
        return new(diff, budget, runs, Description(diff, runs), reviews, summary, changeSummary);
    }

    private static IReadOnlyList<RewriteDiffRun> DiffRuns(VoiceLabWordDiffResult diff, IReadOnlyList<TimedWord> source,
        IReadOnlyList<TimedWord> transcript, IReadOnlyList<RewriteHunkReview> reviews)
    {
        var bridges = diff.Hunks.SelectMany(hunk => hunk.BridgeWordIds).Concat(reviews.Where(review => review.Window is not null)
            .SelectMany(review => review.Window!.LeftBridgeWordIds.Concat(review.Window.RightBridgeWordIds))).ToHashSet(StringComparer.Ordinal);
        var absorbed = diff.Hunks.SelectMany(hunk => hunk.AbsorbedItemIds).ToHashSet(StringComparer.Ordinal);
        var positions = source.Select((word, index) => (word.Id, index)).ToDictionary(pair => pair.Id, pair => pair.index);
        var remaining = source.Where(word => absorbed.Contains(word.Id)).ToList();
        List<RewriteDiffRun> runs = [];
        var sourceIds = source.Select(word => word.Id).ToHashSet(StringComparer.Ordinal);
        foreach (var word in transcript.Where(word => bridges.Contains(word.Id) && !sourceIds.Contains(word.Id) && word.Start < (source.FirstOrDefault()?.Start ?? 0)))
            runs.Add(new(word.Text, RewriteDiffKind.Bridge, word.Id));
        foreach (var op in diff.Ops)
        {
            if (op.SourceWordId is { } id)
                while (remaining.Count > 0 && positions[remaining[0].Id] < positions[id])
                {
                    runs.Add(new(remaining[0].Text, RewriteDiffKind.Removed, remaining[0].Id));
                    remaining.RemoveAt(0);
                }
            if (op.Kind == VoiceLabDiffOpKind.Delete) runs.Add(new(op.SourceToken!, RewriteDiffKind.Removed, op.SourceWordId));
            else if (op.Kind == VoiceLabDiffOpKind.Insert) runs.Add(new(op.NewToken!, RewriteDiffKind.Inserted));
            else if (op.SourceToken != op.NewToken)
            {
                runs.Add(new(op.SourceToken!, RewriteDiffKind.Removed, op.SourceWordId));
                runs.Add(new(op.NewToken!, bridges.Contains(op.SourceWordId!) ? RewriteDiffKind.Bridge : RewriteDiffKind.Inserted, op.SourceWordId));
            }
            else runs.Add(new(op.NewToken!, bridges.Contains(op.SourceWordId!) ? RewriteDiffKind.Bridge : RewriteDiffKind.Equal, op.SourceWordId));
        }
        foreach (var item in remaining) runs.Add(new(item.Text, RewriteDiffKind.Removed, item.Id));
        foreach (var word in transcript.Where(word => bridges.Contains(word.Id) && !sourceIds.Contains(word.Id) && word.Start >= (source.LastOrDefault()?.End ?? 0)))
            runs.Add(new(word.Text, RewriteDiffKind.Bridge, word.Id));
        return runs;
    }

    private static string Description(VoiceLabWordDiffResult diff, IReadOnlyList<RewriteDiffRun> runs)
    {
        List<string> descriptions = [];
        List<string> removed = []; List<string> inserted = [];
        void Flush()
        {
            if (removed.Count > 0 && inserted.Count > 0) descriptions.Add(string.Join(" ", removed) + " becomes " + string.Join(" ", inserted));
            else if (removed.Count > 0) descriptions.Add(string.Join(" ", removed) + " removed");
            else if (inserted.Count > 0) descriptions.Add("insert " + string.Join(" ", inserted));
            removed.Clear(); inserted.Clear();
        }
        foreach (var op in diff.Ops)
        {
            if (op.Kind == VoiceLabDiffOpKind.Delete) removed.Add(op.SourceToken!);
            else if (op.Kind == VoiceLabDiffOpKind.Insert) inserted.Add(op.NewToken!);
            else { Flush(); if (op.SourceToken != op.NewToken) descriptions.Add(op.SourceToken + " becomes " + op.NewToken); }
        }
        Flush();
        foreach (var run in runs.Where(run => run.Kind == RewriteDiffKind.Removed && diff.Hunks.Any(hunk => hunk.AbsorbedItemIds.Contains(run.SourceId!))))
            descriptions.Add(run.Text + " removed");
        return string.Join(", ", descriptions);
    }
}
