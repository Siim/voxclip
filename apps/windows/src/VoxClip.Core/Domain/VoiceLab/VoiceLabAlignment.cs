#pragma warning disable CS1591 // Alignment members follow voice-lab.md §8.7-§8.8 and match the Swift Core.
using System.Buffers;
using System.Text;
using VoxClip.Core.Domain.Editing;
using VoxClip.Core.Domain.Transcript;

namespace VoxClip.Core.Domain.VoiceLab;

/// <summary>§8.8 character alignment to synthetic words, §8.7 item 1 TTS trim and §8.8 step 3 relative word times.
/// The forced-alignment and Scribe fallbacks belong to the later QA pass; a missing alignment is a typed refusal here.</summary>
public static class VoiceLabAlignment
{
    /// <summary>Unicode White_Space, not JS_WHITESPACE (editing §4.5): U+0085 separates words and U+FEFF does not.</summary>
    static bool IsWhiteSpace(int scalar) => scalar is >= 0x09 and <= 0x0d or 0x20 or 0x85 or 0xa0 or 0x1680 or >= 0x2000 and <= 0x200a
        or 0x2028 or 0x2029 or 0x202f or 0x205f or 0x3000;

    /// <summary>Noncharacters U+FDD0-U+FDEF and U+xFFFE/U+xFFFF. All three implementations refuse them before NFC.</summary>
    static bool IsNoncharacter(int scalar) => scalar is >= 0xfdd0 and <= 0xfdef || (scalar & 0xfffe) == 0xfffe;

    /// <summary>editing §4.7 tokens are defined on NFC text, and the provider and the user may send either form. A lone
    /// surrogate or a noncharacter makes the alignment mismatch. Both are found by decoding, before Normalize, so the
    /// refusal never depends on whether ICU throws.</summary>
    static string Folded(string token)
    {
        for (var index = 0; index < token.Length;)
        {
            if (Rune.DecodeFromUtf16(token.AsSpan(index), out var rune, out var consumed) != OperationStatus.Done || IsNoncharacter(rune.Value))
                throw VoiceLabGeometry.Error(VoiceLabGeometryErrorCode.AlignmentMismatch);
            index += consumed;
        }
        return EditingAlgorithms.NormalizeForMatch(EditingAlgorithms.Nfc(token));
    }

    static IEnumerable<string> SplitWhiteSpace(string text)
    {
        var start = 0;
        for (var index = 0; index <= text.Length; index++)
        {
            if (index != text.Length && !IsWhiteSpace(text[index])) continue;
            if (index > start) yield return text[start..index];
            start = index + 1;
        }
    }

    /// <summary>The §8.8 loop over the provider's alignment arrays. Times stay on the asset's clock and every word is synthetic.</summary>
    public static IReadOnlyList<VoiceLabWord> Words(IReadOnlyList<string>? characters, IReadOnlyList<double>? starts, IReadOnlyList<double>? ends, string expectedText)
    {
        if (characters is null || starts is null || ends is null || characters.Count == 0 || characters.Count != starts.Count ||
            starts.Count != ends.Count || characters.Any(string.IsNullOrEmpty)) throw VoiceLabGeometry.Error(VoiceLabGeometryErrorCode.AlignmentUnavailable);
        var words = new List<VoiceLabWord>();
        var buffer = new StringBuilder();
        double? start = null;
        var end = 0.0;
        for (var index = 0; index < characters.Count; index++)
        {
            if (characters[index].EnumerateRunes().All(rune => IsWhiteSpace(rune.Value)))
            {
                if (start is { } first && buffer.Length > 0) words.Add(new(buffer.ToString(), first, end, true));
                buffer.Clear();
                start = null;
            }
            else
            {
                start ??= starts[index];
                buffer.Append(characters[index]);
                end = ends[index];
            }
        }
        if (start is { } last && buffer.Length > 0) words.Add(new(buffer.ToString(), last, end, true));
        var derived = words.Select(word => Folded(word.Text));
        var expected = SplitWhiteSpace(expectedText).Select(Folded);
        if (!derived.SequenceEqual(expected, StringComparer.Ordinal)) throw VoiceLabGeometry.Error(VoiceLabGeometryErrorCode.AlignmentMismatch);
        if (words.Count == 0) throw VoiceLabGeometry.Error(VoiceLabGeometryErrorCode.AlignmentUnavailable);
        return words;
    }

