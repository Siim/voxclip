using System.Text.Json;
using System.Text.Json.Serialization;
using System.Diagnostics.CodeAnalysis;
using VoxClip.Core.Domain.Shared;

namespace VoxClip.Core.Domain.ContextDemo;

/// <summary>A canonical persisted motion keyframe; project schema v4.</summary>
public sealed record MotionKeyframe(double Progress, double Scale, double AnchorX, double AnchorY);

/// <summary>Source-take motion metadata, independent of narration and capture asset trims.</summary>
public sealed record MotionCue(string Id, [property: JsonPropertyName("clipID")] string ClipID,
    double SourceStart, double SourceEnd, IReadOnlyList<MotionKeyframe> Keyframes)
{
    /// <summary>Validate canonical motion, identities, source bounds and per-clip limits without normalization.</summary>
    public static void ValidateAll(Project project)
    {
        var identities = new HashSet<string>(StringComparer.Ordinal);
        var clips = project.Edits.Clips.Select(clip => clip.Id).ToHashSet(StringComparer.Ordinal);
        var counts = new Dictionary<string, int>(StringComparer.Ordinal);
        foreach (var cue in project.MotionCues)
        {
            Require(cue is not null && ContextDemoValidation.Identifier(cue.Id) && ContextDemoValidation.Identifier(cue.ClipID));
            Require(identities.Add(cue!.Id) && clips.Contains(cue.ClipID));
            ValidateRange(cue.SourceStart, cue.SourceEnd);
            Require(cue.SourceEnd <= project.Media.Source.DurationSeconds && cue.Keyframes is { Count: >= 2 and <= 8 });
            var previous = double.NegativeInfinity;
            for (var index = 0; index < cue.Keyframes.Count; index++)
            {
                var frame = cue.Keyframes[index];
                Require(frame is not null);
                ValidateFrame(frame!.Progress, frame.Scale, frame.AnchorX, frame.AnchorY, previous, index, cue.Keyframes.Count);
                previous = frame.Progress;
            }
            counts.TryGetValue(cue.ClipID, out var count);
            Require(count < 64);
            counts[cue.ClipID] = count + 1;
        }
    }

    internal static void ValidateWire(JsonElement value)
    {
        Require(value.ValueKind == JsonValueKind.Array);
        foreach (var cue in value.EnumerateArray())
        {
            Object(cue, "id clipID sourceStart sourceEnd keyframes");
            foreach (var key in new[] { "id", "clipID" })
                Require(cue.GetProperty(key).ValueKind == JsonValueKind.String && !string.IsNullOrEmpty(cue.GetProperty(key).GetString()));
            ValidateRange(Number(cue.GetProperty("sourceStart")), Number(cue.GetProperty("sourceEnd")));
            var frames = cue.GetProperty("keyframes");
            Require(frames.ValueKind == JsonValueKind.Array && frames.GetArrayLength() is >= 2 and <= 8);
            var previous = double.NegativeInfinity;
            var index = 0;
            foreach (var frame in frames.EnumerateArray())
            {
                Object(frame, "progress scale anchorX anchorY");
                var progress = Number(frame.GetProperty("progress"));
                ValidateFrame(progress, Number(frame.GetProperty("scale")), Number(frame.GetProperty("anchorX")),
                    Number(frame.GetProperty("anchorY")), previous, index++, frames.GetArrayLength());
                previous = progress;
            }
        }
    }

    private static void ValidateRange(double start, double end) => Require(double.IsFinite(start) && double.IsFinite(end) &&
        start >= 0 && end - start + 1e-9 >= 0.1 && end - start <= 120 + 1e-9);

    private static void ValidateFrame(double progress, double scale, double anchorX, double anchorY, double previous, int index, int count)
        => Require(double.IsFinite(progress) && progress is >= 0 and <= 1 && progress > previous &&
            (index != 0 || progress == 0) && (index != count - 1 || progress == 1) &&
            double.IsFinite(scale) && scale is >= 1 and <= 1.35 && double.IsFinite(anchorX) && anchorX is >= 0 and <= 1 &&
            double.IsFinite(anchorY) && anchorY is >= 0 and <= 1);

    private static void Object(JsonElement value, string keys)
    {
        Require(value.ValueKind == JsonValueKind.Object);
        var expected = keys.Split(' ').ToHashSet(StringComparer.Ordinal);
        Require(value.EnumerateObject().Select(property => property.Name).ToHashSet(StringComparer.Ordinal).SetEquals(expected));
    }

    private static double Number(JsonElement value)
    {
        Require(value.ValueKind == JsonValueKind.Number && value.TryGetDouble(out _));
        var number = value.GetDouble();
        Require(double.IsFinite(number));
        return number;
    }

    private static void Require([DoesNotReturnIf(false)] bool condition)
    {
        if (!condition) throw new VoxClipException(VoxClipErrorCode.ProjectUnreadable, "Invalid canonical motion cue.");
    }
}
