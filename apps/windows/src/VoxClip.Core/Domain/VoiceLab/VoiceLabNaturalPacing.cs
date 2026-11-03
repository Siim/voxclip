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

    /// <summary>No pause of this class was measured: every percentile is zero, so it bounds neither growth nor shrinking.</summary>
    public bool IsEmpty => P25 <= 0;
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
    public const double CUT_QUIET_RUN = 0.04;
    public static bool EndsSentence(string token) => token.Length > 0 && ".?!…。！？".Contains(token[^1], StringComparison.Ordinal);
    public static bool ClauseBoundary(string token, string next) =>
        token.Length > 0 && ",;:.?!，；：。！？".Contains(token[^1], StringComparison.Ordinal) ||
        new[] { "and", "but", "so" }.Contains(next.Trim(',', ';', ':', '.', '?', '!').ToLowerInvariant(), StringComparer.Ordinal);

    public static IReadOnlyList<VoiceLabAudioTag> PauseTags(IReadOnlyList<VoiceLabAudioTag> tags, string modelId, int tokenCount)
    {
        if (tags.Count == 0) return [];
        var root = VoxClip.Core.Services.Project.SharedResources.ResolveRoot();
        using var catalog = System.Text.Json.JsonDocument.Parse(File.ReadAllText(Path.Combine(root, "data", "voice-audio-tags.json")));
        if (!catalog.RootElement.GetProperty("models").EnumerateArray().Any(model => model.GetString() == modelId)) return [];
        var allowed = catalog.RootElement.GetProperty("tags").EnumerateArray().Select(tag => tag.GetProperty("tag").GetString()).ToHashSet(StringComparer.Ordinal);
        return tags.Take(64).Where(tag => tag is not null && tag.BeforeToken >= 0 && tag.BeforeToken <= tokenCount && allowed.Contains(tag.Tag)).ToArray();
    }

    public static VoiceLabFitResult Fit(VoiceLabWindow window, double? incomingSilence, double? outgoingSilence, VoiceLabFitTake take,
        int sourceSampleRate, bool hardJoinSmoothing, VoiceLabPauseProfile pauseProfile, IReadOnlyList<VoiceLabAudioTag> audioTags,
        AudioEnvelope sourceEnvelope, IReadOnlyList<TimedWord> items)
    {
        VoiceLabFitResult Plan(bool allowGrowth) => VoiceLabFitPlanner.Plan(window, incomingSilence, outgoingSilence, take,
            take.Words.Select(word => word.Text).ToArray(), sourceSampleRate, hardJoinSmoothing, pauseProfile, audioTags, allowGrowth);
        var fitted = Plan(true);
        if (fitted is VoiceLabFitResult.Exact) return fitted;
        var spoken = Plan(false);
        // The same output the video-duration options and the recipe use, so a paid take's cut passes ValidCuts.
        var rounded = VoxClip.Core.Domain.Editing.EditingMath.Round(VoiceLabRewriteFit.VideoDuration(spoken) * sourceSampleRate);
        if (!double.IsFinite(rounded) || rounded <= 0 || rounded >= long.MaxValue) return fitted;
        var cuts = Cuts(spoken.Plan.WindowStartSample, spoken.Plan.WindowEndSample, (long)rounded, sourceSampleRate, sourceEnvelope, items);
        if (cuts.Count == 0) return fitted;
        var plan = spoken.Plan with { VideoCuts = cuts };
        return spoken is VoiceLabFitResult.ChangedDuration changed ?
            new VoiceLabFitResult.ChangedDuration(plan, changed.NaturalOut, changed.ResidualSeconds) : new VoiceLabFitResult.Exact(plan);
    }

    public static IReadOnlyList<VoiceLabVideoCut> Cuts(long windowStartSample, long windowEndSample, long outputSamples,
        int sampleRate, AudioEnvelope envelope, IReadOnlyList<TimedWord> items)
    {
        if (sampleRate <= 0 || envelope.SampleRate != sampleRate || outputSamples <= 0 || windowStartSample < 0 || windowEndSample <= windowStartSample) return [];
        var needed = windowEndSample - windowStartSample - outputSamples;
        var edge = VoiceLabGeometry.Samples(CUT_EDGE_GUARD, sampleRate);
        var lower = windowStartSample + edge; var upper = windowEndSample - edge;
        if (needed <= 0 || upper <= lower || needed > upper - lower) return [];
        var size = VoiceLabGeometry.FrameSize(sampleRate);
        var minimumRun = VoiceLabGeometry.Samples(CUT_QUIET_RUN, sampleRate);
        var reach = (minimumRun + size - 1) / size;
        var first = Math.Max(0, lower / size - reach); var last = Math.Min(upper / size + reach + 1, envelope.Rms.Count);
        if (first >= last) return [];
        var speech = items.Where(word => (word.Kind is WordKind.Word or WordKind.UnlabeledSpeech) && word.End > (double)(first * size) / sampleRate && word.Start < (double)(last * size) / sampleRate).ToArray();
        var eligible = new bool[(int)(last - first)];
        var runStarts = Enumerable.Repeat(-1L, (int)(last - first)).ToArray();
        var start = first;
        for (var block = first; block <= last; block++)
        {
            var lo = block * size; var hi = lo + size;
            var quiet = block < last && envelope.Rms[(int)block] < VoiceLabPatchConstants.VOICED_FRAME_LEVEL &&
                !speech.Any(word => word.Start < (double)hi / sampleRate && word.End > (double)lo / sampleRate);
            if (!quiet)
            {
                if ((block - start) * size >= minimumRun)
                    for (var member = start; member < block; member++)
                    {
                        eligible[(int)(member - first)] = true;
                        runStarts[(int)(member - first)] = start;
                    }
                start = block + 1;
            }
        }
        bool IsEligible(long block) => block >= first && block < last && eligible[(int)(block - first)];
        double? BoundaryPower(long sample, long startSample)
        {
            if (sample < lower || sample > upper) return null;
            var block = sample / size;
            if (!IsEligible(block))
            {
                var startBlock = startSample / size;
                if (sample % size != 0 || !IsEligible(block - 1) || !IsEligible(startBlock) ||
                    runStarts[(int)(startBlock - first)] != runStarts[(int)(block - 1 - first)]) return null;
                block--;
            }
            var level = (double)envelope.Rms[(int)block];
            return level * level;
        }
        List<(long Sample, double Power)> starts = [];
        for (var block = first; block < last; block++)
        {
            var sample = block * size;
            if (IsEligible(block) && sample >= lower && sample < upper)
            {
                var level = (double)envelope.Rms[(int)block];
                starts.Add((sample, level * level));
            }
        }
        (double Power, long Start)? best = null;
        foreach (var candidate in starts)
            if (BoundaryPower(candidate.Sample + needed, candidate.Sample) is { } endPower)
            {
                var scored = (candidate.Power + endPower, candidate.Sample);
                if (best is null || scored.CompareTo(best.Value) < 0) best = scored;
            }
        if (best is { } selected) return [new(selected.Start, selected.Start + needed)];
        long[] phases = needed % size == 0 ? [0] : [0, needed % size];
        List<(long Sample, double Power)> endings = [];
        for (var block = first; block <= last; block++)
            foreach (var phase in phases)
            {
                var sample = block * size + phase;
                if (BoundaryPower(sample, sample - size) is { } power) endings.Add((sample, power));
            }
        endings.Sort((left, right) => left.Sample.CompareTo(right.Sample));
        var endingIndex = 0;
        Dictionary<long, (double Power, long Start, long End)> leftByLength = [];
        (double Power, long FirstStart, long FirstEnd, long SecondStart)? bestTwo = null;
        foreach (var right in starts)
        {
            while (endingIndex < endings.Count && endings[endingIndex].Sample < right.Sample)
            {
                var end = endings[endingIndex];
                foreach (var left in starts)
                {
                    var count = end.Sample - left.Sample;
                    if (count <= 0) break;
                    if (count >= needed) continue;
                    if (BoundaryPower(end.Sample, left.Sample) is not { } endPower) continue;
                    var scored = (left.Power + endPower, left.Sample, end.Sample);
                    if (!leftByLength.TryGetValue(count, out var previous) || scored.CompareTo(previous) < 0) leftByLength[count] = scored;
                }
                endingIndex++;
            }
            foreach (var (count, left) in leftByLength)
            {
                if (BoundaryPower(right.Sample + needed - count, right.Sample) is not { } endPower) continue;
                var scored = (left.Power + right.Power + endPower, left.Start, left.End, right.Sample);
                if (bestTwo is null || scored.CompareTo(bestTwo.Value) < 0) bestTwo = scored;
            }
        }
        if (bestTwo is { } pair)
            return [new(pair.FirstStart, pair.FirstEnd), new(pair.SecondStart, pair.SecondStart + needed - (pair.FirstEnd - pair.FirstStart))];
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
