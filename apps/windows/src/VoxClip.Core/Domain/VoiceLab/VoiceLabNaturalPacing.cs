#pragma warning disable CS1591
using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Domain.Transcript;

namespace VoxClip.Core.Domain.VoiceLab;

public sealed record VoiceLabPauseDistribution
{
    public double P25 { get; }
    public double P75 { get; }
    public double P90 { get; }
    public VoiceLabPauseDistribution(IEnumerable<double> seconds)
    {
        var sorted = seconds.Where(value => double.IsFinite(value) && value > 0).Order().ToArray();
        double Percentile(double fraction) => sorted.Length == 0 ? 0 : sorted[Math.Max(0, (int)Math.Ceiling(sorted.Length * fraction) - 1)];
        P25 = Percentile(0.25); P75 = Percentile(0.75); P90 = Percentile(0.90);
    }
}

public sealed record VoiceLabPauseProfile(VoiceLabPauseDistribution WithinSentence, VoiceLabPauseDistribution BetweenSentences)
{
    public VoiceLabPauseDistribution Distribution(string token) => VoiceLabNaturalPacing.EndsSentence(token) ? BetweenSentences : WithinSentence;
    public static VoiceLabPauseProfile Measure(IReadOnlyList<TimedWord> items, AudioEnvelope envelope, double start, double end)
    {
        var words = items.Where(word => word.Kind == WordKind.Word && word.Start >= start && word.End <= end).ToArray();
        List<double> within = [], between = [];
        if (envelope.SampleRate <= 0) return new(new(within), new(between));
        var size = VoiceLabGeometry.FrameSize(envelope.SampleRate);
        for (var index = 0; index + 1 < words.Length; index++)
        {
            var lower = Math.Max(0, (int)Math.Ceiling(words[index].End * envelope.SampleRate / size));
            var upper = Math.Min(envelope.Rms.Count, (int)Math.Floor(words[index + 1].Start * envelope.SampleRate / size));
            var longest = 0; var run = 0;
            for (var block = lower; block < upper; block++)
            {
                run = envelope.Rms[block] < VoiceLabPatchConstants.VOICED_FRAME_LEVEL ? run + 1 : 0;
                longest = Math.Max(longest, run);
            }
            var seconds = (double)(longest * size) / envelope.SampleRate;
            (VoiceLabNaturalPacing.EndsSentence(words[index].Text) ? between : within).Add(seconds);
        }
        return new(new(within), new(between));
    }
}

public sealed record VoiceLabVideoCut(long StartSample, long EndSample);

public static class VoiceLabNaturalPacing
{
    public const double NATURAL_PACE_MIN = 0.90;
    public const double NATURAL_PACE_MAX = 1.10;
    public const double CUT_EDGE_GUARD = 0.30;
    public const double CUT_PUNCH_IN = 1.06;
    public static bool EndsSentence(string token) => token.Length > 0 && ".?!…。！？".Contains(token[^1], StringComparison.Ordinal);
    public static bool ClauseBoundary(string token, string next) =>
        token.Length > 0 && ",;:.?!，；：。！？".Contains(token[^1], StringComparison.Ordinal) ||
        new[] { "and", "but", "so" }.Contains(next.Trim(',', ';', ':', '.', '?', '!').ToLowerInvariant(), StringComparer.Ordinal);

