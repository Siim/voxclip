using System.Text.Json;
using System.Text;
using VoxClip.Core.Domain.Shared;

namespace VoxClip.Core.Domain.Editing;

/// <summary>The result of an atomic recording or part change.</summary>
public abstract record RecordingEditResult
{
    private RecordingEditResult() { }
    /// <summary>The new snapshot, named Undo step, and any announcement for the editor.</summary>
    public sealed record Applied(Project Project, string UndoName, string? Announcement = null, RecordingEditDetails? Details = null) : RecordingEditResult
    {
        /// <summary>The single snapshot step, absent for a no-op.</summary>
        public RecordingEditStep? UndoStep { get; init; }
    }
    /// <summary>Why the command left the snapshot unchanged.</summary>
    public sealed record Refused(string Message) : RecordingEditResult;
}

/// <summary>Exact project snapshots for one recording edit's Undo and Redo.</summary>
public sealed record RecordingEditStep(string Name, Project Before, Project After);

/// <summary>The clip, resulting parts, and skipped lines for recording shortcut feedback.</summary>
public sealed record RecordingEditDetails(string ClipId, IReadOnlyList<string> MadePartIds, IReadOnlyList<TakeMatch.Take> LeftOut)
{
    /// <summary>The original part split by this action, if any.</summary>
    public string? SplitPartId { get; init; }
    /// <summary>The joins performed in order.</summary>
    public IReadOnlyList<RecordingPartJoin> Joins { get; init; } = [];
}

/// <summary>A joined pair of parts and the identity that survived.</summary>
public sealed record RecordingPartJoin(string KeptPartId, string RemovedPartId);

/// <summary>Pure recording and ordered part edits on the project clock.</summary>
public static partial class RecordingEdits
{
    private const string PrefixHighWater = "com.voxclip.spoken-prefix-high-water";
    private const string CopyOrigins = "com.voxclip.recording-copy-origins";

    /// <summary>Apply one undoable edit without touching source files or paid assets.</summary>
    public static RecordingEditResult Apply(RecordingEdit edit, Project project)
    {
        var result = Reduce(edit, project);
        return result is RecordingEditResult.Applied applied && applied.Project != project
            ? applied with { UndoStep = new(applied.UndoName, project, applied.Project) } : result;
    }

    private static RecordingEditResult Reduce(RecordingEdit edit, Project project)
    {
        try
        {
            return edit switch
            {
                RecordingEdit.AddSpokenSource add => new RecordingEditResult.Applied(Adding(add, project), "Add recording"),
                RecordingEdit.RemoveSpokenSource remove => new RecordingEditResult.Applied(Removing(remove.Key, project), "Remove recording"),
                RecordingEdit.StartFromRecording start => Start(start.Key, project),
                RecordingEdit.UseLineVersion use => UseVersion(use, project),
                RecordingEdit.InsertLine insert => InsertShortcut(insert, project),
                RecordingEdit.AddPart add => ChangeParts(add.ClipId, project, "Add part", (parts, _) =>
                    Insert(add.Part, add.AfterPartId, parts, parts.Count)),
                RecordingEdit.MovePart move => ChangeParts(move.ClipId, project, "Move part", (parts, _) =>
                {
                    var index = PartIndex(move.PartId, parts);
                    if (move.PartId == move.AfterPartId) return;
                    var part = parts[index];
                    parts.RemoveAt(index);
                    Insert(part, move.AfterPartId, parts, 0);
                }),
                RecordingEdit.RemovePart remove => ChangeParts(remove.ClipId, project, "Remove part", (parts, _) =>
                {
                    if (parts.Count < 2) throw new Refusal("Keep at least one part in the clip.");
                    parts.RemoveAt(PartIndex(remove.PartId, parts));
                }),
                RecordingEdit.TrimPart trim => ChangeParts(trim.ClipId, project, "Trim part", (parts, clock) =>
                {
                    var index = PartIndex(trim.PartId, parts);
                    if (clock.RegionOf(parts[index].StartWordId) != clock.RegionOf(trim.StartWordId))
                        throw new Refusal("Trim the part within its recording.");
                    parts[index] = parts[index] with { StartWordId = trim.StartWordId, EndWordId = trim.EndWordId };
                }),
                RecordingEdit.SwapTake swap => ChangeParts(swap.ClipId, project, "Use version", (parts, clock) =>
                {
                    var index = PartIndex(swap.PartId, parts);
                    if (clock.RegionOf(swap.StartWordId) is not { } region || region == clock.RegionOf(parts[index].StartWordId))
                        throw new Refusal("Choose a version from another recording.");
                    parts[index] = parts[index] with { StartWordId = swap.StartWordId, EndWordId = swap.EndWordId, TakeReason = swap.TakeReason };
                }),
                _ => throw new Refusal("This edit would make the recording or part invalid."),
            };
        }
        catch (Refusal refusal) { return new RecordingEditResult.Refused(refusal.Message); }
        catch (VoxClipException refusal) { return new RecordingEditResult.Refused(refusal.Message); }
    }

