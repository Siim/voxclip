using VoxClip.Core.Domain.Shared;

namespace VoxClip.Core.Domain.Transcript;

/// <summary>Display-only take paragraphs; editing §11.5. Speaker, sentence and bounded-gap rules match Swift.</summary>
public static class TranscriptParagraphs
{
    /// <summary>Minimum gap after a sentence that starts a new paragraph.</summary>
    public const double GapSeconds = 1.5;
    /// <summary>First sentence end at or beyond this many words breaks.</summary>
    public const int SentenceWords = 80;
    /// <summary>A paragraph reaches at most this many words before a forced break.</summary>
    public const int MaximumWords = 150;
    /// <summary>First word whose following gap can force the break (one-based).</summary>
    public const int ForcedWindowStart = 120;

    /// <summary>Contiguous half-open index ranges covering every source word. Later gaps win ties.</summary>
    public static IReadOnlyList<Range> Split(IReadOnlyList<TimedWord> words)
    {
        if (words.Count == 0) return [];
        var result = new List<Range>();
        var start = 0;
        for (var index = 1; index < words.Count; index++)
        {
            var count = index - start;
            var previous = words[index - 1];
            var word = words[index];
            var sentence = EndsSentence(previous.Text);
            if (word.Speaker != previous.Speaker || sentence && word.Start - previous.End >= GapSeconds || sentence && count >= SentenceWords)
            {
                result.Add(new(start, index));
                start = index;
            }
            else if (count == MaximumWords)
            {
                var length = ForcedWindowStart;
                var widest = double.NegativeInfinity;
                for (var candidate = ForcedWindowStart; candidate <= MaximumWords; candidate++)
                {
                    var gap = words[start + candidate].Start - words[start + candidate - 1].End;
                    if (gap >= widest) { widest = gap; length = candidate; }
                }
                result.Add(new(start, start + length));
                start += length;
            }
        }
        result.Add(new(start, words.Count));
        return result;
    }

    /// <summary>Only a final period, question mark, exclamation mark or ellipsis ends a sentence.</summary>
    public static bool EndsSentence(string text) => text.Length > 0 && text[^1] is '.' or '?' or '!' or '…';
}
