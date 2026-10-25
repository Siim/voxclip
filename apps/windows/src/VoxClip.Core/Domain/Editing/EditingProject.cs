using VoxClip.Core.Domain.Shared;
using ProjectModel = VoxClip.Core.Domain.Shared.Project;

namespace VoxClip.Core.Domain.Editing;

internal static class EditingProject
{
    internal static EditState? FromProject(ProjectModel project)
    {
        if (project.Transcript is not { } transcript) return null;
        project = Clean(project, []);
        var edits = project.Edits;
        return new(transcript, EditingAlgorithms.DetectPauses(transcript.Words, edits.PauseThresholdSeconds),
            edits.PauseThresholdSeconds, edits.PauseKeepSeconds, edits.CutWordIds.ToHashSet(StringComparer.Ordinal),
            edits.CutPauseIds.ToHashSet(StringComparer.Ordinal), new Dictionary<string, string>(edits.Corrections, StringComparer.Ordinal),
            edits.Clips.ToArray(), edits.ActiveClipId);
    }

    internal static ProjectModel ApplyToProject(ProjectModel project, EditState state)
    {
        var replaced = !ReferenceEquals(project.Transcript, state.Transcript);
        var edits = new ProjectEdits(state.PauseThresholdSeconds, state.PauseKeepSeconds,
            state.Transcript.Words.Where(word => state.CutWordIds.Contains(word.Id)).Select(word => word.Id).ToArray(),
            state.Pauses.Where(pause => state.CutPauseIds.Contains(pause.Id)).Select(pause => pause.Id).ToArray(),
            new Dictionary<string, string>(state.Corrections, StringComparer.Ordinal), state.Clips.ToArray(), state.ActiveClipId);
        return Clean(project with { Transcript = state.Transcript, Edits = edits,
            Ai = replaced ? new([]) : project.Ai,
            Share = replaced ? new(new Dictionary<string, string>(StringComparer.Ordinal)) : project.Share }, []);
    }

    internal static ProjectModel Clean(ProjectModel project, List<string> warnings)
    {
        var words = project.Transcript?.Words ?? [];
        var ids = words.Select((word, index) => (word.Id, index)).ToDictionary(pair => pair.Id, pair => pair.index, StringComparer.Ordinal);
        var pauses = EditingAlgorithms.DetectPauses(words, project.Edits.PauseThresholdSeconds);
        var results = project.Ai.Results.ToDictionary(result => result.Id, StringComparer.Ordinal);
        var clips = project.Edits.Clips.Where(clip =>
        {
            var valid = ids.TryGetValue(clip.StartWordId, out var start) && ids.TryGetValue(clip.EndWordId, out var end) && start <= end;
            if (!valid) warnings.Add("Dropped a clip with invalid transcript references.");
            return valid;
        }).Select(clip =>
        {
            if (clip.AiResultId is not null && !results.ContainsKey(clip.AiResultId))
            {
                warnings.Add("Cleared an unresolved AI result reference.");
                return clip with { AiResultId = null, AiClipIndex = null };
            }
            return clip;
        }).ToArray();
        var clipIds = clips.Select(clip => clip.Id).ToHashSet(StringComparer.Ordinal);
        var cutWords = new HashSet<string>(project.Edits.CutWordIds, StringComparer.Ordinal);
        var cutPauses = new HashSet<string>(project.Edits.CutPauseIds, StringComparer.Ordinal);
        foreach (var id in cutWords.Where(id => !ids.ContainsKey(id))) warnings.Add("Dropped an unknown cut word reference.");
        var knownPauses = pauses.Select(pause => pause.Id).ToHashSet(StringComparer.Ordinal);
        foreach (var id in cutPauses.Where(id => !knownPauses.Contains(id))) warnings.Add("Dropped an unknown cut pause reference.");
        var corrections = new Dictionary<string, string>(StringComparer.Ordinal);
        foreach (var word in words)
        {
            if (!project.Edits.Corrections.TryGetValue(word.Id, out var text)) continue;
            if (word.Kind == WordKind.Word && text != word.Text) corrections.Add(word.Id, text);
            else warnings.Add("Dropped a redundant or non-word correction.");
        }
        foreach (var id in project.Edits.Corrections.Keys.Where(id => !ids.ContainsKey(id))) warnings.Add("Dropped an unknown correction reference.");
        var active = project.Edits.ActiveClipId;
        if (active is not null && !clipIds.Contains(active)) { active = null; warnings.Add("Cleared an unknown active clip reference."); }
        var share = new Dictionary<string, string>(StringComparer.Ordinal);
        foreach (var pair in project.Share.Captions.OrderBy(pair => pair.Key, StringComparer.Ordinal))
        {
            if (pair.Key == "full" || clipIds.Contains(pair.Key)) share.Add(pair.Key, pair.Value);
            else warnings.Add("Dropped a removed clip's share caption.");
        }
        return project with { Edits = project.Edits with { CutWordIds = words.Where(word => cutWords.Contains(word.Id)).Select(word => word.Id).ToArray(),
            CutPauseIds = pauses.Where(pause => cutPauses.Contains(pause.Id)).Select(pause => pause.Id).ToArray(), Corrections = corrections, Clips = clips, ActiveClipId = active }, Share = new(share) };
    }
}
