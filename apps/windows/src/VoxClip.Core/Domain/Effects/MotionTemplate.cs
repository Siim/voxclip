using System.Globalization;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace VoxClip.Core.Domain.Effects;

/// <summary>A closed set of compositor graphics with bounded, local-only inputs.</summary>
public sealed record MotionTemplate
{
    /// <summary>The shared template identifier.</summary>
    public string Name { get; }
    /// <summary>Display text, or null for a counter.</summary>
    public string? Text { get; }
    /// <summary>The counter's starting value.</summary>
    public int From { get; }
    /// <summary>The counter's final value.</summary>
    public int To { get; }

    private MotionTemplate(string name, string? text = null, int from = 0, int to = 0) =>
        (Name, Text, From, To) = (name, text, from, to);

    internal static MotionTemplate? Read(JsonNode value)
    {
        using var document = JsonDocument.Parse(value.ToJsonString());
        return Read(document.RootElement);
    }

    internal static MotionTemplate? Read(JsonElement value)
    {
        if (value.ValueKind != JsonValueKind.Object || !value.TryGetProperty("name", out var nameValue) ||
            nameValue.ValueKind != JsonValueKind.String || nameValue.GetString() is not { } name) return null;
        var keys = value.EnumerateObject().Select(property => property.Name).ToArray();
        if (name == "counter")
        {
            if (keys.Length != 3 || !value.TryGetProperty("from", out var from) || !value.TryGetProperty("to", out var to) ||
                CounterValue(from) is not { } start || CounterValue(to) is not { } end) return null;
            return new(name, from: start, to: end);
        }
        if (name is not ("titleCard" or "kineticCaption" or "logoSting") || keys.Length != 2 ||
            !value.TryGetProperty("text", out var raw) || raw.ValueKind != JsonValueKind.String || raw.GetString() is not { Length: > 0 } text ||
            text != text.Trim() || text.EnumerateRunes().Count() > (name == "logoSting" ? 24 : 80) ||
            text.EnumerateRunes().Any(rune => Rune.GetUnicodeCategory(rune) is
                UnicodeCategory.Control or UnicodeCategory.LineSeparator or UnicodeCategory.ParagraphSeparator)) return null;
        return new(name, text);
    }

    private static int? CounterValue(JsonElement value) => value.ValueKind == JsonValueKind.Number &&
        value.TryGetDouble(out var number) && number is >= -999_999 and <= 999_999 && number == Math.Truncate(number) ? (int)number : null;

    /// <summary>The visible text and pose at a fraction of the source span.</summary>
    public (string Text, double Scale, double Down) Presentation(double progress)
    {
        progress = Math.Clamp(progress, 0, 1);
        switch (Name)
        {
            case "titleCard":
                var remaining = 1 - Math.Min(1, progress / 0.55);
                return (Text!, 1, 0.06 * remaining * remaining);
            case "kineticCaption":
                var words = Text!.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries);
                var reveal = Math.Min(1, progress / 0.75);
                var count = Math.Max(1, 1 + (int)(reveal * words.Length));
                return (string.Join(' ', words.Take(count)), 1, 0);
            case "logoSting":
                var entrance = Math.Min(1, progress / 0.65);
                var scale = entrance < 0.6 ? 0.64 + 0.46 * entrance / 0.6 : 1.10 - 0.10 * (entrance - 0.6) / 0.4;
                return (Text!, scale, 0);
            default:
                var fraction = Math.Min(1, progress / 0.68);
                var value = (int)Math.Round(From + (To - From) * fraction, MidpointRounding.AwayFromZero);
                return (value.ToString(CultureInfo.InvariantCulture), 1, 0);
        }
    }
}
