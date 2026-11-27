using VoxClip.Core.Domain.Shared;

namespace VoxClip.Core.Domain.Editing;

public static partial class RecordingEdits
{
    /// <summary>Find the last word of a solo run's preceding beat as played in the clip.</summary>
    public static string? Placement(string clipId, TakeMatch.SoloRun run, Project project)
    {
        if (run.AfterBeatId is null || project.Edits.Clips.FirstOrDefault(clip => clip.Id == clipId) is not { } clip) return null;
        var clock = ProjectClock.Build(project);
        var beat = TakeMatch.Build(clock).Beats.FirstOrDefault(beat => beat.Id == run.AfterBeatId);
        return beat is not null && new ShortcutParts(clip, clock).CurrentLine(beat) is { } line ? clock.Words[line.End].Id : null;
    }

    private static RecordingEditResult.Applied UseVersion(RecordingEdit.UseLineVersion edit, Project project)
    {
        var parts = Shortcut(edit.ClipId, project);
        var beat = TakeMatch.Build(parts.Clock).Beats.FirstOrDefault(beat => beat.Id == edit.BeatId);
        if (beat is null || parts.CurrentLine(beat) is not { } line) throw new Refusal("That line isn't in the clip.");
        if (line.Key == edit.Key) return new(project, "Use version");
        var span = beat.Spans.FirstOrDefault(span => span.FromKey == line.Key && span.ToKey == edit.Key)
            ?? throw new Refusal("Choose a version from another recording.");
        var original = parts.Parts[line.PartIndex];
        var replacement = original with { StartWordId = span.StartWordId, EndWordId = span.EndWordId, TakeReason = null };
        parts.Replace(line.PartIndex, line.Start, line.End + 1, replacement, keepLeadingId: true);
        return FinishShortcut(parts, project, "Use version");
    }

    private static RecordingEditResult.Applied InsertShortcut(RecordingEdit.InsertLine edit, Project project)
    {
        var parts = Shortcut(edit.ClipId, project);
        if (!parts.Positions.TryGetValue(edit.StartWordId, out var start) || !parts.Positions.TryGetValue(edit.EndWordId, out var end) ||
            end < start || parts.Clock.RegionOf(edit.StartWordId)?.Key != edit.Key || parts.Clock.RegionOf(edit.EndWordId)?.Key != edit.Key)
            throw new Refusal("Choose words from one recording.");
        var inserted = new ClipPart(parts.NextId(), edit.StartWordId, edit.EndWordId);
        parts.Made.Add(inserted.Id);
        if (edit.AfterWordId is { } anchor)
        {
            if (!parts.Positions.TryGetValue(anchor, out var position)) throw new Refusal("That line isn't in the clip.");
            var index = parts.Parts.FindIndex(part => parts.Positions[part.StartWordId] <= position && position <= parts.Positions[part.EndWordId]);
            if (index < 0) throw new Refusal("That line isn't in the clip.");
            var before = parts.Parts[index];
            if (position + 1 == start && parts.Clock.RegionOf(anchor)?.Key == edit.Key) inserted = inserted with { Reframe = before.Reframe };
            parts.Replace(index, position + 1, position + 1, inserted, keepLeadingId: false);
        }
        else
        {
            var before = parts.Parts[^1];
            if (parts.Positions[before.EndWordId] + 1 == start && parts.Clock.RegionOf(before.EndWordId)?.Key == edit.Key)
                inserted = inserted with { Reframe = before.Reframe };
            parts.Parts.Add(inserted);
            parts.Touched.Add(inserted.Id);
        }
        return FinishShortcut(parts, project, "Add part");
    }

    private static ShortcutParts Shortcut(string clipId, Project project)
    {
        var clip = project.Edits.Clips.FirstOrDefault(clip => clip.Id == clipId) ?? throw new Refusal("Choose a clip first.");
        var result = new ShortcutParts(clip, ProjectClock.Build(project));
        if (clip.PlayPartIndices(result.Clock.Words) is null) throw new Refusal("Choose non-overlapping parts in the clip's transcript.");
        return result;
    }

