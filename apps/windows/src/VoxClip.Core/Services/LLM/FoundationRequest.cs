using System.Text.Json.Nodes;

namespace VoxClip.Core.Services.LLM;

internal static class FoundationRequest
{
    internal static JsonObject Logical(LlmRequest request, int macOsMajor, int? clipBudget) => new()
    {
        ["kind"] = "logical", ["model"] = "system", ["timeoutSeconds"] = request.Timeout.TotalSeconds,
        ["session"] = new JsonObject { ["fresh"] = true, ["instructions"] = request.System },
        ["prompt"] = LlmConnector.UserContent(request),
        ["schema"] = new JsonObject { ["root"] = Map(request.Schema, request.SchemaName, clipBudget), ["dependencies"] = new JsonArray() },
        ["options"] = new JsonObject { [macOsMajor >= 27 ? "samplingMode" : "sampling"] = "greedy", ["maximumResponseTokens"] = Math.Min(1500, request.MaxOutputTokens) },
        ["language"] = request.Language
    };

    private static JsonObject Map(JsonObject schema, string name, int? clipBudget, string? propertyName = null) => schema["type"]!.GetValue<string>() switch
    {
        "object" => new JsonObject
        {
            ["name"] = name,
            ["properties"] = new JsonArray(schema["properties"]!.AsObject().Select(property => (JsonNode)new JsonObject
            {
                ["name"] = property.Key, ["schema"] = Map(property.Value!.AsObject(), name + "_" + property.Key, clipBudget, property.Key), ["isOptional"] = false
            }).ToArray())
        },
        "array" => new JsonObject { ["arrayOf"] = Map(schema["items"]!.AsObject(), name + "_item", clipBudget), ["maximumElements"] = propertyName == "clips" ? clipBudget : null },
        "string" when schema["enum"] is { } values => new JsonObject { ["name"] = name, ["anyOf"] = values.DeepClone() },
        "string" => new JsonObject { ["type"] = "String" },
        "integer" => new JsonObject { ["type"] = "Int" },
        "number" => new JsonObject { ["type"] = "Double" },
        "boolean" => new JsonObject { ["type"] = "Bool" },
        _ => throw new ArgumentException("Unsupported canonical JSON schema type.", nameof(schema))
    };
}
