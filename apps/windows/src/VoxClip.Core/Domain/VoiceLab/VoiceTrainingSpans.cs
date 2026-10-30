#pragma warning disable CS1591 // The selection records are documented together in voice-lab.md §6.5.1 and training-spans-README.md.
using System.Text.Json.Serialization;
using VoxClip.Core.Domain.Shared;

namespace VoxClip.Core.Domain.VoiceLab;

/// <summary>One transcript item as the selection reads it; times are source seconds.</summary>
public sealed record VoiceTrainingItem(WordKind Kind, double Start, double End, double? Conf, string? Speaker, bool Synthetic);
/// <summary>A source range in seconds that must never be used for training.</summary>
public readonly record struct VoiceTrainingRange(double Start, double End);
public sealed record VoiceTrainingSpan(long StartMs, long EndMs, double SnrDb);
[JsonConverter(typeof(JsonStringEnumConverter<VoiceTrainingRejectionReason>))]
public enum VoiceTrainingRejectionReason
{
    [JsonStringEnumMemberName("short")] Short,
    [JsonStringEnumMemberName("unsplittable")] Unsplittable,
    [JsonStringEnumMemberName("lowSnr")] LowSnr
}
public sealed record VoiceTrainingRejection(long StartMs, long EndMs, VoiceTrainingRejectionReason Reason, double? SnrDb);
[JsonConverter(typeof(JsonStringEnumConverter<VoiceTrainingSpanStatus>))]
public enum VoiceTrainingSpanStatus
{
    [JsonStringEnumMemberName("ok")] Ok,
    [JsonStringEnumMemberName("belowMinimum")] BelowMinimum
}
public sealed record VoiceTrainingSpanSelection(VoiceTrainingSpanStatus Status, long AvailableMs, long SelectedMs,
    IReadOnlyList<VoiceTrainingSpan> Selected, IReadOnlyList<VoiceTrainingSpan> Qualifying, IReadOnlyList<VoiceTrainingRejection> Rejected);
/// <summary>The selection inputs taken from a project; see <see cref="VoiceTrainingSpans.Inputs"/>.</summary>
public sealed record VoiceTrainingInputs(IReadOnlyList<VoiceTrainingItem> Items, IReadOnlyList<VoiceTrainingRange> Excluded);

/// <summary>Pure §6.5.1 choice of own-voice training spans in the open project's source audio, identical on both platforms
/// (shared/fixtures/voice-lab/training-spans.json). Everything after the millisecond conversion is integer, except the SNR.</summary>
public static class VoiceTrainingSpans
{
    public const double MinConf = 0.8;
    public const long MaxGapMs = 2_000;
    public const long SpanMinMs = 5_000;
    public const long SpanMaxMs = 30_000;
    public const double VoicedDb = -45;
    public const double MinSnrDb = 20;
    public const long TotalMinMs = 30_000;
    public const long TotalMaxMs = 120_000;
    // 2^53 ms: every bound stays an exact binary64 integer, and sums of four bounds cannot overflow.
    const double MaxMs = 9_007_199_254_740_992;

    /// <summary>The transcript items in stored order, with every item of a Voice Lab segment's replaced words synthetic, and every
    /// segment's replaced source range excluded, enabled or not. Times are source seconds; cuts and corrections are ignored.</summary>
    public static VoiceTrainingInputs Inputs(Project project)
    {
        var words = project.Transcript?.Words ?? [];
        var segments = project.VoiceLab.Segments;
        var index = new Dictionary<string, int>(StringComparer.Ordinal);
        for (var position = 0; position < words.Count; position++) index.TryAdd(words[position].Id, position);
        var synthetic = new bool[words.Count];
        foreach (var segment in segments)
            if (index.TryGetValue(segment.Replace.FirstWordId, out var first) && index.TryGetValue(segment.Replace.LastWordId, out var last))
                for (var position = first; position <= last; position++) synthetic[position] = true;
        return new(words.Select((word, position) => new VoiceTrainingItem(word.Kind, word.Start, word.End, word.Conf, word.Speaker, synthetic[position])).ToArray(),
            segments.Select(segment => new VoiceTrainingRange(segment.Replace.Start, segment.Replace.End)).ToArray());
    }

