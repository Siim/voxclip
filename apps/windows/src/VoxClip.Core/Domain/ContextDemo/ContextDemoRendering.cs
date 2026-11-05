using VoxClip.Core.Domain.Editing;
using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Domain.VoiceLab;

namespace VoxClip.Core.Domain.ContextDemo;

/// <summary>The screen recording shown at one edited time: which asset, and the time in it.</summary>
public readonly record struct ContextDemoLayerFrame(string AssetId, double SourceTime);

/// <summary>The context demos a preview or export of one scope draws (doc/spec/context-demo.md, Mac RenderCallerInputs.prepare):
/// the prepared placements on the scope's edited clock, starting at zero, and where each asset lives under the data folder.</summary>
public sealed record ContextDemoRenderLayers(ContextDemoRenderInput Input, string DataRoot)
{
    /// <summary>The placement over <paramref name="editedTime"/> (half-open), or null when the source picture shows.</summary>
    public ContextDemoLayerFrame? At(double editedTime)
    {
        foreach (var placement in Input.Placements)
            if (editedTime >= placement.Output.Start && editedTime < placement.Output.End)
                return new(placement.AssetId, placement.Source.Start + (editedTime - placement.Output.Start));
        return null;
    }

    /// <summary>The asset's canonical file: <c>&lt;data folder&gt;/context-demo/&lt;projectId&gt;/&lt;assetId&gt;.mp4</c>.</summary>
    public string AssetPath(ContextDemoAsset asset) =>
        Path.Combine([DataRoot, .. ContextDemoAsset.MakeRelativePath(Input.ProjectId, asset.Id).Split('/')]);
}

/// <summary>Resolves a project's context-demo placements for a render (Mac RenderCallerInputs.prepare): the document must be current
/// for the full edited narration; a clip's scope is its span of that narration; placements are clipped to the scope and rebased to
/// zero, and the scope's rendered timeline must match.</summary>
public static class ContextDemoRendering
{
    /// <summary>The reason a render stops when the placements no longer fit the edited narration.</summary>
    public const string StaleMessage =
        "This video's screen recordings no longer line up with its edits. Undo the last edit, or place the recordings again on a Mac. Your media and edits are unchanged.";

    /// <summary>The reason a render stops when a screen recording's file is missing, changed or unreadable.</summary>
    public const string AssetMessage =
        "A screen recording this video shows is missing or has changed, so it can't be rendered. Your media and edits are unchanged.";

    /// <summary>The full edited narration's timeline (no clip): the Voice Lab output when it needs synthetic rendering, else the edit plan.</summary>
    public static RenderTimeline FullTimeline(Project project)
    {
        var source = project.Media.Source;
        var rate = (double)(source.Audio?.SampleRate ?? 48_000);
        var duration = source.DurationSeconds;
        if (project.SchemaVersion >= 3 && project.Transcript is not null)
        {
            var output = VoiceLabOutputPlanner.Build(project, VoiceLabOutputScope.Full);
            if (output.RequiresSyntheticRendering) return new RenderTimeline.VoiceLab(output);
        }
        if (EditingEngine.FromProject(project) is { } state)
            return new RenderTimeline.Legacy(EditingEngine.BuildEditPlan(EditingEngine.BuildSegments(state with { ActiveClipId = null }, duration),
                duration, rate, state.PauseKeepSeconds));
        var samples = checked((long)Math.Floor(duration * rate + 0.5));
        return new RenderTimeline.Legacy(new(rate, samples, [], [new(0, samples)], samples, []));
    }

    /// <summary>The layers a render of <paramref name="clipId"/> (null: the full video) draws over <paramref name="scoped"/>, its rendered
    /// timeline; null when the project places no screen recordings. Throws <see cref="VoxClipException"/> with
    /// <see cref="StaleMessage"/> when the placements no longer fit.</summary>
    public static ContextDemoRenderLayers? Resolve(Project project, string? clipId, RenderTimeline scoped, string dataRoot)
    {
        if (project.ContextDemo is not { Placements.Length: > 0 } document) return null;
        try
        {
            var full = FullTimeline(project);
            ContextDemoValidation.Require(document.IsCurrent(project, full), ContextDemoError.StaleNarration);
            TimeRange scope;
            if (clipId is null) scope = new(0, full.Duration);
            else
            {
                var narration = ContextDemoNarrationSnapshot.FromTimeline(scoped);
                ContextDemoValidation.Require(narration.Pieces.Length > 0, ContextDemoError.InvalidNarration);
                scope = new(full.MapTime(narration.Pieces[0].Source.Start), full.MapTime(narration.Pieces[^1].Source.End));
            }
            var prepared = ContextDemoPlanner.Prepare(document, project, full, scope, document.Revision);
            prepared.VerifyRenderedTimeline(scoped);
            return prepared.Placements.Length == 0 ? null : new(prepared, dataRoot);
        }
        catch (ContextDemoException)
        {
            throw new VoxClipException(VoxClipErrorCode.ExportFailed, StaleMessage);
        }
    }
}