    public static IReadOnlyList<VoiceLabVideoCut> Cuts(long windowStartSample, long windowEndSample, long outputSamples,
        int sampleRate, AudioEnvelope envelope, IReadOnlyList<TimedWord> items)
    {
        if (sampleRate <= 0 || envelope.SampleRate != sampleRate || outputSamples <= 0 || windowStartSample < 0 || windowEndSample <= windowStartSample) return [];
        var needed = windowEndSample - windowStartSample - outputSamples;
        var edge = VoiceLabGeometry.Samples(CUT_EDGE_GUARD, sampleRate);
        var lower = windowStartSample + edge; var upper = windowEndSample - edge;
        if (needed <= 0 || upper <= lower || needed > upper - lower) return [];
        var size = VoiceLabGeometry.FrameSize(sampleRate);
        var first = (lower + size - 1) / size; var last = Math.Min(upper / size, envelope.Rms.Count);
        if (first >= last) return [];
        var speech = items.Where(word => (word.Kind is WordKind.Word or WordKind.UnlabeledSpeech) && word.End > (double)lower / sampleRate && word.Start < (double)upper / sampleRate).ToArray();
        List<(long Start, long End, double Power)> runs = [];
        var start = first; var power = 0.0;
        for (var block = first; block <= last; block++)
        {
            var lo = block * size; var hi = lo + size;
            var quiet = block < last && envelope.Rms[(int)block] < VoiceLabPatchConstants.VOICED_FRAME_LEVEL &&
                !speech.Any(word => word.Start < (double)hi / sampleRate && word.End > (double)lo / sampleRate);
            if (quiet) { var level = envelope.Rms[(int)block]; power += (double)level * level; }
            else
            {
                if (block > start) runs.Add((start * size, lo, power / (block - start)));
                start = block + 1; power = 0;
            }
        }
        var ranked = runs.OrderBy(run => run.Power).ThenBy(run => run.Start).ToArray();
        var prefix = new double[envelope.Rms.Count + 1];
        for (var index = 0; index < envelope.Rms.Count; index++)
            prefix[index + 1] = prefix[index] + (double)envelope.Rms[index] * envelope.Rms[index] * size;
        double Energy(long sample)
        {
            var block = (int)(sample / size);
            return block >= envelope.Rms.Count ? prefix[^1] : prefix[block] + (double)envelope.Rms[block] * envelope.Rms[block] * (sample % size);
        }
        (long Start, double Power)? best = null;
        foreach (var run in runs.Where(run => run.End - run.Start >= needed))
        {
            var candidates = new List<long>();
            for (var candidate = run.Start; candidate <= run.End - needed; candidate += size) candidates.Add(candidate);
            candidates.Add(run.End - needed);
            foreach (var candidate in candidates)
            {
                var spanPower = Energy(candidate + needed) - Energy(candidate);
                if (best is null || spanPower < best.Value.Power - 1e-12 || (Math.Abs(spanPower - best.Value.Power) <= 1e-12 && candidate < best.Value.Start)) best = (candidate, spanPower);
            }
        }
        if (best is { } selected) return [new(selected.Start, selected.Start + needed)];
        for (var firstIndex = 0; firstIndex < ranked.Length; firstIndex++)
            for (var secondIndex = firstIndex + 1; secondIndex < ranked.Length; secondIndex++)
            {
                var left = ranked[firstIndex]; var right = ranked[secondIndex];
                if (left.End - left.Start + right.End - right.Start < needed) continue;
                var firstCount = Math.Min(left.End - left.Start, needed / 2);
                var secondCount = Math.Min(right.End - right.Start, needed - firstCount);
                return new[] { new VoiceLabVideoCut(left.Start, left.Start + needed - secondCount),
                    new VoiceLabVideoCut(right.Start, right.Start + secondCount) }.OrderBy(cut => cut.StartSample).ToArray();
            }
        return [];
    }

    public static bool ValidCuts(VoiceLabVideoRecipe video, double sampleRate)
    {
        if (video.Cuts is not { Count: >= 1 and <= 2 } cuts || !double.IsFinite(sampleRate) || sampleRate <= 0 ||
            video.OutputSamples <= 0 || video.Zoom != CUT_PUNCH_IN || video.FaceX != 0.5 || video.FaceY != 0.5 ||
            video.RetimeFactor is not null || video.AssetId is not null || video.Provider is not null || video.Model is not null ||
            video.RequestId is not null || video.WindowStartSample is not null || video.WindowEndSample is not null || video.SyncMode is not null) return false;
        var edge = VoiceLabGeometry.Samples(CUT_EDGE_GUARD, sampleRate);
        var cursor = video.SourceStartSample + edge; long removed = 0;
        foreach (var cut in cuts)
        {
            if (cut is null || cut.StartSample < cursor || cut.EndSample <= cut.StartSample || cut.EndSample > video.SourceEndSample - edge) return false;
            removed += cut.EndSample - cut.StartSample; cursor = cut.EndSample + 1;
        }
        return video.SourceEndSample - video.SourceStartSample - removed == video.OutputSamples;
    }
}