    private static RecordingEditResult.Applied Start(string key, Project project)
    {
        if (EditingEngine.FromProject(project) is not { } state || state.Clips.Count >= 64)
            throw new Refusal("Choose a spoken recording with words and room for another clip.");
        var clock = state.ProjectClock ?? ProjectClock.Build(project);
        var takes = TakeMatch.Build(clock).Beats.SelectMany(beat => beat.Takes).Where(take => take.Key == key).ToArray();
        var leftOut = takes.Where(take => take.Flags.Contains("restart") || take.Flags.Contains("falseStart")).ToArray();
        var omitted = leftOut.Select(take => take.StartWordId).ToHashSet();
        var id = FreshId("recording-clip", state.Clips.Select(clip => clip.Id).ToHashSet());
        var parts = new List<ClipPart>();
        var separated = true;
        foreach (var take in takes)
        {
            if (omitted.Contains(take.StartWordId)) { separated = true; continue; }
            if (separated)
                parts.Add(new(parts.Count == 0 ? id : $"part-{parts.Count + 1}", take.StartWordId, take.EndWordId));
            else
                parts[^1] = parts[^1] with { EndWordId = take.EndWordId };
            separated = false;
        }
        if (parts.Count == 0 || StoryClips.Indices(parts.Select(part => (part.StartWordId, part.EndWordId)), clock.Words) is not { } ranges)
            throw new Refusal("Choose a spoken recording with a line to keep.");
        var title = EditingAlgorithms.ClipTitle(ranges.SelectMany(range => Enumerable.Range(range.Start, range.End - range.Start + 1))
            .Select(index => state.Corrections.GetValueOrDefault(clock.Words[index].Id, clock.Words[index].Text)));
        var clip = new ClipRange(id, parts[0].StartWordId, parts[^1].EndWordId, title, ClipOrigin.Manual, null, null, true,
            Parts: parts.Count > 1 ? parts : null, Kind: parts.Count > 1 ? StoryClipKind.Story : null);
        var active = state.Clips.FirstOrDefault(clip => clip.Id == state.ActiveClipId);
        var original = active is not null && NeedsPaidCopy(active, clip, project, clock.Words) ? active : null;
        var applied = AddShortcutClip(clip, original, project, state, "Start from recording");
        var added = applied.Project.Edits.Clips[^1];
        return applied with { Details = new(added.Id, added.PlayParts.Select(part => part.Id).ToArray(), leftOut) };
    }

    private static string FreshId(string basis, HashSet<string> reserved)
    {
        for (var number = 1; ; number++)
        {
            var suffix = number == 1 ? "" : $"-{number}";
            var id = basis[..Math.Min(basis.Length, 64 - suffix.Length)] + suffix;
            if (!reserved.Contains(id)) return id;
        }
    }