    private static RecordingEditResult.Applied FinishShortcut(ShortcutParts change, Project project, string name)
    {
        change.Join();
        var words = change.Clock.Words;
        if (EditingEngine.FromProject(project) is not { } state ||
            StoryClips.Indices(change.Parts.Select(part => (part.StartWordId, part.EndWordId)), words) is not { Count: > 0 } ranges)
            throw new Refusal("Choose non-overlapping parts in the clip's transcript.");
        var proposed = change.Clip with
        {
            StartWordId = words[ranges.Min(range => range.Start)].Id,
            EndWordId = words[ranges.Max(range => range.End)].Id,
            Parts = change.Parts.Count > 1 ? change.Parts : null,
            Kind = change.Parts.Count > 1 ? change.Clip.Kind ?? StoryClipKind.Story : null,
            LeadInSeconds = change.Clip.PlayParts[0].StartWordId == change.Parts[0].StartWordId ? change.Clip.LeadInSeconds : null,
        };
        var applied = NeedsPaidCopy(change.Clip, proposed, project, words) ? AddShortcutClip(proposed, change.Clip, project, state, name) :
            (RecordingEditResult.Applied)ChangeParts(change.Clip.Id, project, name, (parts, _) =>
        {
            parts.Clear();
            parts.AddRange(change.Parts);
        });
        var resultClip = applied.Project.Edits.Clips.Count > project.Edits.Clips.Count ? applied.Project.Edits.Clips[^1] :
            applied.Project.Edits.Clips.First(clip => clip.Id == change.Clip.Id);
        return applied with { Details = new(resultClip.Id, change.Made.ToArray(), []) { SplitPartId = change.Split, Joins = change.Joins.ToArray() } };
    }

    private sealed class ShortcutParts(ClipRange clip, ProjectClock clock)
    {
        public ClipRange Clip { get; } = clip;
        public ProjectClock Clock { get; } = clock;
        public Dictionary<string, int> Positions { get; } = clock.Words.Select((word, index) => (word.Id, index)).ToDictionary(pair => pair.Id, pair => pair.index);
        public List<ClipPart> Parts { get; } = clip.PlayParts.ToList();
        private readonly HashSet<string> reserved = clip.PlayParts.Select(part => part.Id).ToHashSet();
        public HashSet<string> Touched { get; } = [];
        public List<string> Made { get; } = [];
        public List<RecordingPartJoin> Joins { get; } = [];
        public string? Split { get; private set; }

        public (int PartIndex, string Key, int Start, int End)? CurrentLine(TakeMatch.Beat beat)
        {
            for (var index = 0; index < Parts.Count; index++)
            {
                var part = Parts[index];
                var key = Clock.RegionOf(part.StartWordId)?.Key;
                var take = beat.Takes.FirstOrDefault(take => take.Key == key);
                if (take is null || !Positions.TryGetValue(part.StartWordId, out var first) || !Positions.TryGetValue(part.EndWordId, out var last)) continue;
                bool Holds(int start, int end) => first <= start && end <= last;
                if (Holds(Positions[take.StartWordId], Positions[take.EndWordId]))
                    return (index, take.Key, Positions[take.StartWordId], Positions[take.EndWordId]);
                var aligned = beat.Spans.Where(span => span.ToKey == key).Select(span => (Start: Positions[span.StartWordId], End: Positions[span.EndWordId]))
                    .Where(span => Holds(span.Start, span.End)).OrderByDescending(span => span.End - span.Start).FirstOrDefault((Start: -1, End: -1));
                if (aligned.Start >= 0) return (index, take.Key, aligned.Start, aligned.End);
            }
            return null;
        }

        public string NextId()
        {
            var id = FreshId("part", reserved);
            reserved.Add(id);
            return id;
        }

        public void Replace(int index, int start, int end, ClipPart replacement, bool keepLeadingId)
        {
            var original = Parts[index];
            var before = Positions[original.StartWordId] < start;
            var after = end <= Positions[original.EndWordId];
            var fragments = new List<ClipPart>();
            if (before) fragments.Add(original with { EndWordId = Clock.Words[start - 1].Id });
            if (keepLeadingId && before)
            {
                replacement = replacement with { Id = NextId() };
                Made.Add(replacement.Id);
            }
            fragments.Add(replacement);
            if (after)
            {
                var following = original with { Id = NextId(), StartWordId = Clock.Words[end].Id };
                fragments.Add(following);
                Made.Add(following.Id);
            }
            if (after || keepLeadingId && before) Split = original.Id;
            Parts.RemoveAt(index);
            Parts.InsertRange(index, fragments);
            foreach (var fragment in fragments) Touched.Add(fragment.Id);
        }

        public void Join()
        {
            for (var index = 1; index < Parts.Count;)
            {
                var before = Parts[index - 1];
                var after = Parts[index];
                if ((Touched.Contains(before.Id) || Touched.Contains(after.Id)) && before.Reframe?.Mode == after.Reframe?.Mode &&
                    Clock.RegionOf(before.EndWordId) == Clock.RegionOf(after.StartWordId) &&
                    Positions[before.EndWordId] + 1 == Positions[after.StartWordId])
                {
                    Parts[index - 1] = before with { EndWordId = after.EndWordId };
                    Parts.RemoveAt(index);
                    Touched.Add(before.Id);
                    Joins.Add(new(before.Id, after.Id));
                    index = Math.Max(1, index - 1);
                }
                else index++;
            }
        }
    }
}
