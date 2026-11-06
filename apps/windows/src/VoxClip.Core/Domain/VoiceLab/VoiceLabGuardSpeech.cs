#pragma warning disable CS1591
using VoxClip.Core.Domain.Shared;

namespace VoxClip.Core.Domain.VoiceLab;

/// <summary>The speech a Rewrite patch's use-time guard embeds (voice-lab.md §6.9, ADR-R40; Mac <c>VoiceLabGuardSpeech</c>): the
/// transcript words' own audio nearest the patch, from the original source, joined, up to <see cref="MaximumSeconds"/>. Silence, road
/// noise and music between words are not part of it, so a noisy recording is judged on the speaker, as the enrollment statement is.
/// Where the transcript knows speakers, only the patch speaker's words count: first that speaker's turn around the patch, widened
/// outward word by word, then the same speaker's other turns nearest the patch. Another speaker's words are never taken.</summary>
public sealed record VoiceLabGuardSpeech(IReadOnlyList<(long Start, long End)> Ranges, string? Speaker)
{
    /// <summary>Speech the guard reads for a patch, in seconds of word spans.</summary>
    public const double MaximumSeconds = 10;
    /// <summary>The most of one word's span that counts, the part nearest the patch.</summary>
    public const double MaximumWordSeconds = 2;
    /// <summary>Word spans closer than this are read as one range.</summary>
    internal const double JoinSeconds = 0.01;

    /// <summary>The frames the ranges hold.</summary>
    public long Frames => Ranges.Sum(range => range.End - range.Start);

    /// <summary>The guard's word spans for the patch <paramref name="start"/>..<paramref name="end"/> (source seconds) of a source of
    /// <paramref name="totalFrames"/> frames at <paramref name="sampleRate"/>. Every transcript word counts, cut or kept: the guard asks
    /// whose voice the recording is.</summary>
    public static VoiceLabGuardSpeech Select(IReadOnlyList<TimedWord> items, double start, double end, int sampleRate, long totalFrames,
        double maximumSeconds = MaximumSeconds)
    {
        if (sampleRate <= 0 || totalFrames <= 0) return new([], null);
        var duration = (double)totalFrames / sampleRate;
        var words = items.Where(word => word.Kind == WordKind.Word && double.IsFinite(word.Start) && double.IsFinite(word.End) &&
            word.End > word.Start && word.Start < duration && word.End > 0).OrderBy(word => word.Start).ToArray();
        if (words.Length == 0) return new([], null);
        double Distance(int index) => Math.Max(0, Math.Max(start - words[index].End, words[index].Start - end));
        var labeled = words.Any(word => word.Speaker is not null);
        var speaker = labeled ? PatchSpeaker(words, Distance) : null;
        // The turn around the patch: the contiguous words that carry the patch speaker's label.
        var turn = Enumerable.Range(0, words.Length).ToHashSet();
        if (labeled)
        {
            var labelled = Enumerable.Range(0, words.Length).Where(index => words[index].Speaker == speaker).ToArray();
            int? inside = labelled.Cast<int?>().FirstOrDefault(index => Distance(index!.Value) == 0);
            int? closest = labelled.Length == 0 ? null : labelled.MinBy(Distance);
            turn = [];
            if ((inside ?? closest) is { } anchor)
            {
                int low = anchor, high = anchor;
                while (low > 0 && words[low - 1].Speaker == speaker) low--;
                while (high + 1 < words.Length && words[high + 1].Speaker == speaker) high++;
                turn = Enumerable.Range(low, high - low + 1).ToHashSet();
            }
        }
        var eligible = Enumerable.Range(0, words.Length).Where(index => !labeled || words[index].Speaker == speaker).ToList();
        eligible.Sort((left, right) =>
        {
            bool leftTurn = turn.Contains(left), rightTurn = turn.Contains(right);
            if (leftTurn != rightTurn) return leftTurn ? -1 : 1;
            var order = Distance(left).CompareTo(Distance(right));
            return order != 0 ? order : left.CompareTo(right);
        });
        var chosen = new List<(long Start, long End)>();
        double total = 0, rate = sampleRate;
        foreach (var index in eligible)
        {
            if (total >= maximumSeconds) break;
            var budget = Math.Min(MaximumWordSeconds, maximumSeconds - total);
            var (spanStart, spanEnd) = NearestPart(words[index], start, end, budget);
            var wordStart = Math.Max(0, spanStart);
            var wordEnd = Math.Min(duration, spanEnd);
            var lower = Math.Max(0, Math.Min(totalFrames, (long)Math.Floor(wordStart * rate)));
            var upper = Math.Max(lower, Math.Min(totalFrames, (long)Math.Ceiling(wordEnd * rate)));
            if (upper <= lower) continue;
            chosen.Add((lower, upper));
            total += (upper - lower) / rate;
        }
        var join = (long)Math.Round(JoinSeconds * rate, MidpointRounding.AwayFromZero);
        var merged = new List<(long Start, long End)>();
        foreach (var range in chosen.OrderBy(range => range.Start))
        {
            if (merged.Count > 0 && range.Start <= merged[^1].End + join) merged[^1] = (merged[^1].Start, Math.Max(merged[^1].End, range.End));
            else merged.Add(range);
        }
        return new(merged, speaker);
    }

