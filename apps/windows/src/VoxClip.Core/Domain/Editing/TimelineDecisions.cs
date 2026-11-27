using System.Text.Json.Nodes;
using VoxClip.Core.Domain.Effects;
using VoxClip.Core.Domain.Music;
using VoxClip.Core.Domain.Shared;

namespace VoxClip.Core.Domain.Editing;

/// <summary>The harness projection of the editor's timeline geometry and item shape.</summary>
public static class TimelineDecisions
{
    /// <summary>Return the edited-axis decisions and stable edit targets for a scope.</summary>
    public static JsonObject Read(Project project, string? scope)
    {
        var plan = RenderCallerInputs.PlacementPlan(project, scope);
        var layout = TimelineItems.Layout(project, plan, scope, TimelineAxis.Edited);
        var clock = new TimelineClock(project, plan, scope);
        var entries = TimelineEntry.Collect(project, clock);
        var effects = project.ClipEffects.Select(ClipEffect.Parse).ToDictionary(effect => effect.Id, StringComparer.Ordinal);
        var track = project.Music.FirstOrDefault(item => item.ClipId == scope);
        var music = track?.Segments ?? (track is not null && clock.Bed(track) is { } bed ? [bed] : []);
        var words = clock.Words;
        int? Word(double time, bool end = false)
        {
            for (var offset = 0; offset < words.Count; offset++)
            {
                var index = end ? words.Count - 1 - offset : offset;
                if (end ? words[index].Start < time : words[index].End > time) return index;
            }
            return null;
        }
        static JsonObject Shape(double? fadeIn, double? fadeOut, double? gain = null, IReadOnlyList<GainPoint>? points = null) =>
            new() { ["fadeIn"] = fadeIn, ["fadeOut"] = fadeOut, ["gainDb"] = gain,
                ["gainPoints"] = new JsonArray((points ?? []).Select(point => (JsonNode)new JsonObject { ["t"] = point.T, ["db"] = point.Db }).ToArray()) };
        var items = layout.Items.Select(item =>
        {
            var shape = new JsonObject();
            var paid = item.Id.Type == TimelineItemType.Voice;
            switch (item.Id.Type)
            {
                case TimelineItemType.Effect when effects.TryGetValue(item.Id.Value, out var effect):
                    shape = Shape(effect.FadeInSeconds, effect.FadeOutSeconds, effect.GainDb, effect.GainPoints);
                    shape["soundFrom"] = effect.MediaOffsetSeconds;
                    shape["text"] = effect.Text;
                    paid = effect.Kind == "illustration";
                    break;
                case TimelineItemType.Footage when project.Media.Footage?.FirstOrDefault(entry => entry.Id == item.Id.Value) is { } footage:
                    shape = Shape(footage.FadeInSeconds, footage.FadeOutSeconds);
                    shape["mediaFrom"] = footage.Footage.Start;
                    break;
                case TimelineItemType.Music when track is not null && music.FirstOrDefault(segment => segment.Id == item.Id.Value) is { } segment:
                    shape = Shape(segment.FadeInSeconds, segment.FadeOutSeconds, segment.GainDb, segment.GainPoints);
                    shape["track"] = track.Id;
                    shape["duckDb"] = track.DuckDb ?? (track.Ducking ? -12 : 0);
                    shape["songFrom"] = segment.SongFromSeconds;
                    shape["lengthSeconds"] = segment.LengthSeconds;
                    shape["loop"] = segment.Loop;
                    paid = track.Source == MusicSource.Generated;
                    break;
            }
            var end = entries.FirstOrDefault(entry => entry.Id == item.Id)?.Span.End ?? item.SourceAnchor;
            return (JsonNode)new JsonObject { ["id"] = Id(item.Id, project, scope), ["kind"] = item.Kind, ["lane"] = item.Lane.ToString(), ["row"] = item.Row,
                ["partId"] = item.PartId, ["sourceAnchor"] = item.SourceAnchor, ["startWord"] = Word(item.SourceAnchor), ["endWord"] = Word(end, end: true),
                ["editedIntervals"] = new JsonArray(item.EditedIntervals.Select(interval => (JsonNode)new JsonObject { ["start"] = interval.Start, ["end"] = interval.End }).ToArray()),
                ["hidden"] = item.Hidden, ["marker"] = item.Marker, ["reason"] = item.Reason,
                ["seamNotches"] = new JsonArray(item.SeamNotches.Select(time => (JsonNode?)JsonValue.Create(time)).ToArray()), ["paid"] = paid, ["shape"] = shape };
        }).ToArray();
        var rows = new JsonObject();
        foreach (var (lane, count) in layout.RowCounts) rows[lane.ToString()] = count;
        return new() { ["items"] = new JsonArray(items), ["rowCounts"] = rows,
            ["snapTargets"] = new JsonArray(layout.SnapTargets.Select(target => (JsonNode)new JsonObject {
                ["time"] = target.Time, ["kind"] = JsonKey(target.Kind.ToString()),
                ["item"] = target.Item is { } id ? Id(id, project, scope) : null }).ToArray()) };
    }

    internal static string Id(TimelineItemId item, Project project, string? scope) => item.Type == TimelineItemType.Music
        ? $"music:{project.Music.FirstOrDefault(track => track.ClipId == scope)?.Id}/{item.Value}"
        : $"{JsonKey(item.Type.ToString())}:{item.Value}";

    private static string JsonKey(string name) => char.ToLowerInvariant(name[0]) + name[1..];
}
