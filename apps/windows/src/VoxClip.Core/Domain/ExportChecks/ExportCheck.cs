using System.Globalization;
using System.Text.Json.Nodes;
using VoxClip.Core.Domain.Captions;
using VoxClip.Core.Domain.Loudness;
using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Domain.Transcript;
using VoxClip.Core.Domain.VoiceLab;

namespace VoxClip.Core.Domain.ExportChecks;

/// <summary>The four checks of an export (ADR-R49).</summary>
public enum ExportCheckKind
{
    /// <summary>The words heard against the edit.</summary>
    Words,
    /// <summary>Picture and sound in sync, and each revoiced phrase where the edit placed it.</summary>
    Sync,
    /// <summary>Loudness against ADR-R47's target.</summary>
    Loudness,
    /// <summary>Caption cards and the title against the feed's safe-zone bands.</summary>
    Captions,
}

/// <summary><c>Ok</c>: measured and within its rule. <c>Warning</c>: measured and outside it. <c>Skipped</c>: not measured, with
/// the reason.</summary>
public enum ExportCheckStatus
{
    /// <summary>Measured and within its rule.</summary>
    Ok,
    /// <summary>Measured and outside its rule.</summary>
    Warning,
    /// <summary>Not measured.</summary>
    Skipped,
}

/// <summary>What one finding is about.</summary>
public enum ExportCheckItemKind
{
    /// <summary>An expected word heard as another word, or not heard.</summary>
    Mismatch,
    /// <summary>A word next to a cut or a clip edge not heard, or heard as a shorter different word.</summary>
    CutOff,
    /// <summary>The audio track starts more than a frame from the video track.</summary>
    TrackStart,
    /// <summary>The audio track ends more than a frame from the video track.</summary>
    TrackEnd,
    /// <summary>A revoiced or rewritten phrase's heard words sit further from where the edit placed them than the tolerance.</summary>
    PhraseOffset,
    /// <summary>None of a phrase's words were heard, so its placement can't be measured.</summary>
    PhraseNotHeard,
    /// <summary>Phrase placement wasn't measured (the words check was skipped).</summary>
    PhrasesSkipped,
    /// <summary>The integrated loudness is outside the target's range.</summary>
    IntegratedLoudness,
    /// <summary>The true peak is above the ceiling.</summary>
    TruePeak,
    /// <summary>Nothing is audible.</summary>
    Silent,
    /// <summary>A caption card reaches into a safe-zone band.</summary>
    CaptionBand,
    /// <summary>The title reaches into a safe-zone band.</summary>
    TitleBand,
}

/// <summary>One finding, at a time in the export (output seconds from its first frame). Twin of the Mac <c>ExportCheckItem</c>.</summary>
public sealed record ExportCheckItem(ExportCheckItemKind Kind, double Time)
{
    /// <summary>The expected word.</summary>
    public string? Expected { get; init; }
    /// <summary>What was heard in its place.</summary>
    public string? Heard { get; init; }
    /// <summary>What was measured: seconds for sync, LUFS or dBTP for loudness, the band overlap (fraction of the frame's height)
    /// for captions.</summary>
    public double? Value { get; init; }
    /// <summary>The rule's limit for <see cref="Value"/>.</summary>
    public double? Limit { get; init; }
    /// <summary>The band's edge, for captions.</summary>
    public CaptionSafeZones.Edge? Band { get; init; }
    /// <summary>The phrase (Voice Lab segment) id, for words in a phrase and for sync.</summary>
    public string? Phrase { get; init; }
    /// <summary>Why, for a skipped part.</summary>
    public string? Reason { get; init; }
    /// <summary>How many cards in a row reach the same depth into the band (from <see cref="Time"/> on); null for one.</summary>
    public int? Count { get; init; }
}

