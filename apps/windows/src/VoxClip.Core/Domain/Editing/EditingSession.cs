using System.Text;
using VoxClip.Core.Domain.Clips;
using VoxClip.Core.Domain.Shared;

namespace VoxClip.Core.Domain.Editing;

internal static class EditingSession
{
    private static IReadOnlyList<(int Start, int End)>? Scope(EditState state) =>
        state.Clips.FirstOrDefault(clip => clip.Id == state.ActiveClipId)?.PlayPartIndices(state.Transcript.Words);

    private static bool InScope(int index, IReadOnlyList<(int Start, int End)>? scope) => scope?.Any(range => index >= range.Start && index <= range.End) ?? true;
    private static bool PauseInScope(Pause pause, IReadOnlyList<(int Start, int End)>? scope) =>
        scope?.Any(range => pause.AfterIndex >= range.Start && pause.AfterIndex + 1 <= range.End) ?? true;
    private static string Text(EditState state, TimedWord word) => state.Corrections.GetValueOrDefault(word.Id, word.Text);
    private static bool Filler(EditState state, TimedWord word) => word.Kind == WordKind.UnlabeledSpeech || word.Kind == WordKind.Word && EditingAlgorithms.IsFillerText(Text(state, word));

    internal static EditSummary Summarize(EditState state)
    {
        var scope = Scope(state);
        var words = state.Transcript.Words.Where((word, index) => InScope(index, scope)).ToArray();
        var pauses = state.Pauses.Where(pause => PauseInScope(pause, scope)).ToArray();
        var fillers = words.Count(word => !state.CutWordIds.Contains(word.Id) && Filler(state, word));
        var cuts = words.Count(word => state.CutWordIds.Contains(word.Id));
        var pauseCuts = pauses.Count(pause => state.CutPauseIds.Contains(pause.Id));
        return new(fillers, cuts, pauses.Length, pauseCuts, fillers > 0, pauses.Length > 0 && pauseCuts != pauses.Length, cuts > 0 || pauseCuts > 0, !(words.Length > 0 && cuts == words.Length));
    }

    internal static IReadOnlyList<EditSegment> BuildSegments(EditState state)
    {
        var scope = Scope(state);
        var words = state.Transcript.Words;
        var segments = words.Select((word, index) => new EditSegment(word.Id, EditSegmentKind.Word, word.Kind, Text(state, word), word.Start, word.End, state.CutWordIds.Contains(word.Id) || !InScope(index, scope))).ToList();
        segments.AddRange(state.Pauses.Where(pause => state.CutPauseIds.Contains(pause.Id)).Select(pause => new EditSegment(pause.Id, EditSegmentKind.Pause, null, null, pause.Start, pause.End, true)));
        if (scope is { Count: 1 })
        {
            var range = scope[0];
            // The clip's opening lead-in (ADR-R48 part 2) opens it earlier, inside the pause before its first word.
            var leadIn = state.Clips.FirstOrDefault(clip => clip.Id == state.ActiveClipId)?.LeadInSeconds;
            var times = EditingAlgorithms.ClipTimes(words, range.Start, range.End, leadIn);
            if (times.Start > 0) segments.Add(new("clip-head", EditSegmentKind.Range, null, null, 0, times.Start, true));
            var tailEnd = Math.Max(times.End, words[^1].End) + 3600;
            if (tailEnd > times.End) segments.Add(new("clip-tail", EditSegmentKind.Range, null, null, times.End, tailEnd, true));
        }
        return segments.Select((segment, index) => (segment, index)).OrderBy(pair => pair.segment.Start).ThenBy(pair => pair.index).Select(pair => pair.segment).ToArray();
    }

