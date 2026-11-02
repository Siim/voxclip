#pragma warning disable CS1591
using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Domain.VoiceLab;

namespace VoxClip.Core.Domain.ContextDemo;

public static class ContextDemoProject
{
    public static void Validate(Project project)
    {
        ContextDemoValidation.Require(project.SchemaVersion is >= 1 and <= 4, ContextDemoError.UnsupportedVersion);
        ContextDemoValidation.Require(project.SchemaVersion == 4 || (project.ContextDemo is null && project.MotionCues.Count == 0),
            ContextDemoError.UnsupportedVersion);
        if (project.ContextDemo is { } document)
        {
            document.Validate();
            ContextDemoValidation.Require(document.ProjectId == project.Id && document.SourceContentKey == project.Media.Source.ContentKey &&
                document.Narration.Pieces.All(piece => piece.Source.End <= project.Media.Source.DurationSeconds + 1 / document.Narration.SampleRate),
                ContextDemoError.StaleNarration);
        }
        MotionCue.ValidateAll(project);
    }

    public static Project UpgradeToV4(Project project)
    {
        Validate(project);
        var result = VoiceLabProject.UpgradeToV3(project) with { SchemaVersion = 4 };
        Validate(result);
        return result;
    }

    public static Project Setting(ContextDemoDocument? document, Project project, RenderTimeline timeline)
    {
        var basis = project with { ContextDemo = null };
        Validate(basis);
        ContextDemoValidation.Require(document is null || document.IsCurrent(project, timeline), ContextDemoError.StaleNarration);
        var result = (document is null ? basis : UpgradeToV4(basis)) with { ContextDemo = document };
        Validate(result);
        return result;
    }

    public static Project SettingMotionCues(IReadOnlyList<MotionCue> cues, Project project)
    {
        var result = (cues.Count == 0 ? project : UpgradeToV4(project)) with { MotionCues = Array.AsReadOnly(cues.ToArray()) };
        Validate(result);
        return result;
    }

    public static Project ReplacingPlacement(ContextDemoPlacement placement, Project project, RenderTimeline timeline, int expectedRevision) =>
        Setting((project.ContextDemo ?? throw new ContextDemoException(ContextDemoError.InvalidPlacement))
            .ReplacingPlacement(placement, expectedRevision), project, timeline);

    public static Project RemovingPlacement(string id, Project project, RenderTimeline timeline, int expectedRevision) =>
        Setting((project.ContextDemo ?? throw new ContextDemoException(ContextDemoError.InvalidPlacement))
            .RemovingPlacement(id, expectedRevision), project, timeline);

    public static Project Placing(ContextDemoAsset asset, ContextDemoPlacement placement, Project project, RenderTimeline timeline, int expectedRevision) =>
        Setting((project.ContextDemo ?? throw new ContextDemoException(ContextDemoError.InvalidPlacement))
            .Placing(asset, placement, expectedRevision), project, timeline);
}
