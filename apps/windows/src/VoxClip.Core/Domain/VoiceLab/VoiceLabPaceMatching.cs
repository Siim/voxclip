#pragma warning disable CS1591
using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Domain.Transcript;
namespace VoxClip.Core.Domain.VoiceLab;

public static class VoiceLabPaceMatching
{
    public static VoiceLabRewriteFitResult Measure(string text, double rate, VoiceLabWindow window,
        double? incomingSilence, double? outgoingSilence, int sourceSampleRate, bool hardJoinSmoothing, bool supportsPace = true,
        IReadOnlyList<TimedWord>? sourceItems = null, AudioEnvelope? sourceEnvelope = null,
        IReadOnlyList<VoiceLabAudioTag>? audioTags = null, string modelId = "", double rateMultiplier = 1)
    {
        if (!double.IsFinite(rateMultiplier) || rateMultiplier <= 0) throw new VoiceLabLengthBudgetException(VoiceLabLengthBudgetErrorCode.InvalidInput);
        return Match(VoiceLabRewriteFit.Estimate(text, rate) * rateMultiplier + VoiceLabAudioTags.Allowance(audioTags ?? [], text, modelId), window, incomingSilence, outgoingSilence, sourceSampleRate,
            supportsPace: supportsPace, hardJoinSmoothing: hardJoinSmoothing, sourceItems: sourceItems, sourceEnvelope: sourceEnvelope, generatedText: text);
    }

    public static VoiceLabRewriteFitResult Match(double seconds, VoiceLabWindow window,
        double? incomingSilence, double? outgoingSilence, int sourceSampleRate, bool hardJoinSmoothing, double oldPace = 1, bool supportsPace = true,
        IReadOnlyList<TimedWord>? sourceItems = null, AudioEnvelope? sourceEnvelope = null, string? generatedText = null, VoiceLabPauseProfile? pauseProfile = null)
    {
        if (!double.IsFinite(seconds) || seconds <= 0 || !VoiceLabPace.IsValid(oldPace))
            throw new VoiceLabLengthBudgetException(VoiceLabLengthBudgetErrorCode.InvalidInput);
        var profile = pauseProfile ?? (sourceEnvelope is null ? null : VoiceLabPauseProfile.Measure(sourceItems ?? [], sourceEnvelope, 0, double.MaxValue));
        VoiceLabFitResult Fit(double duration) => VoiceLabRewriteFit.Hypothetical(window, incomingSilence, outgoingSilence, duration, sourceSampleRate,
            hardJoinSmoothing, generatedText, profile);
        VoiceLabFitResult Bounds(double duration) => VoiceLabRewriteFit.Hypothetical(window, incomingSilence, outgoingSilence, duration, sourceSampleRate, hardJoinSmoothing);
        var probeSeconds = 2 * (window.End - window.Start + (incomingSilence ?? 0) + (outgoingSilence ?? 0) + 1);
        var high = Bounds(probeSeconds).Plan;
        var low = Bounds(1.0 / sourceSampleRate).Plan;
        var source = (window.EndSample - window.StartSample) / (double)sourceSampleRate;
        var expanded = (high.WindowEndSample - high.WindowStartSample) / (double)sourceSampleRate;
        var edge = (high.Incoming.PadFrames + high.Outgoing.PadFrames) / (double)sourceSampleRate;
        var padding = (low.OutputFrames - 1) / (double)sourceSampleRate;
        var exactLower = Math.Max(1.0 / sourceSampleRate, source - padding);
        var exactUpper = expanded - edge;
        var retimeUpper = expanded / VoiceLabRewriteFit.MinimumVideoSpeed - edge;
        // The shortest wording that still fits at source speed: the fit range's lower end the wording fit aims for.
        var fitLower = exactLower;
        if (profile is not null && generatedText is not null && Fit(exactLower) is VoiceLabFitResult.Exact)
        {
            double lower = 1.0 / sourceSampleRate, upper = exactLower;
            for (var step = 0; step < 14; step++)
            {
                var middle = (lower + upper) / 2;
                if (Fit(middle) is VoiceLabFitResult.Exact) upper = middle;
                else lower = middle;
            }
            fitLower = upper;
        }
        var natural = seconds * oldPace;
        var minimum = supportsPace ? VoiceLabNaturalPacing.NATURAL_PACE_MIN : 1;
        var maximum = supportsPace ? VoiceLabNaturalPacing.NATURAL_PACE_MAX : 1;
        double? Pace(double lower, double upper)
        {
            if (upper < lower || upper <= 0) return null;
            var slowest = Math.Max(minimum, Math.Ceiling(natural / upper * 100) / 100);
            var fastest = Math.Min(maximum, Math.Floor(natural / lower * 100) / 100);
            return slowest <= fastest ? Math.Clamp(1, slowest, fastest) : null;
        }
        var chosen = 1.0;
        if (profile is not null && Fit(natural) is not VoiceLabFitResult.Exact && supportsPace)
        {
            foreach (var candidate in Enumerable.Range(90, 21).Select(value => value / 100.0).OrderBy(value => Math.Abs(value - 1)).ThenBy(value => value))
                if (Fit(natural / candidate) is VoiceLabFitResult.Exact) { chosen = candidate; break; }
        }
        else if (Fit(natural) is not VoiceLabFitResult.Exact && Pace(exactLower, exactUpper) is { } exact && Fit(natural / exact) is VoiceLabFitResult.Exact)
            chosen = exact;
        var predicted = natural / chosen;
        var fit = Fit(predicted);
        var cuts = sourceEnvelope is null ? [] : VoiceLabNaturalPacing.Cuts(fit.Plan.WindowStartSample, fit.Plan.WindowEndSample,
            fit.Plan.OutputFrames, sourceSampleRate, sourceEnvelope, sourceItems ?? []);
        return new(predicted, source, VoiceLabRewriteFit.AllowsVideo(fit, sourceSampleRate, sourceSampleRate) || cuts.Count > 0,
            chosen, fit is not VoiceLabFitResult.Exact && cuts.Count > 0, Math.Max(0, retimeUpper), fitLower);
    }
}
