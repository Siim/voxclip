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
/// Every key is written, null included, as the Mac Core writes it. An entry at its defaults is never stored.</summary>
public sealed record ProjectClipControls(string ClipId, double Speed, ClipShape? Shape, ClipLook Look, double GainDb,
    double FadeInSeconds, double FadeOutSeconds, bool MuteSource, bool FlipHorizontal, int RotationDegrees)
{
    /// <summary>Every control at its default.</summary>
    [JsonIgnore]
    public bool IsDefault => Speed == 1 && Shape is null && Look == ClipLook.Original && GainDb == 0 && FadeInSeconds == 0 &&
        FadeOutSeconds == 0 && !MuteSource && !FlipHorizontal && RotationDegrees == 0;
}

/// <summary>Validation, pruning and the export refusal for the v4 clipControls field. Windows opens, validates and saves
/// clip controls unchanged; rendering them is Mac-only for now, so Windows export refuses with a reason.</summary>
public static class ClipControlsProject
{
    /// <summary>The reason a Windows render or export of a project with clip controls stops.</summary>
    public const string ExportUnsupportedMessage =
        "Windows cannot play clip speed, looks, volume, fades, flip or rotation yet. Export this project on a Mac, or reset its clip controls there. Your clip controls and edits are unchanged.";

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
            Require(entry.EnumerateObject().Select(property => property.Name).ToHashSet(StringComparer.Ordinal).SetEquals(
                "clipId speed shape look gainDb fadeInSeconds fadeOutSeconds muteSource flipHorizontal rotationDegrees".Split(' ')));
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
