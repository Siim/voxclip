using VoxClip.Core.Domain.Editing;

namespace VoxClip.Media.Tests;

internal static class TestPlan
{
    internal static EditPlan FromKept(double sampleRate, long totalSamples, IReadOnlyList<MediaInterval> kept)
    {
        var cuts = new List<MediaInterval>();
        var joins = new List<Join>();
        var fadeLength = (long)Math.Floor(0.005 * sampleRate + 0.5);
        long sourceEnd = 0;
        long outputSamples = 0;
        long previousFadeOut = 0;
        foreach (var interval in kept)
        {
            if (interval.StartSample > sourceEnd) cuts.Add(new(sourceEnd, interval.StartSample));
            var length = interval.EndSample - interval.StartSample;
            var fade = Math.Min(fadeLength, length / 2);
            var fadeIn = interval.StartSample > 0 ? fade : 0;
            if (outputSamples > 0 || fadeIn > 0) joins.Add(new(outputSamples, previousFadeOut, fadeIn));
            outputSamples += length;
            previousFadeOut = interval.EndSample < totalSamples ? fade : 0;
            sourceEnd = interval.EndSample;
        }
        if (sourceEnd < totalSamples) cuts.Add(new(sourceEnd, totalSamples));
        if (previousFadeOut > 0) joins.Add(new(outputSamples, previousFadeOut, 0));
        return new(sampleRate, totalSamples, cuts, kept, outputSamples, joins);
    }
}
