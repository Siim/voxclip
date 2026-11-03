using VoxClip.Core.Domain.Editing;
using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Domain.VoiceLab;

namespace VoxClip.App.ViewModels;

internal sealed record RewriteSentenceReview(string Identity, string? ModelId, string? VoiceId, int Ordinal,
    VoiceLabDiffHunk Hunk, VoiceLabWindow Window, string Original, string Text);

internal sealed partial class RewriteSession
{
    internal const string SentenceUnavailable = "A complete surrounding sentence cannot safely fit this change inside the approved scope. Excluded changes and other takes are kept. Re-record this sentence instead. Nothing was sent.";
    internal const string SentenceOverlap = "This sentence overlaps another selected change. Review a combined rewrite instead. No changes were merged and nothing was sent.";
    internal const string SentenceStale = "The rewrite or source changed. Review the surrounding sentence again. Nothing was sent.";
    internal RewriteSentenceReview? SentenceReview { get; private set; }
    internal string SentenceProblem { get; private set; } = "";
    private readonly Dictionary<int, VoiceLabDiffHunk> sentenceReplacements = [];
    internal VoiceLabDiffHunk GenerationHunk(VoiceLabDiffHunk hunk, int ordinal) => sentenceReplacements.GetValueOrDefault(ordinal) ?? hunk;

