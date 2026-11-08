using VoxClip.Core.Domain.Editing;
using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Domain.Transcript;

namespace VoxClip.Core.Domain.Frames;

/// <summary>A clip's words as the frame analyzer reads them, twin of the Mac <c>FrameClip</c>: the clip's transcript range, which
/// of its words are kept, and where it starts (ADR-R48).</summary>
public sealed class FrameClip
{
    private FrameClip(IReadOnlyList<TimedWord> words, int first, int last, int[] kept)
    {
        Words = words;
        First = first;
        Last = last;
        Kept = kept;
    }

    /// <summary>The transcript's items.</summary>
    public IReadOnlyList<TimedWord> Words { get; }
    /// <summary>Transcript position of the clip's first item.</summary>
    public int First { get; }
    /// <summary>Transcript position of the clip's last item.</summary>
    public int Last { get; }
    /// <summary>Positions of the clip's spoken words that are not cut, in order.</summary>
    public IReadOnlyList<int> Kept { get; }

    /// <summary>The clip of <paramref name="clip"/>'s range; null when either end word is missing, the range is reversed or no word
    /// in it is kept.</summary>
    public static FrameClip? Make(VoxClip.Core.Domain.Transcript.Transcript transcript, ClipRange clip, IReadOnlySet<string> cutWordIds)
    {
        var first = IndexOf(transcript.Words, clip.StartWordId);
        var last = IndexOf(transcript.Words, clip.EndWordId);
        return first < 0 || last < 0 || first > last ? null : Make(transcript.Words, first, last, cutWordIds);
    }

    /// <summary>The clip from item <paramref name="first"/> to <paramref name="last"/>; null when the range is out of bounds or
    /// reversed, or no word in it is kept.</summary>
    public static FrameClip? Make(IReadOnlyList<TimedWord> words, int first, int last, IReadOnlySet<string> cutWordIds)
    {
        if (first < 0 || last >= words.Count || first > last) return null;
        var kept = Enumerable.Range(first, last - first + 1)
            .Where(index => words[index].Kind == WordKind.Word && !cutWordIds.Contains(words[index].Id)).ToArray();
        return kept.Length == 0 ? null : new FrameClip(words, first, last, kept);
    }

    /// <summary>The source second the clip's first kept word starts.</summary>
    public double Start => Words[Kept[0]].Start;
    /// <summary>The source second the clip's last kept word ends.</summary>
    public double End => Words[Kept[^1]].End;

    /// <summary>The end of the last transcript item, of any kind, that ends at or before the clip's start; 0 when none does. A
    /// shift of the start never goes before it, so no earlier word is heard (<see cref="OpeningFrame"/>).</summary>
    public double LeadInFloor
    {
        get
        {
            var startIndex = Kept[0];
            var start = Start;
            var floor = (double?)null;
            for (var index = 0; index < startIndex; index++)
            {
                var end = Words[index].End;
                if (end <= start + 1e-9 && (floor is null || end > floor)) floor = end;
            }
            return floor ?? 0;
        }
    }

    private static int IndexOf(IReadOnlyList<TimedWord> words, string id)
    {
        for (var index = 0; index < words.Count; index++) if (words[index].Id == id) return index;
        return -1;
    }
}

/// <summary>One sentence's frame: its source time and the kept words it stands for.</summary>
public readonly record struct FrameSample(double Time, int FirstWord, int LastWord);

/// <summary>Which source times the analyzer looks at (ADR-R48), twin of the Mac <c>FrameSampling</c>.</summary>
public static class FrameSampling
{
    /// <summary>At most this many sentence frames per clip: the frame sheet's limit.</summary>
    public const int MaximumSentences = 24;
    /// <summary>A sentence longer than this many kept words is split, so a run-on transcript still gets frames.</summary>
    public const int MaximumSentenceWords = 40;
    /// <summary>The opening scan: every <see cref="OpeningStep"/> seconds from this far before the clip's start to this far after.</summary>
    public const double OpeningSpan = 0.6;
    /// <summary>The opening scan's step, seconds.</summary>
    public const double OpeningStep = 0.1;

