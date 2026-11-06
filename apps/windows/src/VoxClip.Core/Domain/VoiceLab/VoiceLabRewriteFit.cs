#pragma warning disable CS1591
using System.Globalization;
using VoxClip.Core.Domain.Editing;
using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Domain.Transcript;

namespace VoxClip.Core.Domain.VoiceLab;

public sealed record VoiceLabRewriteFitResult(double EstimateSeconds, double SlotSeconds, bool Fits, double Pace = 1, bool FitsWithVideoCut = false,
    double? MaximumSeconds = null, double? MinimumSeconds = null)
{
    public bool TooLong => EstimateSeconds > (MaximumSeconds ?? SlotSeconds);
    public string Copy => "≈ " + EditingFormat.ToFixed1(EstimateSeconds) + " s" +
        (Pace == 1 ? "" : " at " + Pace.ToString("F2", CultureInfo.InvariantCulture) + "× pace") +
        " · slot " + EditingFormat.ToFixed1(SlotSeconds) + " s" + (FitsWithVideoCut ? " · fits with a video cut" : Fits ? " · fits" : "");
}

public static class VoiceLabRewriteFit
{
    public const double MinimumVideoSpeed = 0.80;
    public const double MaximumVideoSpeed = 1.25;
    /// <summary>The calibrated prior (ADR-R43; Mac <c>VoiceLabPhraseTiming</c>): how many times the speaker's letters per voiced second a
    /// cloned take speaks. Observed on 78 real Eleven v4 takes: about the speaker's own letter rate, plus a fixed onset.</summary>
    public const double ProviderSpeechRateMultiplier = 1.2;
    /// <summary>Fixed per-take speech overhead beyond the trim allowance: the onset and decay a take always has.</summary>
    public const double OnsetSeconds = 0.4;
    /// <summary>A sentence-ending group followed by more speech; a final group adds nothing.</summary>
    public const double SentencePauseSeconds = 0.5;
    /// <summary>A comma, semicolon, colon or dash group followed by more speech.</summary>
    public const double ClausePauseSeconds = 0.1;
    /// <summary>The prior's generation. Ratios measured against an older prior are not comparable and are not read.</summary>
    public const int PriorVersion = 2;
    public const string TooLongCopy = "Too long for its slot. A take won't fit the video.";
    public const string TooShortCopy = "Too short for its slot. A take won't fit the video.";

    public static double SpeakingRate(IReadOnlyList<TimedWord> transcript)
    {
        _ = VoiceLabLengthBudget.Rate(transcript);
        double seconds = 0, previousEnd = 0;
        var letters = 0;
        foreach (var word in transcript.Where(word => word.Kind == WordKind.Word))
        {
            letters += VoiceLabTextLength.Length(word.Text);
            seconds += Math.Max(0, word.End - Math.Max(word.Start, previousEnd));
            previousEnd = Math.Max(previousEnd, word.End);
        }
        if (seconds <= 0 || letters <= 0) throw new VoiceLabLengthBudgetException(VoiceLabLengthBudgetErrorCode.RateUnavailable);
        return letters / seconds;
    }

    /// <summary>letters ÷ (rate × <see cref="ProviderSpeechRateMultiplier"/>) + the trim allowance + <see cref="OnsetSeconds"/> + the
    /// pauses inside the text (<see cref="PauseSeconds"/>), in the shared evaluation order (<c>tts-estimator-cases.json</c>).</summary>
    public static double Estimate(string text, double rate)
    {
        if (!double.IsFinite(rate) || rate <= 0) throw new VoiceLabLengthBudgetException(VoiceLabLengthBudgetErrorCode.InvalidInput);
        var speech = VoiceLabTextLength.Length(text) / (rate * ProviderSpeechRateMultiplier);
        var fixedSeconds = VoiceLabPatchConstants.TTS_TRIM_LEAD + VoiceLabPatchConstants.TTS_TRIM_TAIL + OnsetSeconds;
        var estimate = speech + fixedSeconds + PauseSeconds(text);
        if (!double.IsFinite(estimate) || estimate <= 0) throw new VoiceLabLengthBudgetException(VoiceLabLengthBudgetErrorCode.InvalidInput);
        return estimate;
    }

    /// <summary>The pauses inside <paramref name="text"/>: each punctuation group counts once, at its largest pause, and only when more
    /// speech follows it. A hyphen between two letters or digits joins a word ("A-10") and is no pause.</summary>
    public static double PauseSeconds(string text)
    {
        var runes = EditingAlgorithms.Nfc(text).EnumerateRunes().ToArray();
        double total = 0, pending = 0;
        for (var index = 0; index < runes.Length; index++)
        {
            var rune = runes[index].ToString();
            if (".!?…。！？".Contains(rune, StringComparison.Ordinal)) pending = Math.Max(pending, SentencePauseSeconds);
            else if (",;:—–，；：".Contains(rune, StringComparison.Ordinal)) pending = Math.Max(pending, ClausePauseSeconds);
            else if (rune == "-")
            {
                var joined = index > 0 && index + 1 < runes.Length && Counts(runes[index - 1]) && Counts(runes[index + 1]);
                if (!joined) pending = Math.Max(pending, ClausePauseSeconds);
            }
            else if (Counts(runes[index])) { total += pending; pending = 0; }
        }
        return total;
    }

