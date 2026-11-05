using VoxClip.Core.Domain.Shared;

namespace VoxClip.Core.Domain.Clips;

/// <summary>Which caption style each clip renders in (design §6.6): the clip's entry in <see cref="ClipStyle.CaptionPicks"/>
/// when it applies (<see cref="StyleId"/>), else the project's <c>captions.styleId</c> (the project default). Preview, export, Export all, the SRT and
/// the export fingerprint all resolve through here, so every clip keeps its own style. A pick is Claude's (its reason) or the
/// user's own (<see cref="YourChoice"/>); no schema change: the picks map already carries both.</summary>
public static class ClipCaptionStyles
{
    /// <summary>The reason stored with a style the user chose for one clip. Claude's picks never replace it.</summary>
    public const string YourChoice = "Your choice";

    /// <summary>The clip's pick, or null (no clip, no clip style, or no pick for it).</summary>
    public static ClipCaptionPick? Pick(Project project, string? clipId) =>
        clipId is { Length: > 0 } && project.ClipStyle?.CaptionPicks.TryGetValue(clipId, out var pick) == true ? pick : null;

    /// <summary>True when the pick is the user's own choice rather than Claude's.</summary>
    public static bool IsYours(ClipCaptionPick pick) => pick.Reason == YourChoice;

    /// <summary>The style <paramref name="clipId"/> renders in (null: the full video): the user's own pick, else Claude's pick
    /// while the clip style's captions are Auto (a fixed style is the project default, never overridden by Claude), else the
    /// project's <c>captions.styleId</c>. A pick whose style is not in <paramref name="library"/> (when given) falls back to the
    /// project default; "off" is a valid pick.</summary>
    public static string StyleId(Project project, string? clipId, IReadOnlySet<string>? library = null) =>
        Pick(project, clipId) is { } pick && (IsYours(pick) || project.ClipStyle!.CaptionsAuto)
            && (pick.StyleId == "off" || library is null || library.Contains(pick.StyleId)) ? pick.StyleId : project.Captions.StyleId;

    /// <summary>The caption settings <paramref name="clipId"/> renders with: the project's, with the clip's style. The project's
    /// overrides and positions stay, as they did when the active clip's pick was copied into the project.</summary>
    public static ProjectCaptions Settings(Project project, string? clipId, IReadOnlySet<string>? library = null)
    {
        var style = StyleId(project, clipId, library);
        return style == project.Captions.StyleId ? project.Captions : project.Captions with { StyleId = style };
    }

    /// <summary><paramref name="project"/> as <paramref name="clipId"/> renders it: its captions resolved for the clip.</summary>
    public static Project Rendered(Project project, string? clipId, IReadOnlySet<string>? library = null)
    {
        var settings = Settings(project, clipId, library);
        return ReferenceEquals(settings, project.Captions) ? project : project with { Captions = settings };
    }

    /// <summary>A style chosen for <paramref name="clipId"/>. With a clip and a clip style it becomes that clip's pick, with
    /// <paramref name="reason"/> (the user's <see cref="YourChoice"/>, or Claude's reason for Make it postable); the project default
    /// and the other clips are unchanged. With no clip (the full video), or before the project has a clip style, it changes the
    /// project default, fixes the clip style's captions so Claude's picks never override it, and keeps every clip's pick.</summary>
    public static Project Choosing(Project project, string? clipId, string styleId, string reason = YourChoice)
    {
        if (clipId is { Length: > 0 } && project.ClipStyle is { } style)
        {
            // The style the clip already shows changes nothing: Claude's pick stays Claude's.
            if (Pick(project, clipId) is { } current ? current.StyleId == styleId && (reason == YourChoice || current.Reason == Trimmed(reason))
                : styleId == project.Captions.StyleId && reason == YourChoice) return project;
            var picks = new SortedDictionary<string, ClipCaptionPick>(StringComparer.Ordinal);
            foreach (var (id, pick) in style.CaptionPicks) picks[id] = pick;
            picks[clipId] = new(styleId, Trimmed(reason));
            return project with { ClipStyle = style with { CaptionPicks = picks } };
        }
        return project with { Captions = project.Captions with { StyleId = styleId }, ClipStyle = project.ClipStyle?.FixingCaptions(styleId) };
    }

    /// <summary>Sets <paramref name="clipId"/>'s pick exactly (undo): <paramref name="pick"/>, or none so the clip follows the
    /// project default again. Unchanged without a clip style.</summary>
    public static Project Restoring(Project project, string clipId, ClipCaptionPick? pick)
    {
        if (project.ClipStyle is not { } style || Pick(project, clipId) == pick) return project;
        var picks = new SortedDictionary<string, ClipCaptionPick>(StringComparer.Ordinal);
        foreach (var (id, existing) in style.CaptionPicks) if (id != clipId) picks[id] = existing;
        if (pick is not null) picks[clipId] = pick;
        return project with { ClipStyle = style with { CaptionPicks = picks } };
    }

    /// <summary>The Captions panel's line: "This clip: Bold Pop · Claude's pick", "This clip: Bold Pop · your choice" or
    /// "Project default". <paramref name="name"/> maps a style id to its name.</summary>
    public static string Source(Project project, string? clipId, Func<string, string> name) => Pick(project, clipId) is { } pick && StyleId(project, clipId) == pick.StyleId
        && (IsYours(pick) || project.ClipStyle!.CaptionsAuto)
        ? $"This clip: {(pick.StyleId == "off" ? "Captions off" : name(pick.StyleId))} · {(IsYours(pick) ? "your choice" : "Claude's pick")}"
        : "Project default";

    private static string Trimmed(string reason)
    {
        var runes = reason.EnumerateRunes().ToArray();
        return runes.Length <= 120 ? reason : string.Concat(runes.Take(120).Select(rune => rune.ToString()));
    }
}