    /// <summary>Usable words form runs, long runs split at their longest pause, pieces keep a take-relative SNR of at least 20 dB,
    /// and the best pieces are picked up to 120 s. Refuses non-finite numbers, reversed excluded ranges and a negative duration.</summary>
    public static VoiceTrainingSpanSelection Select(IReadOnlyList<VoiceTrainingItem> items, IReadOnlyList<VoiceTrainingRange> excluded,
        IReadOnlyList<double> frameDb, double duration)
    {
        ArgumentNullException.ThrowIfNull(items); ArgumentNullException.ThrowIfNull(excluded); ArgumentNullException.ThrowIfNull(frameDb);
        if (items.Any(item => item is null || !double.IsFinite(item.Start) || !double.IsFinite(item.End) || item.Conf is { } conf && !double.IsFinite(conf)) ||
            excluded.Any(range => !double.IsFinite(range.Start) || !double.IsFinite(range.End) || range.End < range.Start) ||
            frameDb.Any(level => !double.IsFinite(level)) || !double.IsFinite(duration) || duration < 0) throw Invalid();
        var end = Ms(duration);
        var ranges = excluded.Select(range => (Start: Ms(range.Start), End: Ms(range.End))).ToArray();
        var pieces = new List<(long Start, long End)>();
        var rejected = new List<VoiceTrainingRejection>();
        var run = new List<(long Start, long End)>();
        string? speaker = null;
        long runEnd = 0;
        foreach (var item in items)
        {
            var start = Ms(item.Start);
            var stop = Ms(item.End);
            var usable = item.Kind == WordKind.Word && (item.Conf is null || item.Conf >= MinConf) && !item.Synthetic && start < stop && stop <= end &&
                !ranges.Any(range => range.Start < stop && range.End > start);
            if (usable && run.Count > 0 && string.Equals(item.Speaker, speaker, StringComparison.Ordinal) && start - runEnd <= MaxGapMs &&
                !ranges.Any(range => range.Start < start && range.End > runEnd))
            {
                run.Add((start, stop)); runEnd = Math.Max(runEnd, stop);
                continue;
            }
            Split(run, 0, run.Count - 1, pieces, rejected);
            run.Clear();
            if (!usable) continue;
            run.Add((start, stop)); speaker = item.Speaker; runEnd = stop;
        }
        Split(run, 0, run.Count - 1, pieces, rejected);
        var levels = frameDb.ToArray();
        var sorted = levels.Order().ToArray();
        double? floor = sorted.Length == 0 ? null : sorted[sorted.Length / 10];
        var qualifying = new List<VoiceTrainingSpan>();
        foreach (var piece in pieces)
        {
            // The numerators clamp to 0 whenever they are negative, so truncating division gives the same frames as floor.
            var lo = (int)Math.Clamp((piece.Start + 5) / 10, 0, levels.Length);
            var hi = (int)Math.Clamp((piece.End + 5) / 10, 0, levels.Length);
            var voiced = levels[lo..Math.Max(lo, hi)].Where(level => level > VoicedDb).Order().ToArray();
            double? snr = voiced.Length == 0 || floor is not { } noise ? null : voiced[voiced.Length / 2] - noise;
            if (snr is { } value && value >= MinSnrDb) qualifying.Add(new(piece.Start, piece.End, value));
            else rejected.Add(new(piece.Start, piece.End, VoiceTrainingRejectionReason.LowSnr, snr));
        }
        var available = qualifying.Sum(span => span.EndMs - span.StartMs);
        var inOrder = qualifying.OrderBy(span => span.StartMs).ToArray();
        var rejections = rejected.OrderBy(rejection => rejection.StartMs).ToArray();
        if (available < TotalMinMs) return new(VoiceTrainingSpanStatus.BelowMinimum, available, 0, [], inOrder, rejections);
        var selected = new List<VoiceTrainingSpan>();
        long total = 0;
        foreach (var span in qualifying.OrderByDescending(span => span.SnrDb).ThenByDescending(span => span.EndMs - span.StartMs).ThenBy(span => span.StartMs))
        {
            if (total + span.EndMs - span.StartMs > TotalMaxMs) continue;
            selected.Add(span); total += span.EndMs - span.StartMs;
        }
        return new(VoiceTrainingSpanStatus.Ok, available, total, selected.OrderBy(span => span.StartMs).ToArray(), inOrder, rejections);
    }

    /// <summary>ms(t) = floor(t × 1000 + 0.5) in binary64.</summary>
    static long Ms(double seconds)
    {
        var value = Math.Floor(seconds * 1000 + 0.5);
        if (!double.IsFinite(value) || Math.Abs(value) > MaxMs) throw Invalid();
        return (long)value;
    }

    /// <summary>Words a..b of one run: keep 5–30 s pieces, reject shorter ones, and split longer ones at the valid boundary with the
    /// longest gap, then the gap nearest the middle, then the earliest boundary; left side first.</summary>
    static void Split(List<(long Start, long End)> words, int a, int b, List<(long Start, long End)> pieces, List<VoiceTrainingRejection> rejected)
    {
        if (b < a) return;
        var start = words[a].Start;
        var end = words.Skip(a).Take(b - a + 1).Max(word => word.End);
        if (end - start < SpanMinMs) { rejected.Add(new(start, end, VoiceTrainingRejectionReason.Short, null)); return; }
        if (end - start <= SpanMaxMs) { pieces.Add((start, end)); return; }
        var rightEnds = new long[b - a + 2];
        rightEnds[b - a + 1] = long.MinValue;
        for (var index = b; index >= a; index--) rightEnds[index - a] = Math.Max(rightEnds[index - a + 1], words[index].End);
        var best = -1;
        long bestGap = 0, bestMiddle = 0, leftEnd = long.MinValue;
        for (var boundary = a; boundary < b; boundary++)
        {
            leftEnd = Math.Max(leftEnd, words[boundary].End);
            var rightStart = words[boundary + 1].Start;
            if (leftEnd - start < SpanMinMs || rightEnds[boundary + 1 - a] - rightStart < SpanMinMs) continue;
            var gap = rightStart - leftEnd;
            var middle = Math.Abs(leftEnd + rightStart - start - end);
            if (best >= 0 && (gap < bestGap || gap == bestGap && middle >= bestMiddle)) continue;
            best = boundary; bestGap = gap; bestMiddle = middle;
        }
        if (best < 0) { rejected.Add(new(start, end, VoiceTrainingRejectionReason.Unsplittable, null)); return; }
        Split(words, a, best, pieces, rejected);
        Split(words, best + 1, b, pieces, rejected);
    }

    static VoiceLabException Invalid() => new(VoiceLabErrorKind.InvalidInput);
}
