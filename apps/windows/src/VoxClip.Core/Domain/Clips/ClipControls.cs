using System.Diagnostics.CodeAnalysis;
using System.Text.Json;
using System.Text.Json.Serialization;
using System.Text.RegularExpressions;
using VoxClip.Core.Domain.ContextDemo;
using VoxClip.Core.Domain.Shared;

namespace VoxClip.Core.Domain.Clips;

/// <summary>A clip's colour look (design §6.9); the same ids the clip planner writes.</summary>
[JsonConverter(typeof(JsonStringEnumConverter<ClipLook>))]
public enum ClipLook
{
    /// <summary>The footage as filmed.</summary>
    [JsonStringEnumMemberName("original")] Original,
    /// <summary>About 35% less saturation and lifted blacks.</summary>
    [JsonStringEnumMemberName("muted")] Muted,
    /// <summary>A small temperature and tint shift.</summary>
    [JsonStringEnumMemberName("warm")] Warm,
    /// <summary>Black and white with a gentle contrast curve.</summary>
    [JsonStringEnumMemberName("bw")] Bw
}

/// <summary>A clip's own frame; null on a clip keeps the project's export frame. 4:5 exists only here.</summary>
[JsonConverter(typeof(JsonStringEnumConverter<ClipShape>))]
public enum ClipShape
{
    /// <summary>16:9.</summary>
    [JsonStringEnumMemberName("16:9")] Landscape,
    /// <summary>9:16.</summary>
    [JsonStringEnumMemberName("9:16")] Portrait,
    /// <summary>1:1.</summary>
    [JsonStringEnumMemberName("1:1")] Square,
    /// <summary>4:5.</summary>
    [JsonStringEnumMemberName("4:5")] PortraitFourFive
}

/// <summary>One clip's speed, frame, look, source volume, fades, mute, flip and rotation; schema v4, design §6.9.
/// Every key is written, null included, as the Mac Core writes it, except the optional <paramref name="Reframe"/> ("9:16 follows
/// your face") and <paramref name="CoverSeconds"/> (the cover's source second), ADR-R48 part 2, which are omitted when null.
/// An entry at its defaults is never stored.</summary>
public sealed record ProjectClipControls(string ClipId, double Speed, ClipShape? Shape, ClipLook Look, double GainDb,
    double FadeInSeconds, double FadeOutSeconds, bool MuteSource, bool FlipHorizontal, int RotationDegrees,
    [property: JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)] ReframeSettings? Reframe = null,
    [property: JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)] double? CoverSeconds = null)
{
    /// <summary>Every control at its default.</summary>
    [JsonIgnore]
    public bool IsDefault => Speed == 1 && Shape is null && Look == ClipLook.Original && GainDb == 0 && FadeInSeconds == 0 &&
        FadeOutSeconds == 0 && !MuteSource && !FlipHorizontal && RotationDegrees == 0 && Reframe is null && CoverSeconds is null;

    /// <summary>The face-follow centre (0–1 from the top left of the source) for an output of width over height
    /// <paramref name="outputAspect"/>: only in face mode and for 9:16 and 1:1 (16:9 ignores it). Twin of the Mac <c>cropCenter</c>.</summary>
    public (double X, double Y)? CropCenter(double outputAspect) =>
        Reframe is { Mode: ReframeSettings.FaceMode, CenterX: { } x, CenterY: { } y } && double.IsFinite(outputAspect) && outputAspect <= 1 + 1e-9 ? (x, y) : null;
}

/// <summary>"9:16 follows your face" (ADR-R48 part 2): the frame's crop moved to centre on the clip's measured face, kept inside the
/// picture. Twin of the Mac <c>FrameCompositor.aspectCrop</c>.</summary>
public static class ClipFaceCrop
{
    /// <summary>The centre crop <paramref name="crop"/> of a <paramref name="width"/>×<paramref name="height"/> oriented source,
    /// moved to the face (mapped through the clip's flip and turns) for an output of <paramref name="outputAspect"/>.</summary>
    public static RectD Centered(RectD crop, double width, double height, ProjectClipControls? controls, double outputAspect)
    {
        if (controls?.CropCenter(outputAspect) is not { } center) return crop;
        var (x, y) = controls.MapAnchor(center.X, center.Y);
        var left = Math.Min(width - crop.Width, Math.Max(0, width * x - crop.Width / 2));
        var top = Math.Min(height - crop.Height, Math.Max(0, height * y - crop.Height / 2));
        return new(left, top, crop.Width, crop.Height);
    }
}

