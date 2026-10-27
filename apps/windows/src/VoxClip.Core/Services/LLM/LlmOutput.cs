using System.Globalization;
using System.Text.Json;
using System.Text.Json.Nodes;
using VoxClip.Core.Domain.Editing;

namespace VoxClip.Core.Services.LLM;

internal static class LlmOutput
{
    /// <summary>A reply holds at most 64 levels of nesting (ai.md §4.5), the System.Text.Json default.</summary>
    internal const int ReplyMaxDepth = 64;
    /// <summary>A transport envelope may nest a reply one level down, so it may go 512 levels deep (ai.md §4.5).</summary>
    internal const int EnvelopeMaxDepth = 512;

    internal static double Number(JsonNode value) => value is JsonValue scalar && scalar.TryGetValue<double>(out var number) ? number :
        double.Parse(value.ToJsonString(), NumberStyles.Float, CultureInfo.InvariantCulture);

    internal static long? CliInteger(JsonNode? value) => value is JsonValue scalar && scalar.TryGetValue<double>(out var number) &&
        double.IsFinite(number) && number == Math.Truncate(number) && number >= -9223372036854775808d && number < 9223372036854775808d ? (long)number : null;

    /// <summary>ai.md §4.5: drop a code fence, parse the whole text, and only when that fails take the first balanced object. A
    /// whole text that parses as something other than an object holds no object (§2.3). Trimming uses JavaScript's whitespace,
    /// and every delimiter is one UTF-16 unit, so this reads the same Unicode scalars as the Mac.</summary>
    internal static JsonObject? Extract(string? text, int maxDepth = ReplyMaxDepth)
    {
        text = EditingAlgorithms.JsTrim(text ?? "");
        if (text.StartsWith("```", StringComparison.Ordinal))
        {
            var newline = text.IndexOf('\n');
            text = newline < 0 ? "" : text[(newline + 1)..];
            var rest = EditingAlgorithms.JsTrim(text);
            if (rest.EndsWith("```", StringComparison.Ordinal)) text = rest[..^3];
        }
        if (TryParse(text, out var whole, maxDepth)) return whole as JsonObject;
        var start = text.IndexOf('{');
        if (start < 0) return null;
        var depth = 0;
        var quoted = false;
        var escaped = false;
        for (var index = start; index < text.Length; index++)
        {
            var character = text[index];
            if (quoted)
            {
                if (escaped) escaped = false;
                else if (character == '\\') escaped = true;
                else if (character == '"') quoted = false;
            }
            else if (character == '"') quoted = true;
            else if (character == '{') depth++;
            else if (character == '}' && --depth == 0) return TryParse(text[start..(index + 1)], out var found, maxDepth) ? found as JsonObject : null;
        }
        return null;
    }

    /// <summary>A transport envelope (ai.md §4.5): an HTTP response body, the Claude CLI result, a Codex exec or app-server line,
    /// the model cache file or Claude auth output. It is one strict parse of the whole text after jsTrim, at most 512 levels
    /// deep, with no code fence or balanced-object scan.</summary>
    internal static JsonNode? Envelope(string? text) => TryParse(EditingAlgorithms.JsTrim(text ?? ""), out var node, EnvelopeMaxDepth) ? node : null;

    /// <summary>The strict parse of ai.md §4.5: one RFC 8259 value within <paramref name="maxDepth"/> levels, where every
    /// string, key names and the values of repeated keys included, is well-formed UTF-16 and every number is a finite double;
    /// a non-zero number that rounds to zero does not fit either. A repeated key keeps its first value, as on the Mac.</summary>
    internal static bool TryParse(string text, out JsonNode? node, int maxDepth = ReplyMaxDepth)
    {
        node = null;
        try
        {
            using var document = JsonDocument.Parse(text, new JsonDocumentOptions { MaxDepth = maxDepth });
            node = Build(document.RootElement);
            return true;
        }
        catch (Exception exception) when (exception is JsonException or ArgumentException or InvalidOperationException or FormatException)
        {
            return false;
        }
    }

