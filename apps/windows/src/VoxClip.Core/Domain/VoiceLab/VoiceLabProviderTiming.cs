using System.Globalization;
using System.Text;
using VoxClip.Core.Domain.Editing;
#pragma warning disable CS1591

namespace VoxClip.Core.Domain.VoiceLab;

/// <summary>Why provider or recovered word timing could not be mapped to the typed words (voice-lab §8.5; Mac
/// <c>VoiceLabTimingFailure</c>). The check name, the character index and the two scalars at a text mismatch are logged in
/// every build; the text never is.</summary>
public sealed class VoiceLabTimingFailure(string check, int? index = null, int? typedScalar = null, int? providerScalar = null)
    : Exception("Voice Lab timing check " + check + " failed.")
{
    public string Check { get; } = check;
    public int? Index { get; } = index;
    public int? TypedScalar { get; } = typedScalar;
    public int? ProviderScalar { get; } = providerScalar;
    /// <summary><c>check=… index=… typed=U+… provider=U+…</c>, the release log's redacted evidence.</summary>
    public string LogFields => "check=" + Check + " index=" + (Index?.ToString(CultureInfo.InvariantCulture) ?? "none") +
        " typed=" + Code(TypedScalar) + " provider=" + Code(ProviderScalar);
    static string Code(int? value) => value is { } scalar ? "U+" + scalar.ToString("X4", CultureInfo.InvariantCulture) : "none";
}

/// <summary>Maps provider character timing, or a transcription's word timing, to the typed words (voice-lab §8.5 "Tolerant
/// timing" and "Timing recovery"; Mac <c>VoiceLabProviderTiming</c>). Equal words keep their own times; a quirk that a
/// correct reply can produce (case, punctuation, apostrophes, whitespace, bracket directions, number/symbol expansion, a
/// small overrun, a small overlap) is accepted. Words that actually differ are refused. The result holds one timing per
/// typed token with a space between tokens, so <see cref="VoiceLabAlignment.Words"/> rebuilds exactly the typed tokens.</summary>
public static class VoiceLabProviderTiming
{
    /// <summary>Character times may end this far past the PCM; they are clamped to it.</summary>
    public const double OverrunTolerance = 0.25;
    /// <summary>A character may start this much before the one before it (rounding), never more.</summary>
    public const double OrderTolerance = 0.001;

    sealed record Token(string Text, string Folded, double Start, double End);

    /// <summary>The first differing Unicode scalar of the typed and provider texts, for the release log.</summary>
    public static (int Index, int? Typed, int? Provider) FirstMismatch(string typed, string provider)
    {
        var left = typed.EnumerateRunes().Select(rune => rune.Value).ToArray();
        var right = provider.EnumerateRunes().Select(rune => rune.Value).ToArray();
        var index = Enumerable.Range(0, Math.Max(left.Length, right.Length))
            .Where(i => i >= left.Length || i >= right.Length || left[i] != right[i]).DefaultIfEmpty(0).First();
        return (index, index < left.Length ? left[index] : null, index < right.Length ? right[index] : null);
    }

