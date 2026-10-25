using System.Text.Json;
using System.Text.Json.Nodes;

namespace VoxClip.Core.Services.LLM;

internal static class LlmOutput
{
    internal static double Number(JsonNode value) => value is JsonValue scalar && scalar.TryGetValue<double>(out var number) ? number :
        double.Parse(value.ToJsonString(), System.Globalization.NumberStyles.Float, System.Globalization.CultureInfo.InvariantCulture);
    internal static JsonObject? Extract(string? text)
    {
        if (string.IsNullOrWhiteSpace(text)) return null;
        text = text.Trim();
        if (text.StartsWith("```", StringComparison.Ordinal))
        {
            var newline = text.IndexOf('\n');
            text = newline < 0 ? "" : text[(newline + 1)..].Trim();
            if (text.EndsWith("```", StringComparison.Ordinal)) text = text[..^3].TrimEnd();
        }
        if (Parse(text) is JsonObject whole) return whole;
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
            else if (character == '}' && --depth == 0) return Parse(text[start..(index + 1)]) as JsonObject;
        }
        return null;
    }

    internal static JsonNode? Parse(string text) { try { return JsonNode.Parse(text); } catch (JsonException) { return null; } }

    internal static (JsonObject? Object, int Dropped, string? Reason) Validate(RawCompletion raw, JsonObject schema)
    {
        var parsed = raw.Object is null ? Extract(raw.Text) : raw.Object as JsonObject;
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
