using VoxClip.Core.Domain.Editing;
using VoxClip.Core.Domain.VoiceLab;
using VoxClip.Media.Ffmpeg;

namespace VoxClip.Media.Pipeline;

internal sealed class TimelineCursor(RenderTimeline timeline)
{
    private int part;
    private long outputStart;
    private readonly EditPlan? legacy = (timeline as RenderTimeline.Legacy)?.Plan;
    private readonly VoiceLabOutputPlan? voice = (timeline as RenderTimeline.VoiceLab)?.Plan;
    internal TimelineCursor(EditPlan plan) : this(new RenderTimeline.Legacy(plan)) { }
    internal int Part => part;
    internal double NextJoin => voice is { } synthetic
        ? part + 1 < synthetic.Pieces.Count ? synthetic.Pieces[part].OutputEndSample / synthetic.SampleRate : double.PositiveInfinity
        : part + 1 < legacy!.Kept.Count
            ? (outputStart + legacy.Kept[part].EndSample - legacy.Kept[part].StartSample) / legacy.SampleRate : double.PositiveInfinity;
    internal double NextSource => voice is { } synthetic
        ? part + 1 < synthetic.Pieces.Count ? synthetic.Pieces[part + 1].SourceStartSample / synthetic.SampleRate : double.PositiveInfinity
        : part + 1 < legacy!.Kept.Count ? legacy.Kept[part + 1].StartSample / legacy.SampleRate : double.PositiveInfinity;

    internal double Source(double editedTime)
    {
        if (voice is { } synthetic)
        {
            var index = Math.Clamp(Native.Round(editedTime * synthetic.SampleRate), 0, synthetic.OutputSamples);
            if (part > 0 && (part >= synthetic.Pieces.Count || index < synthetic.Pieces[part].OutputStartSample)) part = 0;
            while (part < synthetic.Pieces.Count && index >= synthetic.Pieces[part].OutputEndSample) part++;
            return synthetic.SourceTime(editedTime);
        }
        var plan = legacy!;
        var sample = Math.Clamp(Native.Round(editedTime * plan.SampleRate), 0, plan.OutputSamples);
        if (sample < outputStart) { part = 0; outputStart = 0; }
        while (part < plan.Kept.Count)
        {
            var length = plan.Kept[part].EndSample - plan.Kept[part].StartSample;
            if (sample < outputStart + length) return (plan.Kept[part].StartSample + sample - outputStart) / plan.SampleRate;
            outputStart += length; part++;
        }
        return plan.TotalSamples / plan.SampleRate;
    }
}
