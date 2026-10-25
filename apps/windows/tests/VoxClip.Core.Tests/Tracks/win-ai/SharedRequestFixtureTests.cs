using System.Text.Json.Nodes;
using VoxClip.Core.Domain.Clips;
using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Services.LLM;
using VoxClip.Core.Services.Process;
using Xunit;
using static VoxClip.Core.Tests.Tracks.WinAi.AiTestSupport;

namespace VoxClip.Core.Tests.Tracks.WinAi;

public sealed partial class SharedFixtureTests
{
    private static ConnectorId Connector(string value) => Enum.GetValues<ConnectorId>().Single(id => LlmCatalog.WireId(id) == value);
    private static LlmFeature Feature(string value) => value switch { "clipFinder" => LlmFeature.ClipFinder, "aiTighten" => LlmFeature.AiTighten, "test" => LlmFeature.Test, _ => throw new InvalidDataException(value) };
    private static LlmRequest ReadRequest(JsonNode node) => new(Feature(Text(node, "feature")), Text(node, "system"), node["cachedBlock"]?.GetValue<string>(), Text(node, "instruction"), Text(node, "schemaName"), node["schema"]!.DeepClone().AsObject(), Integer(node, "maxOutputTokens"), node["effort"] is null ? null : Enum.Parse<Effort>(Text(node, "effort"), true), TimeSpan.FromSeconds(30), node["language"]?.GetValue<string>(), "fixture");
    private static JsonObject Canonical(LlmRequest request) => new()
    {
        ["feature"] = request.Feature switch { LlmFeature.ClipFinder => "clipFinder", LlmFeature.AiTighten => "aiTighten", _ => "test" },
        ["system"] = request.System, ["cachedBlock"] = request.CachedBlock, ["instruction"] = request.Instruction,
        ["schemaName"] = request.SchemaName, ["schema"] = request.Schema.DeepClone(), ["maxOutputTokens"] = request.MaxOutputTokens,
        ["effort"] = request.Effort?.ToString().ToLowerInvariant(), ["language"] = request.Language
    };

    private static async Task RenderCase(string file, JsonNode input, JsonNode expected)
    {
        var prompts = new ClipPrompts(Catalog());
        var source = input["entries"] ?? Load("format-transcript")["cases"]!.AsArray().Single(item => Text(item!, "id") == Text(input, "transcript"))!["input"]!["entries"]!;
        var fullLines = ClipText.Lines(Entries(source));
        var windowInfo = input["window"];
        var selected = windowInfo is null ? fullLines : fullLines.Skip(Integer(windowInfo, "firstLine")).Take(Integer(windowInfo, "lastLine") - Integer(windowInfo, "firstLine") + 1).ToArray();
        var window = new ClipWindow(selected, 0, 0, 0);
        var count = windowInfo is null ? 1 : Integer(windowInfo, "count");
        var instructions = prompts.Instructions(Text(input, "instructions"));
        var choice = Text(input, "choice");
        if (expected["error"] is not null)
        {
            Assert.Equal("needInstructions", Text(expected, "error"));
            var calls = 0;
            var finder = new ClipFinder(Catalog(), new MemoryKeys(null), new Redactor(), _ => { calls++; throw new InvalidOperationException(); });
            var failure = await Assert.ThrowsAsync<ClipFinderGateException>(() => finder.FindClipsAsync(new(WordsFrom(source), new Dictionary<string, string>(), new HashSet<string>(), ClipPreset.Custom, instructions, "en", ConnectorId.OpenAI, "model", DryRun: true), null, CancellationToken.None));
            Assert.Equal(ClipFinderGateKind.NeedInstructions, failure.Kind);
            Assert.Equal(Text(expected, "message"), failure.UserMessage);
            Assert.Equal(0, calls);
            return;
        }
        LlmRequest request;
        if (file == "ai-tighten-requests") request = prompts.TightenRequest(selected, prompts.TightenInstruction(choice, instructions, window, count), input["language"]?.GetValue<string>());
        else
        {
            var preset = Enum.Parse<ClipPreset>(choice, true);
            var instruction = prompts.Instruction(preset, instructions, Entries(source)[^1].End, window, count, windowInfo is null ? 0 : Integer(windowInfo, "maxClips"), windowInfo?["lastEnd"]?.GetValue<int>());
            request = prompts.Request(new(WordsFrom(source), new Dictionary<string, string>(), new HashSet<string>(), preset, instructions, input["language"]?.GetValue<string>(), ConnectorId.OpenAI, "model"), selected, instruction, windowInfo is null ? 1 : Integer(windowInfo, "index") + 1, count);
        }
        EqualJson(expected["request"], Canonical(request));
        foreach (var mapping in expected["connectors"]!.AsObject()) await ConnectorCase(request, mapping.Key, input["connectorOptions"]![mapping.Key]!.AsObject(), mapping.Value!);
    }

