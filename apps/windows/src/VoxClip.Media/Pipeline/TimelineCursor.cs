using VoxClip.Core.Domain.Editing;
using VoxClip.Media.Ffmpeg;

namespace VoxClip.Media.Pipeline;

internal sealed class TimelineCursor(EditPlan plan)
{
    private int part;
    private long outputStart;
    internal int Part => part;
    internal double NextJoin => part + 1 < plan.Kept.Count
        ? (outputStart + plan.Kept[part].EndSample - plan.Kept[part].StartSample) / plan.SampleRate : double.PositiveInfinity;
    internal double NextSource => part + 1 < plan.Kept.Count ? plan.Kept[part + 1].StartSample / plan.SampleRate : double.PositiveInfinity;

    internal double Source(double editedTime)
    {
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
