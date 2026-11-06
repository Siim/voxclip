using VoxClip.Core.Domain.Shared;

namespace VoxClip.Core.Domain.VoiceLab;

/// <summary>One span of the words a rewrite is asked about, how long they take in the video, and the most words its place can hold
/// (ai.md §12.9, ADR-R42; Mac <c>VoiceRewriteSlot</c>). The video keeps running under the new words, so a rewrite never gets more time
/// than the words it replaces: the budget is the estimator's word target for the span's seconds, never more than the span's words.</summary>
public sealed record VoiceRewriteSlot(string Text, double Seconds, int MaxWords);

/// <summary>A selection's spans and their word budgets (Mac <c>VoiceRewriteSlots</c>). Vectors: <c>shared/fixtures/voice-lab/rewrite-slot-cases.json</c>.</summary>
public static class VoiceRewriteSlots
{
    /// <summary>A silence this long between two words ends a span, as punctuation does.</summary>
    public const double PauseSeconds = 0.3;
    /// <summary>A request lists at most this many spans; a longer selection is sent with its length line alone.</summary>
    public const int MaximumSlots = 60;
    /// <summary>A word ending in one of these closes its span.</summary>
    public const string Closing = ".,;:!?…—";

    /// <summary>The speaker's words per second over <paramref name="transcript"/>: the estimator's speaking rate (letters and digits per
    /// second) over the letters per word, as the wording fit computes it.</summary>
    public static double WordsPerSecond(IReadOnlyList<TimedWord> transcript)
    {
        var words = transcript.Where(word => word.Kind == WordKind.Word).ToArray();
        var characters = words.Sum(word => VoiceLabTextLength.Length(word.Text));
        if (characters <= 0) throw new VoiceLabLengthBudgetException(VoiceLabLengthBudgetErrorCode.RateUnavailable);
        return VoiceLabRewriteFit.SpeakingRate(transcript) * words.Length / characters;
    }

    /// <summary><paramref name="sourceWords"/> in spans, each closed after a word ending in punctuation or before a pause of
    /// <see cref="PauseSeconds"/>, with its budget from <see cref="VoiceLabWordingFit.WordTarget"/> at <paramref name="multiplier"/> (the
    /// voice's and project's measured takes) and <paramref name="spread"/> (four takes in five fit), after each take's fixed start
    /// (<see cref="VoiceLabRewriteFit.OnsetSeconds"/>), capped at the span's word count. Null when the words make no span or more than
    /// <see cref="MaximumSlots"/>.</summary>
    public static IReadOnlyList<VoiceRewriteSlot>? Make(IReadOnlyList<TimedWord> sourceWords, double wordsPerSecond, double multiplier,
        double spread = VoiceLabRateCalibration.PriorSpread)
    {
        var words = sourceWords.Where(word => word.Kind == WordKind.Word && double.IsFinite(word.Start) && double.IsFinite(word.End) && word.End >= word.Start);
        var spans = new List<List<TimedWord>>();
        var current = new List<TimedWord>();
        foreach (var word in words)
        {
            if (current.Count > 0 && word.Start - current[^1].End >= PauseSeconds) { spans.Add(current); current = []; }
            current.Add(word);
            if (word.Text.Length > 0 && Closing.Contains(word.Text[^1])) { spans.Add(current); current = []; }
        }
        if (current.Count > 0) spans.Add(current);
        if (spans.Count == 0 || spans.Count > MaximumSlots) return null;
        var slots = new List<VoiceRewriteSlot>();
        foreach (var span in spans)
        {
            var seconds = span[^1].End - span[0].Start;
            if (!(seconds > 0)) continue;
            var target = VoiceLabWordingFit.WordTarget(wordsPerSecond, multiplier, 0, seconds, Math.Min(VoiceLabRewriteFit.OnsetSeconds, seconds),
                spread: spread);
            slots.Add(new(string.Join(" ", span.Select(word => word.Text)), seconds, Math.Max(1, Math.Min(target.Maximum, span.Count))));
        }
        return slots;
    }
}