    internal static EditState Reduce(EditState state, EditOperation operation, IReadOnlyList<AiResult>? aiResults = null,
        Project? project = null, string copySuffix = "story")
    {
        if (operation is EditOperation.ReplaceTranscript replacement)
        {
            var newThreshold = replacement.Transcript.Refined ? 0.8 : 1.0;
            return PreserveNoOp(state, state with { Transcript = replacement.Transcript, ProjectClock = null, Pauses = EditingAlgorithms.DetectPauses(replacement.Transcript.Words, newThreshold),
                PauseThresholdSeconds = newThreshold, CutWordIds = new HashSet<string>(StringComparer.Ordinal), CutPauseIds = new HashSet<string>(StringComparer.Ordinal),
                Corrections = new Dictionary<string, string>(StringComparer.Ordinal), Clips = [], ActiveClipId = null });
        }
        var words = state.Transcript.Words;
        var scope = Scope(state);
        var wordIds = words.Select(word => word.Id).ToHashSet(StringComparer.Ordinal);
        var pauseIds = state.Pauses.Select(pause => pause.Id).ToHashSet(StringComparer.Ordinal);
        var cutWords = new HashSet<string>(state.CutWordIds, StringComparer.Ordinal);
        var cutPauses = new HashSet<string>(state.CutPauseIds, StringComparer.Ordinal);
        var corrections = new Dictionary<string, string>(state.Corrections, StringComparer.Ordinal);
        var clips = state.Clips.ToList();
        var active = state.ActiveClipId;
        var pauses = state.Pauses;
        var keep = state.PauseKeepSeconds;
        var threshold = state.PauseThresholdSeconds;
        switch (operation)
        {
            case EditOperation.Toggle toggle:
                SetCuts([toggle.Id], !IsCut(toggle.Id));
                break;
            case EditOperation.CutSelection selection:
                SetCuts(selection.Ids, !selection.Ids.All(IsCut));
                break;
            case EditOperation.RestoreSelection selection:
                SetCuts(selection.Ids, false);
                break;
            case EditOperation.SetWordCuts selection:
                foreach (var id in selection.Ids.Where(wordIds.Contains)) Set(cutWords, id, selection.Cut);
                break;
            case EditOperation.SetPauseCuts selection:
                foreach (var id in selection.Ids.Where(pauseIds.Contains)) Set(cutPauses, id, selection.Cut);
                break;
            case EditOperation.CutFillers:
                foreach (var word in words.Where((word, index) => InScope(index, scope) && Filler(state, word))) cutWords.Add(word.Id);
                break;
            case EditOperation.TightenPauses:
                foreach (var pause in pauses.Where(pause => PauseInScope(pause, scope))) cutPauses.Add(pause.Id);
                break;
            case EditOperation.RestoreCuts:
                foreach (var word in words.Where((word, index) => InScope(index, scope))) cutWords.Remove(word.Id);
                foreach (var pause in pauses.Where(pause => PauseInScope(pause, scope))) cutPauses.Remove(pause.Id);
                break;
            case EditOperation.Correct correction:
                var item = words.FirstOrDefault(word => word.Id == correction.Id);
                var text = EditingAlgorithms.JsTrim(EditingAlgorithms.Nfc(correction.Text));
                if (text.Length == 0 || item is not { Kind: WordKind.Word } || text == Text(state, item)) return state;
                if (!EditingLimits.ValidLength(text, EditingLimits.MaxCorrectionCodePoints)) return state;
                if (text == item.Text) corrections.Remove(item.Id);
                else corrections[item.Id] = text;
                break;
            case EditOperation.SetActiveClip select:
                active = select.Id is null || clips.Any(clip => clip.Id == select.Id) ? select.Id : active;
                break;
            case EditOperation.AddClip add:
                if (aiResults is not null && !ValidAiReference(add.Clip, aiResults)) return state;
                var addedTitle = NormalizeTitle(add.Clip.Title);
                if (!EditingLimits.ValidId(add.Clip.Id) || !ValidTitle(addedTitle) ||
                    add.Clip.AiResultId is { } resultId && !EditingLimits.ValidId(resultId) || add.Clip.AiClipIndex < 0 ||
                    add.Clip.PlayPartIndices(words) is null || !ValidParts(add.Clip) || clips.Any(clip => clip.Id == add.Clip.Id)) return state;
                if (project is not null && add.Clip.Parts is not null) StoryClips.ValidatePlacement(add.Clip, project, words);
                clips.Add(add.Clip with { Selected = true, Title = addedTitle });
                break;
            case EditOperation.AddAiClips add:
                if (!EditingLimits.ValidId(add.ResultId)) return state;
                if (aiResults is not null && !aiResults.Any(result => result.Id == add.ResultId && add.Clips.Count <= result.Clips.Count)) return state;
                var previousCount = clips.Count;
                for (var index = 0; index < add.Clips.Count; index++)
                {
                    var clip = add.Clips[index];
                    var aiTitle = NormalizeTitle(clip.Title);
                    var parts = clip.Parts?.Select((part, partIndex) => new ClipPart($"part-{partIndex + 1}", part.StartWordId, part.EndWordId)).ToArray();
                    var candidate = new ClipRange("candidate", clip.StartWordId, clip.EndWordId, aiTitle, ClipOrigin.Ai, add.ResultId, index, true, Parts: parts);
                    if (!ValidTitle(aiTitle) || candidate.PlayPartIndices(words) is null || !ValidParts(candidate) ||
                        clips.Any(existing => existing.PlayParts.Select(part => (part.StartWordId, part.EndWordId))
                            .SequenceEqual(candidate.PlayParts.Select(part => (part.StartWordId, part.EndWordId))))) continue;
                    var baseId = "ai-" + add.ResultId + "-" + index.ToString(System.Globalization.CultureInfo.InvariantCulture);
                    var id = baseId.Length <= 60 ? baseId : "ai-" + Convert.ToHexStringLower(System.Security.Cryptography.SHA256.HashData(Encoding.UTF8.GetBytes(baseId)))[..40];
                    var suffix = 1;
                    var uniqueId = id;
                    while (clips.Any(existing => existing.Id == uniqueId))
                    {
                        var suffixText = "-" + (suffix++).ToString(System.Globalization.CultureInfo.InvariantCulture);
                        uniqueId = id[..Math.Min(id.Length, EditingLimits.MaxIdLength - suffixText.Length)] + suffixText;
                    }
                    candidate = candidate with { Id = uniqueId };
                    if (project is not null && parts is not null) StoryClips.ValidatePlacement(candidate, project, words);
                    clips.Add(candidate);
                }
                if (clips.Count == previousCount) return state;
                break;
            case EditOperation.UpdateClip update:
                if (update.StartIndex < 0 || update.EndIndex < update.StartIndex || update.EndIndex >= words.Count) return state;
                if (state.ProjectClock?.ContainsRange(words[update.StartIndex].Id, words[update.EndIndex].Id) == false) return state;
                // A new first word drops the opening lead-in, as the Mac's updateClip does.
                ChangeClip(update.Id, clip => clip.Parts is not null ? clip : clip with { StartWordId = words[update.StartIndex].Id, EndWordId = words[update.EndIndex].Id,
                    LeadInSeconds = clip.StartWordId == words[update.StartIndex].Id ? clip.LeadInSeconds : null });
                break;
            case EditOperation.SetClipParts set:
                var clipIndex = clips.FindIndex(clip => clip.Id == set.Id);
                if (clipIndex < 0 || set.Parts.Count == 0 || StoryClips.Indices(set.Parts.Select(part => (part.StartWordId, part.EndWordId)), words) is not { } ranges) return state;
                var original = clips[clipIndex];
                var changed = original with { Parts = set.Parts.Count > 1 ? set.Parts.ToArray() : null,
                    Kind = set.Parts.Count > 1 ? original.Kind ?? StoryClipKind.Story : null,
                    StartWordId = words[ranges.Min(range => range.Start)].Id, EndWordId = words[ranges.Max(range => range.End)].Id,
                    LeadInSeconds = original.PlayParts[0].StartWordId == set.Parts[0].StartWordId ? original.LeadInSeconds : null };
                if (state.ProjectClock is { } clock && !changed.PlayParts.All(part => clock.ContainsRange(part.StartWordId, part.EndWordId)))
                    throw new VoxClipException(VoxClipErrorCode.ProjectUnreadable, "A part comes from one recording.");
                if (!StoryClips.Valid(changed, words) || original.PlayParts.SequenceEqual(changed.PlayParts) && (original.Parts is null) == (changed.Parts is null)) return state;
                if (project is not null)
                {
                    var before = StoryClips.Times(original, words);
                    var after = StoryClips.Times(changed, words);
                    var keyed = project.VoiceLab.WholeClipRevoices?.Any(record => record.ClipId == original.Id) == true;
                    var protectedSpans = copySuffix == "copy" ? RecordingEdits.ProtectedSpans(original.Id, project, words) : [];
                    var losesLipsync = StoryClips.LipsyncWindows(project).Any(window => before.Any(span => StoryClips.Overlaps(span, window)) &&
                        !after.Any(span => StoryClips.Overlaps(span, window)) && !protectedSpans.Any(span => span.Start <= window.Start && span.End >= window.End));
                    if (keyed && !before.SequenceEqual(after) || losesLipsync)
                    {
                        var originalTitle = original.Title ?? $"Clip {clipIndex + 1}";
                        var suffix = " " + copySuffix;
                        var copyTitle = copySuffix == "copy" ? string.Concat(originalTitle.EnumerateRunes().Take(120 - suffix.Length)) + suffix :
                            string.Concat((originalTitle + suffix).EnumerateRunes().Take(120));
                        changed = changed with { Id = UniqueId(original.Id, copySuffix), Title = copyTitle };
                        StoryClips.ValidatePlacement(changed, project, words);
                        clips.Add(changed);
                        active = changed.Id;
                        break;
                    }
                    StoryClips.ValidatePlacement(changed, project, words);
                }
                clips[clipIndex] = changed;
                break;
            case EditOperation.MakeClipOfPart make:
                var part = clips.Find(clip => clip.Id == make.ClipId)?.PlayParts.FirstOrDefault(part => part.Id == make.PartId);
                if (part is null) return state;
                active = UniqueId(make.ClipId, "part");
                clips.Add(new(active, part.StartWordId, part.EndWordId, null, ClipOrigin.Manual, null, null, true));
                break;
            case EditOperation.RenameClip rename:
                var title = NormalizeTitle(rename.Title);
                if (!EditingLimits.ValidId(rename.Id) || !ValidTitle(title)) return state;
                ChangeClip(rename.Id, clip => clip with { Title = title });
                break;
            case EditOperation.SetClipSelected select:
                ChangeClip(select.Id, clip => clip with { Selected = select.Selected });
                break;
            case EditOperation.RemoveClip remove:
                clips.RemoveAll(clip => clip.Id == remove.Id);
                if (active == remove.Id) active = null;
                break;
            case EditOperation.SetPauseKeep update:
                if (!double.IsFinite(update.Seconds) || update.Seconds < 0 || update.Seconds > 1) return state;
                keep = update.Seconds;
                break;
            case EditOperation.SetPauseThreshold update:
                if (!double.IsFinite(update.Seconds) || update.Seconds <= 0 || update.Seconds > 10) return state;
                threshold = update.Seconds;
                pauses = state.ProjectClock?.Pauses(threshold) ?? EditingAlgorithms.DetectPauses(words, threshold);
                cutPauses.IntersectWith(pauses.Select(pause => pause.Id));
                break;
            default: throw new ArgumentException("Unknown edit operation.", nameof(operation));
        }
        return PreserveNoOp(state, state with { CutWordIds = cutWords, CutPauseIds = cutPauses, Corrections = corrections, Clips = clips.ToArray(), ActiveClipId = active,
            Pauses = pauses, PauseKeepSeconds = keep, PauseThresholdSeconds = threshold });

        bool IsCut(string id) => pauseIds.Contains(id) ? cutPauses.Contains(id) : wordIds.Contains(id) && cutWords.Contains(id);
        static string? NormalizeTitle(string? title)
        {
            var normalized = title is null ? "" : EditingAlgorithms.JsTrim(title);
            return normalized.Length == 0 ? null : normalized;
        }
        static bool ValidTitle(string? title) => title is null || EditingLimits.ValidLength(title, EditingLimits.MaxClipTitleCodePoints);
        bool ValidParts(ClipRange clip) => StoryClips.Valid(clip, words) && (state.ProjectClock is not { } clock ||
            clip.PlayParts.All(part => clock.ContainsRange(part.StartWordId, part.EndWordId)));
        void SetCuts(IReadOnlyList<string> ids, bool cut)
        {
            foreach (var id in ids)
            {
                if (pauseIds.Contains(id)) Set(cutPauses, id, cut);
                else if (wordIds.Contains(id)) Set(cutWords, id, cut);
            }
        }
        string UniqueId(string original, string suffix)
        {
            for (var number = 1; ; number++)
            {
                var ending = number == 1 ? $"-{suffix}" : $"-{suffix}-{number}";
                var id = original[..Math.Min(original.Length, EditingLimits.MaxIdLength - ending.Length)] + ending;
                if (!clips.Any(clip => clip.Id == id)) return id;
            }
        }
        void ChangeClip(string id, Func<ClipRange, ClipRange> change)
        {
            var index = clips.FindIndex(clip => clip.Id == id);
            if (index >= 0) clips[index] = change(clips[index]);
        }
    }

    private static bool ValidAiReference(ClipRange clip, IReadOnlyList<AiResult> aiResults)
        => clip.AiResultId is null ? clip.AiClipIndex is null : aiResults.Any(result => result.Id == clip.AiResultId &&
            (clip.AiClipIndex is null || clip.AiClipIndex >= 0 && clip.AiClipIndex < result.Clips.Count));

    private static EditState PreserveNoOp(EditState state, EditState next)
        => ReferenceEquals(state.Transcript, next.Transcript) && state.Pauses.SequenceEqual(next.Pauses) &&
            state.PauseThresholdSeconds == next.PauseThresholdSeconds && state.PauseKeepSeconds == next.PauseKeepSeconds &&
            state.CutWordIds.SetEquals(next.CutWordIds) && state.CutPauseIds.SetEquals(next.CutPauseIds) &&
            state.Corrections.Count == next.Corrections.Count && state.Corrections.All(pair => next.Corrections.TryGetValue(pair.Key, out var text) && pair.Value == text) &&
            state.Clips.SequenceEqual(next.Clips) && state.ActiveClipId == next.ActiveClipId ? state : next;

    private static void Set(HashSet<string> set, string id, bool cut)
    {
        if (cut) set.Add(id);
        else set.Remove(id);
    }
}