    /// <summary>The <paramref name="seconds"/> of <paramref name="word"/> nearest the patch: a word before it gives its end, one after it
    /// its start, and one over it the part around the patch.</summary>
    private static (double Start, double End) NearestPart(TimedWord word, double start, double end, double seconds)
    {
        if (word.End - word.Start <= seconds) return (word.Start, word.End);
        if (word.End <= start) return (word.End - seconds, word.End);
        if (word.Start >= end) return (word.Start, word.Start + seconds);
        var middle = (Math.Max(word.Start, start) + Math.Min(word.End, end)) / 2;
        var upper = Math.Min(word.End, Math.Max(word.Start, middle - seconds / 2) + seconds);
        return (Math.Max(word.Start, upper - seconds), upper);
    }

    /// <summary>The label most of the patch's own words carry, else the nearest labeled word's.</summary>
    private static string? PatchSpeaker(TimedWord[] words, Func<int, double> distance)
    {
        var counts = new Dictionary<string, int>(StringComparer.Ordinal);
        for (var index = 0; index < words.Length; index++)
            if (distance(index) == 0 && words[index].Speaker is { } label) counts[label] = counts.GetValueOrDefault(label) + 1;
        if (counts.Count > 0)
            return counts.OrderByDescending(pair => pair.Value).ThenBy(pair => pair.Key, StringComparer.Ordinal).First().Key;
        var labelled = Enumerable.Range(0, words.Length).Where(index => words[index].Speaker is not null).ToArray();
        return labelled.Length == 0 ? null : words[labelled.MinBy(distance)].Speaker;
    }

    /// <summary>The source spans to decode for these ranges: neighbouring ranges less than <paramref name="gap"/> frames apart share one
    /// span, so a patch's words are read in a few passes, not one per word.</summary>
    public IReadOnlyList<(long Start, long End)> Covers(long gap)
    {
        var result = new List<(long Start, long End)>();
        foreach (var range in Ranges)
        {
            if (result.Count > 0 && range.Start - result[^1].End < gap) result[^1] = (result[^1].Start, range.End);
            else result.Add(range);
        }
        return result;
    }

    /// <summary>The ranges' samples joined in source order, or null when the excerpt does not hold one of them.</summary>
    public float[]? Samples(VoiceLabSourceExcerpt source)
    {
        var joined = new List<float>(checked((int)Frames));
        foreach (var (rangeStart, rangeEnd) in Ranges)
        {
            if (source.Samples(rangeStart, rangeEnd) is not { } slice) return null;
            joined.AddRange(slice.ToArray());
        }
        return joined.ToArray();
    }

    public bool Equals(VoiceLabGuardSpeech? other) => other is not null && Speaker == other.Speaker && Ranges.SequenceEqual(other.Ranges);
    public override int GetHashCode() => HashCode.Combine(Speaker, Ranges.Count);
}