    private static bool Counts(System.Text.Rune rune) => VoiceLabTextLength.Length(rune.ToString()) > 0;

    /// <summary>The seconds the take occupies in the video: the window, plus the residual after a partial fit. Every video
    /// choice, the cut search included, sizes its output from <c>Round(VideoDuration × sourceRate)</c>, never from asset frames.</summary>
    public static double VideoDuration(VoiceLabFitResult fit) =>
        fit.Plan.WindowEnd - fit.Plan.WindowStart + (fit is VoiceLabFitResult.ChangedDuration changed ? changed.ResidualSeconds : 0);

    public static bool AllowsVideo(VoiceLabFitResult fit, double sourceSampleRate, double assetSampleRate)
    {
        var plan = fit.Plan;
        var duration = VideoDuration(fit);
        var output = EditingMath.Round(duration * sourceSampleRate);
        if (sourceSampleRate <= 0 || assetSampleRate <= 0 || plan.OutputFrames <= 0 || plan.WindowStartSample < 0 ||
            plan.WindowEndSample <= plan.WindowStartSample || !double.IsFinite(plan.WindowStart) || plan.WindowStart < 0 ||
            !double.IsFinite(plan.WindowEnd) || plan.WindowEnd <= plan.WindowStart ||
            EditingMath.Round(plan.WindowStart * sourceSampleRate) != plan.WindowStartSample ||
            EditingMath.Round(plan.WindowEnd * sourceSampleRate) != plan.WindowEndSample ||
            !double.IsFinite(duration) || duration <= 0 || EditingMath.Round(duration * assetSampleRate) != plan.OutputFrames ||
            !double.IsFinite(output) || output <= 0 || output >= long.MaxValue) return false;
        var source = plan.WindowEndSample - plan.WindowStartSample;
        if (fit is VoiceLabFitResult.Exact && source == output) return true;
        var speed = source / output;
        return double.IsFinite(speed) && speed >= MinimumVideoSpeed && speed <= MaximumVideoSpeed;
    }

    public static VoiceLabFitResult Hypothetical(VoiceLabWindow window, double? incomingSilence, double? outgoingSilence,
        double seconds, double sourceSampleRate, bool hardJoinSmoothing, string? generatedText = null, VoiceLabPauseProfile? pauseProfile = null,
        IReadOnlyList<VoiceLabAudioTag>? audioTags = null, bool allowPauseGrowth = true)
    {
        if (!double.IsFinite(seconds) || seconds <= 0 || seconds > 3600 || !double.IsFinite(sourceSampleRate) ||
            sourceSampleRate <= 0 || sourceSampleRate > 1_000_000 || sourceSampleRate != Math.Truncate(sourceSampleRate))
            throw new VoiceLabLengthBudgetException(VoiceLabLengthBudgetErrorCode.InvalidInput);
        var assetRate = (int)sourceSampleRate;
        var frames = (long)EditingMath.Round(seconds * assetRate);
        if (frames <= 0 || frames >= VoiceLabFitPlanner.FrameLimit)
            throw new VoiceLabLengthBudgetException(VoiceLabLengthBudgetErrorCode.InvalidInput);
        var duration = (double)frames / assetRate;
        var lastWord = duration * assetRate > frames ? Math.BitDecrement(duration) : duration;
        VoiceLabWord[] words = [new("speech", 0, lastWord, true)];
        var tokens = generatedText?.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries) ?? [];
        if (tokens.Length > 1 && pauseProfile is not null)
        {
            var gaps = tokens.SkipLast(1).Select(token => VoiceLabNaturalPacing.EndsSentence(token) ? SentencePauseSeconds :
                VoiceLabNaturalPacing.ClauseBoundary(token, "") ? ClausePauseSeconds : 0.06).ToArray();
            var speech = lastWord - gaps.Sum();
            if (speech > (double)tokens.Length / assetRate)
            {
                var letters = tokens.Select(token => Math.Max(1, VoiceLabTextLength.Length(token))).ToArray();
                var count = letters.Sum(); var cursor = 0.0;
                words = tokens.Select((token, index) =>
                {
                    var end = index == tokens.Length - 1 ? lastWord : cursor + speech * letters[index] / count;
                    var word = new VoiceLabWord(token, cursor, end, true);
                    cursor = end + (index < gaps.Length ? gaps[index] : 0);
                    return word;
                }).ToArray();
            }
        }
        var size = VoiceLabGeometry.FrameSize(assetRate);
        var levels = Enumerable.Range(0, (int)(frames / size)).Select(block =>
        {
            var start = (double)(block * size) / assetRate; var end = (double)((block + 1) * size) / assetRate;
            return words.Any(word => word.Start < end && word.End > start) ? 1f : 0f;
        }).ToArray();
        var envelope = new AudioEnvelope(assetRate, 0.01, levels);
        return VoiceLabFitPlanner.Plan(window, incomingSilence, outgoingSilence,
            new(frames, assetRate, 0, duration, words, envelope), words.Select(word => word.Text).ToArray(), sourceSampleRate, hardJoinSmoothing,
            pauseProfile, audioTags, allowPauseGrowth);
    }
}