/// <summary>Validation and pruning for the v4 clipControls field. Windows opens, validates and saves clip controls unchanged,
/// and renders them in preview and export (<see cref="ClipControlsRendering"/>).</summary>
public static class ClipControlsProject
{
    private const string Identifier = "[A-Za-z0-9][A-Za-z0-9._:-]{0,63}";

    /// <summary>The typed rules: v4 only, the clip exists, one entry per clip, ranges, no stored defaults.</summary>
    public static void Validate(Project project)
    {
        if (project.ClipControls.Count == 0) return;
        Require(project.SchemaVersion == 4 && project.ClipControls.Count <= 64);
        var clips = project.Edits.Clips.Select(clip => clip.Id).ToHashSet(StringComparer.Ordinal);
        var seen = new HashSet<string>(StringComparer.Ordinal);
        foreach (var entry in project.ClipControls)
        {
            Require(entry is not null && entry.ClipId is not null);
            Require(Regex.IsMatch(entry.ClipId, "\\A(?:" + Identifier + ")\\z", RegexOptions.CultureInvariant, TimeSpan.FromSeconds(1)));
            Require(double.IsFinite(entry.Speed) && entry.Speed is >= 0.5 and <= 2);
            Require(double.IsFinite(entry.GainDb) && entry.GainDb is >= -24 and <= 12);
            Require(double.IsFinite(entry.FadeInSeconds) && entry.FadeInSeconds is >= 0 and <= 5);
            Require(double.IsFinite(entry.FadeOutSeconds) && entry.FadeOutSeconds is >= 0 and <= 5);
            Require(entry.RotationDegrees is 0 or 90 or 180 or 270 && Enum.IsDefined(entry.Look) && (entry.Shape is null || Enum.IsDefined(entry.Shape.Value)));
            if (entry.Reframe is { } reframe)
                Require(reframe.Mode == ReframeSettings.FaceMode && reframe.Zoom == 1 && reframe.CenterX is >= 0 and <= 1 && reframe.CenterY is >= 0 and <= 1);
            if (entry.CoverSeconds is { } cover) Require(double.IsFinite(cover) && cover >= 0);
            Require(!entry.IsDefault && clips.Contains(entry.ClipId) && seen.Add(entry.ClipId));
        }
    }

    /// <summary>Strict wire shape: exact keys and JSON types, a non-empty list (absent when empty).</summary>
    internal static void ValidateWire(JsonElement value)
    {
        Require(value.ValueKind == JsonValueKind.Array && value.GetArrayLength() is >= 1 and <= 64);
        foreach (var entry in value.EnumerateArray())
        {
            Require(entry.ValueKind == JsonValueKind.Object);
            var keys = entry.EnumerateObject().Select(property => property.Name).ToHashSet(StringComparer.Ordinal);
            keys.Remove("reframe"); keys.Remove("coverSeconds");
            Require(keys.SetEquals("clipId speed shape look gainDb fadeInSeconds fadeOutSeconds muteSource flipHorizontal rotationDegrees".Split(' ')));
            if (entry.TryGetProperty("reframe", out var reframe))
            {
                Require(reframe.ValueKind == JsonValueKind.Object && reframe.EnumerateObject().Select(property => property.Name)
                    .ToHashSet(StringComparer.Ordinal).SetEquals(["mode", "zoom", "centerX", "centerY"]));
                Require(reframe.GetProperty("mode").ValueKind == JsonValueKind.String);
                foreach (var key in new[] { "zoom", "centerX", "centerY" }) Number(reframe.GetProperty(key));
            }
            if (entry.TryGetProperty("coverSeconds", out var cover)) Number(cover);
            Require(entry.GetProperty("clipId").ValueKind == JsonValueKind.String && entry.GetProperty("look").ValueKind == JsonValueKind.String);
            Require(entry.GetProperty("shape").ValueKind is JsonValueKind.String or JsonValueKind.Null);
            foreach (var key in new[] { "speed", "gainDb", "fadeInSeconds", "fadeOutSeconds" }) Number(entry.GetProperty(key));
            foreach (var key in new[] { "muteSource", "flipHorizontal" }) Require(entry.GetProperty(key).ValueKind is JsonValueKind.True or JsonValueKind.False);
            var rotation = entry.GetProperty("rotationDegrees");
            Require(rotation.ValueKind == JsonValueKind.Number && rotation.TryGetInt32(out var degrees) && degrees is 0 or 90 or 180 or 270);
            Require(entry.GetProperty("look").GetString() is "original" or "muted" or "warm" or "bw");
            Require(entry.GetProperty("shape").ValueKind == JsonValueKind.Null || entry.GetProperty("shape").GetString() is "16:9" or "9:16" or "1:1" or "4:5");
        }
    }

