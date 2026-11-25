using System.Text.Json;
using System.Text.Json.Nodes;
using VoxClip.Core.Domain.Editing;
using VoxClip.Core.Domain.Music;
using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Services.Project;

namespace VoxClip.Core.Domain.Autopilot;

/// <summary>Optional timeline shaping for a picked or generated music track.</summary>
public sealed class ClipPlanMusicShape
{
    internal static readonly string[] Keys = ["fadeIn", "fadeOut", "duckDb", "segments"];
    private readonly JsonObject fields;
    private ClipPlanMusicShape(JsonObject fields) => this.fields = fields;

    internal static ClipPlanMusicShape? Read(JsonNode? value, bool provider = false)
    {
        var fields = new JsonObject();
        if (value is not JsonObject source) return null;
        foreach (var key in Keys) if (source.ContainsKey(key)) fields[key] = source[key]?.DeepClone();
        if (provider)
        {
            foreach (var key in new[] { "fadeIn", "fadeOut" }) if (AiJson.Number(fields[key]) == -1) fields.Remove(key);
            if (AiJson.Number(fields["duckDb"]) == 1) fields.Remove("duckDb");
            if (fields["segments"] is JsonArray segments)
            {
                foreach (var segment in segments.OfType<JsonObject>())
                    foreach (var key in new[] { "fadeIn", "fadeOut", "songFrom" })
                        if (AiJson.Number(segment[key]) == -1) segment.Remove(key);
                if (segments.Count == 0) fields.Remove("segments");
            }
        }
        if (fields.Count == 0) return null;
        static bool Number(JsonObject item, string key, double minimum, double maximum) => !item.ContainsKey(key) ||
            AiJson.Number(item[key]) is var number && number >= minimum && number <= maximum;
        static JsonException Invalid() => new("Choose valid music fades, ducking and segment anchors.");
        if (!Number(fields, "fadeIn", 0, 10) || !Number(fields, "fadeOut", 0, 10) || !Number(fields, "duckDb", -24, 0)) throw Invalid();
        if (fields.ContainsKey("segments"))
        {
            if (fields["segments"] is not JsonArray { Count: <= 8 } entries) throw Invalid();
            foreach (var entry in entries)
            {
                if (entry is not JsonObject item || item.Any(field => field.Key is not ("startWord" or "endWord" or "songFrom" or "loop" or "gainDb" or "fadeIn" or "fadeOut")) ||
                    AiJson.Integer(item["startWord"]) is not (>= 0 and var start) || AiJson.Integer(item["endWord"]) is not { } end || end < start ||
                    item.ContainsKey("loop") && !(item["loop"] is JsonValue loop && loop.TryGetValue<bool>(out _)) ||
                    !Number(item, "songFrom", 0, 1800) || !Number(item, "gainDb", -40, 12) ||
                    !Number(item, "fadeIn", 0, 10) || !Number(item, "fadeOut", 0, 10)) throw Invalid();
            }
        }
        return new(fields);
    }

    internal JsonObject Write(JsonObject target)
    {
        foreach (var (key, value) in fields) target[key] = value?.DeepClone();
        return target;
    }

    /// <summary>Place the selected phrases on the clip without altering the music asset.</summary>
    public ProjectMusic Place(ProjectMusic track, Project project, string? clipId)
    {
        var depth = AiJson.Number(fields["duckDb"]);
        var result = track with { FadeInSeconds = AiJson.Number(fields["fadeIn"]) ?? track.FadeInSeconds,
            FadeOutSeconds = AiJson.Number(fields["fadeOut"]) ?? track.FadeOutSeconds,
            DuckDb = depth ?? track.DuckDb, Ducking = depth is { } db ? db != 0 : track.Ducking };
        if (fields["segments"] is not JsonArray { Count: > 0 } entries) return result;
        var words = project.Transcript?.Words ?? [];
        var plan = RenderCallerInputs.PlacementPlan(project, clipId);
        var spans = project.Edits.Clips.FirstOrDefault(clip => clip.Id == clipId)?.PlayPartIndices(words);
        static HarnessException Invalid() => new("Place each music segment on kept words in the clip and inside the track.");
        double Round(double seconds) => EditingMath.Round(seconds * plan.SampleRate) / plan.SampleRate;
        var segments = entries.Select((entry, index) =>
        {
            var startWord = AiJson.Integer(entry!["startWord"])!.Value;
            var endWord = AiJson.Integer(entry["endWord"])!.Value;
            if (endWord >= words.Count || spans is not null && (!spans.Any(span => span.Start <= startWord && startWord <= span.End) ||
                !spans.Any(span => span.Start <= endWord && endWord <= span.End))) throw Invalid();
            var start = Round(words[startWord].Start);
            var end = Round(words[endWord].End);
            var duration = Round(plan.MapTime(end, true) - plan.MapTime(start));
            var from = Round(AiJson.Number(entry["songFrom"]) ?? track.StartOffsetSeconds);
            var loop = entry["loop"]?.GetValue<bool>() ?? true;
            if (duration <= 0.1 || from >= track.Asset.DurationSeconds || !loop && duration > track.Asset.DurationSeconds - from) throw Invalid();
            return new MusicSegment($"seg-{index + 1}", start, duration, from, loop, AiJson.Number(entry["gainDb"]) ?? 0,
                AiJson.Number(entry["fadeIn"]) ?? result.FadeInSeconds, AiJson.Number(entry["fadeOut"]) ?? result.FadeOutSeconds);
        }).ToArray();
        return result with { Segments = segments };
    }
}
