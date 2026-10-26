#pragma warning disable CS1591
using VoxClip.Core.Domain.Editing;

namespace VoxClip.Core.Domain.VoiceLab;

/// <summary>Tagged timeline for later native Media composition; current Media requests retain EditPlan.</summary>
public abstract record RenderTimeline
{
    public sealed record Legacy(EditPlan Plan) : RenderTimeline;
    public sealed record VoiceLab(VoiceLabOutputPlan Plan) : RenderTimeline;
    public long OutputSamples => this switch { Legacy item => item.Plan.OutputSamples, VoiceLab item => item.Plan.OutputSamples, _ => throw new InvalidOperationException() };
    public double SampleRate => this switch { Legacy item => item.Plan.SampleRate, VoiceLab item => item.Plan.SampleRate, _ => throw new InvalidOperationException() };
    public double Duration => OutputSamples / SampleRate;
    public double SourceTime(double edited) => this switch { Legacy item => item.Plan.SourceTime(edited), VoiceLab item => item.Plan.SourceTime(edited), _ => throw new InvalidOperationException() };
    public double MapTime(double source) => this switch { Legacy item => item.Plan.MapTime(source), VoiceLab item => item.Plan.MapTime(source), _ => throw new InvalidOperationException() };
}