    /// <summary>Provider <c>alignment</c> or <c>normalized_alignment</c> arrays, mapped to <paramref name="typedText"/>
    /// (bracket tags removed).</summary>
    public static IReadOnlyList<VoiceLabCharacterTiming> Retime(IReadOnlyList<string> characters, IReadOnlyList<double> starts,
        IReadOnlyList<double> ends, string typedText, double duration)
    {
        if (characters.Count == 0 || characters.Count != starts.Count || starts.Count != ends.Count)
            throw new VoiceLabTimingFailure("alignment_count_mismatch");
        var latestStart = 0.0;
        for (var index = 0; index < characters.Count; index++)
        {
            var start = starts[index]; var end = ends[index];
            if (!double.IsFinite(start) || !double.IsFinite(end) || start < 0 || end < start || start < latestStart - OrderTolerance)
                throw new VoiceLabTimingFailure("alignment_time_order", index);
            if (end > duration + OverrunTolerance) throw new VoiceLabTimingFailure("alignment_end_beyond_duration", index);
            latestStart = Math.Max(latestStart, start);
        }
        var scalars = new List<Rune>(); var scalarStarts = new List<double>(); var scalarEnds = new List<double>();
        for (var index = 0; index < characters.Count; index++)
        {
            var list = characters[index].EnumerateRunes().ToArray();
            if (list.Length == 0) continue;
            var start = Math.Min(starts[index], duration); var end = Math.Min(ends[index], duration);
            var step = (end - start) / list.Length;
            for (var offset = 0; offset < list.Length; offset++)
            {
                scalars.Add(list[offset]);
                scalarStarts.Add(start + step * offset);
                scalarEnds.Add(start + step * (offset + 1));
            }
        }
        BlankBrackets(scalars);
        var tokens = new List<Token>();
        var buffer = new StringBuilder(); double tokenStart = 0, tokenEnd = 0;
        void Flush()
        {
            if (buffer.Length == 0) return;
            var text = buffer.ToString();
            tokens.Add(new(text, Fold(text), tokenStart, tokenEnd));
            buffer.Clear();
        }
        for (var index = 0; index < scalars.Count; index++)
        {
            if (VoiceLabAlignment.IsWhiteSpace(scalars[index].Value)) { Flush(); continue; }
            if (buffer.Length == 0) { tokenStart = scalarStarts[index]; tokenEnd = scalarEnds[index]; }
            buffer.Append(scalars[index].ToString()); tokenEnd = Math.Max(tokenEnd, scalarEnds[index]);
        }
        Flush();
        return Map(tokens, typedText, allowsWordGaps: false);
    }

    /// <summary>A transcription's words (the take's Scribe word check or the on-device transcriber) mapped to
    /// <paramref name="typedText"/>. Words the transcription heard differently share their span; the word check, not
    /// timing, decides whether they differ.</summary>
    public static IReadOnlyList<VoiceLabCharacterTiming> Recovered(IReadOnlyList<VoiceLabWord> words, string typedText)
    {
        var tokens = new List<Token>();
        foreach (var word in words)
        {
            if (!double.IsFinite(word.Start) || !double.IsFinite(word.End) || word.End < word.Start || word.Start < 0) continue;
            foreach (var piece in SplitScalars(word.Text)) tokens.Add(new(piece, Fold(piece), word.Start, word.End));
        }
        if (!tokens.Any(token => token.Folded.Length > 0)) throw new VoiceLabTimingFailure("recovery_no_words");
        return Map(tokens, typedText, allowsWordGaps: true);
    }

    internal static string Fold(string text) => EditingAlgorithms.NormalizeForMatch(EditingAlgorithms.Nfc(text));

    /// <summary>A typed token a provider may say as other words: it holds a digit or a symbol ("21", "$12", "50%", "&amp;").</summary>
    internal static bool Expands(string token) => token.EnumerateRunes().Any(rune =>
        Rune.GetUnicodeCategory(rune) is UnicodeCategory.DecimalDigitNumber or UnicodeCategory.LetterNumber or UnicodeCategory.OtherNumber
            or UnicodeCategory.CurrencySymbol or UnicodeCategory.MathSymbol or UnicodeCategory.OtherSymbol || "%&@#/+".Contains((char)rune.Value) && rune.IsAscii);

    /// <summary>Bracket expressions are directions, never typed words: their scalars become spaces.</summary>
    static void BlankBrackets(List<Rune> scalars)
    {
        int? open = null;
        for (var index = 0; index < scalars.Count; index++)
        {
            switch (scalars[index].Value)
            {
                case '[': open = index; break;
                case ']':
                    if (open is { } first) for (var inner = first; inner <= index; inner++) scalars[inner] = new Rune(' ');
                    open = null; break;
                case '\r' or '\n': open = null; break;
            }
        }
    }

    static List<string> SplitScalars(string text)
    {
        var pieces = new List<string>(); var buffer = new StringBuilder();
        foreach (var rune in text.EnumerateRunes())
        {
            if (VoiceLabAlignment.IsWhiteSpace(rune.Value)) { if (buffer.Length > 0) { pieces.Add(buffer.ToString()); buffer.Clear(); } }
            else buffer.Append(rune.ToString());
        }
        if (buffer.Length > 0) pieces.Add(buffer.ToString());
        return pieces;
    }