    private static async Task ConnectorCase(LlmRequest request, string connectorName, JsonObject options, JsonNode expected)
    {
        var id = Connector(connectorName);
        var catalog = Catalog();
        var model = options["model"]?.GetValue<string>() ?? catalog.Provider(id)["defaultModel"]?.GetValue<string>() ?? throw new InvalidDataException("A local fixture must select a model.");
        var timeoutKind = request.Feature == LlmFeature.Test ? id is ConnectorId.ClaudeCode or ConnectorId.Codex ? "cliTest" : "test" : id is ConnectorId.ClaudeCode or ConnectorId.Codex ? "cli" : id is ConnectorId.Ollama or ConnectorId.LmStudio ? "localServer" : id == ConnectorId.AppleFoundation ? "appleFoundation" : "cloud";
        request = request with { Timeout = catalog.Timeout(timeoutKind) };
        Assert.Equal(Text(expected, "model"), model);
        Assert.Equal(Number(expected["timeoutSeconds"]!), request.Timeout.TotalSeconds);
        if (id == ConnectorId.AppleFoundation)
        {
            EqualJson(expected, FoundationRequest.Logical(request, Integer(options, "macOSMajor", 27), options["clipBudget"]?.GetValue<int>()));
            return;
        }
        if (id is ConnectorId.ClaudeCode or ConnectorId.Codex) { await CliFixture(request, id, model, catalog, options, expected); return; }
        if (options["serverSideFallback"] is { } beta && catalog.Model(id, model) is { } modelInfo) modelInfo["serverSideFallback"] = beta.DeepClone();
        using var handler = new StubHttp((message, _, _) =>
        {
            if (message.RequestUri!.AbsolutePath == "/api/show") return Task.FromResult(Response(200, new JsonObject { ["model_info"] = new JsonObject { ["model.context_length"] = Integer(options, "modelContext", 4096) }, ["capabilities"] = options["capabilities"]?.DeepClone() ?? new JsonArray("completion") }.ToJsonString()));
            if (message.Method == HttpMethod.Get) return Task.FromResult(Response(200, new JsonObject { ["data"] = new JsonArray(new JsonObject { ["id"] = model, ["capabilities"] = new JsonObject { ["effort"] = new JsonObject { ["supported"] = options["effortSupported"]?.DeepClone() ?? JsonValue.Create(false) }, ["structured_outputs"] = new JsonObject { ["supported"] = options["structuredOutputsSupported"]?.DeepClone() ?? JsonValue.Create(true) } } }) }.ToJsonString()));
            return Task.FromResult(Response(200, Completion(id)));
        });
        using var client = new HttpClient(handler);
        var adapter = new LlmConnector(id, catalog, client, new MemoryKeys("<key>"), new Redactor(), baseUrl: options["baseUrl"]?.GetValue<string>());
        if (options.ContainsKey("effortSupported") || options.ContainsKey("structuredOutputsSupported")) await adapter.GetModelsAsync(true, CancellationToken.None);
        await adapter.SendAsync(request, model, CancellationToken.None);
        var wire = handler.Requests[^1];
        Assert.Equal("POST", Text(expected, "method"));
        Assert.Equal(Text(expected, "url"), wire.Url);
        EqualJson(expected["body"], wire.Body);
        var headers = new JsonObject();
        foreach (var header in wire.Headers.Where(header => !header.Key.Equals("User-Agent", StringComparison.OrdinalIgnoreCase))) headers[header.Key.ToLowerInvariant()] = header.Value;
        var expectedHeaders = new JsonObject();
        foreach (var header in expected["headers"]!.AsObject()) expectedHeaders[header.Key.ToLowerInvariant()] = header.Value!.DeepClone();
        EqualJson(expectedHeaders, headers);
        Assert.Equal($"VoxClip/{LlmRuntime.Version} ({(OperatingSystem.IsWindows() ? "Windows" : "macOS")})", wire.Headers["User-Agent"]);
    }

