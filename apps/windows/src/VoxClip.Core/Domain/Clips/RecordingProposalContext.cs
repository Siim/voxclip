using System.Globalization;
using VoxClip.Core.Domain.Editing;

namespace VoxClip.Core.Domain.Clips;

/// <summary>Recording regions and matched takes on the proposal's word index.</summary>
public sealed class RecordingProposalContext
{
    private sealed record Recording(string Key, string Label, ClipIndexRange Words);
    private sealed record Version(TakeMatch.Take Take, ClipIndexRange Words);
    private sealed record Beat(string Id, IReadOnlyList<Version> Versions);

    private readonly Recording[] recordings;
    private readonly Beat[] beats;
    private readonly ClipIndexRange[] solo;

    private RecordingProposalContext(ProjectClock clock)
    {
        var indices = clock.Words.Select((word, index) => (word.Id, index)).ToDictionary(entry => entry.Id, entry => entry.index);
        var byKey = clock.Words.Select((word, index) => (Key: clock.RegionOf(word.Id)?.Key, Index: index))
            .Where(entry => entry.Key is not null).ToLookup(entry => entry.Key!, entry => entry.Index);
        recordings = clock.Regions.Where(region => byKey.Contains(region.Key)).Select(region =>
            new Recording(region.Key, region.Label, new(byKey[region.Key].First(), byKey[region.Key].Last()))).ToArray();
        var match = TakeMatch.Build(clock);
        ClipIndexRange Range(string start, string end) => new(indices[start], indices[end]);
        beats = match.Beats.Select(beat => new Beat(beat.Id, beat.Takes.Select(take =>
            new Version(take, Range(take.StartWordId, take.EndWordId))).ToArray())).ToArray();
        solo = match.Solo.Select(run => Range(run.StartWordId, run.EndWordId)).ToArray();
    }

    /// <summary>Build metadata only for a clock with more than one region.</summary>
    public static RecordingProposalContext? Create(ProjectClock clock) => clock.Regions.Count > 1 ? new(clock) : null;

    /// <summary>Whether at least two recordings have transcript words to compare.</summary>
    public bool CanCompare => recordings.Length >= 2;

    internal bool Contains(ClipIndexRange range) => recordings.Any(recording =>
        recording.Words.Start <= range.Start && recording.Words.End >= range.End);

    internal IEnumerable<string> BeatIds(ClipIndexRange range) => beats.Where(beat =>
        beat.Versions.Any(version => version.Words.Intersection(range) > 0)).Select(beat => beat.Id);

    internal string Block(string unit, Func<ClipIndexRange, ClipIndexRange> bounds, ClipIndexRange? scope = null)
    {
        ClipIndexRange? Visible(ClipIndexRange words) => scope is not { } limit ? words : words.Intersection(limit) == 0 ? null :
            new(Math.Max(words.Start, limit.Start), Math.Min(words.End, limit.End));
        string Describe(ClipIndexRange words)
        {
            var span = bounds(words);
            return string.Create(CultureInfo.InvariantCulture, $"{unit} {span.Start}–{span.End}");
        }
        var labels = recordings.ToDictionary(recording => recording.Key, recording => recording.Label);
        var lines = new List<string> { "<recordings>" };
        foreach (var recording in recordings)
            if (Visible(recording.Words) is { } words) lines.Add($"Recording {recording.Label}: {Describe(words)}");
        lines.AddRange(["</recordings>", "<takes>"]);
        foreach (var beat in beats)
        {
            var versionLines = new List<string>();
            foreach (var version in beat.Versions)
            {
                if (Visible(version.Words) is not { } words) continue;
                var take = version.Take;
                var signals = take.Signals;
                var flags = take.Flags.Count == 0 ? "none" : string.Join(", ", take.Flags);
                versionLines.Add(string.Create(CultureInfo.InvariantCulture, $"- {labels.GetValueOrDefault(take.Key, take.Key)} {Describe(words)}; flags: {flags}; fillers: {signals.Fillers}; longest pause: {EditingFormat.ToFixed1(signals.LongestPause)}s; restarts: {signals.Restarts}; cut off: {signals.CutOff.ToString().ToLowerInvariant()}"));
            }
            if (versionLines.Count == 0) continue;
            lines.Add($"Beat {beat.Id}:");
            lines.AddRange(versionLines);
        }
        foreach (var range in solo)
            if (Visible(range) is { } words) lines.Add($"Solo: {Describe(words)}");
        lines.Add("</takes>");
        return string.Join('\n', lines);
    }
}
