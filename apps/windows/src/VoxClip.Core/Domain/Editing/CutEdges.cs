using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Domain.Transcript;

namespace VoxClip.Core.Domain.Editing;

/// <summary>Cut edges seated in the quiet (editing §5.10). When one word is cut out of fluent speech, the edge between it and its kept
/// neighbour moves to the nearest quiet point and is stored in <c>edits.cutEdges</c>; word times never change. Pure. Words are one
/// recording's, in that recording's local seconds, with clock ids. Numbers follow editing §2.6: binary64 in the written order, float
/// levels read as doubles, frame choices in integers. Twin of the Mac <c>CutEdges</c>; the generator twin is
/// tools/fixtures/editing/lib/cutedges.mjs.</summary>
public static class CutEdges
{
    /// <summary>How far an edge may move from the word edge, in seconds.</summary>
    public const double Reach = 0.15;
    /// <summary>At this gap or more the 0.1 s pad already lands in the gap, so the boundary keeps no key.</summary>
    public const double MaxGap = 0.2;
    /// <summary>A quiet point is a run of at least this many 10 ms frames.</summary>
    public const int MinimumRun = 2;

    /// <summary>What keeps a boundary at today's padding (§3.2): Voice Lab replace ranges in this recording's local seconds, and the
    /// word ranges of paid scopes (a clip with a whole-clip revoice or lip sync, a Rewrite with takes) by clock id.</summary>
    public sealed record Freeze(IReadOnlyList<TimeRange> VoiceRanges, IReadOnlyList<ClipWordRange> PaidScopes)
    {
        /// <summary>Nothing frozen.</summary>
        public static Freeze None { get; } = new([], []);
    }

    /// <summary>New keys, and the boundaries that would have moved but sit beside a voice patch or a paid scope.</summary>
    public sealed record Seating(IReadOnlyDictionary<string, double> Edges, int Frozen);

    /// <summary>One recording's words in its local seconds, with clock ids, and the key its envelope is cached under.</summary>
    public sealed record Recording(string Key, IReadOnlyList<TimedWord> Words);

    /// <summary>The inline offer (§6): <paramref name="Count"/> boundaries without a key that would move, <paramref name="Frozen"/> kept
    /// beside voice patches, and the recordings with a qualifying boundary whose envelope is not loaded.</summary>
    public sealed record OfferSummary(int Count, int Frozen, IReadOnlyList<string> Unloaded);

    /// <summary>§3.1's qualifying boundary between <paramref name="a"/> = words[i−1] and <paramref name="b"/> = words[i], apart from "no
    /// key yet": both are speech, exactly one is cut, and the gap is at least 0 and under 0.2 s.</summary>
    public static bool Qualifies(TimedWord a, TimedWord b, IReadOnlySet<string> cutWordIds)
    {
        if (!IsSpeech(a) || !IsSpeech(b) || cutWordIds.Contains(a.Id) == cutWordIds.Contains(b.Id)) return false;
        var gap = b.Start - a.End;
        return gap >= 0 && gap < MaxGap;
    }

    /// <summary>§3.1 over one recording: a key for each qualifying boundary without one (only those named by <paramref name="only"/>
    /// when given).</summary>
    public static Seating Seat(IReadOnlyList<TimedWord> words, IReadOnlySet<string> cutWordIds, AudioEnvelope envelope, double sampleRate,
        Freeze? freeze = null, IReadOnlyDictionary<string, double>? existing = null, IReadOnlySet<string>? only = null)
    {
        var edges = new Dictionary<string, double>(StringComparer.Ordinal);
        var frozen = 0;
        if (words.Count < 2 || !double.IsFinite(sampleRate) || sampleRate <= 0 || Analyze(words, envelope) is not { } analysis)
            return new(edges, frozen);
        freeze ??= Freeze.None;
        var positions = new Dictionary<string, int>(StringComparer.Ordinal);
        for (var index = 0; index < words.Count; index++) positions.TryAdd(words[index].Id, index);
        for (var index = 1; index < words.Count; index++)
        {
            var a = words[index - 1];
            var b = words[index];
            if (!Qualifies(a, b, cutWordIds) || existing?.ContainsKey(b.Id) == true || only?.Contains(b.Id) == false ||
                QuietPoint(a, b, analysis, sampleRate) is not { } point) continue;
            if (Frozen(a, b, cutWordIds, point.Window, freeze, positions)) frozen++;
            else edges[b.Id] = point.Value;
        }
        return new(edges, frozen);
    }