    private static async Task CliFixture(LlmRequest request, ConnectorId id, string model, LlmCatalog catalog, JsonObject options, JsonNode expected)
    {
        using var runner = new FixtureProcessRunner(id, catalog, options);
        using var client = new HttpClient(new StubHttp((_, _, _) => throw new InvalidOperationException("CLI must not use HTTP.")));
        var adapter = new LlmConnector(id, catalog, client, new MemoryKeys(null), new Redactor(), processes: runner, binaryOverride: runner.BinaryPath);
        if (options["supportedEfforts"] is not null) await adapter.GetModelsAsync(true, CancellationToken.None);
        await adapter.SendAsync(request, model, CancellationToken.None);
        var process = Assert.Single(runner.Generations);
        var cwd = process.WorkingDirectory!;
        var argv = process.Arguments.ToArray();
        var schemaIndex = System.Array.IndexOf(argv, "--output-schema");
        var io = schemaIndex < 0 ? null : Path.GetDirectoryName(argv[schemaIndex + 1]);
        string Normalize(string text) => (io is null ? text : text.Replace(io, "<io>", StringComparison.Ordinal).Replace("<io>" + Path.DirectorySeparatorChar, "<io>/", StringComparison.Ordinal)).Replace(cwd, "<cwd>", StringComparison.Ordinal);
        Assert.Equal(Text(expected, "executable"), OperatingSystem.IsWindows() ? Path.GetFileNameWithoutExtension(process.Executable) : Path.GetFileName(process.Executable));
        EqualJson(expected["argv"], Array(argv.Select(argument => (JsonNode)JsonValue.Create(Normalize(argument))!)));
        Assert.Equal(Text(expected, "stdin"), process.StandardInput);
        Assert.Equal("<cwd>", Normalize(cwd));
        var files = new JsonObject();
        foreach (var file in runner.GenerationFiles) files[Normalize(file.Key)] = file.Value;
        EqualJson(expected["files"], files);
        foreach (var file in runner.GenerationBytes) Assert.Equal(System.Text.Encoding.UTF8.GetBytes(Text(expected["files"]!, Normalize(file.Key))), file.Value);
        Assert.False(Directory.Exists(cwd));
        if (io is not null) Assert.False(Directory.Exists(io));
        Assert.All(runner.Requests, command =>
        {
            Assert.NotNull(command.WorkingDirectory);
            Assert.False(Directory.Exists(command.WorkingDirectory));
            if (command.Environment is not null) Assert.All(command.Environment.Keys, name => Assert.Equal("PATH", name));
        });
    }
}

