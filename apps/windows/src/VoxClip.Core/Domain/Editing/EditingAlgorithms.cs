using System.Globalization;
using System.Text;
using System.Text.RegularExpressions;
using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Domain.Transcript;

namespace VoxClip.Core.Domain.Editing;

/// <summary>Pure import and text algorithms, editing §4–5; no decoding or engine dependencies.</summary>
public static partial class EditingAlgorithms
{
    /// <summary>Trim only JavaScript whitespace, editing §4.5.</summary>
    public static string JsTrim(string value)
    {
        var start = 0;
        var end = value.Length;
        while (start < end && IsWhitespace(value[start])) start++;
        while (end > start && IsWhitespace(value[end - 1])) end--;
        return value[start..end];
    }

    /// <summary>Split maximal JavaScript whitespace runs, editing §4.5.</summary>
    public static IReadOnlyList<string> SplitWords(string value)
    {
        var result = new List<string>();
        var start = 0;
        for (var index = 0; index <= value.Length; index++)
        {
            if (index != value.Length && !IsWhitespace(value[index])) continue;
            if (index > start) result.Add(value[start..index]);
            start = index + 1;
        }
        return result;
    }

    /// <summary>Unicode NFC that never throws, the one normaliser every Core rule uses (ADR-R19, editing §4.8). .NET's
    /// <c>Normalize</c> rejects an unpaired surrogate and U+FFFE. An unpaired surrogate becomes U+FFFD, as in a Swift string.
    /// U+FFFE is kept: it is a starter in no composition, so the NFC of the text is the NFC of each run between two U+FFFE,
    /// joined with U+FFFE again.</summary>
    internal static string Nfc(string value)
    {
        var text = WellFormed(value);
        if (text.IndexOf(NonCharacter) < 0) return text.Normalize(NormalizationForm.FormC);
        return string.Join(NonCharacter, text.Split(NonCharacter).Select(run => run.Normalize(NormalizationForm.FormC)));
    }

    /// <summary>The text with each unpaired surrogate replaced by U+FFFD, as a Swift string holds it.</summary>
    internal static string WellFormed(string value)
    {
        ArgumentNullException.ThrowIfNull(value);
        for (var index = 0; index < value.Length; index++)
        {
            if (!char.IsSurrogate(value[index])) continue;
            if (char.IsHighSurrogate(value[index]) && index + 1 < value.Length && char.IsLowSurrogate(value[index + 1])) { index++; continue; }
            var builder = new StringBuilder(value.Length);
            foreach (var rune in value.EnumerateRunes()) builder.Append(rune.ToString());
            return builder.ToString();
        }
        return value;
    }

    private const char NonCharacter = (char)0xFFFE;

    private static bool IsWhitespace(char value) => value is >= '\u0009' and <= '\u000d' or '\u0020' or '\u00a0' or '\u1680'
        or >= '\u2000' and <= '\u200a' or '\u2028' or '\u2029' or '\u202f' or '\u205f' or '\u3000' or '\ufeff';

    [GeneratedRegex(@"\A(?:[Uu][Mm]+|[Uu][Hh]+|[Ee][Rr][Mm]+|[Hh][Mm][Mm]+)[,.!?]?\z", RegexOptions.CultureInvariant)]
    private static partial Regex FillerPattern();

    /// <summary>Absolute-anchor, ASCII-only hesitation rule, editing §4.11.</summary>
    public static bool IsFillerText(string text) => FillerPattern().IsMatch(text);

    /// <summary>Words a manual clip's title takes from its selection, design §6.2.</summary>
    public const int ClipTitleWords = 7;

    /// <summary>A manual clip's title, design §6.2: the first <see cref="ClipTitleWords"/> words of the selection as shown
    /// (corrections applied), joined by one space, trimmed, cut to <see cref="EditingLimits.MaxClipTitleCodePoints"/> code
    /// points and trimmed again. Null when nothing is left. Both Cores check it against
    /// shared/fixtures/clips/manual-titles.json: this one and VoxClipCore's EditingAlgorithms.clipTitle.</summary>
    public static string? ClipTitle(IEnumerable<string> selectedWords)
    {
        ArgumentNullException.ThrowIfNull(selectedWords);
        var joined = JsTrim(string.Join(' ', selectedWords.Take(ClipTitleWords)));
        var title = JsTrim(string.Concat(joined.EnumerateRunes().Take(EditingLimits.MaxClipTitleCodePoints).Select(rune => rune.ToString())));
        return title.Length == 0 ? null : title;
    }