    /// <summary>§3.4 for one recording: the keys still at a qualifying kept/cut boundary, in word order.</summary>
    public static IReadOnlyDictionary<string, double> Normalized(IReadOnlyDictionary<string, double> edges, IReadOnlyList<TimedWord> words,
        IReadOnlySet<string> cutWordIds)
    {
        var result = new Dictionary<string, double>(StringComparer.Ordinal);
        for (var index = 1; index < words.Count; index++)
            if (edges.TryGetValue(words[index].Id, out var edge) && Qualifies(words[index - 1], words[index], cutWordIds))
                result[words[index].Id] = edge;
        return result;
    }

    /// <summary>Each recording's words in local seconds with clock ids, in clock order.</summary>
    public static IReadOnlyList<Recording> Recordings(Project project)
    {
        if (project.Transcript is not { } transcript) return [];
        var result = new List<Recording> { new(project.Media.Source.ContentKey, transcript.Words) };
        foreach (var source in project.Media.SpokenSources ?? [])
            result.Add(new(source.SourceKey, source.Transcript.Words.Select(word => word with { Id = source.WordIdPrefix + word.Id }).ToArray()));
        return result;
    }

    /// <summary>§3.4 on every commit: drops keys no longer at a qualifying kept/cut boundary, so a cut followed by a restore leaves the
    /// edits as they were, and writes the version the fields now need (editing §10.1).</summary>
    public static Project Normalize(Project project)
    {
        var result = project;
        if (project.Edits.CutEdges is { } edges)
        {
            var cut = CutSet(project);
            var kept = new Dictionary<string, double>(StringComparer.Ordinal);
            foreach (var recording in Recordings(project))
                foreach (var (id, edge) in Normalized(edges, recording.Words, cut)) kept.TryAdd(id, edge);
            result = project with { Edits = project.Edits with { CutEdges = kept.Count > 0 ? kept : null } };
        }
        return ProjectSerialization.Framed(result);
    }

    /// <summary>§3.3: seats the boundaries whose kept/cut state changed from <paramref name="before"/> to <paramref name="after"/>, in the
    /// same step, then normalizes. A recording without a loaded envelope gets no key, so today's padding applies there.</summary>
    public static Project Finalize(Project before, Project after, IReadOnlyDictionary<string, AudioEnvelope> envelopes,
        IReadOnlyDictionary<string, Freeze>? freeze = null)
    {
        var was = CutSet(before);
        var cut = CutSet(after);
        var rate = ClockRate(after);
        var edges = new Dictionary<string, double>(after.Edits.CutEdges ?? new Dictionary<string, double>(), StringComparer.Ordinal);
        foreach (var recording in Recordings(after))
        {
            if (!envelopes.TryGetValue(recording.Key, out var envelope)) continue;
            var changed = ChangedBoundaries(recording.Words, was, cut);
            if (changed.Count == 0) continue;
            var seated = Seat(recording.Words, cut, envelope, rate, freeze?.GetValueOrDefault(recording.Key), edges, changed);
            foreach (var (id, edge) in seated.Edges) edges[id] = edge;
        }
        return Normalize(after with { Edits = after.Edits with { CutEdges = edges.Count > 0 ? edges : null } });
    }

    /// <summary>§6: what "Fix cut edges" would do now, over every qualifying boundary without a key.</summary>
    public static OfferSummary Offer(Project project, IReadOnlyDictionary<string, AudioEnvelope> envelopes,
        IReadOnlyDictionary<string, Freeze>? freeze = null) => Fixing(project, envelopes, freeze).Offer;

    /// <summary>§6 "Fix cut edges": seats every qualifying boundary without a key, as one step.</summary>
    public static (Project Project, OfferSummary Offer) Fix(Project project, IReadOnlyDictionary<string, AudioEnvelope> envelopes,
        IReadOnlyDictionary<string, Freeze>? freeze = null)
    {
        var (added, offer) = Fixing(project, envelopes, freeze);
        var edges = new Dictionary<string, double>(project.Edits.CutEdges ?? new Dictionary<string, double>(), StringComparer.Ordinal);
        foreach (var (id, edge) in added) edges[id] = edge;
        return (Normalize(project with { Edits = project.Edits with { CutEdges = edges.Count > 0 ? edges : null } }), offer);
    }

