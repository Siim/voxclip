using System.Text.Json;
using System.Text.Json.Serialization;
using System.Text.RegularExpressions;

namespace VoxClip.Core.Domain.Clips;

/// <summary>The camera fix (looks spec §5.4): Exposure, Temperature and Tint, -100 to 100. It corrects the picture before the
/// look and stays when the look changes. Twin of the Mac <c>ClipColorFix</c>.</summary>
public readonly partial record struct ClipColorFix(int Exposure, int Temperature, int Tint)
{
    /// <summary>No correction.</summary>
    public bool IsNeutral => Exposure == 0 && Temperature == 0 && Tint == 0;
}

/// <summary>One tone curve: five Y values in thousandths at x = 0, ¼, ½, ¾ and 1, never decreasing.</summary>
public readonly record struct ClipCurveChannel(int Y0, int Y1, int Y2, int Y3, int Y4)
{
    /// <summary>The five values in order.</summary>
    public IReadOnlyList<int> Values => [Y0, Y1, Y2, Y3, Y4];

    internal bool IsValid => Values.All(value => value is >= 0 and <= 1000) && Y0 <= Y1 && Y1 <= Y2 && Y2 <= Y3 && Y3 <= Y4;
}

/// <summary>A preset's tone curves (looks spec §5.6 stage T3): <paramref name="Master"/> on every channel, then the channel
/// curves. Data only; at least one is present. Twin of the Mac <c>ClipToneCurve</c>.</summary>
public sealed record ClipToneCurve(ClipCurveChannel? Master = null, ClipCurveChannel? Red = null, ClipCurveChannel? Green = null,
    ClipCurveChannel? Blue = null)
{
    internal bool IsValid => new[] { Master, Red, Green, Blue }.Any(channel => channel is not null) &&
        new[] { Master, Red, Green, Blue }.All(channel => channel?.IsValid != false);
}

/// <summary>A preset's split toning (looks spec §5.6 stage T4): hues 0-359, strengths 0-100, balance -100 to 100. Data only.</summary>
public sealed record ClipSplitTone(int ShadowHue, int ShadowSaturation, int HighlightHue, int HighlightSaturation, int Balance)
{
    internal bool IsValid => ShadowHue is >= 0 and <= 359 && HighlightHue is >= 0 and <= 359 && ShadowSaturation is >= 0 and <= 100 &&
        HighlightSaturation is >= 0 and <= 100 && Balance is >= -100 and <= 100;
}

/// <summary><c>clipControls[].colorGrade</c> (looks spec §8.1): the Fix, the newer look controls, Amount and a preset's toning in
/// whole points, stored expanded so a project is self-contained. It exists only when something is non-neutral; a preset alone
/// never creates it. Every slider key is written; <c>preset</c>, <c>curve</c> and <c>splitTone</c> are omitted when absent,
/// and <c>amount</c> at 100. Schema v8 only. Twin of the Mac <c>ClipColorGrade</c>.</summary>
[JsonConverter(typeof(ClipColorGradeJsonConverter))]
public sealed record ClipColorGrade
{
    /// <summary>The nine sliders' keys, in the order the file writes them.</summary>
    public static IReadOnlyList<string> Sliders { get; } = ["exposure", "temperature", "tint", "highlights", "shadows", "vibrance", "fade", "vignette", "grain"];

    /// <summary>Nothing to store.</summary>
    public static ClipColorGrade Neutral { get; } = new();

    /// <summary>The look these values came from, for display only; an ID this build doesn't know shows "Custom".</summary>
    public string? Preset { get; init; }
    /// <summary>The look's strength, 0-100%; the Fix always applies in full.</summary>
    public int Amount { get; init; } = 100;
    /// <summary>Exposure, -100 to 100 (±2 EV).</summary>
    public int Exposure { get; init; }
    /// <summary>Temperature, -100 to 100 (+ warmer).</summary>
    public int Temperature { get; init; }
    /// <summary>Tint, -100 to 100 (- green, + magenta).</summary>
    public int Tint { get; init; }
    /// <summary>Highlights, -100 to 100.</summary>
    public int Highlights { get; init; }
    /// <summary>Shadows, -100 to 100.</summary>
    public int Shadows { get; init; }
    /// <summary>Vibrance, -100 to 100.</summary>
    public int Vibrance { get; init; }
    /// <summary>Fade, 0-100.</summary>
    public int Fade { get; init; }
    /// <summary>Vignette, 0-100.</summary>
    public int Vignette { get; init; }
    /// <summary>Grain, 0-100.</summary>
    public int Grain { get; init; }
    /// <summary>A preset's tone curves.</summary>
    public ClipToneCurve? Curve { get; init; }
    /// <summary>A preset's split toning.</summary>
    public ClipSplitTone? SplitTone { get; init; }