/// <summary>One check's outcome. <see cref="Matched"/> and <see cref="Total"/> are the words check's; <see cref="IntegratedLufs"/>
/// and <see cref="TruePeakDbtp"/> the loudness check's; <see cref="StartOffset"/> and <see cref="EndOffset"/> the sync check's
/// (audio minus video, seconds). Twin of the Mac <c>ExportCheckResult</c>.</summary>
public sealed record ExportCheckResult(ExportCheckKind Check, ExportCheckStatus Status)
{
    /// <summary>Why the check was skipped.</summary>
    public string? Reason { get; init; }
    /// <summary>The findings.</summary>
    public IReadOnlyList<ExportCheckItem> Items { get; init; } = [];
    /// <summary>Expected words heard as edited.</summary>
    public int? Matched { get; init; }
    /// <summary>Expected words scored.</summary>
    public int? Total { get; init; }
    /// <summary>Numbers lined up only with words of another language (<see cref="SpokenNumbers"/>): neither matched nor a
    /// mismatch, and left out of <see cref="Matched"/> and <see cref="Total"/>. Null when there were none.</summary>
    public int? Unverified { get; init; }
    /// <summary>The measured integrated loudness, LUFS.</summary>
    public double? IntegratedLufs { get; init; }
    /// <summary>The measured true peak, dBTP.</summary>
    public double? TruePeakDbtp { get; init; }
    /// <summary>Audio start minus video start, seconds.</summary>
    public double? StartOffset { get; init; }
    /// <summary>Audio end minus video end, seconds.</summary>
    public double? EndOffset { get; init; }

    internal static ExportCheckResult Skipped(ExportCheckKind check, string reason) => new(check, ExportCheckStatus.Skipped) { Reason = reason };

    /// <summary>The result as the CLI's JSON writes it, the Mac's keys: <c>check</c>, <c>status</c>, <c>reason</c>, <c>items</c> and
    /// the check's own numbers, each left out when it has no value.</summary>
    public JsonObject ToJson()
    {
        var fields = new JsonObject { ["check"] = ExportCheck.Name(Check), ["status"] = ExportCheck.Name(Status) };
        if (Reason is not null) fields["reason"] = Reason;
        fields["items"] = new JsonArray(Items.Select(item =>
        {
            var entry = new JsonObject { ["kind"] = ExportCheck.Name(item.Kind), ["time"] = item.Time };
            if (item.Expected is not null) entry["expected"] = item.Expected;
            if (item.Heard is not null) entry["heard"] = item.Heard;
            if (item.Value is { } value) entry["value"] = value;
            if (item.Limit is { } limit) entry["limit"] = limit;
            if (item.Band is { } band) entry["band"] = CaptionSafeZones.Name(band);
            if (item.Phrase is not null) entry["phrase"] = item.Phrase;
            if (item.Reason is not null) entry["reason"] = item.Reason;
            if (item.Count is { } count) entry["count"] = count;
            return (JsonNode)entry;
        }).ToArray());
        if (Matched is { } matched) fields["matched"] = matched;
        if (Total is { } total) fields["total"] = total;
        if (Unverified is { } unverified) fields["unverified"] = unverified;
        if (IntegratedLufs is { } lufs) fields["integratedLufs"] = lufs;
        if (TruePeakDbtp is { } peak) fields["truePeakDbtp"] = peak;
        if (StartOffset is { } start) fields["startOffset"] = start;
        if (EndOffset is { } end) fields["endOffset"] = end;
        return fields;
    }
}

/// <summary>The four results, in <see cref="ExportCheckKind"/> order.</summary>
public sealed record ExportCheckReport(IReadOnlyList<ExportCheckResult> Results)
{
    /// <summary>No check warned: every result is ok or skipped.</summary>
    public bool Passed => Results.All(result => result.Status != ExportCheckStatus.Warning);
    /// <summary>The result of <paramref name="check"/>, if any.</summary>
    public ExportCheckResult? this[ExportCheckKind check] => Results.FirstOrDefault(result => result.Check == check);
}

