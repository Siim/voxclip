#pragma warning disable CS1591
using VoxClip.Core.Domain.Editing;

namespace VoxClip.Core.Domain.VoiceLab;

/// <summary>One measured/estimated duration ratio of a take, stored per model in <c>voiceLab.speakingRateSamples</c>.</summary>
public sealed record VoiceLabRateSample(string Id, double Ratio);

/// <summary>An inclusive word range the automatic wording fit asks for.</summary>
public sealed record VoiceLabWordTarget(int Minimum, int Maximum);

/// <summary>One phrase an automatic wording-fit round asks the connector to reword (voice-lab.md, automatic wording fit).</summary>
public sealed record VoiceLabFitPhrase(int Ordinal, string Original, string Proposed, double EstimateSeconds, double SlotSeconds,
    string Direction, VoiceLabWordTarget Target, double? MeasuredSeconds = null, bool Calibrated = false)
{
    /// <summary>The wordings already tried for this phrase with their measured results (voice-lab §8.2.2); null when none.</summary>
    public IReadOnlyList<VoiceLabFitTried>? Tried { get; init; }
    /// <summary>The bridge words the reworded phrase must keep (voice-lab §8.2.2); null when its window has none.</summary>
    public VoiceLabFitBridge? Bridge { get; init; }
}

/// <summary>The unchanged words that join a reworded phrase to the recording around it (voice-lab §8.2.2, §8.4; Mac
/// <c>VoiceLabFitBridge</c>). A measured round rewords the whole phrase, these words included; a reply without them can't be
/// placed or priced, so the request names them and the reply is checked before it counts as a round.</summary>
public sealed record VoiceLabFitBridge(IReadOnlyList<string> Leading, IReadOnlyList<string> Trailing)
{
    /// <summary>The take input's bridge words; null when its window has none.</summary>
    public static VoiceLabFitBridge? From(VoiceLabTakeInput input)
    {
        var (leading, trailing) = VoiceLabTakeProcessing.BridgeWords(input);
        return leading.Count == 0 && trailing.Count == 0 ? null : new(leading, trailing);
    }
    /// <summary>Whether a reworded phrase keeps them, as the take's preflight checks it.</summary>
    public bool Keeps(string text) => VoiceLabTakeProcessing.KeepsBridgeWords(text, (Leading, Trailing));
    /// <summary>The words for a person: "I use … as".</summary>
    public string Display => string.Join(" … ", new[] { string.Join(' ', Leading), string.Join(' ', Trailing) }.Where(part => part.Length > 0));
    public bool Equals(VoiceLabFitBridge? other) => other is not null && Leading.SequenceEqual(other.Leading, StringComparer.Ordinal) &&
        Trailing.SequenceEqual(other.Trailing, StringComparer.Ordinal);
    public override int GetHashCode() => HashCode.Combine(string.Join('\u001f', Leading), string.Join('\u001f', Trailing));
}

/// <summary>One wording a stuck phrase already had, and what came of it: the fix loop's memory (voice-lab §8.2.2; Mac
/// <c>VoiceLabFitTried</c>). <c>Result</c> is <c>tooLong</c>, <c>tooShort</c>, <c>words</c>, <c>fit</c>, <c>repeat</c>,
/// <c>notShorter</c>, <c>notLonger</c>, <c>missingBridge</c> or <c>unchecked</c> (<c>shared/prompts/voice-rewrite-tried.json</c>
/// <c>results</c>).</summary>
public sealed record VoiceLabFitTried(string Text, string Result, double? Seconds = null)
{
    /// <summary>Case-, punctuation- and spacing-blind identity of a wording: two wordings with one key are one variant.</summary>
    public static string Key(string text) => string.Join(' ', EditingAlgorithms.SplitWords(VoiceLabAudioTags.StrippingTags(text))
        .Select(word => EditingAlgorithms.NormalizeForMatch(EditingAlgorithms.Nfc(word))).Where(word => word.Length > 0));
}

/// <summary>The structured answer for one requested phrase: reworded text, or keep the original recording.</summary>
public sealed record VoiceLabFitUpdate(int Ordinal, bool KeepOriginal, string Text);

/// <summary>Pure wording-fit rules shared with macOS through <c>autofit-cases.json</c> and <c>tts-estimator-cases.json</c>.</summary>
public static class VoiceLabWordingFit
{
    public const string ModelId = "eleven_v4";
    public const int MaximumRounds = 3;
    /// <summary>A project keeps its last ten samples per model key (<c>voiceLab.speakingRateSamples</c>).</summary>
    public const int ProjectSampleLimit = 10;

