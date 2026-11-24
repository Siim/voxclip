#pragma warning disable CS1591

namespace VoxClip.Core.Domain.VoiceLab;

public enum SyncMode { CutOff, Remap }

public sealed record LipsyncWindow(long StartSample, long EndSample, IReadOnlyList<int> PhraseIds)
{
    public static LipsyncWindow Make(long seamIn, long seamOut, long totalSamples, int sampleRate, int phraseId)
    {
        if (sampleRate is < 8000 or > 192000 || totalSamples < sampleRate * 3L || totalSamples > sampleRate * 86400L ||
            seamIn < 0 || seamOut <= seamIn || seamOut > totalSamples || phraseId < 0) throw Invalid();
        var start = Math.Max(0, seamIn - sampleRate);
        var end = Math.Min(totalSamples, seamOut + sampleRate);
        long minimum = sampleRate * 3L;
        if (end - start < minimum)
        {
            start = Math.Max(0, start - (minimum - (end - start) + 1) / 2);
            end = Math.Min(totalSamples, start + minimum);
            start = end - minimum;
        }
        if (end - start > 300L * sampleRate) throw Invalid();
        return new(start, end, [phraseId]);
    }

    public static IReadOnlyList<LipsyncWindow> Merge(IEnumerable<LipsyncWindow> windows, int sampleRate)
    {
        if (sampleRate is < 8000 or > 192000) throw Invalid();
        List<LipsyncWindow> result = [];
        foreach (var window in windows.OrderBy(window => window.StartSample).ThenBy(window => window.EndSample))
        {
            if (window.StartSample < 0 || window.EndSample <= window.StartSample || window.PhraseIds.Count == 0) throw Invalid();
            if (result.Count != 0 && window.StartSample <= result[^1].EndSample)
            {
                var prior = result[^1];
                result[^1] = new(prior.StartSample, Math.Max(prior.EndSample, window.EndSample), prior.PhraseIds.Union(window.PhraseIds).Order().ToArray());
            }
            else result.Add(window);
        }
        if (result.Any(window => window.EndSample - window.StartSample > 300L * sampleRate)) throw Invalid();
        return result.AsReadOnly();
    }

    internal static VoiceLabProjectException Invalid() => new(VoiceLabProjectErrorCode.InvalidRange);
}

public sealed record LipsyncRenderWindow(LipsyncWindow Source, long OutputStartSample, long OutputEndSample)
{
    public SyncMode Mode => OutputEndSample - OutputStartSample == Source.EndSample - Source.StartSample ? SyncMode.CutOff : SyncMode.Remap;
    public double Seconds(double rate) => (OutputEndSample - OutputStartSample) / rate;
    public static double UploadSeconds(double needed) => needed + Math.Max(0.4, 0.02 * needed);

    public static LipsyncRenderWindow Project(LipsyncWindow source, VoiceLabOutputPlan plan)
    {
        var start = OutputSample(source.StartSample, plan);
        var end = OutputSample(source.EndSample, plan);
        var minimum = Round(3 * plan.SampleRate);
        if (end - start < minimum && plan.OutputSamples >= minimum)
        {
            start = Math.Max(0, start - (minimum - (end - start) + 1) / 2);
            end = Math.Min(plan.OutputSamples, start + minimum);
            start = end - minimum;
            source = source with { StartSample = SourceSample(start, plan), EndSample = SourceSample(end, plan) };
        }
        if (end - start < minimum || UploadSeconds((end - start) / plan.SampleRate) > 300) throw LipsyncWindow.Invalid();
        return new(source, start, end);
    }

    public static IReadOnlyList<LipsyncRenderWindow> Jobs(VoiceLabOutputPlan plan, IReadOnlyList<VoiceLabSelectedRecipe> recipes)
    {
        var sampleRate = checked((int)plan.SampleRate);
        var windows = recipes.Select((item, index) => Project(LipsyncWindow.Make(item.Piece.SourceStartSample,
            item.Piece.SourceEndSample, plan.TotalSourceSamples, sampleRate, index), plan).Source);
        return LipsyncWindow.Merge(windows, sampleRate).Select(window => Project(window, plan)).ToArray();
    }

    public static long OutputSample(long sample, VoiceLabOutputPlan plan) => Round(plan.MapTime(sample / plan.SampleRate) * plan.SampleRate);
    private static long SourceSample(long sample, VoiceLabOutputPlan plan) => Round(plan.SourceTime(sample / plan.SampleRate) * plan.SampleRate);
    private static long Round(double value) => checked((long)Math.Round(value, MidpointRounding.AwayFromZero));
}