    static int ScalarCount(string text) => text.EnumerateRunes().Count();

    static IReadOnlyList<VoiceLabCharacterTiming> Map(IReadOnlyList<Token> source, string typedText, bool allowsWordGaps)
    {
        var typed = SplitScalars(VoiceLabAudioTags.StrippingTags(typedText));
        if (typed.Count == 0) throw new VoiceLabTimingFailure("alignment_text_mismatch");
        var folded = typed.Select(Fold).ToArray();
        // Longest common subsequence of folded tokens, walked forward; a tie drops the provider token first.
        var width = folded.Length + 1;
        var lengths = new int[(source.Count + 1) * width];
        for (var l = source.Count - 1; l >= 0; l--)
            for (var r = folded.Length - 1; r >= 0; r--)
            {
                var cell = l * width + r;
                lengths[cell] = source[l].Folded == folded[r] ? lengths[cell + width + 1] + 1 : Math.Max(lengths[cell + width], lengths[cell + 1]);
            }
        var result = new List<Token>();
        var removed = new List<Token>(); var inserted = new List<int>();
        int left = 0, right = 0;
        double? Next(int index)
        {
            int probe = index, other = right;
            while (probe < source.Count && other < folded.Length)
            {
                if (source[probe].Folded == folded[other]) return source[probe].Start;
                if (lengths[(probe + 1) * width + other] >= lengths[probe * width + other + 1]) probe++; else other++;
            }
            return null;
        }
        void Flush()
        {
            if (inserted.Count == 0 && removed.Count == 0) return;
            try
            {
                var previous = result.Count > 0 ? result[^1].End : 0;
                var spoken = removed.Any(token => token.Folded.Length > 0);
                var words = inserted.Where(index => folded[index].Length > 0).ToArray();
                if (!allowsWordGaps)
                {
                    if (inserted.Count == 0 && spoken) throw new VoiceLabTimingFailure("alignment_words_mismatch", result.Count);
                    if (words.Length > 0 && (!spoken || !words.All(index => Expands(typed[index]))))
                        throw new VoiceLabTimingFailure("alignment_words_mismatch", words[0]);
                }
                if (inserted.Count == 0) return;
                double first, last;
                if (removed.Count > 0)
                {
                    first = Math.Max(previous, removed[0].Start); last = Math.Max(first, removed[^1].End);
                }
                else
                {
                    first = previous; last = Math.Max(previous, Next(left) ?? previous);
                }
                double total = inserted.Sum(index => Math.Max(1, ScalarCount(typed[index])));
                var cursor = first;
                for (var offset = 0; offset < inserted.Count; offset++)
                {
                    var index = inserted[offset];
                    var end = offset == inserted.Count - 1 ? last : cursor + (last - first) * Math.Max(1, ScalarCount(typed[index])) / total;
                    result.Add(new(typed[index], folded[index], cursor, end));
                    cursor = end;
                }
            }
            finally { removed.Clear(); inserted.Clear(); }
        }
        while (left < source.Count || right < folded.Length)
        {
            if (left < source.Count && right < folded.Length && source[left].Folded == folded[right])
            {
                Flush();
                var previous = result.Count > 0 ? result[^1].End : 0;
                var start = Math.Max(previous, source[left].Start);
                result.Add(new(typed[right], folded[right], start, Math.Max(start, source[left].End)));
                left++; right++;
            }
            else if (right >= folded.Length || left < source.Count && lengths[(left + 1) * width + right] >= lengths[left * width + right + 1])
            {
                removed.Add(source[left]); left++;
            }
            else { inserted.Add(right); right++; }
        }
        Flush();
        if (result.Count != typed.Count) throw new VoiceLabTimingFailure("alignment_words_mismatch");
        var timing = new List<VoiceLabCharacterTiming>(result.Count * 2);
        for (var index = 0; index < result.Count; index++)
        {
            var word = result[index];
            if (index > 0) timing.Add(new(" ", word.Start, word.Start));
            timing.Add(new(word.Text, word.Start, word.End));
        }
        return timing.AsReadOnly();
    }
}