/// <summary>A word the edit puts in the export: a kept source word, or a Rewrite's or revoiced phrase's word at its placed time.
/// <paramref name="Optional"/>: a filler the edit keeps, never a mismatch when it isn't heard (Whisper drops "um" and "uh").
/// <paramref name="Phrase"/>: the Voice Lab segment whose audio speaks it.</summary>
public sealed record ExportCheckWord(string Text, double Start, double End, bool Optional = false, string? Phrase = null);

/// <summary>A word the local engine heard in the export.</summary>
public sealed record ExportCheckHeard(string Text, double Start, double End);

/// <summary>A revoiced or rewritten phrase where the edit placed it.</summary>
public sealed record ExportCheckPhrase(string Id, double Start, double End);

/// <summary>A track's time range in the file, seconds.</summary>
public sealed record ExportCheckTrack(double Start, double End);

/// <summary>The export's measured loudness and its loudness setting. <paramref name="IntegratedLufs"/> is null when nothing is
/// above the gate.</summary>
public sealed record ExportCheckLoudness(ExportLoudness Setting, double? IntegratedLufs, double? TruePeakDbtp);

/// <summary>What a laid-out box is.</summary>
public enum ExportCheckBoxKind
{
    /// <summary>A caption card.</summary>
    Caption,
    /// <summary>A title.</summary>
    Title,
}

/// <summary>A caption card's or the title's laid-out box, top-left origin, in fractions of the frame, from when it first shows
/// (output seconds).</summary>
public sealed record ExportCheckBox(ExportCheckBoxKind Kind, double Time, RectD Rect);

/// <summary>What the check compares, all in output seconds: built from the render the export ran (<see cref="ExportCheckExpectation"/>)
/// and from what was measured in the exported file. Twin of the Mac <c>ExportCheckInput</c>.</summary>
/// <param name="Expected">The words the edit puts in the export.</param>
/// <param name="Heard">Null when no local engine heard the export: words and phrase sync are skipped with <see cref="HearingSkipped"/>.</param>
/// <param name="Video">The video track's range, null without one.</param>
/// <param name="Audio">The audio track's range, null without one.</param>
/// <param name="FrameSeconds">One video frame, seconds.</param>
/// <param name="Loudness">Null when the export has no audio track.</param>
/// <param name="Frame">The export frame's pixel size, which picks the safe-zone bands.</param>
public sealed record ExportCheckInput(IReadOnlyList<ExportCheckWord> Expected, IReadOnlyList<ExportCheckHeard>? Heard, ExportCheckTrack? Video,
    ExportCheckTrack? Audio, double FrameSeconds, ExportCheckLoudness? Loudness, PixelSize Frame)
{
    /// <summary>Why the words weren't heard.</summary>
    public string HearingSkipped { get; init; } = ExportCheck.NoLocalEngine;
    /// <summary>Where the edit joins two pieces that were not next to each other (cuts, a phrase's seams), output seconds.</summary>
    public IReadOnlyList<double> Cuts { get; init; } = [];
    /// <summary>The revoiced or rewritten phrases.</summary>
    public IReadOnlyList<ExportCheckPhrase> Phrases { get; init; } = [];
    /// <summary>The caption cards and titles.</summary>
    public IReadOnlyList<ExportCheckBox> Boxes { get; init; } = [];
}

/// <summary>The export self-check (ADR-R49): the export transcribed again and compared word for word with the edit, picture and
/// sound measured for sync, loudness measured against ADR-R47's target, and every caption card and the title checked against the
/// frame's safe-zone bands. It reports what it measured and nothing it can't: sync never claims the lips match. Twin of the Mac
/// <c>ExportCheck</c>; shared/fixtures/export-check holds the vectors both replay.</summary>
public static class ExportCheck
{
    /// <summary>Why the words are skipped without a local engine.</summary>
    public const string NoLocalEngine = "No local transcription model";
    /// <summary>The words check warns below this share of matched words: the take QA's transcript threshold (voice-lab §8.11).</summary>
    public const double MatchFloor = 0.9;
    /// <summary>How far a phrase's heard words may sit from where the edit placed them, seconds: the median of the phrase's matched
    /// words' start offsets.</summary>
    public const double PhraseToleranceSeconds = 0.30;
    /// <summary>ADR-R47's target.</summary>
    public const double TargetLufs = SocialLoudness.TargetLufs;
    /// <summary>The target's tolerance, LU.</summary>
    public const double LoudnessToleranceLu = 1.0;
    /// <summary>ADR-R47's true-peak ceiling.</summary>
    public const double CeilingDbtp = SocialLoudness.CeilingDbtp;
    /// <summary>AAC rings past the PCM's ceiling on a limited transient (ADR-R49).</summary>
    public const double TruePeakToleranceDb = 0.2;