    private static bool NeedsPaidCopy(ClipRange original, ClipRange changed, Project project, IReadOnlyList<TimedWord> words)
    {
        var before = StoryClips.Times(original, words);
        var after = StoryClips.Times(changed, words);
        if (!before.SequenceEqual(after) && project.VoiceLab.WholeClipRevoices?.Any(record => record.ClipId == original.Id) == true) return true;
        var protectedSpans = ProtectedSpans(original.Id, project, words);
        return StoryClips.LipsyncWindows(project).Any(window => before.Any(span => StoryClips.Contains(span, window)) &&
            !after.Any(span => StoryClips.Contains(span, window)) && !protectedSpans.Any(span => StoryClips.Contains(span, window)));
    }

    private static RecordingEditResult.Applied AddShortcutClip(ClipRange clip, ClipRange? original, Project project, EditState state, string name)
    {
        if (state.Clips.Count >= 64) throw new Refusal("There isn't room for another clip.");
        string? announcement = null;
        if (original is not null)
        {
            var index = state.Clips.ToList().FindIndex(clip => clip.Id == original.Id);
            var title = string.Concat((original.Title ?? $"Clip {index + 1}").EnumerateRunes().Take(EditingLimits.MaxClipTitleCodePoints - 5)) + " copy";
            var id = FreshId(original.Id[..Math.Min(original.Id.Length, 59)] + "-copy", state.Clips.Select(clip => clip.Id).ToHashSet());
            clip = clip with { Id = id, Title = title };
            project = RecordCopy(project, id, original.Id);
            announcement = $"Made {title} to keep the paid voice work.";
        }
        var added = EditingSession.Reduce(state, new EditOperation.AddClip(clip), project.Ai.Results, project);
        if (added.Clips.Count <= state.Clips.Count) throw new Refusal("Choose up to 12 non-overlapping parts in the clip's transcript.");
        var selected = EditingSession.Reduce(added, new EditOperation.SetActiveClip(clip.Id));
        return new(EditingEngine.ApplyToProject(project, selected), name, announcement);
    }

    private static Project Adding(RecordingEdit.AddSpokenSource add, Project project)
    {
        var sources = project.Media.SpokenSources ?? [];
        var companions = project.Media.AdditionalSources ?? [];
        if (add.Key == project.Media.Source.ContentKey || sources.Any(source => source.SourceKey == add.Key) || !companions.Any(source => source.ContentKey == add.Key))
            throw new Refusal("Choose a companion that isn't already a spoken recording.");
        if (sources.Count >= 5) throw new Refusal("A project can have up to six spoken recordings.");
        var last = sources.LastOrDefault();
        var previousEnd = last is not null && companions.FirstOrDefault(source => source.ContentKey == last.SourceKey) is { } reference
            ? last.OffsetSeconds + reference.DurationSeconds : project.Media.Source.DurationSeconds;
        var offset = Math.Ceiling(previousEnd) + 1;
        var highest = HighestPrefix(project);
        if (!(offset is >= 1 and <= int.MaxValue) || highest == int.MaxValue)
            throw new Refusal("This recording can't fit on the project clock.");
        var source = new SpokenSource(add.Key, (int)offset, FormattableString.Invariant($"r{highest + 1}."), add.Transcript, add.Label, add.GainDb);
        var result = ProjectSerialization.ForWriting(project with { Media = project.Media with { SpokenSources = [.. sources, source] } });
        _ = ProjectSerialization.Serialize(result);
        return result;
    }

