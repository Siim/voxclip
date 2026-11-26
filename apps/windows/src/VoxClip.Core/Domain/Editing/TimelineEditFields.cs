using System.Text.Json;
using System.Text.Json.Serialization;
using VoxClip.Core.Domain.ContextDemo;
using VoxClip.Core.Domain.Effects;
using VoxClip.Core.Domain.Shared;

namespace VoxClip.Core.Domain.Editing;

/// <summary>A point in an item's relative gain envelope.</summary>
/// <param name="T">Seconds from the item's start on its own clock.</param>
/// <param name="Db">Relative gain in dB.</param>
public readonly record struct GainPoint(double T, double Db);

/// <summary>The optional fades and gain envelope of a connected item.</summary>
/// <param name="FadeInSeconds">Entrance fade duration.</param>
/// <param name="FadeOutSeconds">Exit fade duration.</param>
/// <param name="GainPoints">Relative gain in strictly increasing item-local time.</param>
public sealed record ItemShape(
    [property: JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)] double? FadeInSeconds = null,
    [property: JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)] double? FadeOutSeconds = null,
    [property: JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)] IReadOnlyList<GainPoint>? GainPoints = null)
{
    /// <summary>The most gain points one item may store.</summary>
    public const int MaximumGainPoints = 64;

    internal static bool ValidGainPoints(IReadOnlyList<GainPoint> points)
    {
        if (points.Count > MaximumGainPoints) return false;
        var previous = double.NegativeInfinity;
        foreach (var point in points)
        {
            if (!double.IsFinite(point.T) || point.T < 0 || point.T <= previous || !(point.Db is >= -60 and <= 12)) return false;
            previous = point.T;
        }
        return true;
    }

    internal static bool ValidGainPointsWire(JsonElement value) =>
        value.ValueKind == JsonValueKind.Array && value.GetArrayLength() <= MaximumGainPoints && value.EnumerateArray().All(point =>
            point.ValueKind == JsonValueKind.Object && point.EnumerateObject().Count() == 2 &&
            point.TryGetProperty("t", out var time) && TimelineEditFields.IsNumber(time) &&
            point.TryGetProperty("db", out var db) && TimelineEditFields.IsNumber(db));

    internal static GainPoint[] ReadGainPoints(JsonElement value) => value.EnumerateArray()
        .Select(point => new GainPoint(point.GetProperty("t").GetDouble(), point.GetProperty("db").GetDouble())).ToArray();
}

internal static class TimelineEditFields
{
    internal const int Version = 6;

    internal static bool IsNumber(JsonElement value) =>
        value.ValueKind == JsonValueKind.Number && value.TryGetDouble(out var number) && double.IsFinite(number);

    internal static Project Promoting(Project project)
    {
        if (project.SchemaVersion is < 1 or >= Version ||
            !(project.ClipEffects.Any(ClipEffects.UsesTimelineEditFields) ||
              project.Music.Any(track => track is not null && (track.DuckDb is not null || track.Segments is not null)) ||
              project.Media.Footage?.Any(entry => entry is not null && (entry.FadeInSeconds is not null || entry.FadeOutSeconds is not null)) == true)) return project;
        return (project.SchemaVersion < 4 ? ContextDemoProject.UpgradeToV4(project) : project) with { SchemaVersion = Version };
    }
}