    /// <summary>The median of the last ten in-bounds ratios, outliers trimmed (<see cref="VoiceLabRateCalibration.RobustRatios"/>); 1 below
    /// two. Callers pass <see cref="VoiceLabRateCalibration.Samples(IReadOnlyList{VoiceLabRateSample}?, IReadOnlyList{VoiceLabRateSample}?)"/>,
    /// so a new project starts from its voice.</summary>
    public static double Multiplier(IReadOnlyList<VoiceLabRateSample>? samples) => VoiceLabRateCalibration.Multiplier(samples, ProjectSampleLimit);

    /// <summary>Adds a take's ratio once, keeping the last ten. Invalid lengths, a ratio outside 0.25–4 and an already recorded take change
    /// nothing.</summary>
    public static IReadOnlyList<VoiceLabRateSample> Recording(IReadOnlyList<VoiceLabRateSample>? samples, string id, double measured, double estimated)
    {
        var previous = samples ?? [];
        if (string.IsNullOrEmpty(id) || !double.IsFinite(measured) || !double.IsFinite(estimated) || measured <= 0 || estimated <= 0 ||
            !VoiceLabRateCalibration.InBounds(measured / estimated) || previous.Any(sample => sample.Id == id)) return previous;
        return previous.Append(new(id, measured / estimated)).TakeLast(ProjectSampleLimit).ToArray();
    }

    /// <summary>The deterministic word range for a fit range of <paramref name="minimumSeconds"/>…<paramref name="maximumSeconds"/>. The
    /// upper bound aims at the p80 duration (<paramref name="spread"/> × the median, from the calibration's spread), so four takes in five
    /// fit the first time; the lower bound aims at the median.</summary>
    public static VoiceLabWordTarget WordTarget(double wordsPerSecond, double multiplier, double minimumSeconds, double maximumSeconds,
        double overheadSeconds, int bridgeWords = 0, double spread = VoiceLabRateCalibration.PriorSpread)
    {
        if (!new[] { wordsPerSecond, multiplier, minimumSeconds, maximumSeconds, overheadSeconds, spread }.All(double.IsFinite) ||
            wordsPerSecond <= 0 || multiplier <= 0 || minimumSeconds < 0 || maximumSeconds < minimumSeconds || overheadSeconds < 0 || bridgeWords < 0 ||
            spread < 1)
            throw new VoiceLabLengthBudgetException(VoiceLabLengthBudgetErrorCode.InvalidInput);
        var rate = wordsPerSecond * VoiceLabRewriteFit.ProviderSpeechRateMultiplier / multiplier;
        var lower = Math.Max(0, minimumSeconds - overheadSeconds) * rate - bridgeWords;
        var upper = Math.Max(0, maximumSeconds / spread - overheadSeconds) * rate - bridgeWords;
        if (!double.IsFinite(lower) || !double.IsFinite(upper)) throw new VoiceLabLengthBudgetException(VoiceLabLengthBudgetErrorCode.InvalidInput);
        var minimum = Math.Max(1, (int)Math.Max(0, Math.Min(2_000, Math.Ceiling(lower))));
        var maximum = Math.Max(minimum, Math.Min(2_000, (int)Math.Max(0, Math.Min(2_000, Math.Floor(upper)))));
        return new(minimum, maximum);
    }

    /// <summary>The ordinals the next round sends: candidates that neither fit nor were kept, until Stop or the third round.</summary>
    public static IReadOnlyList<int> NextOrdinals(int roundsCompleted, IReadOnlyList<int> candidates, IReadOnlySet<int> fitting,
        IReadOnlySet<int> kept, bool stopped) =>
        stopped || roundsCompleted >= MaximumRounds ? [] : candidates.Distinct().Where(ordinal => !fitting.Contains(ordinal) && !kept.Contains(ordinal)).Order().ToArray();

    /// <summary>How many words the phrase line asks to add or remove.</summary>
    public static int DifferenceWords(VoiceLabFitPhrase phrase)
    {
        var count = EditingAlgorithms.SplitWords(phrase.Proposed).Count;
        return phrase.Direction == "longer" ? Math.Max(1, phrase.Target.Minimum - count) : Math.Max(1, count - phrase.Target.Maximum);
    }

    /// <summary>The hunk with new words and re-anchored annotations; its source span and kind are unchanged.</summary>
    public static VoiceLabDiffHunk Reword(VoiceLabDiffHunk hunk, string text) => hunk with
    {
        NewTokens = EditingAlgorithms.SplitWords(text).ToArray(),
        AudioTags = VoiceLabAudioTags.Reanchored(hunk.AudioTags, string.Join(" ", hunk.NewTokens), text)
    };
}