    /// <summary>The four checks of <paramref name="input"/>.</summary>
    public static ExportCheckReport Run(ExportCheckInput input)
    {
        var alignment = input.Heard is { } heard ? new WordAlignment(input.Expected, heard) : null;
        return new([Words(input, alignment), Sync(input, alignment), Loudness(input), Captions(input)]);
    }

    /// <summary>The wire name of a check: "words", "sync", "loudness", "captions".</summary>
    public static string Name(ExportCheckKind kind) => Camel(kind.ToString());
    /// <summary>The wire name of a status: "ok", "warning", "skipped".</summary>
    public static string Name(ExportCheckStatus status) => Camel(status.ToString());
    /// <summary>The wire name of an item kind: "mismatch", "cutOff", "trackStart" and so on.</summary>
    public static string Name(ExportCheckItemKind kind) => Camel(kind.ToString());
    private static string Camel(string name) => char.ToLowerInvariant(name[0]) + name[1..];

    // Words.

    /// <summary>The expected words matched against the heard words, word by word. Numbers match however they are written
    /// (<see cref="SpokenNumbers"/>): "three hundred dollar" heard as "$300" is three matched words.</summary>
    internal sealed class WordAlignment
    {
        /// <summary>For each expected word, the heard word it matched, if any.</summary>
        internal int?[] Matched { get; }
        /// <summary>For each expected word, whether it is a number only lined up with words of another language.</summary>
        internal bool[] Unverified { get; }
        /// <summary>How many such numbers there were.</summary>
        internal int UnverifiedNumbers { get; }
        /// <summary>For each unmatched expected word, the heard words in its place (between the matches around it), joined.</summary>
        internal string?[] HeardInstead { get; }
        /// <summary>For each unmatched expected word, whether what was heard in its place is one shorter, different word.</summary>
        internal bool[] HeardShorter { get; }
        internal IReadOnlyList<ExportCheckHeard> Heard { get; }