    /// <summary>Invariant lowercase letters and numbers only, editing §4.7.</summary>
    public static string NormalizeForMatch(string text)
    {
        var result = new StringBuilder();
        foreach (var scalar in text.EnumerateRunes())
        {
            var lower = scalar.Value == 0x130 ? new Rune('i') : Rune.ToLowerInvariant(scalar);
            if (Rune.IsLetterOrDigit(lower) || Rune.GetUnicodeCategory(lower) is UnicodeCategory.LetterNumber or UnicodeCategory.OtherNumber)
                result.Append(lower.ToString());
        }
        return result.ToString();
    }

    /// <summary>Use final-text punctuation only when every normalized token matches, editing §5.3.</summary>
    public static IReadOnlyList<RawWord> AlignTranscriptWords(IReadOnlyList<RawWord> words, string finalText)
    {
        var tokens = SplitWords(finalText);
        var same = tokens.Count == words.Count && words.Select((word, index) => NormalizeForMatch(word.Text) == NormalizeForMatch(tokens[index])).All(match => match);
        return words.Select((word, index) => same ? word with { Text = tokens[index] } : word)
            .Where(word => JsTrim(word.Text).Length > 0 && word.Start is { } start && word.End is { } end && double.IsFinite(start) && double.IsFinite(end) && start >= 0 && end > start).ToArray();
    }

    /// <summary>Raw-only estimated times weighted by UTF-16 code units, editing §5.4.</summary>
    public static IReadOnlyList<RawWord> EstimateTranscriptWords(string text, double start, double end)
    {
        var tokens = SplitWords(text);
        if (tokens.Count == 0 || !double.IsFinite(start) || !double.IsFinite(end) || end <= start) return [];
        var length = tokens.Sum(token => token.Length);
        var consumed = 0;
        var result = new List<RawWord>();
        foreach (var token in tokens)
        {
            var wordStart = start + (double)consumed / length * (end - start);
            consumed += token.Length;
            result.Add(new(token, wordStart, start + (double)consumed / length * (end - start), 0, null, WordKind.Word));
        }
        return result;
    }

    /// <summary>Compute 10ms binary32 RMS levels, accumulating channels and samples in binary64, editing §5.1.</summary>
    public static AudioEnvelope Analyze(IReadOnlyList<ReadOnlyMemory<float>> channels, int sampleRate)
    {
        if (sampleRate <= 0) throw new ArgumentOutOfRangeException(nameof(sampleRate));
        if (channels.Count == 0) return new(sampleRate, 0.01, []);
        var builder = new AudioEnvelopeBuilder(sampleRate, channels.Count);
        var samples = channels.Min(channel => channel.Length);
        var chunk = new float[Math.Min(samples, 4096) * channels.Count];
        for (var offset = 0; offset < samples; offset += 4096)
        {
            var count = Math.Min(samples - offset, 4096);
            for (var sample = 0; sample < count; sample++)
                for (var channel = 0; channel < channels.Count; channel++)
                    chunk[sample * channels.Count + channel] = channels[channel].Span[offset + sample];
            builder.Append(chunk.AsSpan(0, count * channels.Count));
        }
        return builder.Finish();
    }

    internal sealed record Analysis(AudioEnvelope Envelope, double Threshold, double SpeechLevel, double Total)
    {
        internal int Frames => Envelope.Rms.Count;
        internal double FrameLength => Math.Max(1, EditingMath.Round(Envelope.SampleRate * 0.01)) / Envelope.SampleRate;
        internal int FrameAt(double time) => (int)Math.Min(Frames - 1, Math.Max(0, Math.Floor(time / FrameLength)));
        internal bool Audible(int frame) => Envelope.Rms[frame] >= Threshold;
    }

    internal static Analysis? AnalyzeItems(IReadOnlyList<TimedWord> words, AudioEnvelope envelope, double? duration)
    {
        if (envelope.SampleRate <= 0) throw new ArgumentOutOfRangeException(nameof(envelope));
        if (words.Count == 0 || envelope.Rms.Count < 10) return null;
        var frameLength = Math.Max(1, EditingMath.Round(envelope.SampleRate * 0.01)) / envelope.SampleRate;
        var analysis = new Analysis(envelope, 0, 0, duration ?? envelope.Rms.Count * frameLength);
        var sorted = envelope.Rms.Order().ToArray();
        var speech = new List<float>();
        foreach (var word in words)
            for (var frame = analysis.FrameAt(word.Start); frame <= analysis.FrameAt(word.End); frame++) speech.Add(envelope.Rms[frame]);
        speech.Sort();
        var level = speech.Count > 0 ? speech[speech.Count / 2] : 0;
        var threshold = Math.Max((double)sorted[(int)Math.Floor(sorted.Length * 0.1)] * 2, (double)level * 0.08);
        return threshold > 0 ? analysis with { Threshold = threshold, SpeechLevel = level } : null;
    }