    /// <summary>[max(0, firstStart − TTS_TRIM_LEAD), min(assetDuration, lastEnd + TTS_TRIM_TAIL)] in asset seconds.</summary>
    public static (double Start, double End) Trim(IReadOnlyList<VoiceLabWord> words, double assetDuration)
    {
        if (!double.IsFinite(assetDuration) || assetDuration <= 0) throw VoiceLabGeometry.Error(VoiceLabGeometryErrorCode.InvalidInput);
        if (words.Count == 0) throw VoiceLabGeometry.Error(VoiceLabGeometryErrorCode.AlignmentUnavailable);
        var first = words[0].Start;
        var last = words[words.Count - 1].End;
        if (!double.IsFinite(first) || !double.IsFinite(last)) throw VoiceLabGeometry.Error(VoiceLabGeometryErrorCode.InvalidWordTiming);
        var start = Math.Max(0, first - VoiceLabPatchConstants.TTS_TRIM_LEAD);
        var end = Math.Min(assetDuration, last + VoiceLabPatchConstants.TTS_TRIM_TAIL);
        if (!(end > start)) throw VoiceLabGeometry.Error(VoiceLabGeometryErrorCode.InvalidWordTiming);
        return (start, end);
    }

    /// <summary>Without alignment: the first to the end of the last 10 ms frame above VOICED_FRAME on the TTS envelope, widened by
    /// TTS_TRIM_LEAD and TTS_TRIM_TAIL and clamped to the asset as with alignment.</summary>
    public static (double Start, double End) Trim(AudioEnvelope envelope, double assetDuration)
    {
        double rate = envelope.SampleRate;
        if (!double.IsFinite(assetDuration) || assetDuration <= 0 || rate <= 0 || envelope.Rms.Any(level => !float.IsFinite(level) || level < 0))
            throw VoiceLabGeometry.Error(VoiceLabGeometryErrorCode.InvalidInput);
        int first = -1, last = -1;
        for (var index = 0; index < envelope.Rms.Count; index++)
        {
            if (!((double)envelope.Rms[index] > VoiceLabPatchConstants.VOICED_FRAME_LEVEL)) continue;
            if (first < 0) first = index;
            last = index;
        }
        if (first < 0) throw VoiceLabGeometry.Error(VoiceLabGeometryErrorCode.NoVoicedAudio);
        var size = VoiceLabGeometry.FrameSize(rate);
        var start = Math.Max(0, (double)(first * size) / rate - VoiceLabPatchConstants.TTS_TRIM_LEAD);
        var end = Math.Min(assetDuration, (double)((last + 1) * size) / rate + VoiceLabPatchConstants.TTS_TRIM_TAIL);
        if (!(end > start)) throw VoiceLabGeometry.Error(VoiceLabGeometryErrorCode.InvalidInput);
        return (start, end);
    }

    /// <summary>Recipe words: (t − trimStart) × stretch, checked exactly as the v3 render validator checks them.</summary>
    public static IReadOnlyList<VoiceLabWord> RelativeWords(IReadOnlyList<VoiceLabWord> words, double trimStart, double stretch, double outDuration,
        double sourceSampleRate)
    {
        var rate = sourceSampleRate;
        if (!double.IsFinite(trimStart) || !double.IsFinite(stretch) || stretch <= 0 || !double.IsFinite(outDuration) || outDuration <= 0 ||
            !double.IsFinite(rate) || rate <= 0 || outDuration * rate >= VoiceLabGeometry.SampleLimit) throw VoiceLabGeometry.Error(VoiceLabGeometryErrorCode.InvalidInput);
        if (words.Count == 0) throw VoiceLabGeometry.Error(VoiceLabGeometryErrorCode.AlignmentUnavailable);
        var output = VoiceLabGeometry.Samples(outDuration, rate);
        var cursor = 0.0;
        var result = new List<VoiceLabWord>(words.Count);
        foreach (var word in words)
        {
            var start = (word.Start - trimStart) * stretch;
            var end = (word.End - trimStart) * stretch;
            if (string.IsNullOrEmpty(word.Text) || !double.IsFinite(start) || !double.IsFinite(end) || start < cursor || !(end > start) || end > outDuration ||
                VoiceLabGeometry.Samples(end, rate) <= VoiceLabGeometry.Samples(start, rate) || VoiceLabGeometry.Samples(end, rate) > output)
                throw VoiceLabGeometry.Error(VoiceLabGeometryErrorCode.InvalidWordTiming);
            result.Add(new(word.Text, start, end, true));
            cursor = end;
        }
        return result;
    }
}
