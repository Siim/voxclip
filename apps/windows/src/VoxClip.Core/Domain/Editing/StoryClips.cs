using System.Text;
using System.Text.RegularExpressions;
using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Domain.VoiceLab;

namespace VoxClip.Core.Domain.Editing;

internal static class StoryClips
{
    private static readonly Regex PartId = new(@"\A[A-Za-z0-9][A-Za-z0-9._:-]{0,63}\z", RegexOptions.CultureInvariant);

    internal static IReadOnlyList<(int Start, int End)>? Indices(IEnumerable<(string Start, string End)> parts, IReadOnlyList<TimedWord> words)
    {
        var ids = new Dictionary<string, int>(StringComparer.Ordinal);
        for (var index = 0; index < words.Count; index++) ids.TryAdd(words[index].Id, index);
        var result = new List<(int Start, int End)>();
        foreach (var (startId, endId) in parts)
        {
            if (!ids.TryGetValue(startId, out var start) || !ids.TryGetValue(endId, out var end) || start > end) return null;
            result.Add((start, end));
        }
        var sorted = result.OrderBy(range => range.Start).ToArray();
        return sorted.Zip(sorted.Skip(1)).All(pair => pair.First.End < pair.Second.Start) ? result : null;
    }

    internal static bool Valid(ClipRange clip, IReadOnlyList<TimedWord> words)
    {
        if (clip.Parts is not { } parts) return clip.Kind is null;
        return parts.Count is >= 2 and <= 12 && parts.Select(part => part.Id).Distinct(StringComparer.Ordinal).Count() == parts.Count &&
            parts.All(part => PartId.IsMatch(part.Id) && (part.Reframe is null ||
                part.Reframe is { Mode: ReframeSettings.FaceMode, Zoom: 1, CenterX: >= 0 and <= 1, CenterY: >= 0 and <= 1 })) &&
            clip.PlayPartIndices(words) is { } ranges && clip.StartWordId == words[ranges.Min(range => range.Start)].Id &&
            clip.EndWordId == words[ranges.Max(range => range.End)].Id;
    }

    internal static Project ForWriting(Project project)
    {
        if (project.SchemaVersion is < 1 or > 5) return project;
        if (project.Edits.Clips.Any(clip => clip.Parts is not null))
            return (project.SchemaVersion < 4 ? ContextDemo.ContextDemoProject.UpgradeToV4(project) : project) with { SchemaVersion = 5 };
        if (project.SchemaVersion == 5) project = project with { SchemaVersion = 4 };
        if (!project.Ai.Results.Any(result => result.Clips.Any(clip => clip.Parts is not null || clip.NotInTake is not null))) return project;
        return project with { Ai = new(project.Ai.Results.Select(result => result with
        {
            Clips = result.Clips.Select(clip => clip with { Parts = null, NotInTake = null }).ToArray()
        }).ToArray()) };
    }

    internal static void Validate(Project project)
    {
        var words = project.Transcript?.Words ?? [];
        Require(project.SchemaVersion >= TimelineEditFields.Version || (project.SchemaVersion == 5) == project.Edits.Clips.Any(clip => clip.Parts is not null), "Invalid story clip project version.");
        foreach (var clip in project.Edits.Clips)
        {
            Require(Valid(clip, words), "Invalid story clip parts or source hull.");
            if (clip.Parts is not null) ValidatePlacement(clip, project, words);
        }
        foreach (var clip in project.Ai.Results.SelectMany(result => result.Clips))
        {
            Require(clip.NotInTake is null || clip.NotInTake.EnumerateRunes().Count() <= 200, "Invalid missing-from-take note.");
            if (clip.Parts is { } parts)
                Require(parts.Count is >= 2 and <= 12 && Indices(parts.Select(part => (part.StartWordId, part.EndWordId)), words) is not null,
                    "Invalid AI clip parts.");
        }
    }

    internal static IReadOnlyList<TimeRange> Times(ClipRange clip, IReadOnlyList<TimedWord> words) =>
        clip.PlayPartIndices(words)?.Select((range, index) => EditingAlgorithms.ClipTimes(words, range.Start, range.End,
            index == 0 ? clip.LeadInSeconds : null)).ToArray() ?? [];

    internal static IEnumerable<TimeRange> LipsyncWindows(Project project)
    {
        var rate = (double)(project.Media.Source.Audio?.SampleRate ?? 48_000);
        foreach (var candidate in project.VoiceLab.Segments.SelectMany(segment => segment.Candidates))
            if (candidate.Recipe?.Video is { Mode: VoiceLabVideoMode.Lipsync, WindowStartSample: { } start, WindowEndSample: { } end } && start < end)
                yield return new(start / rate, end / rate);
    }

    internal static void ValidatePlacement(ClipRange clip, Project project, IReadOnlyList<TimedWord> words)
    {
        var spans = Times(clip, words);
        foreach (var window in LipsyncWindows(project))
            for (var index = 0; index < spans.Count; index++)
                Require(!Overlaps(spans[index], window) || Contains(spans[index], window),
                    $"Part {index + 1} cuts through a lip-synced stretch. Include all of {Clock(window.Start)}–{Clock(window.End)} or none of it.");
        foreach (var effect in project.ClipEffects.Where(effect => effect.GetProperty("clipId").GetString() == clip.Id))
            Require(spans.Any(span => Contains(span, new(effect.GetProperty("start").GetDouble(), effect.GetProperty("end").GetDouble()))),
                "Place it inside one part.");
    }

    internal static bool Overlaps(TimeRange span, TimeRange window) => span.Start < window.End && window.Start < span.End;
    private static bool Contains(TimeRange span, TimeRange window) => span.Start <= window.Start && window.End <= span.End;
    private static string Clock(double seconds) => $"{(long)seconds / 60}:{(long)seconds % 60:00}";
    private static void Require(bool condition, string message)
    {
        if (!condition) throw new VoxClipException(VoxClipErrorCode.ProjectUnreadable, message);
    }
}