    private static JsonNode? Build(JsonElement element)
    {
        switch (element.ValueKind)
        {
            case JsonValueKind.Object:
                var result = new JsonObject();
                var normalizedKeys = new Dictionary<string, string>(StringComparer.Ordinal);
                foreach (var property in element.EnumerateObject())
                {
                    // Reading the name and building the value check both, even when a repeated key's value is then unused.
                    var name = property.Name;
                    var value = Build(property.Value);
                    var normalized = EditingAlgorithms.Nfc(name);
                    if (normalizedKeys.TryGetValue(normalized, out var previous) && !string.Equals(previous, name, StringComparison.Ordinal))
                        throw new FormatException("Object keys are canonically equivalent but byte-different.");
                    normalizedKeys.TryAdd(normalized, name);
                    if (!result.ContainsKey(name)) result.Add(name, value);
                }
                return result;
            case JsonValueKind.Array:
                var array = new JsonArray();
                foreach (var item in element.EnumerateArray()) array.Add(Build(item));
                return array;
            case JsonValueKind.String:
                return JsonValue.Create(element.GetString()!);
            case JsonValueKind.Number:
                var raw = element.GetRawText();
                if (raw.Length > 1024 || !double.TryParse(raw, NumberStyles.Float, CultureInfo.InvariantCulture, out var number) || !double.IsFinite(number) ||
                    number == 0 && raw.TakeWhile(character => character is not ('e' or 'E')).Any(character => character is >= '1' and <= '9'))
                    throw new FormatException("The number does not fit a double.");
                return JsonValue.Create(element.Clone());
            case JsonValueKind.True:
                return JsonValue.Create(true);
            case JsonValueKind.False:
                return JsonValue.Create(false);
            default:
                return null;
        }
    }

    /// <summary>ai.md §2.3. A reply object a connector already parsed goes through the same strict parse as text, and nothing a
    /// malformed reply can do escapes as anything but "not JSON".</summary>
    internal static (JsonObject? Object, int Dropped, string? Reason) Validate(RawCompletion raw, JsonObject schema)
    {
        try
        {
            var parsed = raw.Object is null ? Extract(raw.Text) : TryParse(raw.Object.ToJsonString(), out var reparsed) ? reparsed as JsonObject : null;
            if (parsed is null) return (null, 0, "not JSON");
            var result = parsed.DeepClone().AsObject();
            var dropped = 0;
            foreach (var property in schema["properties"]!.AsObject())
            {
                var propertySchema = property.Value!.AsObject();
                var value = result[property.Key];
                if (propertySchema["type"]!.GetValue<string>() == "array")
                {
                    if (value is not JsonArray array) return (null, 0, $"missing \"{property.Key}\"");
                    var valid = new JsonArray();
                    foreach (var item in array)
                        if (Matches(item, propertySchema["items"]!.AsObject())) valid.Add(item?.DeepClone()); else dropped++;
                    result[property.Key] = valid;
                }
                else if (!Matches(value, propertySchema)) return (null, 0, $"missing \"{property.Key}\"");
            }
            return (result, dropped, null);
        }
        catch (Exception exception) when (exception is ArgumentException or InvalidOperationException)
        {
            return (null, 0, "not JSON");
        }
    }

    private static bool Matches(JsonNode? value, JsonObject schema)
    {
        if (value is null) return false;
        var kind = value.GetValueKind();
        return schema["type"]!.GetValue<string>() switch
        {
            "object" => value is JsonObject obj && schema["required"]!.AsArray().All(name => obj.ContainsKey(name!.GetValue<string>())) &&
                schema["properties"]!.AsObject().All(property => Matches(obj[property.Key], property.Value!.AsObject())),
            "array" => value is JsonArray array && array.All(item => Matches(item, schema["items"]!.AsObject())),
            "integer" or "number" => kind == JsonValueKind.Number,
            "string" => kind == JsonValueKind.String && (schema["enum"] is not JsonArray choices || choices.Any(choice => choice!.GetValue<string>() == value.GetValue<string>())),
            "boolean" => kind is JsonValueKind.True or JsonValueKind.False,
            _ => false
        };
    }
}
