using System.Globalization;
using System.Text;
using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Domain.Transcript;

namespace VoxClip.Core.Domain.Editing;

/// <summary>Import output with final ids, provenance and derived pauses, editing §5.0.</summary>
public sealed record EditingImportResult(IReadOnlyList<TimedWord> Words, double PauseThresholdSeconds, IReadOnlyList<Pause> Pauses);

/// <summary>Single import post-processing pipeline shared by speech adapters, editing §5.</summary>
public static class EditingImport
{
    /// <summary>Attach punctuation, normalize NFC and reject invalid engine times, editing §5.2.</summary>
    public static IReadOnlyList<RawWord> CleanWords(IReadOnlyList<RawWord> raw)
    {
        var result = new List<RawWord>();
        var prefix = "";
        foreach (var word in raw)
        {
            var kind = word.Kind == WordKind.Event ? WordKind.Event : WordKind.Word;
            var text = EditingAlgorithms.JsTrim(EditingAlgorithms.Nfc(word.Text ?? ""));
            if (text.Length == 0) continue;
            var categories = text.EnumerateRunes().Select(Rune.GetUnicodeCategory).ToArray();
            if (kind == WordKind.Word && categories.All(IsPunctuation))
            {
                if (text.EnumerateRunes().All(scalar => Rune.GetUnicodeCategory(scalar) is UnicodeCategory.OpenPunctuation or UnicodeCategory.InitialQuotePunctuation || scalar.Value is 0xbf or 0xa1)) prefix += text;
                else if (result.Count > 0 && result[^1].Kind == WordKind.Word) result[^1] = result[^1] with { Text = result[^1].Text + text };
                continue;
            }
            if (word.Start is not { } start || word.End is not { } end || !double.IsFinite(start) || !double.IsFinite(end) || start < 0 || end <= start) continue;
            result.Add(word with { Text = kind == WordKind.Word ? prefix + text : text, Kind = kind,
                Conf = word.Conf is { } conf && double.IsFinite(conf) && conf >= 0 && conf <= 1 ? conf : null });
            if (kind == WordKind.Word) prefix = "";
        }
        return result.Select((word, index) => (word, index)).OrderBy(pair => pair.word.Start).ThenBy(pair => pair.index).Select(pair => pair.word).ToArray();
    }

    private static bool IsPunctuation(UnicodeCategory category) => category is UnicodeCategory.ConnectorPunctuation or UnicodeCategory.DashPunctuation
        or UnicodeCategory.OpenPunctuation or UnicodeCategory.ClosePunctuation or UnicodeCategory.InitialQuotePunctuation
        or UnicodeCategory.FinalQuotePunctuation or UnicodeCategory.OtherPunctuation;

    /// <summary>Shrink gapless ranges to first/last sound islands, editing §5.5.</summary>
    public static IReadOnlyList<TimedWord> TightenIntoSound(IReadOnlyList<TimedWord> words, AudioEnvelope envelope, TimingSource timing, double? durationSeconds = null)
    {
        var analysis = EditingAlgorithms.AnalyzeItems(words, envelope, durationSeconds);
        if (analysis is null) return words;
        return words.Select(word =>
        {
            var first = analysis.FrameAt(word.Start);
            var last = (int)Math.Min(analysis.Frames - 1, Math.Max(0, Math.Ceiling(word.End / analysis.FrameLength) - 1));
            var islands = new List<(int First, int Last)>();
            foreach (var run in EditingAlgorithms.AudibleRuns(analysis, first, last))
            {
                if (islands.Count > 0 && run.First - islands[^1].Last - 1 < 15) islands[^1] = (islands[^1].First, run.Last);
                else islands.Add(run);
            }
            if (islands.Count == 0) return word;
            var island = timing == TimingSource.RunGrouped ? islands[^1] : islands[0];
            var start = island.First - first >= 7 ? Math.Max(word.Start, island.First * analysis.FrameLength) : word.Start;
            var end = last - island.Last >= 7 ? Math.Min(word.End, (island.Last + 1) * analysis.FrameLength) : word.End;
            if (end - start < 0.04) { start = Math.Max(word.Start, end - 0.04); end = Math.Min(word.End, start + 0.04); }
            return word with { Start = start, End = end };
        }).ToArray();
    }

    /// <summary>Find full-frame speech runs omitted by non-verbatim engines, editing §5.8.</summary>
    public static IReadOnlyList<TimeRange> FindUnlabeledSpeech(IReadOnlyList<TimedWord> words, AudioEnvelope envelope, double? durationSeconds = null)
    {
        var analysis = EditingAlgorithms.AnalyzeItems(words, envelope, durationSeconds);
        if (analysis is null) return [];
        var result = new List<TimeRange>();
        var reached = 0.0;
        for (var index = 0; index <= words.Count; index++)
        {
            var start = reached;
            var end = index < words.Count ? words[index].Start : analysis.Total;
            if (index < words.Count) reached = Math.Max(reached, words[index].End);
            if (!(end - start >= 0.25)) continue;
            var first = (int)Math.Max(0, Math.Ceiling(start / analysis.FrameLength));
            var last = (int)Math.Min(analysis.Frames - 1, Math.Floor(end / analysis.FrameLength) - 1);
            foreach (var run in EditingAlgorithms.AudibleRuns(analysis, first, last))
            {
                var peak = 0.0;
                for (var frame = run.First; frame <= run.Last; frame++) peak = Math.Max(peak, envelope.Rms[frame]);
                if (run.Last - run.First + 1 >= 10 && peak >= analysis.SpeechLevel * 0.25)
                    result.Add(new(run.First * analysis.FrameLength, (run.Last + 1) * analysis.FrameLength));
            }
        }
        return result;
    }

    /// <summary>Clean, optionally refine, detect omitted speech, then assign ids once, editing §5.0.</summary>
    public static EditingImportResult Pipeline(IReadOnlyList<RawWord> raw, AudioEnvelope? envelope, TimingSource timing, bool verbatim, double? durationSeconds = null)
    {
        IReadOnlyList<TimedWord> words = CleanWords(raw).Select(word => new TimedWord("", word.Text, word.Kind, word.Start!.Value, word.End!.Value, word.Start, word.End, word.Conf, word.Speaker, timing)).ToArray();
        if (envelope is not null)
        {
            if (timing is TimingSource.RunGrouped or TimingSource.TokenGrouped or TimingSource.Dtw) words = TightenIntoSound(words, envelope, timing, durationSeconds);
            words = EditingAlgorithms.RefineWordBoundaries(words, envelope, durationSeconds);
            if (!verbatim)
            {
                var extra = FindUnlabeledSpeech(words, envelope, durationSeconds).Select(range => new TimedWord("", "…", WordKind.UnlabeledSpeech, range.Start, range.End, null, null, null, null, TimingSource.Detected));
                words = words.Concat(extra).Select((word, index) => (word, index)).OrderBy(pair => pair.word.Start).ThenBy(pair => pair.index).Select(pair => pair.word).ToArray();
            }
        }
        words = words.Select((word, index) => word with { Id = "w" + (index + 1).ToString(CultureInfo.InvariantCulture) }).ToArray();
        var threshold = envelope is null ? 1.0 : 0.8;
        return new(words, threshold, EditingAlgorithms.DetectPauses(words, threshold));
    }

}