    internal bool ReviewSurroundingSentence(int ordinal)
    {
        SentenceReview = null;
        SentenceProblem = SentenceUnavailable;
        if (!ReviewIsCurrent || Review is null || Envelope is null || generationWindows.Any(window => window.IsRunning || window.IsPreparing) ||
            sentenceReplacements.ContainsKey(ordinal) ||
            Review.VoiceHunks.FirstOrDefault(hunk => hunk.Ordinals.Contains(ordinal)) is not { Ordinals.Count: 1 } target) return SentenceRecoveryChanged(false);
        try
        {
            var project = Editor.ProjectWithLocalOperations(Project, LocalOperations());
            var words = Transcript.Select(word => word.Kind == WordKind.Word
                ? word with { Text = project.Edits.Corrections.GetValueOrDefault(word.Id) ?? word.Text } : word).ToArray();
            var positions = words.Select((word, index) => (word.Id, Index: index)).ToDictionary(item => item.Id, item => item.Index, StringComparer.Ordinal);
            var original = target.Hunk;
            if (original.SourceWordIds.Count == 0 || original.AnchorSeconds is not null ||
                !positions.TryGetValue(original.SourceWordIds[0], out var first) || !positions.TryGetValue(original.SourceWordIds[^1], out var last) ||
                !words.Skip(first).Take(last - first + 1).Select(word => word.Id).SequenceEqual(original.SourceWordIds)) return SentenceRecoveryChanged(false);
            var approved = Source.Select(word => word.Id).ToHashSet(StringComparer.Ordinal);
            if (Source.Count == 0) return SentenceRecoveryChanged(false);
            var approvedFirst = positions[Source[0].Id];
            var approvedLast = positions[Source[^1].Id];
            var approvedTimes = EditingAlgorithms.ClipTimes(words, approvedFirst, approvedLast);
            var pauses = EditingAlgorithms.DetectPauses(words, project.Edits.PauseThresholdSeconds);
            var breaks = pauses.Select(pause => pause.AfterIndex).ToHashSet();
            var boundaries = new[] { 0 }.Concat(Enumerable.Range(0, words.Length - 1)
                .Where(index => EndsSentence(words[index].Text) || breaks.Contains(index)).Select(index => index + 1)).Append(words.Length).ToArray();
            var candidates = boundaries.Where(start => start <= first && first - start < 60)
                .SelectMany(start => boundaries.Where(end => end > last && end - start <= 60).Select(end => (Start: start, End: end)))
                .OrderBy(candidate => candidate.End - candidate.Start).ThenBy(candidate => candidate.Start);
            var selectedModel = Generation?.Models.FirstOrDefault(model => model.Id == Generation.ModelId);
            var limit = Math.Min(5000, selectedModel?.MaximumTextLength ?? 5000);
            var evidence = project.VoiceLab.Segments.Where(segment => segment.Kind == VoiceLabSegmentKind.Tts && segment.SelectedCandidateIndex >= 0 &&
                segment.SelectedCandidateIndex < segment.Candidates.Count).Select(segment => segment.Candidates[segment.SelectedCandidateIndex])
                .Where(candidate => candidate.Rejected is null && candidate.Recipe?.Words is { Count: > 0 })
                .Select(candidate => candidate.Recipe!.Words!)
                .Select(aligned => new VoiceLabRateCandidate(string.Join(" ", aligned.Select(word => word.Text)),
                    aligned[0].Start, aligned[^1].End)).ToArray();
            var rate = Math.Max(20, VoiceLabLengthBudget.Rate(words, project.Edits.PauseThresholdSeconds, evidence).CharactersPerSecond);
            foreach (var candidate in candidates)
            {
                var sentence = words.Skip(candidate.Start).Take(candidate.End - candidate.Start).ToArray();
                if (sentence.Any(word => word.Kind != WordKind.Word || !approved.Contains(word.Id) || project.Edits.CutWordIds.Contains(word.Id)) ||
                    sentence.Select(word => word.Speaker).Distinct().Count() > 1 ||
                    sentence.Zip(sentence.Skip(1)).Any(pair => pair.First.End > pair.Second.Start) ||
                    pauses.Any(pause => project.Edits.CutPauseIds.Contains(pause.Id) && pause.AfterIndex >= candidate.Start && pause.AfterIndex + 1 < candidate.End)) continue;
                var owners = sentence.Select(word => word.Id).ToHashSet(StringComparer.Ordinal);
                var conflicts = Review.Diff.Hunks.Select((hunk, index) => (Hunk: hunk, Ordinal: index + 1))
                    .Where(item => item.Ordinal != ordinal && item.Hunk.SourceWordIds.Any(owners.Contains)).ToArray();
                if (conflicts.Any(item => item.Hunk.Kind == VoiceLabDiffHunkKind.Cut || changeStates.GetValueOrDefault(item.Ordinal) == TranscriptChangeState.Excluded)) continue;
                var pieces = words.Skip(candidate.Start).Take(first - candidate.Start).Select(word => word.Text).Concat(original.NewTokens)
                    .Concat(words.Skip(last + 1).Take(candidate.End - last - 1).Select(word => word.Text)).ToArray();
                var text = string.Join(" ", pieces);
                if (text.EnumerateRunes().Count() > limit) continue;
                var sourceSeconds = sentence.Sum(word => word.End - word.Start);
                if (sourceSeconds <= 0) continue;
                var conservativeRate = Math.Max(rate, sentence.Sum(word => VoiceLabTextLength.Length(word.Text)) / sourceSeconds);
                var raw = VoiceLabTextLength.Length(text) / Math.Max(20, conservativeRate);
                var voiced = Math.Max(0, raw - VoiceLabPatchConstants.TTS_TRIM_LEAD - VoiceLabPatchConstants.TTS_TRIM_TAIL) * 0.8;
                var margin = sentence.Max(word => word.End - word.Start);
                if (voiced < 3 + margin) continue;
                VoiceLabWindow window;
                try
                {
                    window = VoiceLabWindowPlanner.Place(project, Scope, Envelope, sentence[0].Id, sentence[^1].Id);
                    VoiceLabRenderContract.ValidatePlacement(project, Scope, window);
                }
                catch (Exception error) when (error is VoiceLabGeometryException or VoiceLabProjectException) { continue; }
                var lower = approvedFirst == 0 ? 0 : approvedTimes.Start;
                var upper = approvedLast == words.Length - 1 ? project.Media.Source.DurationSeconds : approvedTimes.End;
                if (window.LeftBridgeWordIds.Count != 0 || window.RightBridgeWordIds.Count != 0 || window.Start < lower || window.End > upper ||
                    words.Any(word => project.Edits.CutWordIds.Contains(word.Id) && word.Start < window.End && window.Start < word.End) ||
                    pauses.Any(pause => project.Edits.CutPauseIds.Contains(pause.Id) && pause.Start < window.End && window.Start < pause.End)) continue;
                var silence = VoiceLabWindowPlanner.LendableSilence(project, Scope, window);
                if (VoiceLabFitMeter.Measure(text, window, silence.Incoming, silence.Outgoing, conservativeRate, text).UpperBoundSeconds < 3 + margin) continue;
                if (conflicts.Any(item => item.Hunk.Kind == VoiceLabDiffHunkKind.Voice))
                { SentenceProblem = SentenceOverlap; return SentenceRecoveryChanged(false); }
                var reservations = PricedVoiceHunks.Select((hunk, index) =>
                    generationWindows.ElementAtOrDefault(index)?.Selected?.Audio?.Fit.Plan is { } fit && hunk.Window is { } reserved
                        ? hunk with { Window = reserved with { StartSample = fit.WindowStartSample, EndSample = fit.WindowEndSample } } : hunk)
                    .Where(hunk => !hunk.Ordinals.Contains(ordinal)).ToArray();
                if (reservations.Any(hunk => hunk.Window is not { } reserved ||
                    window.StartSample - window.LeftSeam.FadeSamples / 2 <= reserved.EndSample + (reserved.RightSeam.FadeSamples + 1) / 2 &&
                    reserved.StartSample - reserved.LeftSeam.FadeSamples / 2 <= window.EndSample + (window.RightSeam.FadeSamples + 1) / 2))
                { SentenceProblem = SentenceOverlap; return SentenceRecoveryChanged(false); }
                var prefix = words.Skip(candidate.Start).Take(first - candidate.Start).Sum(word => EditingAlgorithms.SplitWords(word.Text).Count);
                var suffix = words.Skip(last + 1).Take(candidate.End - last - 1).Sum(word => EditingAlgorithms.SplitWords(word.Text).Count);
                var expanded = original with { SourceWordIds = sentence.Select(word => word.Id).ToArray(), NewTokens = pieces,
                    CorrectedTexts = [], AbsorbedItemIds = [], BridgeWordIds = [], SourceStartIndex = original.SourceStartIndex - prefix,
                    SourceEndIndex = original.SourceEndIndex + suffix, AnchorSeconds = null };
                var proposed = Review.Diff with { Hunks = IncludedHunks.Select(hunk => ReferenceEquals(hunk, original) ? expanded : hunk).ToArray() };
                if (VoiceLabPatchBudget.Evaluate(proposed, words).Flag != VoiceLabPatchBudgetFlag.Allowed) continue;
                SentenceReview = new(ReviewIdentity, Generation?.ModelId, Generation?.VoiceId, ordinal, expanded, window,
                    string.Join(" ", sentence.Select(word => word.Text)), text);
                SentenceProblem = "";
                return SentenceRecoveryChanged(true);
            }
        }
        catch (Exception error) when (error is VoiceLabGeometryException or VoiceLabLengthBudgetException or VoiceLabProjectException) { }
        return SentenceRecoveryChanged(false);
    }

