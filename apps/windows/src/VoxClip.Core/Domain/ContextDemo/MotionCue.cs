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

/// <summary>The crop a motion cue applies to the finished picture: <c>1/Scale</c> of the frame, placed by its anchor (0 left or top,
/// 1 right or bottom). Twin of Mac MotionCropTransform.</summary>
public sealed record MotionCropTransform(double Scale, double AnchorX, double AnchorY)
{
    /// <summary>No motion.</summary>
    public static MotionCropTransform Identity { get; } = new(1, 0.5, 0.5);

    /// <summary>The crop of a <paramref name="width"/> × <paramref name="height"/> frame, in top-left pixel coordinates.</summary>
    public RectD Crop(double width, double height)
    {
        var cropWidth = width / Scale;
        var cropHeight = height / Scale;
        return new((width - cropWidth) * AnchorX, (height - cropHeight) * AnchorY, cropWidth, cropHeight);
    }
}

/// <summary>Motion cues at render time (Mac MotionCue.transform): the clip's cue covering a source time, its keyframes eased with a
/// smoothstep, scale 1–1.35 and anchors 0–1 clamped. Only the rendered clip's cues apply; the full video has none.</summary>
public static class MotionCueRendering
{
    /// <summary>The cue's crop at <paramref name="sourceTime"/>; the identity outside [start, end).</summary>
    public static MotionCropTransform Transform(MotionCue cue, double sourceTime)
    {
        if (cue.Keyframes.Count == 0 || cue.SourceEnd - cue.SourceStart + 1e-9 < 0.1 || !double.IsFinite(sourceTime)
            || sourceTime < cue.SourceStart || sourceTime >= cue.SourceEnd) return MotionCropTransform.Identity;
        var progress = (sourceTime - cue.SourceStart) / (cue.SourceEnd - cue.SourceStart);
        var upper = cue.Keyframes.Count - 1;
        for (var index = 0; index < cue.Keyframes.Count; index++)
            if (cue.Keyframes[index].Progress > progress) { upper = index; break; }
        var first = cue.Keyframes[Math.Max(0, upper - 1)];
        var last = cue.Keyframes[upper];
        var fraction = Clamp((progress - first.Progress) / Math.Max(1e-12, last.Progress - first.Progress), 0, 1, 0);
        var eased = fraction * fraction * (3 - 2 * fraction);
        return new(Clamp(first.Scale + (last.Scale - first.Scale) * eased, 1, 1.35, 1),
            Clamp(first.AnchorX + (last.AnchorX - first.AnchorX) * eased, 0, 1, 0.5),
            Clamp(first.AnchorY + (last.AnchorY - first.AnchorY) * eased, 0, 1, 0.5));
    }

    /// <summary>The crop at <paramref name="sourceTime"/> from the earliest of <paramref name="cues"/> covering it (ties by id).</summary>
    public static MotionCropTransform Transform(IReadOnlyList<MotionCue> cues, double sourceTime)
    {
        if (!double.IsFinite(sourceTime)) return MotionCropTransform.Identity;
        var cue = cues.Take(64).Where(item => sourceTime >= item.SourceStart && sourceTime < item.SourceEnd)
            .OrderBy(item => item.SourceStart).ThenBy(item => item.Id, StringComparer.Ordinal).FirstOrDefault();
        return cue is null ? MotionCropTransform.Identity : Transform(cue, sourceTime);
    }

    /// <summary>The cues a render of <paramref name="clipId"/> applies; none for the full video.</summary>
    public static IReadOnlyList<MotionCue> For(Project project, string? clipId) =>
        clipId is null ? [] : project.MotionCues.Where(cue => cue.ClipID == clipId).ToArray();

    private static double Clamp(double value, double lower, double upper, double fallback) =>
        double.IsFinite(value) ? Math.Min(upper, Math.Max(lower, value)) : fallback;
}