        internal WordAlignment(IReadOnlyList<ExportCheckWord> expected, IReadOnlyList<ExportCheckHeard> heard)
        {
            Heard = heard;
            var expectedTokens = new List<SpokenNumbers.Token>();
            var expectedOwner = new List<int>();
            for (var index = 0; index < expected.Count; index++)
                foreach (var token in SpokenTokens(expected[index].Text)) { expectedTokens.Add(token); expectedOwner.Add(index); }
            var heardTokens = new List<SpokenNumbers.Token>();
            var heardOwner = new List<int>();
            for (var index = 0; index < heard.Count; index++)
                foreach (var token in SpokenTokens(heard[index].Text)) { heardTokens.Add(token); heardOwner.Add(index); }
            // A recognizer spells a name it does not know as the common word it sounds like ("Claude" as "cloud").
            var expectedTexts = expectedTokens.Select(token => token.Text).ToArray();
            var spelled = VoiceLabTakeQuality.NormalizingHomophones(heardTokens.Select(token => token.Text).ToArray(), expectedTexts,
                expectedTexts.ToHashSet(StringComparer.Ordinal));
            var recognized = heardTokens.Select((token, index) => token with { Text = spelled[index] }).ToArray();
            var alignment = SpokenNumbers.Align(expectedTokens, recognized);
            // A numeral matched to several heard words maps to the first of them.
            var tokenMatch = new int?[expectedTokens.Count];
            foreach (var (wanted, got) in alignment.Pairs) tokenMatch[wanted] ??= got;
            var unverifiedTokens = alignment.UnverifiedExpected.ToHashSet();
            // A word matches when every token of it matched; it is matched to its first token's heard word. A word whose tokens
            // are matched or unverified, one at least unverified, is unverified.
            var matched = new int?[expected.Count];
            var complete = Enumerable.Repeat(true, expected.Count).ToArray();
            var unverified = new bool[expected.Count];
            for (var token = 0; token < expectedOwner.Count; token++)
            {
                var owner = expectedOwner[token];
                if (tokenMatch[token] is { } heardToken) matched[owner] ??= heardOwner[heardToken];
                else if (unverifiedTokens.Contains(token)) unverified[owner] = true;
                else complete[owner] = false;
            }
            for (var index = 0; index < expected.Count; index++)
            {
                if (complete[index] && !unverified[index]) continue;
                matched[index] = null;
                if (!complete[index]) unverified[index] = false;
            }
            Matched = matched;
            Unverified = unverified;
            UnverifiedNumbers = alignment.UnverifiedNumbers;
            // The heard tokens in each gap between matches go to that gap's unmatched expected tokens in order; the last one takes
            // what remains. A numeral heard is never a shorter word: a number heard in digits is not cut off.
            var instead = Enumerable.Range(0, expected.Count).Select(_ => new List<string>()).ToArray();
            var shorter = new bool[expected.Count];
            var anchors = new List<(int Expected, int Recognized)> { (-1, -1) };
            anchors.AddRange(alignment.Pairs);
            anchors.Add((expectedTokens.Count, recognized.Length));
            for (var anchor = 0; anchor + 1 < anchors.Count; anchor++)
            {
                var (left, right) = (anchors[anchor], anchors[anchor + 1]);
                var missing = Range(left.Expected + 1, right.Expected).Where(token => !unverifiedTokens.Contains(token)).ToArray();
                var extra = Range(left.Recognized + 1, right.Recognized).ToArray();
                for (var offset = 0; offset < missing.Length; offset++)
                {
                    var token = missing[offset];
                    var owner = expectedOwner[token];
                    int[] taken = offset >= extra.Length ? [] : offset < missing.Length - 1 ? [extra[offset]] : extra[offset..];
                    var words = taken.Select(index => heardTokens[index].Text).ToArray();
                    instead[owner].AddRange(words);
                    var wanted = expectedTokens[token].Text;
                    if (taken.Length == 1 && heardTokens[taken[0]].Numeral is null && Characters(words[0]) < Characters(wanted) &&
                        !string.Equals(words[0], wanted, StringComparison.Ordinal))
                        shorter[owner] = true;
                }
            }
            HeardInstead = instead.Select(words => words.Count == 0 ? null : string.Join(' ', words)).ToArray();
            HeardShorter = shorter;
        }

        // Swift's half-open lower..<max(lower, upper).
        private static IEnumerable<int> Range(int lower, int upper) => Enumerable.Range(lower, Math.Max(0, upper - lower));
        // Characters as the Mac counts them: grapheme clusters.
        private static int Characters(string text) => new StringInfo(text).LengthInTextElements;
    }

    /// <summary>The take QA's tokens of <paramref name="text"/> (audio tags stripped), with the number each one writes in digits.</summary>
    internal static SpokenNumbers.Token[] SpokenTokens(string text) => SpokenNumbers.Tokens(VoiceLabAudioTags.StrippingTags(text));

    /// <summary>Whether each expected word sits next to a cut or a clip edge: the first and the last word, and any word with a cut
    /// between it and the word before or after it. The bounds are inclusive: a recognizer's words touch, and a cut between touching
    /// words falls on that boundary.</summary>
    internal static bool[] AtEdges(IReadOnlyList<ExportCheckWord> words, IReadOnlyList<double> cuts)
    {
        if (words.Count == 0) return [];
        var sorted = cuts.Order().ToArray();
        bool Cut(double lower, double upper) => sorted.Any(cut => cut >= lower && cut <= upper);
        var last = words.Count - 1;
        return Enumerable.Range(0, words.Count).Select(index => index == 0 || index == last ||
            Cut(words[index - 1].End, words[index].End) || Cut(words[index].Start, words[index + 1].Start)).ToArray();
    }

