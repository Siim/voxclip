using System.Text.Json;
using System.Text.Json.Nodes;
using VoxClip.Core.Domain.Shared;

namespace VoxClip.Core.Domain.Captions;

internal static class CaptionStyleResolver
{
    internal static string Aspect(PixelSize frame) => 10L * frame.Width < 9L * frame.Height ? "portrait" : 9L * frame.Width > 10L * frame.Height ? "landscape" : "square";
    internal static string? Preset(PixelSize frame) => 16L * frame.Width == 9L * frame.Height ? "9:16" : 9L * frame.Width == 16L * frame.Height ? "16:9" : frame.Width == frame.Height ? "1:1" : null;
    internal static RectD Safe(PixelSize frame)
    {
        var inset = SafeInsets(frame);
        return new(frame.Width * inset.Left, frame.Height * inset.Top, frame.Width * (1 - inset.Right) - frame.Width * inset.Left,
            frame.Height * (1 - inset.Bottom) - frame.Height * inset.Top);
    }

    internal static (double Left, double Right, double Top, double Bottom) SafeInsets(PixelSize frame)
    {
        var portrait = Aspect(frame) == "portrait";
        var margin = portrait ? 0.06 : 0.05;
        return (margin, margin, margin, portrait ? 0.10 : 0.07);
    }

    internal static CaptionStyle Decode(string json, CaptionData data)
    {
        using var document = JsonDocument.Parse(json);
        var style = JsonSerializer.Deserialize(json, CaptionJsonContext.Default.CaptionStyle) ?? throw new JsonException("Expected a caption style.");
        CaptionStyleValidation.Validate(style, document.RootElement);
        Semantic(style, data);
        return style;
    }

    internal static CaptionStyle Resolve(CaptionLayoutRequest request, CaptionData data)
        => Resolve(request, data, out _);

    internal static CaptionStyle Resolve(CaptionLayoutRequest request, CaptionData data, out bool overridesRejected)
    {
        overridesRejected = false;
        var style = request.Style;
        var aspect = Aspect(request.Frame) switch { "portrait" => style.Aspects?.Portrait, "landscape" => style.Aspects?.Landscape, _ => style.Aspects?.Square };
        style = style with
        {
            Font = style.Font with { SizeSh = aspect?.SizeSh ?? style.Font.SizeSh },
            Position = style.Position with { X = aspect?.X ?? style.Position.X, Y = aspect?.Y ?? style.Position.Y },
            Layout = style.Layout with { MaxLineWidthW = aspect?.MaxLineWidthW ?? style.Layout.MaxLineWidthW, MaxWords = aspect?.MaxWords ?? style.Layout.MaxWords }
        };
        var patch = request.Captions.Overrides;
        if (patch.ValueKind != JsonValueKind.Undefined)
        {
            try
            {
                if (patch.ValueKind != JsonValueKind.Object || patch.EnumerateObject().Any(property => new[] { "$schema", "schemaVersion", "id", "name", "description", "order", "tags", "aspects", "preview" }.Contains(property.Name)))
                    throw new JsonException("Invalid caption patch.");
                var changes = JsonNode.Parse(patch.GetRawText())!.AsObject();
                if (!request.Style.Text.UserOverridable && changes["text"] is JsonObject text)
                {
                    text.Remove("transform");
                    text.Remove("punctuation");
                }
                var source = JsonSerializer.SerializeToNode(style, CaptionJsonContext.Default.CaptionStyle)!;
                style = Decode(Merge(source, changes)!.ToJsonString(), data);
            }
            catch (Exception exception) when (exception is not OperationCanceledException)
            {
                overridesRejected = true;
                Semantic(style, data);
            }
        }
        Semantic(style, data);
        var preset = Preset(request.Frame);
        var position = preset is not null && request.Captions.PositionByAspect.TryGetValue(preset, out var byAspect) ? byAspect : request.Captions.Position;
        if (position is { } stored && style.Position.UserDraggable) style = style with { Position = style.Position with { X = stored.X, Y = stored.Y } };
        return style;
    }

    private static JsonNode? Merge(JsonNode? target, JsonNode? patch)
    {
        if (patch is not JsonObject changes) return patch?.DeepClone();
        var result = target as JsonObject ?? new JsonObject();
        foreach (var property in changes)
        {
            if (property.Value is null) result.Remove(property.Key);
            else result[property.Key] = Merge(result[property.Key]?.DeepClone(), property.Value);
        }
        return result;
    }

    private static void Semantic(CaptionStyle style, CaptionData data)
    {
        if (!data.Fonts.TryGetValue(style.Font.File, out var font) || font.Family != style.Font.Family || font.Weight != style.Font.Weight || font.Italic != style.Font.Italic
            || style.Font.FallbackFiles.Any(file => !data.Fonts.ContainsKey(file)) || style.Emphasis?.FontFile is { } emphasisFont && !data.Fonts.ContainsKey(emphasisFont)) throw new JsonException("Invalid bundled caption font.");
        var serialized = JsonSerializer.SerializeToElement(style, CaptionJsonContext.Default.CaptionStyle);
        void Visit(JsonElement value)
        {
            if (value.ValueKind == JsonValueKind.String && value.GetString()!.StartsWith("$accent", StringComparison.Ordinal) && style.Accent is null) throw new JsonException("Caption accent is missing.");
            if (value.ValueKind == JsonValueKind.Array) foreach (var child in value.EnumerateArray()) Visit(child);
            if (value.ValueKind != JsonValueKind.Object) return;
            if (value.TryGetProperty("borderWidthEm", out var width) && width.GetDouble() > 0 && !value.TryGetProperty("borderColor", out _)) throw new JsonException("Caption border color is missing.");
            if (value.TryGetProperty("stops", out var stops))
            {
                var previous = -1.0;
                foreach (var stop in stops.EnumerateArray())
                {
                    var offset = stop.GetProperty("offset").GetDouble();
                    if (offset < previous) throw new JsonException("Caption gradient stops are not sorted.");
                    previous = offset;
                }
            }
            foreach (var child in value.EnumerateObject()) Visit(child.Value);
        }
        Visit(serialized);
        if (style.Words?.Past?.Box is not null || style.Words?.Future?.Box is not null || style.Reveal?.Cursor is not null && style.Reveal.Unit != CaptionRevealUnitValue.Char) throw new JsonException("Invalid caption word appearance.");
        if (style.Emphasis is { Source: not CaptionEmphasisSourceValue.None } emphasis && emphasis.Fill is null && emphasis.Palette is null && emphasis.FontFile is null && emphasis.Scale == 1) throw new JsonException("Caption emphasis has no visible effect.");
        if (style.Preview.ActiveWord >= style.Preview.Text.Split(' ', StringSplitOptions.RemoveEmptyEntries).Length) throw new JsonException("Caption preview word is out of range.");
    }
}