    internal bool AcceptSurroundingSentence(RewriteSentenceReview reviewed)
    {
        if (!ReferenceEquals(SentenceReview, reviewed) || !ReviewIsCurrent || reviewed.Identity != ReviewIdentity ||
            reviewed.ModelId != Generation?.ModelId || reviewed.VoiceId != Generation?.VoiceId ||
            generationWindows.Any(window => window.IsRunning || window.IsPreparing))
        { SentenceReview = null; SentenceProblem = SentenceStale; return SentenceRecoveryChanged(false); }
        if (!ReviewSurroundingSentence(reviewed.Ordinal) || SentenceReview is not { } current || current.Text != reviewed.Text ||
            current.Window.StartSample != reviewed.Window.StartSample || current.Window.EndSample != reviewed.Window.EndSample)
        { SentenceReview = null; SentenceProblem = SentenceStale; return SentenceRecoveryChanged(false); }
        InvalidateProposal();
        sentenceReplacements[reviewed.Ordinal] = reviewed.Hunk;
        priceOverrides.ExceptWith([reviewed.Ordinal]);
        SentenceReview = null; SentenceProblem = "";
        RefreshReview(preserveGenerations: true);
        if (generationFactory is null) InvalidateGenerationInputs();
        return SentenceRecoveryChanged(true);
    }

    internal void CancelSurroundingSentence() { SentenceReview = null; SentenceProblem = ""; SentenceRecoveryChanged(false); }
    private bool SentenceRecoveryChanged(bool result) { Changed?.Invoke(this, EventArgs.Empty); return result; }
    private static bool EndsSentence(string text) => text.TrimEnd().TrimEnd('"', '\'', '”', '’', ')', ']', '»') is { Length: > 0 } trimmed && ".!?…。！？".Contains(trimmed[^1]);
}
