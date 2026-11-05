using VoxClip.Core.Domain.Shared;

namespace VoxClip.Core.Domain.Clips;

/// <summary>The clip style card's decisions (design §6.6), shared by the Windows view model and its tests; the twin of
/// EditorModel+ClipStyle.swift. Pure: each returns the next project, or the same instance when nothing changes.</summary>
public static class ClipStyleCard
{
    /// <summary>The card shows once above the clip list, the first time the project has clips, until the user chooses;
    /// the status bar item reopens it. A read-only project never shows it: every control on it changes the project.</summary>
    public static bool Shows(Project project, bool reopened, bool editable) =>
        editable && (reopened || project.ClipStyle is null && project.Edits.Clips.Count > 0);

    /// <summary>What the card shows: the project's clip style, else the one a new project starts with.</summary>
    public static ClipStyle Showing(Project project, ClipStyleCatalog catalog, ClipStyle? saved) => project.ClipStyle ?? catalog.Initial(saved);

    /// <summary>Stores <paramref name="style"/>. A fixed caption style (or "off") is applied to the project's captions; Claude's
    /// per-clip picks never override it (<see cref="ClipStyle.CaptionStyleFor"/>), the user's own per-clip choices still do.</summary>
    public static Project Choose(Project project, ClipStyle style, IReadOnlySet<string> libraryStyles)
    {
        style.Validate();
        var next = project with { ClipStyle = style };
        if (style.FixedCaptionStyle is { } fixedStyle && (fixedStyle == "off" || libraryStyles.Contains(fixedStyle)))
            next = next with { Captions = next.Captions with { StyleId = fixedStyle } };
        return next;
    }

    /// <summary>The user chose a caption style (a gallery tile, the Captions switch, the Export picker). While a clip is active it
    /// becomes that clip's pick; with no clip active it changes the project default and fixes the clip style's captions, so no AI
    /// pick overrides it (<see cref="ClipCaptionStyles.Choosing"/>).</summary>
    public static Project ChooseCaptionStyle(Project project, string styleId) =>
        ClipCaptionStyles.Choosing(project, project.Edits.ActiveClipId, styleId);

    /// <summary>"Style: Auto · ≤60 s · 16:9+9:16" once the project has a clip style; null before.</summary>
    public static string? StatusText(Project project, ClipStyleCatalog catalog) =>
        project.ClipStyle is { } style ? style.Summary(catalog.Find(style.Preset).Label) : null;
}