internal sealed class FixtureProcessRunner : IProcessRunner, IDisposable
{
    private readonly ConnectorId id;
    private readonly LlmCatalog catalog;
    private readonly JsonObject options;
    private readonly string directory = Path.Combine(Path.GetTempPath(), "voxclip-fake-cli-" + Guid.NewGuid().ToString("N"));
    internal string BinaryPath { get; }
    internal List<ProcessRequest> Requests { get; } = [];
    internal List<ProcessRequest> Generations { get; } = [];
    internal Dictionary<string, string> GenerationFiles { get; } = [];
    internal Dictionary<string, byte[]> GenerationBytes { get; } = [];
    internal Func<ProcessRequest, ProcessResult?>? Override { get; set; }
    internal FixtureProcessRunner(ConnectorId id, LlmCatalog catalog, JsonObject options)
    {
        this.id = id; this.catalog = catalog; this.options = options;
        Directory.CreateDirectory(directory);
        BinaryPath = Path.Combine(directory, (id == ConnectorId.ClaudeCode ? "claude" : "codex") + (OperatingSystem.IsWindows() ? ".exe" : ""));
        File.WriteAllText(BinaryPath, "fake-runner-placeholder");
    }
    public Task<ProcessResult> RunAsync(ProcessRequest request, IProgress<ProcessProgress>? progress, CancellationToken ct)
    {
        ct.ThrowIfCancellationRequested(); Requests.Add(request);
        Assert.Empty(Directory.EnumerateFileSystemEntries(request.WorkingDirectory!));
        if (Override?.Invoke(request) is { } replacement) return Task.FromResult(replacement);
        var args = request.Arguments;
        string output;
        if (request.Executable == "/bin/zsh") output = "/usr/bin:/bin";
        else if (args.Contains("--version")) output = id == ConnectorId.ClaudeCode ? "2.2.0" : "codex-cli 0.120.0";
        else if (args.Contains("--help")) output = options["supportedFlags"] is JsonArray flags ? string.Join("\n", flags.Select(value => value!.GetValue<string>())) : string.Join("\n", catalog.Provider(id)["cli"]!["detect"]!["help"]!["requiredFlags"]!.AsArray().Concat(catalog.Provider(id)["cli"]!["detect"]!["help"]!["optionalFlags"]!.AsArray()).Select(value => value!.GetValue<string>()));
        else if (args.Contains("features")) output = string.Join("\n", (options["features"] as JsonArray ?? catalog.Provider(id)["cli"]!["disableFeatures"]!.AsArray()).Select(value => value is JsonObject feature ? feature["name"]!.GetValue<string>() + " " + feature["stage"]!.GetValue<string>() + " true" : value!.GetValue<string>() + " stable true"));
        else if (args.Contains("auth")) output = "{\"loggedIn\":true,\"authMethod\":\"oauth\"}";
        else if (args.Contains("login")) output = "Logged in using ChatGPT";
        else if (args.Contains("app-server")) output = new JsonObject { ["id"] = 2, ["result"] = new JsonObject { ["data"] = new JsonArray(new JsonObject { ["id"] = options["model"]?.DeepClone() ?? JsonValue.Create("default"), ["supportedReasoningEfforts"] = new JsonArray((options["supportedEfforts"] as JsonArray ?? []).Select(value => (JsonNode)new JsonObject { ["reasoningEffort"] = value!.DeepClone() }).ToArray()) }) } }.ToJsonString();
        else
        {
            Generations.Add(request);
            var index = args.ToList().IndexOf("--output-schema");
            if (index >= 0)
            {
                GenerationFiles[args[index + 1]] = File.ReadAllText(args[index + 1]);
                GenerationBytes[args[index + 1]] = File.ReadAllBytes(args[index + 1]);
            }
            output = id == ConnectorId.ClaudeCode ? "{\"type\":\"result\",\"is_error\":false,\"structured_output\":{\"ok\":true,\"echo\":\"voxclip\"}}" : "{\"type\":\"item.completed\",\"item\":{\"type\":\"agent_message\",\"text\":\"{\\\"ok\\\":true,\\\"echo\\\":\\\"voxclip\\\"}\"}}\n{\"type\":\"turn.completed\"}";
        }
        return Task.FromResult(new ProcessResult(0, output, "", TimeSpan.FromMilliseconds(1), false));
    }
    public void Dispose() => Directory.Delete(directory, true);
}
