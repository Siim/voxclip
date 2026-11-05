using System.Globalization;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using VoxClip.Core.Domain.Clips;
using VoxClip.Core.Domain.Editing;
using VoxClip.Core.Domain.Shared;

namespace VoxClip.Core.Domain.Effects;

/// <summary>The hook's title card (design §6.7): Make it postable shows the planner's hook as an Ask Claude <c>title</c> effect at the
/// top over the first 2 rendered seconds of the clip. Twin of the Mac <c>ClipHookTitle</c>.</summary>
public static class ClipHookTitle
{
    /// <summary>How long the card shows, in rendered seconds.</summary>
    public const double Seconds = 2;
    /// <summary>The longest title, in Unicode scalars.</summary>
    public const int MaximumTitleScalars = 80;
    private const string IdPrefix = "fx-hook-";

    /// <summary>Whether the stored effect is a hook card.</summary>
    public static bool IsHook(JsonElement effect) =>
        effect.GetProperty("kind").GetString() == "title" && effect.GetProperty("id").GetString()!.StartsWith(IdPrefix, StringComparison.Ordinal);

    /// <summary>The clip's hook card, if it has one.</summary>
    public static JsonElement? Existing(string clipId, Project project)
    {
        foreach (var effect in project.ClipEffects)
            if (IsHook(effect) && effect.GetProperty("clipId").ValueKind == JsonValueKind.String && effect.GetProperty("clipId").GetString() == clipId) return effect;
        return null;
    }

    /// <summary>The hook as a title's text: one line, words joined by one space, at most 80 scalars, trimmed; null when empty.</summary>
    public static string? Text(string hook)
    {
        var line = string.Concat(hook.EnumerateRunes().Select(rune => Rune.GetUnicodeCategory(rune) == UnicodeCategory.Control ? " " : rune.ToString()));
        var words = string.Join(" ", line.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries));
        var limited = string.Concat(words.EnumerateRunes().Take(MaximumTitleScalars).Select(rune => rune.ToString())).Trim();
        return limited.Length == 0 ? null : limited;
    }

    /// <summary>The clip's render timeline at 1×: its own words with the project's cuts, at the source's sample rate.</summary>
    public static EditPlan? Timeline(Project project, string clipId)
    {
        if (EditingEngine.FromProject(project) is not { } state || state.Clips.All(clip => clip.Id != clipId)) return null;
        var duration = project.Media.Source.DurationSeconds;
        var rate = project.Media.Source.Audio?.SampleRate ?? 48000;
        var scoped = state with { ActiveClipId = clipId };
        return EditingEngine.BuildEditPlan(EditingEngine.BuildSegments(scoped, duration), duration, rate, state.PauseKeepSeconds);
    }

    /// <summary>The card for <paramref name="hook"/> on <paramref name="clipId"/>, replacing the clip's existing card (same id). It runs
    /// from the clip's first kept frame to the source time its render reaches 2 s later (cuts skipped, at the clip's speed), starting
    /// one overlay fade early so the first frame shows it whole. Null when the hook is empty or the clip is unknown.</summary>
    public static JsonElement? Effect(string hook, string clipId, Project project)
    {
        if (Text(hook) is not { } text || ClipControlsProject.SourceSpan(clipId, project) is not { } span) return null;
        var speed = ClipControlsProject.Controls(clipId, project)!.Speed;
        var edited = new ClipSpeedTiming(speed).Edited(Seconds);
        double first = span.Start, last = Math.Min(span.End, span.Start + edited);
        if (Timeline(project, clipId) is { Duration: > 0 } timeline)
        {
            first = timeline.SourceTime(0);
            last = edited < timeline.Duration ? timeline.SourceTime(edited) : span.End;
        }
        var start = Math.Max(0, first - ClipEffect.OverlayFadeSeconds);
        if (last <= start) return null;
        var id = Existing(clipId, project)?.GetProperty("id").GetString() ?? NextId(project);
        var json = new JsonObject
        {
            ["id"] = id, ["clipId"] = clipId, ["kind"] = "title", ["start"] = start, ["end"] = Math.Min(last, start + 600), ["text"] = text, ["position"] = "top"
        };
        using var document = JsonDocument.Parse(json.ToJsonString());
        return document.RootElement.Clone();
    }

    private static string NextId(Project project)
    {
        var used = project.ClipEffects.Select(effect => effect.GetProperty("id").GetString()).ToHashSet(StringComparer.Ordinal);
        var index = 1;
        while (used.Contains(IdPrefix + index.ToString(CultureInfo.InvariantCulture))) index++;
        return IdPrefix + index.ToString(CultureInfo.InvariantCulture);
    }
}
