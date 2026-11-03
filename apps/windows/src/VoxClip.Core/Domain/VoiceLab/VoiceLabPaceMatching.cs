#pragma warning disable CS1591
using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Domain.Transcript;
namespace VoxClip.Core.Domain.VoiceLab;

public static class VoiceLabPaceMatching
{
    public static VoiceLabRewriteFitResult Measure(string text, double rate, VoiceLabWindow window,
        double? incomingSilence, double? outgoingSilence, int sourceSampleRate, bool hardJoinSmoothing, bool supportsPace = true,
        IReadOnlyList<TimedWord>? sourceItems = null, AudioEnvelope? sourceEnvelope = null,
        IReadOnlyList<VoiceLabAudioTag>? audioTags = null, string modelId = "") =>
        Match(VoiceLabRewriteFit.Estimate(text, rate) + VoiceLabAudioTags.Allowance(audioTags ?? [], text, modelId), window, incomingSilence, outgoingSilence, sourceSampleRate,
            supportsPace: supportsPace, hardJoinSmoothing: hardJoinSmoothing, sourceItems: sourceItems, sourceEnvelope: sourceEnvelope, generatedText: text,
            audioTags: VoiceLabNaturalPacing.PauseTags(audioTags ?? [], modelId, Domain.Editing.EditingAlgorithms.SplitWords(text).Count));

    public static VoiceLabRewriteFitResult Match(double seconds, VoiceLabWindow window,
        double? incomingSilence, double? outgoingSilence, int sourceSampleRate, bool hardJoinSmoothing, double oldPace = 1, bool supportsPace = true,
        IReadOnlyList<TimedWord>? sourceItems = null, AudioEnvelope? sourceEnvelope = null, string? generatedText = null, VoiceLabPauseProfile? pauseProfile = null,
        IReadOnlyList<VoiceLabAudioTag>? audioTags = null)
    {
        if (!double.IsFinite(seconds) || seconds <= 0 || !VoiceLabPace.IsValid(oldPace))
            throw new VoiceLabLengthBudgetException(VoiceLabLengthBudgetErrorCode.InvalidInput);
        var profile = pauseProfile ?? (sourceEnvelope is null ? null : VoiceLabPauseProfile.Measure(sourceItems ?? [], sourceEnvelope, 0, double.MaxValue));
        VoiceLabFitResult Fit(double duration, bool allowPauseGrowth = true) => VoiceLabRewriteFit.Hypothetical(window, incomingSilence, outgoingSilence, duration, sourceSampleRate,
            hardJoinSmoothing, generatedText, profile, audioTags, allowPauseGrowth);
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
        var cutPlan = Fit(predicted, false).Plan;
        var cuts = sourceEnvelope is null ? [] : VoiceLabNaturalPacing.Cuts(cutPlan.WindowStartSample, cutPlan.WindowEndSample,
            cutPlan.OutputFrames, sourceSampleRate, sourceEnvelope, sourceItems ?? []);
        return new(predicted, source, VoiceLabRewriteFit.AllowsVideo(fit, sourceSampleRate, sourceSampleRate) || cuts.Count > 0,
            chosen, fit is not VoiceLabFitResult.Exact && cuts.Count > 0, Math.Max(0, retimeUpper));
    }
}