    /// <summary>Editing §5.10 validation, strict and run before every commit: keys name a word at index 1 or later in the same recording
    /// as the word before it, with a gap of at least 0 and under 0.2 s; values are finite, within the word edge ± (0.15 s + one
    /// sample), and strictly inside the two words. A key at a boundary that is no longer kept/cut is accepted and ignored by the
    /// planner, as unknown cut ids are.</summary>
    internal static void Validate(Project project)
    {
        if (project.Edits.CutEdges is not { Count: > 0 } edges) return;
        Require(project.SchemaVersion >= ProjectSerialization.FrameVersion, "Cut edges require project version 8.");
        var rate = ClockRate(project);
        var found = 0;
        foreach (var recording in Recordings(project))
        {
            var words = recording.Words;
            for (var index = 0; index < words.Count; index++)
            {
                var b = words[index];
                if (!edges.TryGetValue(b.Id, out var value)) continue;
                found++;
                Require(index >= 1, "A cut edge needs a word before it in the same recording.");
                var a = words[index - 1];
                var gap = b.Start - a.End;
                var edge = (a.End + b.Start) / 2;
                Require(gap >= 0 && gap < MaxGap, "A cut edge sits between touching words.");
                Require(double.IsFinite(value) && Math.Abs(value - edge) <= Reach + 1 / rate && value > a.Start && value < b.End,
                    "A cut edge lies within 0.15 s of its word edge.");
            }
        }
        Require(found == edges.Count, "A cut edge names a word that does not exist.");
    }

    /// <summary>A stored cut edge in recording-local seconds on the clock: shifted by its recording's offset as ProjectClock shifts
    /// words, unchanged in the first recording.</summary>
    internal static double ClockTime(EditState state, double local, string wordId)
    {
        if (state.ProjectClock is not { } clock || clock.RegionOf(wordId) is not { OffsetSamples: > 0 } region) return local;
        double rate = clock.SampleRate;
        return (region.OffsetSamples + EditingMath.Round(local * rate)) / rate;
    }

    // Steps

    private readonly record struct Point(double Value, TimeRange Window);

    private static bool IsSpeech(TimedWord word) => word.Kind is WordKind.Word or WordKind.UnlabeledSpeech;

    /// <summary>The ProjectClock sample rate R.</summary>
    private static double ClockRate(Project project) => Math.Max(1, project.Media.Source.Audio?.SampleRate ?? 48_000);

    private static HashSet<string> CutSet(Project project) => new(project.Edits.CutWordIds, StringComparer.Ordinal);

    /// <summary>The import level analysis (editing §5.6) over the recording's words, or null when the envelope cannot be read.</summary>
    private static EditingAlgorithms.Analysis? Analyze(IReadOnlyList<TimedWord> words, AudioEnvelope envelope)
    {
        if (envelope.SampleRate <= 0 || envelope.Rms.Any(level => !float.IsFinite(level) || level < 0) ||
            words.Any(word => !double.IsFinite(word.Start) || !double.IsFinite(word.End))) return null;
        return EditingAlgorithms.AnalyzeItems(words, envelope, null);
    }