    internal static ExportCheckResult Words(ExportCheckInput input, WordAlignment? alignment)
    {
        if (alignment is null) return ExportCheckResult.Skipped(ExportCheckKind.Words, input.HearingSkipped);
        var expected = input.Expected;
        var all = Enumerable.Range(0, expected.Count).Where(index => !expected[index].Optional).ToArray();
        if (all.Length == 0) return ExportCheckResult.Skipped(ExportCheckKind.Words, "No words to check");
        // A number lined up only with another language's words is neither matched nor a mismatch.
        var scored = all.Where(index => !alignment.Unverified[index]).ToArray();
        var edges = AtEdges(expected, input.Cuts);
        var items = new List<ExportCheckItem>();
        var warn = false;
        foreach (var index in scored.Where(index => alignment.Matched[index] is null))
        {
            var word = expected[index];
            var heard = alignment.HeardInstead[index];
            var cutOff = edges[index] && (heard is null || alignment.HeardShorter[index]);
            items.Add(new(cutOff ? ExportCheckItemKind.CutOff : ExportCheckItemKind.Mismatch, word.Start)
            { Expected = word.Text, Heard = heard, Phrase = word.Phrase });
            if (cutOff || word.Phrase is not null) warn = true;
        }
        var matched = scored.Length - items.Count;
        if (matched < MatchFloor * scored.Length) warn = true;
        return new(ExportCheckKind.Words, warn ? ExportCheckStatus.Warning : ExportCheckStatus.Ok)
        {
            Items = items, Matched = matched, Total = scored.Length,
            Unverified = alignment.UnverifiedNumbers > 0 ? alignment.UnverifiedNumbers : null,
        };
    }

    // Sync.

    internal static ExportCheckResult Sync(ExportCheckInput input, WordAlignment? alignment)
    {
        var items = new List<ExportCheckItem>();
        double? startOffset = null, endOffset = null;
        var frame = input.FrameSeconds;
        if (input.Video is { } video && input.Audio is { } audio)
        {
            var start = audio.Start - video.Start;
            var end = audio.End - video.End;
            startOffset = start; endOffset = end;
            // The microsecond keeps a track that ends exactly one frame from the other within the rule.
            if (Math.Abs(start) > frame + 1e-6)
                items.Add(new(ExportCheckItemKind.TrackStart, Math.Min(audio.Start, video.Start)) { Value = start, Limit = frame });
            if (Math.Abs(end) > frame + 1e-6)
                items.Add(new(ExportCheckItemKind.TrackEnd, Math.Min(audio.End, video.End)) { Value = end, Limit = frame });
        }
        else if (input.Phrases.Count == 0)
            return ExportCheckResult.Skipped(ExportCheckKind.Sync, input.Video is null ? "No video track" : "No audio track");
        if (input.Phrases.Count > 0 && alignment is not null)
        {
            foreach (var phrase in input.Phrases)
                if (Placement(phrase, input, alignment) is { } item) items.Add(item);
        }
        else if (input.Phrases.Count > 0)
            items.Add(new(ExportCheckItemKind.PhrasesSkipped, input.Phrases.Min(phrase => phrase.Start)) { Reason = input.HearingSkipped });
        var warn = items.Any(item => item.Kind != ExportCheckItemKind.PhrasesSkipped);
        return new(ExportCheckKind.Sync, warn ? ExportCheckStatus.Warning : ExportCheckStatus.Ok)
        { Items = items, StartOffset = startOffset, EndOffset = endOffset };
    }

