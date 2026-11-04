using VoxClip.Core.Domain.Shared;

namespace VoxClip.Core.Domain.Clips;

/// <summary>The clip style card's decisions (design §6.9), shared by the Windows view model and its tests; the twin of
/// EditorModel+ClipStyle.swift. Pure: each returns the next project, or the same instance when nothing changes.</summary>
public static class ClipStyleCard
{
    /// <summary>The card shows once above the clip list, the first time the project has clips, until the user chooses;
    /// the status bar item reopens it. A read-only project never shows it: every control on it changes the project.</summary>
    public static bool Shows(Project project, bool reopened, bool editable) =>
        editable && (reopened || project.ClipStyle is null && project.Edits.Clips.Count > 0);

    /// <summary>What the card shows: the project's clip style, else the one a new project starts with.</summary>
    public static ClipStyle Showing(Project project, ClipStyleCatalog catalog, ClipStyle? saved) => project.ClipStyle ?? catalog.Initial(saved);

    /// <summary>Stores <paramref name="style"/>. A fixed caption style (or "off") is applied to the project's captions.</summary>
    public static Project Choose(Project project, ClipStyle style, IReadOnlySet<string> libraryStyles)
    {
        style.Validate();
        var next = project with { ClipStyle = style };
        if (style.FixedCaptionStyle is { } fixedStyle && (fixedStyle == "off" || libraryStyles.Contains(fixedStyle)))
            next = next with { Captions = next.Captions with { StyleId = fixedStyle } };
        return next;
    }

    /// <summary>The user chose a caption style (a gallery tile, the Export picker): it fixes the clip style's captions,
    /// so no AI pick overrides it.</summary>
    public static Project ChooseCaptionStyle(Project project, string styleId) =>
        project with { Captions = project.Captions with { StyleId = styleId }, ClipStyle = project.ClipStyle?.FixingCaptions(styleId) };

    /// <summary>With Auto, the active clip uses the AI's pick for it; null when there is nothing to change.</summary>
    public static Project? ApplyPick(Project project, IReadOnlySet<string> libraryStyles)
    {
        if (project.ClipStyle is not { CaptionsAuto: true } style || project.Edits.ActiveClipId is not { } clip
            || !style.CaptionPicks.TryGetValue(clip, out var pick) || pick.StyleId == project.Captions.StyleId || !libraryStyles.Contains(pick.StyleId)) return null;
        return project with { Captions = project.Captions with { StyleId = pick.StyleId } };
    }

    /// <summary>"Style: Auto · ≤60 s · 16:9+9:16" once the project has a clip style; null before.</summary>
    public static string? StatusText(Project project, ClipStyleCatalog catalog) =>
        project.ClipStyle is { } style ? style.Summary(catalog.Find(style.Preset).Label) : null;
}
