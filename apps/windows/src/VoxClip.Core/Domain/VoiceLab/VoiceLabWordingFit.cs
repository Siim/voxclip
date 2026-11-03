#pragma warning disable CS1591
using VoxClip.Core.Domain.Editing;

namespace VoxClip.Core.Domain.VoiceLab;

/// <summary>One measured/estimated duration ratio of a take, stored per model in <c>voiceLab.speakingRateSamples</c>.</summary>
public sealed record VoiceLabRateSample(string Id, double Ratio);

/// <summary>An inclusive word range the automatic wording fit asks for.</summary>
public sealed record VoiceLabWordTarget(int Minimum, int Maximum);

/// <summary>One phrase an automatic wording-fit round asks the connector to reword (voice-lab.md, automatic wording fit).</summary>
public sealed record VoiceLabFitPhrase(int Ordinal, string Original, string Proposed, double EstimateSeconds, double SlotSeconds,
    string Direction, VoiceLabWordTarget Target, double? MeasuredSeconds = null, bool Calibrated = false);

/// <summary>The structured answer for one requested phrase: reworded text, or keep the original recording.</summary>
public sealed record VoiceLabFitUpdate(int Ordinal, bool KeepOriginal, string Text);

/// <summary>Pure wording-fit rules shared with macOS through <c>autofit-cases.json</c>.</summary>
public static class VoiceLabWordingFit
{
    public const string ModelId = "eleven_v4";
    public const int MaximumRounds = 3;
    public const int MaximumSamples = 10;

    /// <summary>The model's speaking-rate multiplier: the median of its last ten valid ratios, or 1 with fewer than two.</summary>
    public static double Multiplier(IReadOnlyList<VoiceLabRateSample>? samples)
    {
        var ratios = (samples ?? []).Where(sample => sample is not null && double.IsFinite(sample.Ratio) && sample.Ratio > 0)
            .Select(sample => sample.Ratio).TakeLast(MaximumSamples).Order().ToArray();
        if (ratios.Length < 2) return 1;
        var middle = ratios.Length / 2;
        return ratios.Length % 2 == 0 ? ratios[middle - 1] / 2 + ratios[middle] / 2 : ratios[middle];
    }

    /// <summary>Adds a take's ratio once, keeping the last ten. Invalid lengths and an already recorded take change nothing.</summary>
    public static IReadOnlyList<VoiceLabRateSample> Recording(IReadOnlyList<VoiceLabRateSample>? samples, string id, double measured, double estimated)
    {
        var previous = samples ?? [];
        if (string.IsNullOrEmpty(id) || !double.IsFinite(measured) || !double.IsFinite(estimated) || measured <= 0 || estimated <= 0 ||
            measured / estimated is var ratio && (!double.IsFinite(ratio) || ratio <= 0) || previous.Any(sample => sample.Id == id)) return previous;
        return previous.Append(new(id, measured / estimated)).TakeLast(MaximumSamples).ToArray();
    }

    /// <summary>The deterministic target word range for a fit range of <paramref name="minimumSeconds"/>…<paramref name="maximumSeconds"/>.</summary>
    public static VoiceLabWordTarget WordTarget(double wordsPerSecond, double multiplier, double minimumSeconds, double maximumSeconds,
        double overheadSeconds, int bridgeWords = 0)
    {
        if (!new[] { wordsPerSecond, multiplier, minimumSeconds, maximumSeconds, overheadSeconds }.All(double.IsFinite) ||
            wordsPerSecond <= 0 || multiplier <= 0 || minimumSeconds < 0 || maximumSeconds < minimumSeconds || overheadSeconds < 0 || bridgeWords < 0)
            throw new VoiceLabLengthBudgetException(VoiceLabLengthBudgetErrorCode.InvalidInput);
        var rate = wordsPerSecond * VoiceLabRewriteFit.ProviderSpeechRateMultiplier / multiplier;
        var lower = Math.Max(0, minimumSeconds - overheadSeconds) * rate - bridgeWords;
        var upper = Math.Max(0, maximumSeconds - overheadSeconds) * rate - bridgeWords;
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