    private static Project Removing(string key, Project project)
    {
        var clock = ProjectClock.Build(project);
        if (project.Media.SpokenSources is not { } sources || sources.FirstOrDefault(source => source.SourceKey == key) is not { } removed ||
            clock.Regions.FirstOrDefault(region => region.Key == key) is not { } region) throw new Refusal("Choose a companion spoken recording.");
        var ids = removed.Transcript.Words.Select(word => region.Prefix + word.Id).ToHashSet(StringComparer.Ordinal);
        bool Uses(string start, string end) => ids.Contains(start) || ids.Contains(end);
        var start = (double)region.OffsetSamples / clock.SampleRate;
        var end = (double)region.EndSample / clock.SampleRate;
        bool Overlaps(double from, double to) => from < end && start < to;
        for (var index = 0; index < project.Edits.Clips.Count; index++)
        {
            var clip = project.Edits.Clips[index];
            var count = clip.PlayParts.Count(part => Uses(part.StartWordId, part.EndWordId));
            if (count == 0) continue;
            var title = clip.Title ?? $"Clip {index + 1}";
            var parts = count == 1 ? "1 part" : $"{count} parts";
            var instruction = count == 1 ? "Remove that part first." : "Remove those parts first.";
            throw new Refusal($"{title} uses {parts} from {region.Label}. {instruction}");
        }
        var pauseIds = clock.Pauses(project.Edits.PauseThresholdSeconds).Where(pause => ids.Contains(clock.Words[pause.AfterIndex].Id))
            .Select(pause => pause.Id).ToHashSet(StringComparer.Ordinal);
        var edits = project.Edits;
        var referenced = edits.CutWordIds.Any(ids.Contains) || edits.Corrections.Keys.Any(ids.Contains) || edits.CutPauseIds.Any(pauseIds.Contains) ||
            project.Ai.Results.SelectMany(result => result.Clips).Any(clip => Uses(clip.StartWordId, clip.EndWordId) ||
                (clip.Parts ?? []).Any(part => Uses(part.StartWordId, part.EndWordId)));
        var anchored = project.CaptionTranslations.Any(item => Uses(item.StartWordId, item.EndWordId)) ||
            project.ClipEffects.Any(item => Overlaps(item.GetProperty("start").GetDouble(), item.GetProperty("end").GetDouble()) ||
                item.TryGetProperty("wordIds", out var words) && words.EnumerateArray().Any(word => ids.Contains(word.GetString()!))) ||
            (project.Media.Footage ?? []).Any(item => Overlaps(item.Start, item.End)) ||
            project.MotionCues.Any(item => Overlaps(item.SourceStart, item.SourceEnd)) ||
            project.VoiceLab.Segments.Any(item => Overlaps(item.Replace.Start, item.Replace.End)) ||
            project.Music.SelectMany(item => item.Segments ?? []).Any(segment => start <= segment.AnchorSeconds && segment.AnchorSeconds < end);
        if (referenced || anchored) throw new Refusal($"{region.Label} is used by edits or items. Remove them first.");
        var extensions = new Dictionary<string, JsonElement>(project.Extensions ?? new Dictionary<string, JsonElement>(), StringComparer.Ordinal)
        {
            [PrefixHighWater] = JsonSerializer.SerializeToElement(HighestPrefix(project), ProjectJsonContext.Default.Int32),
        };
        var remaining = sources.Where(source => source.SourceKey != key).ToArray();
        var editsAfterRemoval = edits with { Clips = edits.Clips.Select(clip =>
        {
            var retained = clip.DisplacedVersions?.Where(saved => !Uses(saved.StartWordId, saved.EndWordId)).ToArray();
            return clip with
            {
                DisplacedVersions = remaining.Length > 0 && retained is { Length: > 0 } ? retained : null,
                Parts = remaining.Length == 0 ? clip.Parts?.Select(part => part with { TakeReason = null }).ToArray() : clip.Parts,
            };
        }).ToArray() };
        var result = project with { Media = project.Media with { SpokenSources = remaining.Length == 0 ? null : remaining },
            Edits = editsAfterRemoval, Extensions = extensions };
        return result with { SchemaVersion = ProjectSerialization.WrittenVersion(result) };
    }

