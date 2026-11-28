using System.Text.Json.Nodes;

namespace VoxClip.Core.Services.Project;

/// <summary>Defines the tool schemas shared by the CLI and live agent chat.</summary>
public static class HarnessToolDefinition
{
    internal static IReadOnlyDictionary<string, HarnessTool> AgentTools { get; } = new Dictionary<string, HarnessTool>(StringComparer.Ordinal)
    {
        ["read_transcript"] = HarnessTool.ReadTranscript, ["read_clips"] = HarnessTool.ReadClips,
        ["read_takes"] = HarnessTool.ReadTakes, ["read_decisions"] = HarnessTool.ReadDecisions,
        ["read_frames"] = HarnessTool.ReadFrames, ["propose_timeline"] = HarnessTool.ProposeTimeline,
        ["check"] = HarnessTool.Check, ["find_music"] = HarnessTool.FindMusic,
        ["offer"] = HarnessTool.Offer, ["point_to"] = HarnessTool.PointTo
    };

    internal static object[] AgentDefinitions(string sharedRoot)
    {
        var definitions = JsonNode.Parse(File.ReadAllText(Path.Combine(sharedRoot, "schemas", "agent-tools.schema.json")))!["$defs"]!;
        return AgentTools.Select(tool => definitions[tool.Key] is JsonObject schema
            ? (object)new { name = tool.Key, inputSchema = schema } : Create(tool.Key, tool.Value, sharedRoot)).ToArray();
    }

    /// <summary>Builds the definition for a harness tool.</summary>
    public static object Create(string name, HarnessTool tool, string sharedRoot)
    {
        var (description, schema) = tool switch
        {
            HarnessTool.ReadTranscript => ("Read corrected transcript words with recording labels, project-clock times and zero-based item indices.",
                ObjectSchema(new { offset = new { type = "integer", minimum = 0 }, limit = new { type = "integer", minimum = 1, maximum = 500 },
                    recordingKey = new { type = "string", description = "Preview indices for a companion with a cached local transcript before proposing useRecording." } })),
            HarnessTool.ReadClips => ("List clips with kind, ordered parts, recordings, inclusive transcript indices and source spans.", ObjectSchema(new { })),
            HarnessTool.ReadTakes => ("Read matched beats, aligned spans, delivery signals and solo runs across spoken recordings.", ObjectSchema(new { })),
            HarnessTool.ReadDecisions => ("Read the clip's saved title context, framing, cover, captions, effects and music choices.",
                ObjectSchema(new { clipId = new { type = "string" } }, "clipId")),
            HarnessTool.ReadFrames => ("Decode one to four unedited JPEG thumbnails from the project's local video at source seconds.",
                ObjectSchema(new { times = new { type = "array", minItems = 1, maxItems = 4, items = new { type = "number", minimum = 0 } } }, "times")),
            HarnessTool.ProposeTimeline => ("Stage one to six timelines, each for Keep or Undo in VoxClip. Use newClip and ordered parts for a story or showreel. Never applies edits, sends data, spends money or captures consent.", TimelineSchema(sharedRoot)),
            _ => throw new HarnessException("Unknown tool or invalid call.")
        };
        return new { name, description, inputSchema = schema, annotations = new { readOnlyHint = tool != HarnessTool.ProposeTimeline, destructiveHint = false, openWorldHint = false } };
    }

    private static object ObjectSchema(object properties, params string[] required) => new { type = "object", additionalProperties = false, properties, required };

    private static object TimelineSchema(string root)
    {
        JsonObject Load(string file) => JsonNode.Parse(File.ReadAllText(Path.Combine(root, "schemas", file)))!.AsObject();
        var timeline = Load("harness-timeline.schema.json");
        var effect = Load("clip-plan-effect.schema.json");
        var template = Load("motion-template.schema.json");
        effect.Remove("$id");
        effect.Remove("$schema");
        template.Remove("$id");
        template.Remove("$schema");
        if (timeline["properties"]?["effects"] is not JsonObject effects ||
            effects["items"]?["$ref"]?.GetValue<string>() != "clip-plan-effect.schema.json" ||
            effect["properties"] is not JsonObject effectProperties)
            throw new HarnessException("The harness timeline schema is missing or invalid.");
        effectProperties["template"] = template;
        effects["items"] = effect;
        timeline.Remove("$id");
        timeline.Remove("$schema");
        var series = new JsonObject { ["type"] = "array", ["minItems"] = 1, ["maxItems"] = 6, ["items"] = timeline };
        var properties = timeline["properties"]!.DeepClone().AsObject();
        properties["timelines"] = series.DeepClone();
        return new { type = "object", properties, oneOf = new object[] { timeline,
            ObjectSchema(new { timelines = series }, "timelines") } };
    }
}
