using System.Text.Json;
using System.Text.Json.Nodes;
using VoxClip.Core.Services.Project;

namespace VoxClip.Core.Services.LLM;

internal sealed class AgentChatPrompt
{
    internal string System { get; }
    internal string SchemaName { get; }
    internal JsonObject Schema { get; }
    private readonly JsonObject headings;
    private readonly string tools;

    internal AgentChatPrompt(string sharedRoot)
    {
        var prompt = JsonNode.Parse(File.ReadAllText(Path.Combine(sharedRoot, "prompts", "agent-chat.json")));
        if (prompt?["promptVersion"]?.GetValue<int>() != 1 || String(prompt["system"]) is not { } system ||
            prompt["request"] is not JsonObject request || String(prompt["output"]?["name"]) is not { } name ||
            prompt["output"]?["schema"] is not JsonObject schema ||
            schema["properties"]?["calls"]?["items"]?["properties"] is not JsonObject fields)
            throw Invalid("The agent chat prompt is missing or invalid.");
        System = system;
        SchemaName = name;
        headings = request;
        fields["args"] = JsonNode.Parse("""{"type":"object","additionalProperties":false,"required":["json"],"properties":{"json":{"type":"string"}}}""");
        Schema = LlmConnector.HttpStructuredSchema(schema).AsObject();
        tools = Text(Json(HarnessToolDefinition.AgentDefinitions(sharedRoot)));
    }

    internal string Instruction(JsonNode digest, JsonNode thread, JsonNode message, JsonNode results, JsonArray steering, string? feedback)
    {
        var sections = new (string Key, string Content)[]
        {
            ("tools", tools), ("project", Text(digest)), ("thread", Text(thread)),
            ("message", Text(message)), ("results", Text(results))
        };
        var blocks = sections.Select(section => $"{String(headings[section.Key]) ?? section.Key}\n{section.Content}").ToList();
        if (String(headings["strictArgs"]) is { } strictArgs) blocks.Add(strictArgs);
        if (steering.Count > 0) blocks.Add($"{String(headings["steer"]) ?? "Steer:"}\n{Text(steering)}");
        if (feedback is not null) blocks.Add(feedback);
        return string.Join("\n\n", blocks);
    }

    internal static string? String(JsonNode? node) => node is JsonValue value && value.TryGetValue<string>(out var text) ? text : null;
    internal static string Text(JsonNode? node) => node?.ToJsonString(LlmRuntime.CompactJson) ?? "null";
    internal static JsonNode? Json<T>(T value) => JsonSerializer.SerializeToNode(value, JsonSerializerOptions.Web);
    internal static LlmException Invalid(string detail) => LlmErrors.Create(LlmErrorKind.InvalidOutput, "", feature: LlmFeature.AgentChat, detail: detail);
}

internal sealed record AgentChatReply(string Say, IReadOnlyList<AgentChatReply.Call> Calls, bool Done, AgentChatSession.Question? Question, IReadOnlyList<string> Next)
{
    internal sealed record Call(string Tool, JsonObject Args);

    internal static AgentChatReply Read(RawCompletion raw)
    {
        static LlmException Invalid() => AgentChatPrompt.Invalid("Expected an agent_step with say, calls and done, and valid optional question and next fields.");
        var root = raw.Object is null ? LlmOutput.Extract(raw.Text) :
            LlmOutput.TryParse(raw.Object.ToJsonString(), out var parsed) ? parsed as JsonObject : null;
        if (raw.Stop is not StopKind.Complete || root is null || root.Any(field => field.Key is not ("say" or "calls" or "done" or "question" or "next")) ||
            AgentChatPrompt.String(root["say"]) is not { } say || say.EnumerateRunes().Count() > 600 ||
            root["calls"] is not JsonArray { Count: <= 6 } calls || root["done"] is not JsonValue doneValue || !doneValue.TryGetValue<bool>(out var done))
            throw Invalid();
        var steps = new List<Call>();
        foreach (var item in calls)
        {
            if (item is not JsonObject { Count: 2 } call || AgentChatPrompt.String(call["tool"]) is not { } tool || call["args"] is not JsonObject args)
                throw Invalid();
            if (args.Count == 1 && AgentChatPrompt.String(args["json"]) is { } text)
            {
                if (!LlmOutput.TryParse(text, out var read) || read is not JsonObject objectArgs) throw Invalid();
                args = objectArgs;
            }
            steps.Add(new(tool, args));
        }
        AgentChatSession.Question? question = null;
        if (root["question"] is { } questionNode)
        {
            if (questionNode is not JsonObject { Count: 2 } fields || AgentChatPrompt.String(fields["text"]) is not { } text ||
                fields["answers"] is not JsonArray { Count: >= 2 } answers || answers.Any(answer => AgentChatPrompt.String(answer) is null)) throw Invalid();
            question = new(text, answers.Select(answer => AgentChatPrompt.String(answer)!).ToArray());
        }
        IReadOnlyList<string> next = [];
        if (root.ContainsKey("next"))
        {
            if (root["next"] is not JsonArray { Count: <= 2 } items || items.Any(item => AgentChatPrompt.String(item) is null)) throw Invalid();
            next = items.Select(item => AgentChatPrompt.String(item)!).ToArray();
        }
        return new(say, steps, done, question, next);
    }
}
