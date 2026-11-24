using System.CommandLine;
using System.Globalization;
using System.Text.Json;
using System.Text.Json.Nodes;
using VoxClip.Core.Services.Project;

namespace VoxClip.Cli;

internal static class HarnessCommands
{
    internal static JsonSerializerOptions JsonOptions => JsonSerializerOptions.Web;

    internal static bool IsHarness(string command) => command is "mcp" or "transcript" or "clips" or "decisions" or "frames" or "propose-timeline";

    internal static void Register(Command root)
    {
        var project = new Option<string>("--project") { Required = true, Description = "Path to one saved .voxclip project." };
        var offset = new Option<long>("--offset") { Description = "Zero-based transcript index." };
        var limit = new Option<int>("--limit") { Description = "Items per page, 1–500 (default 200).", DefaultValueFactory = _ => 200 };
        var clip = new Option<string>("--clip") { Required = true, Description = "Clip id from clips." };
        var times = new Option<string[]>("--time") { Required = true, Description = "Source seconds. Repeat up to four times." };

        Add("mcp", "Serve local tools over stdio for one saved .voxclip project.", null, null);
        Add("transcript", "Read a page of a project's timed transcript as JSON.", HarnessTool.ReadTranscript,
            (result, _) => Arguments(new { offset = result.GetValue(offset), limit = result.GetValue(limit) }), offset, limit);
        Add("clips", "List a project's clips as JSON.", HarnessTool.ReadClips, (_, _) => Arguments(new { }));
        Add("decisions", "Read a clip's saved decisions as JSON.", HarnessTool.ReadDecisions,
            (result, _) => Arguments(new { clipId = result.GetValue(clip) }), clip);
        Add("frames", "Read local JPEG thumbnails at source times as JSON.", HarnessTool.ReadFrames,
            (result, _) => Arguments(new { times = result.GetValue(times)!.Select(SourceTime).ToArray() }), times);
        Add("propose-timeline", "Read a JSON timeline on stdin and stage it for review in VoxClip.", HarnessTool.ProposeTimeline,
            (_, ct) => ReadTimelineAsync(ct));

        void Add(string name, string description, HarnessTool? tool,
            Func<ParseResult, CancellationToken, Task<JsonElement>>? arguments, params Option[] options)
        {
            var command = new Command(name, description);
            command.Options.Add(project);
            foreach (var option in options) command.Options.Add(option);
            root.Subcommands.Add(command);
            command.SetAction(async (result, ct) =>
            {
                var scope = await HarnessProject.OpenAsync(result.GetValue(project)!, ct).ConfigureAwait(false);
                if (tool is { } selected)
                {
                    var request = await arguments!(result, ct).ConfigureAwait(false);
                    var reply = await scope.CallAsync(selected, request, ct).ConfigureAwait(false);
                    await WriteAsync(reply.CliOutput, ct).ConfigureAwait(false);
                }
                else await new HarnessSession(scope, SharedResources.ResolveRoot()).RunAsync(ct).ConfigureAwait(false);
                return 0;
            });
        }

        static Task<JsonElement> Arguments(object arguments) => Task.FromResult(JsonSerializer.SerializeToElement(arguments, JsonOptions));
        static double SourceTime(string text) => double.TryParse(text, NumberStyles.Float, CultureInfo.InvariantCulture, out var time) && double.IsFinite(time)
            ? time : throw new HarnessException("Give one to four source times inside the video.");
    }

    internal static async Task WriteAsync(object message, CancellationToken ct)
    {
        await Console.Out.WriteLineAsync(JsonSerializer.Serialize(message, JsonOptions).AsMemory(), ct).ConfigureAwait(false);
        await Console.Out.FlushAsync(ct).ConfigureAwait(false);
    }

    private static async Task<JsonElement> ReadTimelineAsync(CancellationToken ct)
    {
        using var input = Console.OpenStandardInput();
        var bytes = new byte[HarnessProposal.MaximumBytes + 1];
        var count = await input.ReadAtLeastAsync(bytes, bytes.Length, false, ct).ConfigureAwait(false);
        if (count > HarnessProposal.MaximumBytes) throw new HarnessException("This timeline proposal is too large.");
        using var document = JsonDocument.Parse(bytes.AsMemory(0, count));
        return document.RootElement.Clone();
    }
}

internal sealed class HarnessSession(HarnessProject project, string sharedRoot)
{
    private static readonly string[] Versions = ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"];
    private static readonly Dictionary<string, HarnessTool> Tools = new(StringComparer.Ordinal)
    {
        ["read_transcript"] = HarnessTool.ReadTranscript, ["read_clips"] = HarnessTool.ReadClips,
        ["read_decisions"] = HarnessTool.ReadDecisions, ["read_frames"] = HarnessTool.ReadFrames,
        ["propose_timeline"] = HarnessTool.ProposeTimeline
    };
    private readonly object[] definitions = Tools.Select(tool => Definition(tool.Key, tool.Value, sharedRoot)).ToArray();
    private bool initialized;