    /// <summary>The Fix part.</summary>
    public ClipColorFix Fix => new(Exposure, Temperature, Tint);

    /// <summary>The same values with <paramref name="fix"/> as the Fix.</summary>
    public ClipColorGrade WithFix(ClipColorFix fix) => this with { Exposure = fix.Exposure, Temperature = fix.Temperature, Tint = fix.Tint };

    /// <summary>The values a look tile compares (spec §8.3): everything but the preset, the amount and the Fix.</summary>
    public ClipColorGrade LookValues => WithFix(default) with { Preset = null, Amount = 100 };

    /// <summary>Every slider 0, no toning and the full amount; the preset is ignored.</summary>
    public bool IsNeutral => Values().All(value => value == 0) && Curve is null && SplitTone is null && Amount == 100;

    internal IEnumerable<int> Values() => [Exposure, Temperature, Tint, Highlights, Shadows, Vibrance, Fade, Vignette, Grain];

    internal bool IsValid => !IsNeutral && Amount is >= 0 and <= 100 && Exposure is >= -100 and <= 100 && Temperature is >= -100 and <= 100 &&
        Tint is >= -100 and <= 100 && Highlights is >= -100 and <= 100 && Shadows is >= -100 and <= 100 && Vibrance is >= -100 and <= 100 &&
        Fade is >= 0 and <= 100 && Vignette is >= 0 and <= 100 && Grain is >= 0 and <= 100 && (Preset is null || IsPresetId(Preset)) &&
        Curve?.IsValid != false && SplitTone?.IsValid != false;

    internal static bool IsPresetId(string id) => Regex.IsMatch(id, "\\A[A-Za-z0-9]{1,40}\\z", RegexOptions.CultureInvariant, TimeSpan.FromSeconds(1));

    internal static bool IsAdding(string slider) => slider is "fade" or "vignette" or "grain";

    internal static bool IsFix(string slider) => slider is "exposure" or "temperature" or "tint";

