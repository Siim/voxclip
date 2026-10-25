using System.Text.Json;
using System.Text.RegularExpressions;

namespace VoxClip.Core.Domain.Captions;

internal static class CaptionStyleValidation
{
    internal static void Validate(CaptionStyle style, JsonElement input)
    {
        CheckEncoding(input, JsonSerializer.SerializeToElement(style, CaptionJsonContext.Default.CaptionStyle), "");
        if (style.SchemaVersion != 1 || style.Id == "off") throw new JsonException("Invalid caption style identity.");
        Pattern(style.Id, @"^[a-z0-9][a-z0-9-]{1,39}\z");
        Length(style.Name, 1, 24);
        Length(style.Description, 1, 200);
        Range(style.Order, 0, 999);
        if (style.Tags.Distinct(StringComparer.Ordinal).Count() != style.Tags.Count) throw new JsonException("Duplicate caption tags.");
        foreach (var tag in style.Tags) Pattern(tag, @"^[a-z0-9-]+\z");
        if (style.Accent is { } accent) Color(accent, rgb: true);
        var font = style.Font;
        FontFile(font.File);
        Range(font.Weight, 100, 1000);
        Range(font.SizeSh, 0.01, 0.3);
        Range(font.SizeScale, 0.6, 1.6);
        Range(font.LetterSpacingEm, -0.2, 0.5);
        Range(font.WordSpacingEm, 0, 1);
        Range(font.LineHeightEm, 0.8, 2.5);
        Count(font.FallbackFiles.Count, 0, 3);
        foreach (var file in font.FallbackFiles) FontFile(file);
        var layout = style.Layout;
        Range(layout.MaxWords, 1, 16);
        Range(layout.MaxLines, 1, 3);
        Range(layout.MaxLineWidthW, 0.2, 1);
        Range(layout.MinShrink, 0.3, 1);
        Range(layout.BreakOnGapSec, 0, 10);
        Range(layout.MaxPageSec, 0.5, 30);
        Range(layout.HoldGapSec, 0, 5);
        Range(layout.MinPageSec, 0, 5);
        Range(layout.LineGapEm, 0, 2);
        Range(style.Position.X, 0, 1);
        Range(style.Position.Y, 0, 1);
        foreach (var aspect in new[] { style.Aspects?.Portrait, style.Aspects?.Square, style.Aspects?.Landscape })
        {
            if (aspect is null) continue;
            Range(aspect.SizeSh, 0.01, 0.3);
            Range(aspect.X, 0, 1);
            Range(aspect.Y, 0, 1);
            Range(aspect.MaxLineWidthW, 0.2, 1);
            Range(aspect.MaxWords, 1, 16);
        }
        Paint(style.Fill);
        if (style.Stroke is { } stroke)
        {
            Range(stroke.WidthEm, 0, 0.5);
            Color(stroke.Color);
        }
        Count(style.Shadows.Count, 0, 4);
        foreach (var shadow in style.Shadows)
        {
            Range(shadow.DxEm, -1, 1);
            Range(shadow.DyEm, -1, 1);
            Range(shadow.SigmaEm, 0, 1);
            Color(shadow.Color);
        }
        if (style.Box is { } box) Box(box.Color, box.PaddingXEm, box.PaddingYEm, box.RadiusEm, box.BorderWidthEm, box.BorderColor);
        foreach (var state in new[] { style.Words?.Past, style.Words?.Active, style.Words?.Future })
        {
            if (state is null) continue;
            if (state.Fill is { } fill) Paint(fill);
            Range(state.Opacity, 0, 1);
            Range(state.Scale, 0.5, 2);
            if (state.StrokeColor is { } color) Color(color);
            if (state.Box is { } wordBox) Box(wordBox.Color, wordBox.PaddingXEm, wordBox.PaddingYEm, wordBox.RadiusEm, wordBox.BorderWidthEm, wordBox.BorderColor);
        }
        if (style.Reveal is { } reveal)
        {
            Range(reveal.MaxCharsPerSec, 1, 200);
            if (reveal.Cursor is { } cursor)
            {
                Range(cursor.WidthEm, 0.01, 0.5);
                Color(cursor.Color);
                Range(cursor.BlinkHz, 0, 10);
            }
        }
        foreach (var animation in new[] { style.Animation?.PageIn, style.Animation?.PageOut, style.Animation?.WordIn, style.Animation?.ActiveIn })
        {
            if (animation is null) continue;
            Range(animation.DurationSec, 0, 2);
            Range(animation.FromScale, 0, 2);
            Range(animation.FromOffsetEm, -2, 2);
            Range(animation.Overshoot, 0, 4);
        }
        if (style.Emphasis is { } emphasis)
        {
            Range(emphasis.MaxPerPage, 0, 4);
            Range(emphasis.MinScore, 0, 10);
            Range(emphasis.Scale, 0.5, 2);
            if (emphasis.Fill is { } fill) Paint(fill);
            if (emphasis.Palette is { } palette)
            {
                Count(palette.Count, 1, 8);
                foreach (var color in palette) Color(color);
            }
            if (emphasis.FontFile is { } file) FontFile(file);
        }
        if (style.Emoji is { } emoji)
        {
            if (emoji.Placement != "above-page") throw new JsonException("Invalid caption emoji placement.");
            Range(emoji.SizeEm, 0.5, 3);
            Range(emoji.GapEm, 0, 1);
            Range(emoji.MaxPerPage, 0, 1);
        }
        if (style.Effects?.RgbSplit is { } split)
        {
            Range(split.OffsetEm, 0, 0.2);
            Color(split.LeftColor);
            Color(split.RightColor);
        }
        if (style.Effects?.Jitter is { } jitter)
        {
            Range(jitter.AmplitudeEm, 0, 0.1);
            Range(jitter.RateHz, 1, 60);
            Range(jitter.Seed, 0, uint.MaxValue);
        }
        Length(style.Preview.Text, 1, 60);
        Range(style.Preview.ActiveWord, 0, 15);
        Range(style.Preview.Progress, 0, 1);
        Color(style.Preview.Background, rgb: true);
    }

