using VoxClip.Core.Domain.Shared;

namespace VoxClip.Core.Domain.Clips;

/// <summary>A clip's whole colour state (looks spec §9.6), twin of the Mac <c>ClipColorState</c>: its base look, its fine-tuning and its
/// grade, Fix included. Make it postable's Undo puts all three back, so a look Claude chose with an amount and a Fix leaves nothing
/// behind.</summary>
/// <param name="Look">The base look.</param>
/// <param name="Adjustments">The fine-tuning, or null when neutral.</param>
/// <param name="Grade">The grade, or null when neutral.</param>
public sealed record ClipColorState(ClipLook Look = ClipLook.Original, ClipColorAdjustments? Adjustments = null, ClipColorGrade? Grade = null)
{
    /// <summary>The colour state of <paramref name="controls"/>.</summary>
    public static ClipColorState Of(ProjectClipControls controls)
    {
        ArgumentNullException.ThrowIfNull(controls);
        return new(controls.Look, controls.ColorAdjustments, controls.ColorGrade);
    }

    /// <summary><paramref name="controls"/> with this colour state and its other controls kept.</summary>
    public ProjectClipControls Applied(ProjectClipControls controls)
    {
        ArgumentNullException.ThrowIfNull(controls);
        return controls with { Look = Look, ColorAdjustments = Adjustments, ColorGrade = Grade };
    }

    /// <summary><paramref name="project"/> with one clip's colour state set as one change and its other controls kept.</summary>
    public Project SettingOn(string clipId, Project project)
    {
        var controls = ClipControlsProject.Controls(clipId, project)
            ?? throw new VoxClipException(VoxClipErrorCode.ProjectUnreadable, "That clip isn't in this project.");
        return ClipControlsProject.Setting(Applied(controls), project);
    }
}

/// <summary>The Fix as a review line.</summary>
public static class ClipColorFixText
{
    /// <summary>"exposure +20, temperature −12", the Fix's non-zero values; empty when it is neutral. Twin of the Mac
    /// <c>ClipColorFix.summary</c>.</summary>
    public static string Summary(this ClipColorFix fix) =>
        string.Join(", ", new[] { ("exposure", fix.Exposure), ("temperature", fix.Temperature), ("tint", fix.Tint) }
            .Where(item => item.Item2 != 0)
            .Select(item => item.Item1 + " " + (item.Item2 > 0 ? "+" : "−") + Math.Abs(item.Item2).ToString(System.Globalization.CultureInfo.InvariantCulture)));
}