    private static int HighestPrefix(Project project)
    {
        var active = project.Media.SpokenSources?.Select(source => ProjectClock.PrefixNumber(source.WordIdPrefix) ?? 1).DefaultIfEmpty(1).Max() ?? 1;
        return project.Extensions?.TryGetValue(PrefixHighWater, out var value) == true && value.ValueKind == JsonValueKind.Number &&
            value.TryGetInt32(out var reserved) ? Math.Max(reserved, active) : active;
    }

    private static RecordingEditResult ChangeParts(string id, Project project, string name, Action<List<ClipPart>, ProjectClock> change)
    {
        if (EditingEngine.FromProject(project) is not { } state || state.Clips.FirstOrDefault(clip => clip.Id == id) is not { } clip)
            throw new Refusal("Choose a clip first.");
        var clock = state.ProjectClock ?? ProjectClock.Build(project);
        var parts = clip.PlayParts.ToList();
        change(parts, clock);
        if (parts.SequenceEqual(clip.PlayParts)) return new RecordingEditResult.Applied(project, name);
        if (!parts.All(part => clock.ContainsRange(part.StartWordId, part.EndWordId))) throw new Refusal("A part comes from one recording.");
        var changed = EditingSession.Reduce(state, new EditOperation.SetClipParts(id, parts), project.Ai.Results, project, "copy");
        if (ReferenceEquals(changed, state)) throw new Refusal("Choose non-overlapping parts in the clip's transcript.");
        var result = EditingEngine.ApplyToProject(project, changed);
        if (changed.Clips.Count <= state.Clips.Count) return new RecordingEditResult.Applied(result, name);
        var copy = changed.Clips[^1];
        result = RecordCopy(result, copy.Id, id);
        return new RecordingEditResult.Applied(result, name, $"Made {copy.Title ?? "a copy"} to keep the paid voice work.");
    }

    private static int PartIndex(string id, List<ClipPart> parts) => parts.FindIndex(part => part.Id == id) is var index && index >= 0
        ? index : throw new Refusal("That part isn't in the clip.");

    private static void Insert(ClipPart part, string? after, List<ClipPart> parts, int defaultIndex) =>
        parts.Insert(after is null ? defaultIndex : PartIndex(after, parts) + 1, part);

    internal static Project RecordCopy(Project project, string copy, string original)
    {
        var extensions = new Dictionary<string, JsonElement>(project.Extensions ?? new Dictionary<string, JsonElement>(), StringComparer.Ordinal);
        var origins = extensions.TryGetValue(CopyOrigins, out var value) && value.ValueKind == JsonValueKind.Object
            ? value.EnumerateObject().ToDictionary(property => property.Name, property => property.Value, StringComparer.Ordinal)
            : new Dictionary<string, JsonElement>(StringComparer.Ordinal);
        origins[copy] = JsonSerializer.SerializeToElement(original, ProjectJsonContext.Default.String);
        extensions[CopyOrigins] = JsonSerializer.SerializeToElement(origins, ProjectJsonContext.Default.DictionaryStringJsonElement);
        return project with { Extensions = extensions };
    }

    internal static IReadOnlyList<TimeRange> ProtectedSpans(string copy, Project project, IReadOnlyList<TimedWord> words) =>
        project.Extensions?.TryGetValue(CopyOrigins, out var origins) == true && origins.ValueKind == JsonValueKind.Object &&
        origins.TryGetProperty(copy, out var value) && value.ValueKind == JsonValueKind.String &&
        project.Edits.Clips.FirstOrDefault(clip => clip.Id == value.GetString()) is { } original ? StoryClips.Times(original, words) : [];

    internal static bool IsRecordingCopy(string id, Project project) =>
        project.Extensions?.TryGetValue(CopyOrigins, out var origins) == true && origins.ValueKind == JsonValueKind.Object &&
        origins.TryGetProperty(id, out var value) && value.ValueKind == JsonValueKind.String;

    private sealed class Refusal(string message) : Exception(message);
}
