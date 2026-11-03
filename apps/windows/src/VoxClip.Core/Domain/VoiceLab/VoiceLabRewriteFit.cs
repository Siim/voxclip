#pragma warning disable CS1591
using System.Globalization;
using VoxClip.Core.Domain.Editing;
using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Domain.Transcript;

namespace VoxClip.Core.Domain.VoiceLab;

public sealed record VoiceLabRewriteFitResult(double EstimateSeconds, double SlotSeconds, bool Fits, double Pace = 1, bool FitsWithVideoCut = false,
    double? MaximumSeconds = null)
{
    public bool TooLong => EstimateSeconds > (MaximumSeconds ?? SlotSeconds);
    public string Copy => "≈ " + EditingFormat.ToFixed1(EstimateSeconds) + " s" +
        (Pace == 1 ? "" : " at " + Pace.ToString("F2", CultureInfo.InvariantCulture) + "× pace") +
        " · slot " + EditingFormat.ToFixed1(SlotSeconds) + " s" + (FitsWithVideoCut ? " · fits with a video cut" : Fits ? " · fits" : "");
}

public static class VoiceLabRewriteFit
{
    public const double MinorPauseSeconds = 0.12;
    public const double SentencePauseSeconds = 0.22;
    public const double MinimumVideoSpeed = 0.80;
    public const double MaximumVideoSpeed = 1.25;
    public const double ProviderSpeechRateMultiplier = 1.8;
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

    public static double Estimate(string text, double rate)
    {
        var seconds = VoiceLabLengthBudget.Estimate(text, rate * ProviderSpeechRateMultiplier);
        var previous = 0;
        foreach (var character in text)
        {
            var kind = ".!?…。！？".Contains(character) ? 2 : ",;:—–-，；：".Contains(character) ? 1 : 0;
            if (kind != 0 && previous == 0) seconds += kind == 2 ? SentencePauseSeconds : MinorPauseSeconds;
            else if (kind == 2 && previous == 1) seconds += SentencePauseSeconds - MinorPauseSeconds;
            previous = kind == 0 ? 0 : Math.Max(previous, kind);
        }
        return seconds;
    }

    public static bool AllowsVideo(VoiceLabFitResult fit, double sourceSampleRate, double assetSampleRate)
    {
        var plan = fit.Plan;
        var duration = plan.WindowEnd - plan.WindowStart + (fit is VoiceLabFitResult.ChangedDuration changed ? changed.ResidualSeconds : 0);
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
            var gaps = tokens.SkipLast(1).Select(token => VoiceLabNaturalPacing.EndsSentence(token) ? 0.22 :
                VoiceLabNaturalPacing.ClauseBoundary(token, "") ? 0.12 : 0.06).ToArray();
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