    /// <summary>The phrase's finding, null when its heard words sit within the tolerance of where the edit placed them: the median
    /// of its matched words' start offsets, heard minus placed.</summary>
    internal static ExportCheckItem? Placement(ExportCheckPhrase phrase, ExportCheckInput input, WordAlignment alignment)
    {
        var offsets = new List<double>();
        for (var index = 0; index < input.Expected.Count; index++)
            if (input.Expected[index].Phrase == phrase.Id && alignment.Matched[index] is { } heard)
                offsets.Add(alignment.Heard[heard].Start - input.Expected[index].Start);
        if (offsets.Count == 0) return new(ExportCheckItemKind.PhraseNotHeard, phrase.Start) { Phrase = phrase.Id };
        offsets.Sort();
        var middle = offsets.Count / 2;
        var median = offsets.Count % 2 == 1 ? offsets[middle] : (offsets[middle - 1] + offsets[middle]) / 2;
        if (Math.Abs(median) <= PhraseToleranceSeconds) return null;
        return new(ExportCheckItemKind.PhraseOffset, phrase.Start) { Value = median, Limit = PhraseToleranceSeconds, Phrase = phrase.Id };
    }

    // Loudness.

    internal static ExportCheckResult Loudness(ExportCheckInput input)
    {
        if (input.Loudness is not { } measured) return ExportCheckResult.Skipped(ExportCheckKind.Loudness, "No audio track");
        if (measured.Setting != ExportLoudness.Social) return ExportCheckResult.Skipped(ExportCheckKind.Loudness, "Loudness is off for this export");
        var result = new ExportCheckResult(ExportCheckKind.Loudness, ExportCheckStatus.Ok)
        { IntegratedLufs = measured.IntegratedLufs, TruePeakDbtp = measured.TruePeakDbtp };
        if (measured.IntegratedLufs is not { } lufs || !double.IsFinite(lufs))
            return result with { Items = [new(ExportCheckItemKind.Silent, 0)], Status = ExportCheckStatus.Warning };
        var items = new List<ExportCheckItem>();
        if (Math.Abs(lufs - TargetLufs) > LoudnessToleranceLu)
            items.Add(new(ExportCheckItemKind.IntegratedLoudness, 0) { Value = lufs, Limit = TargetLufs });
        if (measured.TruePeakDbtp is { } peak && peak > CeilingDbtp + TruePeakToleranceDb)
            items.Add(new(ExportCheckItemKind.TruePeak, 0) { Value = peak, Limit = CeilingDbtp });
        return result with { Items = items, Status = items.Count == 0 ? ExportCheckStatus.Ok : ExportCheckStatus.Warning };
    }

    // Captions.

    internal static ExportCheckResult Captions(ExportCheckInput input)
    {
        if (input.Boxes.Count == 0) return ExportCheckResult.Skipped(ExportCheckKind.Captions, "No captions or title in this export");
        var bands = CaptionSafeZones.Bands(input.Frame);
        var items = new List<ExportCheckItem>();
        foreach (var box in input.Boxes)
        {
            foreach (var band in bands)
            {
                var overlap = CaptionSafeZones.Overlap(box.Rect, band);
                // A millionth of the frame's height is rounding, not a box in the band.
                if (overlap <= 1e-6) continue;
                var kind = box.Kind == ExportCheckBoxKind.Title ? ExportCheckItemKind.TitleBand : ExportCheckItemKind.CaptionBand;
                // The cards of a style sit at one place: a run of the same overlap is one finding, with its count.
                if (items.Count > 0 && items[^1] is var last && last.Kind == kind && last.Band == band.Edge && Math.Abs((last.Value ?? 0) - overlap) < 1e-9)
                {
                    items[^1] = last with { Count = (last.Count ?? 1) + 1 };
                    continue;
                }
                items.Add(new(kind, box.Time) { Value = overlap, Limit = band.Fraction, Band = band.Edge });
            }
        }
        return new(ExportCheckKind.Captions, items.Count == 0 ? ExportCheckStatus.Ok : ExportCheckStatus.Warning) { Items = items };
    }
}