    /// <summary>One sample per sentence of kept words, at the middle of its middle word. With more sentences than
    /// <paramref name="limit"/>, evenly spaced sentences are kept, the first and last always among them.</summary>
    public static IReadOnlyList<FrameSample> SentenceSamples(FrameClip clip, int limit = MaximumSentences)
    {
        if (limit <= 0) return [];
        var sentences = new List<int[]>();
        var current = new List<int>();
        foreach (var index in clip.Kept)
        {
            current.Add(index);
            if (TranscriptParagraphs.EndsSentence(clip.Words[index].Text) || current.Count >= MaximumSentenceWords)
            {
                sentences.Add([.. current]);
                current.Clear();
            }
        }
        if (current.Count > 0) sentences.Add([.. current]);
        return Spread(sentences, limit).Select(sentence =>
        {
            var middle = clip.Words[sentence[sentence.Length / 2]];
            return new FrameSample((middle.Start + middle.End) / 2, sentence[0], sentence[^1]);
        }).ToArray();
    }

    /// <summary>At most <paramref name="limit"/> of <paramref name="items"/>, evenly spaced, the first and last always among them.</summary>
    internal static IReadOnlyList<T> Spread<T>(IReadOnlyList<T> items, int limit)
    {
        if (limit <= 0) return [];
        if (items.Count <= limit) return items;
        if (limit == 1) return [items[0]];
        double span = items.Count - 1, steps = limit - 1;
        return Enumerable.Range(0, limit).Select(step => items[(int)Math.Round(step * span / steps, MidpointRounding.AwayFromZero)]).ToArray();
    }

    /// <summary>The whole video's sentence frames (ADR-R48 part 2): one per sentence of every spoken word, cut or not, with no
    /// limit. Empty without a spoken word.</summary>
    public static IReadOnlyList<FrameSample> VideoSamples(IReadOnlyList<TimedWord> words)
    {
        if (words.Count == 0 || FrameClip.Make(words, 0, words.Count - 1, new HashSet<string>()) is not { } whole) return [];
        return SentenceSamples(whole, int.MaxValue);
    }

    /// <summary>A clip's frames out of the whole video's (<see cref="VideoSamples"/>): those whose time lies inside one of the
    /// clip's kept words, at most <paramref name="limit"/>, evenly spaced with the first and last kept. A clip inside one long
    /// sentence whose frame falls outside it gets its own samples instead (<see cref="SentenceSamples"/>).</summary>
    public static IReadOnlyList<FrameSample> ClipSamples(IReadOnlyList<FrameSample> video, FrameClip clip, int limit = MaximumSentences)
    {
        var spans = clip.Kept.Select(index => (Start: clip.Words[index].Start, End: clip.Words[index].End)).ToArray();
        var inside = video.Where(sample => sample.Time >= clip.Start - 1e-9 && sample.Time <= clip.End + 1e-9
            && spans.Any(span => sample.Time >= span.Start - 1e-9 && sample.Time <= span.End + 1e-9)).ToArray();
        return inside.Length == 0 ? SentenceSamples(clip, limit) : Spread(inside, limit);
    }

    /// <summary>The opening scan's times around <paramref name="start"/>, never before 0, in order, each to the millisecond.</summary>
    public static IReadOnlyList<double> OpeningTimes(double start)
    {
        var steps = (int)Math.Round(OpeningSpan / OpeningStep, MidpointRounding.AwayFromZero);
        var times = new List<double>();
        for (var step = -steps; step <= steps; step++)
        {
            var time = start + step * OpeningStep;
            if (time >= 0) times.Add(Math.Round(time * 1000, MidpointRounding.AwayFromZero) / 1000);
        }
        return times;
    }
}