    /// <summary>The strict reader both forms share (spec §8.1, §4.1); null for anything it refuses. A project's object
    /// (<paramref name="look"/> false) writes all nine sliders, omits <c>amount</c> at 100 and is never neutral. A preset's
    /// <c>grade</c> in clip-looks.json (<paramref name="look"/> true) holds only the look's own keys, a missing one meaning 0:
    /// never the Fix, an amount or a preset.</summary>
    internal static ClipColorGrade? Read(JsonElement value, bool look)
    {
        if (value.ValueKind != JsonValueKind.Object) return null;
        var sliders = Sliders.Where(name => !look || !IsFix(name)).ToArray();
        string[] optional = look ? ["curve", "splitTone"] : ["curve", "splitTone", "preset", "amount"];
        var names = value.EnumerateObject().Select(property => property.Name).ToList();
        if (names.Count != names.Distinct(StringComparer.Ordinal).Count() || names.Any(name => !sliders.Contains(name) && !optional.Contains(name))) return null;
        if (!look && sliders.Any(name => !names.Contains(name))) return null;
        var points = new Dictionary<string, int>(StringComparer.Ordinal);
        foreach (var name in sliders)
        {
            if (!value.TryGetProperty(name, out var raw)) continue;
            if (Integer(raw, IsAdding(name) ? 0 : -100, 100) is not { } point) return null;
            points[name] = point;
        }
        int Point(string name) => points.GetValueOrDefault(name);
        var grade = new ClipColorGrade
        {
            Exposure = Point("exposure"), Temperature = Point("temperature"), Tint = Point("tint"), Highlights = Point("highlights"),
            Shadows = Point("shadows"), Vibrance = Point("vibrance"), Fade = Point("fade"), Vignette = Point("vignette"), Grain = Point("grain")
        };
        if (value.TryGetProperty("preset", out var preset))
        {
            if (preset.ValueKind != JsonValueKind.String || preset.GetString() is not { } id || !IsPresetId(id)) return null;
            grade = grade with { Preset = id };
        }
        if (value.TryGetProperty("amount", out var amount))
        {
            if (Integer(amount, 0, 99) is not { } percent) return null;
            grade = grade with { Amount = percent };
        }
        if (value.TryGetProperty("curve", out var curve))
        {
            if (curve.ValueKind != JsonValueKind.Object) return null;
            var channels = new Dictionary<string, ClipCurveChannel>(StringComparer.Ordinal);
            foreach (var channel in curve.EnumerateObject())
            {
                if (channel.Name is not ("master" or "red" or "green" or "blue") || channels.ContainsKey(channel.Name) ||
                    channel.Value.ValueKind != JsonValueKind.Array || channel.Value.GetArrayLength() != 5) return null;
                var knots = channel.Value.EnumerateArray().Select(item => Integer(item, 0, 1000)).ToArray();
                if (knots.Any(knot => knot is null)) return null;
                channels[channel.Name] = new(knots[0]!.Value, knots[1]!.Value, knots[2]!.Value, knots[3]!.Value, knots[4]!.Value);
            }
            ClipCurveChannel? Channel(string name) => channels.TryGetValue(name, out var found) ? found : null;
            var tones = new ClipToneCurve(Channel("master"), Channel("red"), Channel("green"), Channel("blue"));
            if (!tones.IsValid) return null;
            grade = grade with { Curve = tones };
        }
        if (value.TryGetProperty("splitTone", out var split))
        {
            string[] keys = ["shadowHue", "shadowSaturation", "highlightHue", "highlightSaturation", "balance"];
            if (split.ValueKind != JsonValueKind.Object) return null;
            var present = split.EnumerateObject().Select(property => property.Name).ToArray();
            if (present.Length != keys.Length || !present.ToHashSet(StringComparer.Ordinal).SetEquals(keys)) return null;
            var parts = keys.Select(key => Integer(split.GetProperty(key), -100, 359)).ToArray();
            if (parts.Any(part => part is null)) return null;
            var tone = new ClipSplitTone(parts[0]!.Value, parts[1]!.Value, parts[2]!.Value, parts[3]!.Value, parts[4]!.Value);
            if (!tone.IsValid) return null;
            grade = grade with { SplitTone = tone };
        }
        return look || grade.IsValid ? grade : null;

        static int? Integer(JsonElement element, int low, int high) =>
            element.ValueKind == JsonValueKind.Number && element.TryGetDecimal(out var number) && decimal.Truncate(number) == number &&
            number >= low && number <= high ? (int)number : null;
    }
}

internal sealed class ClipColorGradeJsonConverter : JsonConverter<ClipColorGrade>
{
    public ClipColorGradeJsonConverter() { }

    public override ClipColorGrade Read(ref Utf8JsonReader reader, Type typeToConvert, JsonSerializerOptions options)
    {
        using var document = JsonDocument.ParseValue(ref reader);
        return ClipColorGrade.Read(document.RootElement, look: false)
            ?? throw new VoxClip.Core.Domain.Shared.VoxClipException(VoxClip.Core.Domain.Shared.VoxClipErrorCode.ProjectUnreadable, "Invalid clip controls.");
    }

    public override void Write(Utf8JsonWriter writer, ClipColorGrade value, JsonSerializerOptions options)
    {
        writer.WriteStartObject();
        if (value.Preset is { } preset) writer.WriteString("preset", preset);
        if (value.Amount != 100) writer.WriteNumber("amount", value.Amount);
        foreach (var (name, point) in ClipColorGrade.Sliders.Zip(value.Values())) writer.WriteNumber(name, point);
        if (value.Curve is { } curve)
        {
            writer.WriteStartObject("curve");
            foreach (var (name, channel) in new[] { ("master", curve.Master), ("red", curve.Red), ("green", curve.Green), ("blue", curve.Blue) })
            {
                if (channel is not { } knots) continue;
                writer.WriteStartArray(name);
                foreach (var knot in knots.Values) writer.WriteNumberValue(knot);
                writer.WriteEndArray();
            }
            writer.WriteEndObject();
        }
        if (value.SplitTone is { } split)
        {
            writer.WriteStartObject("splitTone");
            writer.WriteNumber("shadowHue", split.ShadowHue);
            writer.WriteNumber("shadowSaturation", split.ShadowSaturation);
            writer.WriteNumber("highlightHue", split.HighlightHue);
            writer.WriteNumber("highlightSaturation", split.HighlightSaturation);
            writer.WriteNumber("balance", split.Balance);
            writer.WriteEndObject();
        }
        writer.WriteEndObject();
    }
}
