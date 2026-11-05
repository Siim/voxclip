using VoxClip.Core.Domain.Shared;

namespace VoxClip.Core.Domain.Clips;

/// <summary>Which caption look each clip renders in (design §6.6), on top of the Mac package's Core rules
/// (<see cref="ClipStyle.CaptionPickFor"/>, <see cref="ClipCaptionLooks.CaptionsFor"/>): the clip's pick where it applies (the
/// creator's own always, <c>by: "user"</c>; Claude's while captions are Auto or when it keeps the fixed style), with its overrides,
/// else the project's captions. Preview, export, Export all, the SRT and the export fingerprint all resolve through here, so every
/// clip keeps its own look; this adds the library fallback, the creator's choice, Make it postable's record, undo and the panel's line.</summary>
public static class ClipCaptionStyles
{
    /// <summary>The pick a render of the clip uses, or null (no clip, no clip style, no pick, or Claude's pick under another fixed style).</summary>
    public static ClipCaptionPick? Pick(Project project, string? clipId) => project.ClipStyle?.CaptionPickFor(clipId);

    /// <summary>The caption settings <paramref name="clipId"/> renders with (null: the full video, always the project's): its pick's style
    /// and overrides, the project's positions. A pick whose style is not in <paramref name="library"/> (when given) falls back to the
    /// project's captions; "off" is a valid pick. The project's own instance when nothing differs.</summary>
    public static ProjectCaptions Settings(Project project, string? clipId, IReadOnlySet<string>? library = null)
    {
        if (Pick(project, clipId) is not { } pick || pick.StyleId != "off" && library is not null && !library.Contains(pick.StyleId)) return project.Captions;
        return project.CaptionsFor(clipId);
    }

    /// <summary>The style <paramref name="clipId"/> renders in.</summary>
    public static string StyleId(Project project, string? clipId, IReadOnlySet<string>? library = null) => Settings(project, clipId, library).StyleId;

    /// <summary><paramref name="project"/> as <paramref name="clipId"/> renders it: its captions resolved for the clip.</summary>
    public static Project Rendered(Project project, string? clipId, IReadOnlySet<string>? library = null)
    {
        var settings = Settings(project, clipId, library);
        return ReferenceEquals(settings, project.Captions) ? project : project with { Captions = settings };
    }

    /// <summary>The creator chose <paramref name="styleId"/> (the Captions panel, the gallery, the card's Captions row or the Export
    /// picker). With a clip and a clip style it becomes that clip's own pick (<c>by: "user"</c>), kept whatever the project default or
    /// Claude does later (Mac ClipStyle.choosingCaptionStyle); the style the clip already shows changes nothing, so Claude's pick stays
    /// Claude's. With no clip (the full video), or before the project has a clip style, it changes the project default and fixes the
    /// clip style's captions so Claude's picks never override it; every clip's pick stays.</summary>
    public static Project Choosing(Project project, string? clipId, string styleId)
    {
        if (clipId is { Length: > 0 } && project.ClipStyle is { } style)
        {
            var current = Settings(project, clipId);
            if (current.StyleId == styleId) return project;
            return Restoring(project, clipId, new(styleId, "") { By = "user" });
        }
        return project with { Captions = project.Captions with { StyleId = styleId }, ClipStyle = project.ClipStyle?.FixingCaptions(styleId) };
    }

    /// <summary>Make it postable's look for <paramref name="clipId"/> (Mac ClipStyle.recordingLook): Claude's pick with its style,
    /// overrides and <paramref name="reason"/> (cut to 120 characters), under Auto any style, under a fixed style only that style. Null
    /// when it cannot apply: the creator chose this clip's style, or the style is fixed to another one or Off. Before the project has
    /// a clip style, the look is the project's captions, as before.</summary>
    public static Project? RecordingLook(Project project, string clipId, ProjectCaptions look, string reason)
    {
        if (project.ClipStyle is not { } style) return project with { Captions = project.Captions with { StyleId = look.StyleId, Overrides = look.Overrides } };
        if (style.CaptionPicks.TryGetValue(clipId, out var own) && own.ByUser) return null;
        if (style.FixedCaptionStyle is { } fixedStyle && fixedStyle != look.StyleId) return null;
        return Restoring(project, clipId, new(look.StyleId, Trimmed(reason))
        {
            Overrides = look.Overrides.ValueKind == System.Text.Json.JsonValueKind.Object ? look.Overrides.Clone() : null
        });
    }

    /// <summary>Sets <paramref name="clipId"/>'s pick exactly (undo, a choice): <paramref name="pick"/>, or none so the clip follows the
    /// project default again. Unchanged without a clip style.</summary>
    public static Project Restoring(Project project, string clipId, ClipCaptionPick? pick)
    {
        if (project.ClipStyle is not { } style) return project;
        if (style.CaptionPicks.TryGetValue(clipId, out var existing) ? pick is not null && existing.Equals(pick) : pick is null) return project;
        var picks = new SortedDictionary<string, ClipCaptionPick>(StringComparer.Ordinal);
        foreach (var (id, item) in style.CaptionPicks) if (id != clipId) picks[id] = item;
        if (pick is not null) picks[clipId] = pick;
        return project with { ClipStyle = style with { CaptionPicks = picks } };
    }

    /// <summary>A fine-tune of <paramref name="clipId"/>'s captions (Mac EditorModel.mutateCaptions): while a pick applies, its style and
    /// overrides take <paramref name="changed"/>'s and the positions stay the project's; otherwise the project's captions become
    /// <paramref name="changed"/>.</summary>
    public static Project Tuning(Project project, string? clipId, ProjectCaptions changed)
    {
        if (clipId is { Length: > 0 } && Pick(project, clipId) is { } pick)
            return Restoring(project with { Captions = project.Captions with { Position = changed.Position, PositionByAspect = changed.PositionByAspect } },
                clipId, pick with { StyleId = changed.StyleId, Overrides = changed.Overrides.ValueKind == System.Text.Json.JsonValueKind.Object ? changed.Overrides.Clone() : null });
        return project with { Captions = changed };
    }

    /// <summary>The Captions panel's line (Mac activeCaptionSourceText): "This clip: Bold Pop · Claude's pick", "This clip: Off · your
    /// pick" or "Project default". <paramref name="name"/> maps a style id to its name.</summary>
    public static string Source(Project project, string? clipId, Func<string, string> name) => Pick(project, clipId) is { } pick
        ? $"This clip: {(pick.StyleId == "off" ? "Off" : name(pick.StyleId))} · {(pick.ByUser ? "your pick" : "Claude's pick")}"
        : "Project default";

    private static string Trimmed(string reason)
    {
        var runes = reason.EnumerateRunes().ToArray();
        return runes.Length <= 120 ? reason : string.Concat(runes.Take(120).Select(rune => rune.ToString()));
    }
}