    /// <summary>Stores controls for their clip, removing the entry at the defaults; the first entry promotes to v4.</summary>
    public static Project Setting(ProjectClipControls controls, Project project)
    {
        Require(project.Edits.Clips.Any(clip => clip.Id == controls.ClipId));
        var kept = project.ClipControls.Where(entry => entry.ClipId != controls.ClipId).ToList();
        var result = project with { ClipControls = kept };
        if (!controls.IsDefault) result = ContextDemoProject.UpgradeToV4(result) with { ClipControls = kept.Append(controls).ToArray() };
        Validate(result);
        return result;
    }

    /// <summary>The clip's controls, its defaults when none are stored; null for no clip.</summary>
    public static ProjectClipControls? Controls(string? clipId, Project project) => clipId is null ? null
        : project.ClipControls.FirstOrDefault(entry => entry.ClipId == clipId) ?? new(clipId, 1, null, ClipLook.Original, 0, 0, 0, false, false, 0);

    /// <summary>A speed clamped to 0.5–2 and rounded to hundredths (Mac <c>normalizedSpeed</c>); 1 when not finite.</summary>
    public static double NormalizedSpeed(double rate) =>
        double.IsFinite(rate) ? Math.Round(Math.Clamp(rate, 0.5, 2) * 100, MidpointRounding.AwayFromZero) / 100 : 1;

    /// <summary>The project with one clip's speed set (normalised) and its other controls kept.</summary>
    public static Project SettingSpeed(double rate, string clipId, Project project) =>
        Setting(Controls(clipId, project)! with { Speed = NormalizedSpeed(rate) }, project);

    /// <summary>The project with one clip's look set and its other controls kept.</summary>
    public static Project SettingLook(ClipLook look, string clipId, Project project) =>
        Setting(Controls(clipId, project)! with { Look = look }, project);

    /// <summary>A clip's span in source seconds, its first word's start to its last word's end; null for an unknown clip.</summary>
    public static (double Start, double End)? SourceSpan(string clipId, Project project)
    {
        var clip = project.Edits.Clips.FirstOrDefault(item => item.Id == clipId);
        var words = project.Transcript?.Words;
        var first = words?.FirstOrDefault(word => word.Id == clip?.StartWordId);
        var last = words?.FirstOrDefault(word => word.Id == clip?.EndWordId);
        return first is not null && last is not null && last.End > first.Start ? (first.Start, last.End) : null;
    }

    /// <summary>How far a stretch may miss a clip's first word start or last word end and still count as the whole clip.</summary>
    public const double WholeClipToleranceSeconds = 0.25;

    /// <summary>The clip a stretch from <paramref name="start"/> to <paramref name="end"/> covers whole, within
    /// <see cref="WholeClipToleranceSeconds"/> at each end: <paramref name="clipId"/> when given, else the one clip that matches (none when
    /// two do). Twin of the Mac <c>wholeClip</c>.</summary>
    public static string? WholeClip(string? clipId, double start, double end, Project project)
    {
        const double tolerance = WholeClipToleranceSeconds + 1e-9;
        bool Covers(string id) => SourceSpan(id, project) is { } span && Math.Abs(span.Start - start) <= tolerance && Math.Abs(span.End - end) <= tolerance;
        if (clipId is not null) return Covers(clipId) ? clipId : null;
        var matching = project.Edits.Clips.Select(clip => clip.Id).Where(Covers).ToArray();
        return matching.Length == 1 ? matching[0] : null;
    }

    /// <summary>Keeps entries whose clip still exists.</summary>
    public static IReadOnlyList<ProjectClipControls> Pruned(IReadOnlyList<ProjectClipControls> controls, IEnumerable<string> clipIds)
    {
        var identities = clipIds.ToHashSet(StringComparer.Ordinal);
        return controls.Where(entry => identities.Contains(entry.ClipId)).ToArray();
    }

    private static void Number(JsonElement value) =>
        Require(value.ValueKind == JsonValueKind.Number && value.TryGetDouble(out var number) && double.IsFinite(number));

    private static void Require([DoesNotReturnIf(false)] bool condition)
    {
        if (!condition) throw new VoxClipException(VoxClipErrorCode.ProjectUnreadable, "Invalid clip controls.");
    }
}
