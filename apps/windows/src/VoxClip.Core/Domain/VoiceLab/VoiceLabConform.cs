using VoxClip.Core.Domain.Editing;
using VoxClip.Core.Domain.Transcript;

namespace VoxClip.Core.Domain.VoiceLab;

/// <summary>How to conform provider audio whose length differs from its input; voice-lab.md §4.4 and §7.3. Sample
/// counts and lags are on the input rate's grid.</summary>
public abstract record VoiceLabConformDecision
{
    /// <summary>The lengths differ by at most 20 ms: trim Delta samples from the end when positive, or zero-pad −Delta
    /// samples there when negative.</summary>
    public sealed record TrimOrPad(long Delta) : VoiceLabConformDecision;
    /// <summary>The output is Lag samples late (early when negative): drop its first Lag samples, or pad −Lag zeros
    /// before it, then trim or pad the end to the input length. Peak is the envelope correlation at that lag.</summary>
    public sealed record Shift(long Lag, double Peak) : VoiceLabConformDecision;
    /// <summary>The output cannot be aligned with its input and is not applied. The provider cost was already spent,
    /// so the UI must say so (§4.4 step 4).</summary>
    public sealed record OutOfSync(double Peak, long Lag) : VoiceLabConformDecision;
}

/// <summary>The duration-conform decision for a Clean audio or voice-changer chunk; voice-lab.md §4.4 and §7.3. Pure:
/// no I/O, media framework or global state.</summary>
public static class VoiceLabConform
{
    /// <summary>The voice changer's lag search (§7.3).</summary>
    public const double VoiceChangerSearchSeconds = 0.3;
    /// <summary>Clean audio's lag search (§4.4 step 3).</summary>
    public const double CleanAudioSearchSeconds = 0.5;
    private const double ToleranceSeconds = 0.020;
    private const double CorrelationFloor = 0.5;

    /// <summary>Decides how to conform outputSamples of provider audio, already resampled to the input rate, to
    /// inputSamples. Both envelopes are the 10 ms RMS of their audio at sampleRate: frames of round_half_up(rate × 0.01)
    /// samples from sample 0, without the partial final frame.
    /// When |Δ| ≤ 20 ms the result is TrimOrPad. Otherwise the lag L, in whole frames within ±searchSeconds, is the one
    /// whose overlapping frames correlate best: the Pearson correlation, with both means taken over the overlap, at
    /// most 1, and 0 for a constant overlap or one shorter than half the shorter envelope. Ties go to the smallest |L|,
    /// then to the negative lag. A peak below 0.5, or |Δ − L| above 20 ms, is OutOfSync; otherwise the result is
    /// Shift.</summary>
    // Spec: voice-lab.md §4.4 step 3 "normalised cross-correlation", read as Pearson over each lag's overlap (lead decision).
    public static VoiceLabConformDecision Decide(AudioEnvelope inputEnvelope, AudioEnvelope outputEnvelope, long inputSamples,
        long outputSamples, int sampleRate, double searchSeconds)
    {
        var frame = sampleRate > 0 ? VoiceLabLoudness.SampleCount(VoiceLabPatchConstants.RMS_FRAME, sampleRate) : 0;
        if (frame < 1 || inputSamples < 0 || outputSamples < 0 ||
            !double.IsFinite(searchSeconds) || searchSeconds < 0 || searchSeconds * sampleRate >= 9007199254740992.0 ||
            !Matches(inputEnvelope, inputSamples / frame, frame, sampleRate) || !Matches(outputEnvelope, outputSamples / frame, frame, sampleRate))
            throw new VoiceLabAudioMathException(VoiceLabAudioMathErrorCode.InvalidInput);
        var tolerance = VoiceLabLoudness.SampleCount(ToleranceSeconds, sampleRate);
        var delta = outputSamples - inputSamples;
        if (Math.Abs(delta) <= tolerance) return new VoiceLabConformDecision.TrimOrPad(delta);
        var input = inputEnvelope.Rms.Select(level => (double)level).ToArray();
        var output = outputEnvelope.Rms.Select(level => (double)level).ToArray();
        var reach = (long)EditingMath.Round(searchSeconds * sampleRate) / frame;
        long bestLag = 0;
        var best = Correlation(input, output, 0);
        for (long distance = 1; distance <= reach; distance++)
            foreach (var lag in new[] { -distance, distance })
            {
                var value = Correlation(input, output, lag);
                if (value > best) (bestLag, best) = (lag, value);
            }
        var samples = bestLag * frame;
        return best < CorrelationFloor || Math.Abs(delta - samples) > tolerance
            ? new VoiceLabConformDecision.OutOfSync(best, samples)
            : new VoiceLabConformDecision.Shift(samples, best);
    }

    private static bool Matches(AudioEnvelope envelope, long frames, int frame, int sampleRate) =>
        envelope.SampleRate == sampleRate && envelope.Rms.Count == frames &&
        EditingMath.Round(envelope.FrameSeconds * sampleRate) == frame && envelope.Rms.All(float.IsFinite);

    // The Pearson correlation of a[i] and b[i + lag] over their overlap, at most 1. It is 0 when the overlap is constant
    // or shorter than ceil(min(a.Length, b.Length) / 2) frames: two frames correlate ±1 by construction, so a short
    // overlap at the edge of the search would beat the true lag of a short chunk (lead decision).
    internal static double Correlation(double[] a, double[] b, long lag)
    {
        var start = Math.Max(0, -lag);
        var end = Math.Min(a.Length, b.Length - lag);
        if (end <= start || end - start < (Math.Min(a.Length, b.Length) + 1) / 2) return 0;
        double sumA = 0, sumB = 0;
        for (var index = start; index < end; index++)
        {
            sumA += a[index];
            sumB += b[index + lag];
        }
        double meanA = sumA / (end - start), meanB = sumB / (end - start);
        double cross = 0, energyA = 0, energyB = 0;
        for (var index = start; index < end; index++)
        {
            double x = a[index] - meanA, y = b[index + lag] - meanB;
            cross += x * y;
            energyA += x * x;
            energyB += y * y;
        }
        return energyA > 0 && energyB > 0 ? Math.Min(1, cross / Math.Sqrt(energyA * energyB)) : 0;
    }
}