    internal async Task RunAsync(CancellationToken ct)
    {
        using var input = Console.OpenStandardInput();
        var block = new byte[8192];
        var line = new byte[HarnessProposal.MaximumBytes];
        var written = 0;
        var discard = false;
        while (await input.ReadAsync(block, ct).ConfigureAwait(false) is > 0 and var read)
        {
            for (var start = 0; start < read;)
            {
                var newline = Array.IndexOf(block, (byte)'\n', start, read - start);
                var end = newline < 0 ? read : newline;
                if (!discard && end - start > line.Length - written)
                {
                    await HarnessCommands.WriteAsync(Error(null, -32700, "Message is too large."), ct).ConfigureAwait(false);
                    discard = true;
                }
                if (!discard)
                {
                    block.AsSpan(start, end - start).CopyTo(line.AsSpan(written));
                    written += end - start;
                }
                if (newline < 0) break;
                if (!discard && written > 0 && await ReceiveAsync(line.AsMemory(0, written), ct).ConfigureAwait(false) is { } reply)
                    await HarnessCommands.WriteAsync(reply, ct).ConfigureAwait(false);
                discard = false;
                written = 0;
                start = end + 1;
            }
        }
    }

    private async Task<object?> ReceiveAsync(ReadOnlyMemory<byte> bytes, CancellationToken ct)
    {
        try
        {
            using var document = JsonDocument.Parse(bytes);
            var request = document.RootElement;
            if (request.ValueKind != JsonValueKind.Object || String(request, "jsonrpc") != "2.0" || String(request, "method") is not { } method)
                return Error(null, -32600, "Invalid request.");
            if (!request.TryGetProperty("id", out var id)) return null;
            if (id.ValueKind != JsonValueKind.String && !(id.ValueKind == JsonValueKind.Number && double.IsInteger(id.GetDouble())))
                return Error(null, -32600, "Invalid request id.");
            id = id.Clone();
            var hasParams = request.TryGetProperty("params", out var fields);
            if (hasParams && fields.ValueKind != JsonValueKind.Object) return Error(id, -32602, "Expected an object for params.");
            if (method == "initialize")
            {
                if (String(fields, "protocolVersion") is not { } asked) return Error(id, -32602, "Missing protocol version.");
                initialized = true;
                return Reply(id, new
                {
                    protocolVersion = Versions.Contains(asked) ? asked : Versions[0], capabilities = new { tools = new { } },
                    serverInfo = new { name = "voxclip", version = CliApplication.Version },
                    instructions = "Read the saved VoxClip project. Only VoxClip can keep edits or run priced actions."
                });
            }
            if (method == "ping") return Reply(id, new { });
            if (!initialized) return Error(id, -32002, "Initialize first.");
            if (method == "tools/list") return hasParams && fields.EnumerateObject().Any()
                ? Error(id, -32602, "There is no tools cursor.") : Reply(id, new { tools = definitions });
            if (method != "tools/call") return Error(id, -32601, "Method not found.");
            if (String(fields, "name") is not { } name || !Tools.TryGetValue(name, out var tool) ||
                fields.EnumerateObject().Any(field => field.Name is not ("name" or "arguments" or "_meta")))
                return Error(id, -32602, "Unknown tool or invalid call.");
            fields.TryGetProperty("arguments", out var arguments);
            try
            {
                var result = await project.CallAsync(tool, arguments, ct).ConfigureAwait(false);
                var content = new List<object> { Text(JsonSerializer.Serialize(result.Fields, HarnessCommands.JsonOptions)) };
                if (result.Frames is not null)
                    content.AddRange(result.Frames.Select(frame => new { type = "image", mimeType = "image/jpeg", data = frame.Jpeg }));
                return Reply(id, new { content, structuredContent = result.Fields });
            }
            catch (HarnessException error) { return Reply(id, new { isError = true, content = new[] { Text(error.Message) } }); }
            catch (Exception) when (!ct.IsCancellationRequested)
            {
                return Reply(id, new { isError = true, content = new[] { Text("VoxClip couldn't read the selected project or stage this timeline.") } });
            }
        }
        catch (JsonException) { return Error(null, -32700, "Invalid JSON."); }
    }

    private static string? String(JsonElement owner, string name) => owner.ValueKind == JsonValueKind.Object &&
        owner.TryGetProperty(name, out var value) && value.ValueKind == JsonValueKind.String ? value.GetString() : null;

    private static object Definition(string name, HarnessTool tool, string sharedRoot)
    {
        var (description, schema) = tool switch
        {
            HarnessTool.ReadTranscript => ("Read a page of the project's transcript, including corrected text, source times and zero-based item indices.",
                ObjectSchema(new { offset = new { type = "integer", minimum = 0 }, limit = new { type = "integer", minimum = 1, maximum = 500 } })),
            HarnessTool.ReadClips => ("List kept and suggested clips, with their inclusive transcript indices and source spans.", ObjectSchema(new { })),
            HarnessTool.ReadDecisions => ("Read the clip's saved title context, framing, cover, captions, effects and music choices.",
                ObjectSchema(new { clipId = new { type = "string" } }, "clipId")),
            HarnessTool.ReadFrames => ("Decode one to four unedited JPEG thumbnails from the project's local video at source seconds.",
                ObjectSchema(new { times = new { type = "array", minItems = 1, maxItems = 4, items = new { type = "number", minimum = 0 } } }, "times")),
            _ => ("Stage a timeline for Keep or Undo in VoxClip. Never applies edits, sends data, spends money or captures consent.", TimelineSchema(sharedRoot))
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
        if (timeline["properties"]?["effects"]?["items"]?["allOf"] is not JsonArray constraints ||
            effect["properties"] is not JsonObject effectProperties)
            throw new HarnessException("The harness timeline schema is missing or invalid.");
        effectProperties["template"] = template;
        constraints[0] = effect;
        return timeline;
    }

    private static object Text(string text) => new { type = "text", text };
    private static object Reply(JsonElement id, object result) => new { jsonrpc = "2.0", id, result };
    private static object Error(JsonElement? id, int code, string message) => new { jsonrpc = "2.0", id, error = new { code, message } };
}
