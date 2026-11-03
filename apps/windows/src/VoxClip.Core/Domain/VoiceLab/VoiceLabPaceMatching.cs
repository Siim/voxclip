#pragma warning disable CS1591
namespace VoxClip.Core.Domain.VoiceLab;

public static class VoiceLabPaceMatching
{
    public static VoiceLabRewriteFitResult Measure(string text, double rate, VoiceLabWindow window,
        double? incomingSilence, double? outgoingSilence, int sourceSampleRate, bool supportsPace = true) =>
        Match(VoiceLabRewriteFit.Estimate(text, rate), window, incomingSilence, outgoingSilence, sourceSampleRate,
            supportsPace: supportsPace);

    public static VoiceLabRewriteFitResult Match(double seconds, VoiceLabWindow window,
        double? incomingSilence, double? outgoingSilence, int sourceSampleRate, double oldPace = 1, bool supportsPace = true)
    {
        if (!double.IsFinite(seconds) || seconds <= 0 || !VoiceLabPace.IsValid(oldPace))
            throw new VoiceLabLengthBudgetException(VoiceLabLengthBudgetErrorCode.InvalidInput);
        VoiceLabFitResult Fit(double duration) => VoiceLabRewriteFit.Hypothetical(window, incomingSilence, outgoingSilence, duration, sourceSampleRate);
        var probeSeconds = 2 * (window.End - window.Start + (incomingSilence ?? 0) + (outgoingSilence ?? 0) + 1);
        var high = Fit(probeSeconds).Plan;
        var low = Fit(1.0 / sourceSampleRate).Plan;
        var source = (window.EndSample - window.StartSample) / (double)sourceSampleRate;
        var expanded = (high.WindowEndSample - high.WindowStartSample) / (double)sourceSampleRate;
        var edge = (high.Incoming.PadFrames + high.Outgoing.PadFrames) / (double)sourceSampleRate;
        var padding = (low.OutputFrames - 1) / (double)sourceSampleRate;
        var exactLower = Math.Max(1.0 / sourceSampleRate, source - padding);
        var exactUpper = expanded - edge;
        var retimeLower = Math.Max(1.0 / sourceSampleRate, source / VoiceLabRewriteFit.MaximumVideoSpeed - padding);
        var retimeUpper = expanded / VoiceLabRewriteFit.MinimumVideoSpeed - edge;
        var target = Math.Max(1.0 / sourceSampleRate, (exactLower + exactUpper) / 2);
        var natural = seconds * oldPace;
        var minimum = supportsPace ? VoiceLabPace.Minimum : 1;
        var maximum = supportsPace ? VoiceLabPace.Maximum : 1;
        var ideal = Math.Round(natural / target * 100, MidpointRounding.AwayFromZero) / 100;
        double? Pace(double lower, double upper)
        {
            if (upper < lower || upper <= 0) return null;
            var slowest = Math.Max(minimum, Math.Ceiling(natural / upper * 100) / 100);
            var fastest = Math.Min(maximum, Math.Floor(natural / lower * 100) / 100);
            return slowest <= fastest ? Math.Clamp(ideal, slowest, fastest) : null;
        }
        var chosen = supportsPace ? VoiceLabPace.Clamp(ideal) : 1;
        if (Pace(exactLower, exactUpper) is { } exact && Fit(natural / exact) is VoiceLabFitResult.Exact)
            chosen = exact;
        else if (Pace(retimeLower, retimeUpper) is { } retimed && VoiceLabRewriteFit.AllowsVideo(Fit(natural / retimed), sourceSampleRate, sourceSampleRate))
            chosen = retimed;
        var predicted = natural / chosen;
        return new(predicted, Math.Max(0, retimeUpper), VoiceLabRewriteFit.AllowsVideo(Fit(predicted), sourceSampleRate, sourceSampleRate), chosen);
    }
}