    private static void CheckEncoding(JsonElement input, JsonElement decoded, string path)
    {
        if (input.ValueKind == JsonValueKind.Null)
        {
            if (path is not "layout.breakOnGapSec" and not "layout.maxPageSec") throw new JsonException("Unexpected null caption property.");
            return;
        }
        if (input.ValueKind == JsonValueKind.Object && decoded.ValueKind == JsonValueKind.Object)
        {
            var names = new HashSet<string>(StringComparer.Ordinal);
            foreach (var property in input.EnumerateObject())
            {
                if (!names.Add(property.Name)) throw new JsonException("Duplicate caption property.");
                decoded.TryGetProperty(property.Name, out var child);
                CheckEncoding(property.Value, child, path.Length == 0 ? property.Name : path + "." + property.Name);
            }
            return;
        }
        if (input.ValueKind == JsonValueKind.Array && decoded.ValueKind == JsonValueKind.Array && input.GetArrayLength() == decoded.GetArrayLength())
        {
            for (var index = 0; index < input.GetArrayLength(); index++) CheckEncoding(input[index], decoded[index], path + "[]");
            return;
        }
        if (!JsonElement.DeepEquals(input, decoded)) throw new JsonException("Invalid caption value encoding.");
    }

    private static void Paint(CaptionPaint paint)
    {
        if (paint is SolidPaint solid) Color(solid.Color);
        else if (paint is LinearPaint linear)
        {
            Range(linear.AngleDeg, -360, 360);
            Count(linear.Stops.Count, 2, 5);
            foreach (var stop in linear.Stops)
            {
                Range(stop.Offset, 0, 1);
                Color(stop.Color, opaque: true);
            }
        }
        else throw new JsonException("Invalid caption paint.");
    }

    private static void Box(string color, double paddingX, double paddingY, double radius, double borderWidth, string? borderColor)
    {
        Color(color);
        Range(paddingX, 0, 2);
        Range(paddingY, 0, 2);
        Range(radius, 0, 2);
        Range(borderWidth, 0, 0.5);
        if (borderColor is not null) Color(borderColor);
    }

    private static void Color(string color, bool rgb = false, bool opaque = false)
    {
        var pattern = rgb ? @"^#[0-9A-Fa-f]{6}\z" : opaque ? @"^(#[0-9A-Fa-f]{6}([Ff]{2})?|\$accent)\z" : @"^(#[0-9A-Fa-f]{6}([0-9A-Fa-f]{2})?|\$accent(/[0-9A-Fa-f]{2})?)\z";
        Pattern(color, pattern);
    }

    private static void FontFile(string file) => Pattern(file, @"^[A-Za-z0-9_-]+\.ttf\z");
    private static void Pattern(string text, string pattern)
    {
        if (!Regex.IsMatch(text, pattern, RegexOptions.CultureInvariant, TimeSpan.FromSeconds(1))) throw new JsonException("Invalid caption string.");
    }
    private static void Length(string text, int minimum, int maximum) => Count(text.EnumerateRunes().Count(), minimum, maximum);
    private static void Count(int count, int minimum, int maximum)
    {
        if (count < minimum || count > maximum) throw new JsonException("Invalid caption collection length.");
    }
    private static void Range(double? value, double minimum, double maximum)
    {
        if (value is { } number && (!double.IsFinite(number) || number < minimum || number > maximum)) throw new JsonException("Caption number out of range.");
    }
}