    internal static List<(int First, int Last)> AudibleRuns(Analysis analysis, int from, int to)
    {
        var runs = new List<(int First, int Last)>();
        var frame = from;
        while (frame <= to)
        {
            if (!analysis.Audible(frame)) { frame++; continue; }
            var last = frame;
            var quiet = 0;
            for (var next = frame + 1; next <= to; next++)
            {
                if (analysis.Audible(next)) { last = next; quiet = 0; }
                else if (++quiet > 2) break;
            }
            runs.Add((frame, last));
            frame = last + 1;
        }
        return runs;
    }

    /// <summary>Widen boundaries and share first-minimum valleys over float envelopes, editing §5.6.</summary>
    public static IReadOnlyList<TimedWord> RefineWordBoundaries(IReadOnlyList<TimedWord> words, AudioEnvelope envelope, double? durationSeconds = null)
    {
        var analysis = AnalyzeItems(words, envelope, durationSeconds);
        if (analysis is null) return words;
        var refined = words.Select((word, index) =>
        {
            var earliest = Math.Max(Math.Max(0, word.Start - 0.35), index > 0 ? (words[index - 1].End + word.Start) / 2 : 0);
            var latest = Math.Min(Math.Min(analysis.Total, word.End + 0.3), index + 1 < words.Count ? (word.End + words[index + 1].Start) / 2 : analysis.Total);
            var first = Edge(analysis.FrameAt(word.Start), -1, frame => frame * analysis.FrameLength >= earliest);
            var last = Edge(analysis.FrameAt(word.End), 1, frame => (frame + 1) * analysis.FrameLength <= latest);
            return word with { Start = first < 0 ? word.Start : Math.Min(word.Start, first * analysis.FrameLength), End = last < 0 ? word.End : Math.Max(word.End, (last + 1) * analysis.FrameLength) };
        }).ToArray();
        for (var index = 1; index < refined.Length; index++)
        {
            var previous = refined[index - 1];
            var next = refined[index];
            if (next.Start - previous.End > 0.03) continue;
            var middle = (previous.End + next.Start) / 2;
            var from = (int)Math.Ceiling(Math.Max(middle - 0.07, previous.Start + 0.04) / analysis.FrameLength);
            var to = (int)Math.Floor(Math.Min(middle + 0.07, next.End - 0.04) / analysis.FrameLength) - 1;
            if (from > to || to >= analysis.Frames) continue;
            var valley = from;
            for (var frame = from + 1; frame <= to; frame++) if (envelope.Rms[frame] < envelope.Rms[valley]) valley = frame;
            if (envelope.Rms[valley] > (double)envelope.Rms[analysis.FrameAt(middle)] * 0.5) continue;
            var edge = (valley + 0.5) * analysis.FrameLength;
            refined[index - 1] = previous with { End = edge };
            refined[index] = next with { Start = edge };
        }
        return refined;

        int Edge(int from, int step, Func<int, bool> inside)
        {
            var found = -1;
            var quiet = 0;
            for (var frame = from; frame >= 0 && frame < analysis.Frames && inside(frame); frame += step)
            {
                if (analysis.Audible(frame)) { found = frame; quiet = 0; }
                else if (++quiet > 2) break;
            }
            return found;
        }
    }

    /// <summary>Derive inclusive-threshold pauses only between consecutive transcript items, editing §5.7.</summary>
    public static IReadOnlyList<Pause> DetectPauses(IReadOnlyList<TimedWord> words, double threshold)
    {
        var result = new List<Pause>();
        for (var index = 0; index + 1 < words.Count; index++)
        {
            var duration = words[index + 1].Start - words[index].End;
            if (duration >= threshold) result.Add(new("pause-after-" + words[index].Id, index, words[index].End, words[index + 1].Start, duration, "pause " + EditingFormat.ToFixed1(duration) + "s"));
        }
        return result;
    }

    /// <summary>Resolve inclusive clip indices with half-gap lead/tail padding, editing §7.2.</summary>
    public static TimeRange ClipTimes(IReadOnlyList<TimedWord> words, int startIndex, int endIndex)
    {
        if (startIndex < 0 || endIndex < startIndex || endIndex >= words.Count) throw new ArgumentOutOfRangeException(nameof(startIndex));
        var first = words[startIndex];
        var last = words[endIndex];
        return new(Math.Max(0, first.Start - Math.Min(0.12, startIndex > 0 ? Math.Max(0, first.Start - words[startIndex - 1].End) / 2 : 0.12)),
            last.End + Math.Min(0.25, endIndex + 1 < words.Count ? Math.Max(0, words[endIndex + 1].Start - last.End) / 2 : 0.25));
    }
}
