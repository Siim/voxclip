using VoxClip.Core.Domain.Editing;

namespace VoxClip.Core.Domain.VoiceLab;

/// <summary>Advisory verdict before an aligned take exists.</summary>
public enum VoiceLabFitVerdict
{
    /// <summary>The estimate lies inside the inclusive seam limits.</summary>
    Fits,
    /// <summary>The planner may still fit internal pauses later.</summary>
    WillChangeLength
}
/// <summary>Duration estimate, w, inclusive bounds, verdict and exact live copy.</summary>
public sealed record VoiceLabFitMeterResult(double EstimateSeconds, double GapSeconds, double LowerBoundSeconds,
    double UpperBoundSeconds, VoiceLabFitVerdict Verdict, string Copy);

/// <summary>The free, per-hunk live fit meter, Voice Lab §8.9.1.</summary>
public static class VoiceLabFitMeter
{
    /// <summary>Estimate complete spoken text including bridges. Required newWords excludes bridges and supplies only the quote.</summary>
    public static VoiceLabFitMeterResult Measure(string text, VoiceLabWindow window, double? incomingSilence, double? outgoingSilence,
        double rate, string newWords, bool multipleHunks = false)
    {
        var geometry = VoiceLabLengthBudget.Geometry(window, incomingSilence, outgoingSilence);
        double estimate = VoiceLabLengthBudget.Estimate(text, rate);
        double leftPad = Pad(window.LeftSeam.Kind);
        double rightPad = Pad(window.RightSeam.Kind);
        double lowerLeft = geometry.Target - leftPad;
        double lower = lowerLeft - rightPad;
        double leftBorrow = Borrow(window.LeftSeam.Kind, incomingSilence);
        double rightBorrow = Borrow(window.RightSeam.Kind, outgoingSilence);
        double upperLeft = geometry.Target + leftBorrow;
        double upper = upperLeft + rightBorrow;
        var verdict = estimate >= lower && estimate <= upper ? VoiceLabFitVerdict.Fits : VoiceLabFitVerdict.WillChangeLength;
        string ending = verdict == VoiceLabFitVerdict.Fits ? "fits" : "will change length";
        string prefix = multipleHunks ? "“" + newWords + "” · " : "";
        string copy = prefix + "about " + EditingFormat.ToFixed1(estimate) + " s for a " + EditingFormat.ToFixed1(geometry.Target) + " s gap: " + ending;
        return new(estimate, geometry.Target, lower, upper, verdict, copy);
    }

    static double Pad(VoiceLabSeamKind kind) => kind == VoiceLabSeamKind.Hard ? VoiceLabPatchConstants.HARD_SEAM_PAD_MAX : VoiceLabPatchConstants.SEAM_PAD_MAX;
    static double Borrow(VoiceLabSeamKind kind, double? silence) => kind == VoiceLabSeamKind.Gap ? Math.Max(0, silence!.Value - VoiceLabPatchConstants.PAUSE_SLACK_KEEP) : 0;
}