    /// <summary>§3.1 steps 1–8 for one boundary: the centre of the nearest quiet run, or null when the edge stays.</summary>
    private static Point? QuietPoint(TimedWord a, TimedWord b, EditingAlgorithms.Analysis analysis, double sampleRate)
    {
        var levels = analysis.Envelope.Rms;
        var frameLength = analysis.FrameLength;
        var edge = (a.End + b.Start) / 2;
        var edgeFrame = analysis.FrameAt(edge);
        var edgeLevel = (double)levels[edgeFrame];
        if (!(edgeLevel > Math.Max(analysis.Threshold, 0.35 * analysis.SpeechLevel))) return null;
        var quiet = Math.Max(analysis.Threshold, Math.Min(0.5 * edgeLevel, 0.35 * analysis.SpeechLevel));
        var lowTime = Math.Max(edge - Reach, a.Start + Math.Max(0.04, 0.5 * (a.End - a.Start)));
        var highTime = Math.Min(edge + Reach, b.End - Math.Max(0.04, 0.5 * (b.End - b.Start)));
        var lowFrame = Math.Max(0, Math.Ceiling(lowTime / frameLength));
        var highFrame = Math.Min(levels.Count - 1, Math.Floor(highTime / frameLength) - 1);
        if (!double.IsFinite(lowFrame) || !double.IsFinite(highFrame) || lowFrame > highFrame) return null;
        var high = (int)highFrame;
        (int First, int Last, int Distance, double Minimum)? best = null;
        var first = (int)lowFrame;
        while (first <= high)
        {
            if (!(levels[first] <= quiet))
            {
                first++;
                continue;
            }
            var last = first;
            var minimum = (double)levels[first];
            while (last + 1 <= high && levels[last + 1] <= quiet)
            {
                last++;
                minimum = Math.Min(minimum, levels[last]);
            }
            if (last - first + 1 >= MinimumRun)
            {
                var distance = first > edgeFrame ? first - edgeFrame : edgeFrame - last;
                if (best is not { } current || distance < current.Distance || distance == current.Distance && minimum < current.Minimum)
                    best = (first, last, distance, minimum);
            }
            first = last + 1;
        }
        if (best is not { } run) return null;
        var time = (double)(run.First + run.Last + 1) / 2 * frameLength;
        return new(EditingMath.Round(time * sampleRate) / sampleRate, new(lowTime, highTime));
    }

    /// <summary>§3.2: a Voice Lab replace range overlaps the window, or the kept word lies inside a paid scope and the cut word outside
    /// it.</summary>
    private static bool Frozen(TimedWord a, TimedWord b, IReadOnlySet<string> cutWordIds, TimeRange window, Freeze freeze,
        IReadOnlyDictionary<string, int> positions)
    {
        if (freeze.VoiceRanges.Any(range => range.Start < window.End && window.Start < range.End)) return true;
        var (kept, removed) = cutWordIds.Contains(a.Id) ? (b, a) : (a, b);
        return freeze.PaidScopes.Any(scope =>
            positions.TryGetValue(scope.StartWordId, out var low) && positions.TryGetValue(scope.EndWordId, out var high) &&
            positions.TryGetValue(kept.Id, out var keptIndex) && positions.TryGetValue(removed.Id, out var removedIndex) &&
            low <= keptIndex && keptIndex <= high && !(low <= removedIndex && removedIndex <= high));
    }

    /// <summary>The boundaries whose kept/cut state differs between two cut sets, named by the later word.</summary>
    private static HashSet<string> ChangedBoundaries(IReadOnlyList<TimedWord> words, IReadOnlySet<string> before, IReadOnlySet<string> after)
    {
        var result = new HashSet<string>(StringComparer.Ordinal);
        for (var index = 1; index < words.Count; index++)
        {
            var a = words[index - 1].Id;
            var b = words[index].Id;
            if (before.Contains(a) != after.Contains(a) || before.Contains(b) != after.Contains(b)) result.Add(b);
        }
        return result;
    }

    private static (IReadOnlyDictionary<string, double> Edges, OfferSummary Offer) Fixing(Project project,
        IReadOnlyDictionary<string, AudioEnvelope> envelopes, IReadOnlyDictionary<string, Freeze>? freeze)
    {
        var edges = new Dictionary<string, double>(StringComparer.Ordinal);
        int count = 0, frozen = 0;
        var unloaded = new List<string>();
        var existing = project.Edits.CutEdges ?? new Dictionary<string, double>();
        var cut = CutSet(project);
        var rate = ClockRate(project);
        foreach (var recording in Recordings(project))
        {
            var words = recording.Words;
            if (!envelopes.TryGetValue(recording.Key, out var envelope))
            {
                var open = false;
                for (var index = 1; index < words.Count && !open; index++)
                    open = !existing.ContainsKey(words[index].Id) && Qualifies(words[index - 1], words[index], cut);
                if (open) unloaded.Add(recording.Key);
                continue;
            }
            var seated = Seat(words, cut, envelope, rate, freeze?.GetValueOrDefault(recording.Key), existing);
            foreach (var (id, edge) in seated.Edges) edges[id] = edge;
            count += seated.Edges.Count;
            frozen += seated.Frozen;
        }
        return (edges, new(count, frozen, unloaded));
    }

    private static void Require(bool condition, string message)
    {
        if (!condition) throw new VoxClipException(VoxClipErrorCode.ProjectUnreadable, message);
    }
}
