using System.Text.Json.Nodes;
using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Services.LLM;
using VoxClip.Core.Services.Process;
using Xunit;
using static VoxClip.Core.Tests.Tracks.WinAi.AiTestSupport;

namespace VoxClip.Core.Tests.Tracks.WinAi;

/// <summary>Images on the request (ai.md §19.3), twin of the Mac <c>HTTPImageRequestTests</c> and the image tests in
/// <c>CLIConnectorTests</c>: the catalogue's capability, each wire with images, and every request without images unchanged. Stub
/// transports and processes only.</summary>
[Trait("Track", "win-ai")]
public sealed class LlmImageTests
{
    internal static readonly LlmImage[] Images =
    [
        new("Frame 1 at 3.20 s", "image/jpeg", [0xFF, 0xD8, 0xFF, 0x01], 320, 180),
        new("Frame 2 at 7.45 s", "image/jpeg", [0xFF, 0xD8, 0xFF, 0x02], 320, 180),
    ];

    [Fact]
    public void TheCatalogueDeclaresWhichConnectorsTakeImages()
    {
        var catalog = Catalog();
        foreach (var id in new[] { ConnectorId.Anthropic, ConnectorId.OpenAI, ConnectorId.Xai, ConnectorId.Gemini, ConnectorId.ClaudeCode, ConnectorId.Codex })
        {
            Assert.True(catalog.SupportsImages(id), id.ToString());
            Assert.Equal(24, catalog.MaximumImages(id));
            Assert.True(((ILlmConnector)new LlmConnector(id, new MemoryKeys(), catalog, new Redactor())).SupportsImages, id.ToString());
        }
        foreach (var id in new[] { ConnectorId.Ollama, ConnectorId.LmStudio, ConnectorId.AppleFoundation })
        {
            Assert.False(catalog.SupportsImages(id), id.ToString());
            Assert.Equal(0, catalog.MaximumImages(id));
            Assert.Empty(catalog.Images(Request(id) with { Images = Images }, id));
        }
        // A request carries at most the connector's maximum; the rest are dropped.
        var many = Enumerable.Range(0, 30).Select(index => Images[0] with { Label = $"Frame {index + 1}" }).ToArray();
        Assert.Equal(24, catalog.Images(Request(ConnectorId.Anthropic) with { Images = many }, ConnectorId.Anthropic).Count);
        Assert.Equal(77, new LlmImage("F", "image/jpeg", [], 320, 180).EstimatedTokens);
        Assert.Equal(new[] { "--input-format", "--verbose" }, catalog.ImageRequiredFlags(ConnectorId.ClaudeCode));
    }

    private static async Task<JsonObject> BodyAsync(ConnectorId id, IReadOnlyList<LlmImage> images)
    {
        var catalog = Catalog();
        var model = catalog.Provider(id)["defaultModel"]?.GetValue<string>() ?? "local-test";
        using var handler = new StubHttp((request, _, _) => Task.FromResult(Response(200, request.RequestUri!.AbsolutePath == "/api/show"
            ? "{\"capabilities\":[\"completion\"],\"model_info\":{\"test.context_length\":32768}}" : Completion(id))));
        using var client = new HttpClient(handler) { Timeout = Timeout.InfiniteTimeSpan };
        var connector = new LlmConnector(id, catalog, client, new MemoryKeys(), new Redactor());
        await connector.SendAsync(Request(id) with { Images = images }, model, TestContext.Current.CancellationToken);
        return handler.Requests[^1].Body!;
    }

    [Theory]
    [InlineData(ConnectorId.Anthropic)]
    [InlineData(ConnectorId.OpenAI)]
    [InlineData(ConnectorId.Xai)]
    [InlineData(ConnectorId.Gemini)]
    [InlineData(ConnectorId.Ollama)]
    [InlineData(ConnectorId.LmStudio)]
    public async Task EachHttpWireShowsEveryImageAfterItsLabelAndTheRestIsUnchanged(ConnectorId id)
    {
        var plain = await BodyAsync(id, []);
        var shown = await BodyAsync(id, Images);
        var expected = plain.DeepClone().AsObject();
        var first = Convert.ToBase64String(Images[0].Data);
        var second = Convert.ToBase64String(Images[1].Data);
        switch (id)
        {
            case ConnectorId.Anthropic:
            {
                // After the cached block, before the instruction.
                var content = expected["messages"]![0]!["content"]!.AsArray();
                content.Insert(1, JsonNode.Parse("{\"type\":\"text\",\"text\":\"Frame 1 at 3.20 s\"}"));
                content.Insert(2, JsonNode.Parse("{\"type\":\"image\",\"source\":{\"type\":\"base64\",\"media_type\":\"image/jpeg\",\"data\":\"" + first + "\"}}"));
                content.Insert(3, JsonNode.Parse("{\"type\":\"text\",\"text\":\"Frame 2 at 7.45 s\"}"));
                content.Insert(4, JsonNode.Parse("{\"type\":\"image\",\"source\":{\"type\":\"base64\",\"media_type\":\"image/jpeg\",\"data\":\"" + second + "\"}}"));
                break;
            }
            case ConnectorId.OpenAI:
            {
                var content = expected["input"]![0]!["content"]!.AsArray();
                content.Insert(1, JsonNode.Parse("{\"type\":\"input_text\",\"text\":\"Frame 1 at 3.20 s\"}"));
                content.Insert(2, JsonNode.Parse("{\"type\":\"input_image\",\"image_url\":\"data:image/jpeg;base64," + first + "\",\"detail\":\"low\"}"));
                content.Insert(3, JsonNode.Parse("{\"type\":\"input_text\",\"text\":\"Frame 2 at 7.45 s\"}"));
                content.Insert(4, JsonNode.Parse("{\"type\":\"input_image\",\"image_url\":\"data:image/jpeg;base64," + second + "\",\"detail\":\"low\"}"));
                break;
            }
            case ConnectorId.Xai:
                expected["messages"]![1]!["content"] = JsonNode.Parse("[{\"type\":\"text\",\"text\":\"Frame 1 at 3.20 s\"},{\"type\":\"image_url\",\"image_url\":{\"url\":\"data:image/jpeg;base64," + first +
                    "\",\"detail\":\"low\"}},{\"type\":\"text\",\"text\":\"Frame 2 at 7.45 s\"},{\"type\":\"image_url\",\"image_url\":{\"url\":\"data:image/jpeg;base64," + second +
                    "\",\"detail\":\"low\"}},{\"type\":\"text\",\"text\":\"B\\n\\nI\"}]");
                break;
            case ConnectorId.Gemini:
            {
                var parts = expected["contents"]![0]!["parts"]!.AsArray();
                parts.Insert(1, JsonNode.Parse("{\"text\":\"Frame 1 at 3.20 s\"}"));
                parts.Insert(2, JsonNode.Parse("{\"inlineData\":{\"mimeType\":\"image/jpeg\",\"data\":\"" + first + "\"}}"));
                parts.Insert(3, JsonNode.Parse("{\"text\":\"Frame 2 at 7.45 s\"}"));
                parts.Insert(4, JsonNode.Parse("{\"inlineData\":{\"mimeType\":\"image/jpeg\",\"data\":\"" + second + "\"}}"));
                break;
            }
            // Text models: the frames go as the instruction's summary only, so the body is the one without images.
        }
        EqualJson(expected, shown);
    }

    // MARK: The CLIs

    private static (LlmConnector Connector, FixtureProcessRunner Runner) Cli(ConnectorId id, JsonObject? options = null)
    {
        var runner = new FixtureProcessRunner(id, Catalog(), options ?? new());
        var client = new HttpClient(new StubHttp((_, _, _) => throw new InvalidOperationException("CLI must not use HTTP.")));
        return (new LlmConnector(id, Catalog(), client, new MemoryKeys(null), new Redactor(), processes: runner, binaryOverride: runner.BinaryPath), runner);
    }

    private static LlmRequest CliRequest(ConnectorId id, bool cached = false) => Catalog().TestRequest(id) with { CachedBlock = cached ? "transcript" : null };

    [Fact]
    public async Task ClaudeImagesGoAsOneStreamJsonUserMessageAndTheLastResultIsRead()
    {
        var (connector, runner) = Cli(ConnectorId.ClaudeCode);
        using (runner)
        {
            var stream = string.Join("\n",
                """{"type":"system","subtype":"init","session_id":"s"}""",
                """{"type":"assistant","message":{"content":[{"type":"text","text":"{\"ok\":true}"}]}}""",
                """{"type":"result","is_error":false,"structured_output":{"ok":true,"echo":"voxclip"},"usage":{"input_tokens":2,"output_tokens":68}}""", "");
            runner.Override = command => command.Arguments.Contains("-p") ? new(0, stream, "", TimeSpan.Zero, false) : null;
            var request = CliRequest(ConnectorId.ClaudeCode, cached: true) with { Images = Images };
            var completion = await connector.SendAsync(request, "haiku", TestContext.Current.CancellationToken);
            EqualJson(JsonNode.Parse("""{"ok":true,"echo":"voxclip"}"""), completion.Object);
            Assert.Equal((2L, 68L), (completion.Usage!.Input, completion.Usage.Output));
            var generation = Assert.Single(runner.Requests, command => command.Arguments.Contains("-p"));
            var plain = await PlainClaudeAsync(cached: true);
            // The stream flags replace `--output-format json`; every other argument is the text send's.
            Assert.Equal(new[] { "-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose" }, generation.Arguments.Take(6));
            Assert.Equal(plain.Arguments.Skip(3), generation.Arguments.Skip(6));
            var first = Convert.ToBase64String(Images[0].Data);
            var second = Convert.ToBase64String(Images[1].Data);
            var message = "{\"message\":{\"content\":[{\"text\":\"Frame 1 at 3.20 s\",\"type\":\"text\"},{\"source\":{\"data\":\"" + first +
                "\",\"media_type\":\"image/jpeg\",\"type\":\"base64\"},\"type\":\"image\"},{\"text\":\"Frame 2 at 7.45 s\",\"type\":\"text\"},{\"source\":{\"data\":\"" + second +
                "\",\"media_type\":\"image/jpeg\",\"type\":\"base64\"},\"type\":\"image\"},{\"text\":" + JsonValue.Create(plain.StandardInput)!.ToJsonString(LlmJsonOptions) +
                ",\"type\":\"text\"}],\"role\":\"user\"},\"type\":\"user\"}";
            Assert.Equal(message + "\n", generation.StandardInput);
        }
    }

    private static readonly System.Text.Json.JsonSerializerOptions LlmJsonOptions = new() { Encoder = System.Text.Encodings.Web.JavaScriptEncoder.UnsafeRelaxedJsonEscaping };

    private static async Task<ProcessRequest> PlainClaudeAsync(bool cached, JsonObject? options = null)
    {
        var (connector, runner) = Cli(ConnectorId.ClaudeCode, options);
        using (runner)
        {
            await connector.SendAsync(CliRequest(ConnectorId.ClaudeCode, cached), "haiku", TestContext.Current.CancellationToken);
            return Assert.Single(runner.Requests, command => command.Arguments.Contains("-p"));
        }
    }

    [Fact]
    public async Task ClaudeWithoutTheStreamInputFlagsSendsTextAsBefore()
    {
        var plain = await PlainClaudeAsync(cached: false);
        Assert.Equal(new[] { "-p", "--output-format", "json", "--json-schema" }, plain.Arguments.Take(4));
        Assert.DoesNotContain("--verbose", plain.Arguments);
        Assert.DoesNotContain("--input-format", plain.Arguments);
        Assert.Equal(CliRequest(ConnectorId.ClaudeCode).Instruction, plain.StandardInput);
        // A CLI whose --help lacks --input-format gets the text send, images dropped.
        var catalog = Catalog();
        var help = catalog.Provider(ConnectorId.ClaudeCode)["cli"]!["detect"]!["help"]!;
        var flags = new JsonArray(help["requiredFlags"]!.AsArray().Concat(help["optionalFlags"]!.AsArray()).Select(flag => flag!.GetValue<string>())
            .Where(flag => flag != "--input-format").Select(flag => (JsonNode)JsonValue.Create(flag)!).ToArray());
        var (connector, runner) = Cli(ConnectorId.ClaudeCode, new JsonObject { ["supportedFlags"] = flags });
        using (runner)
        {
            await connector.SendAsync(CliRequest(ConnectorId.ClaudeCode) with { Images = Images }, "haiku", TestContext.Current.CancellationToken);
            var generation = Assert.Single(runner.Requests, command => command.Arguments.Contains("-p"));
            var withoutFlag = await PlainClaudeAsync(cached: false, new JsonObject { ["supportedFlags"] = flags.DeepClone() });
            Assert.Equal(withoutFlag.Arguments, generation.Arguments);
            Assert.Equal(withoutFlag.StandardInput, generation.StandardInput);
        }
    }

    [Fact]
    public async Task CodexAttachesImageFilesFromItsPrivateFolder()
    {
        var (connector, runner) = Cli(ConnectorId.Codex);
        using (runner)
        {
            var seen = new List<byte[]>();
            var io = "";
            runner.Override = command =>
            {
                var arguments = command.Arguments.ToList();
                var index = arguments.IndexOf("--image");
                if (index < 0) return null;
                for (var offset = 0; offset < Images.Length; offset++)
                {
                    var path = arguments[index + 1 + offset];
                    seen.Add(File.ReadAllBytes(path));
                    Assert.False(path.StartsWith(command.WorkingDirectory + Path.DirectorySeparatorChar, StringComparison.Ordinal), "images live outside the working directory");
                }
                io = Path.GetDirectoryName(arguments[index + 1])!;
                return new(0, "{\"type\":\"item.completed\",\"item\":{\"type\":\"agent_message\",\"text\":\"{\\\"ok\\\":true,\\\"echo\\\":\\\"voxclip\\\"}\"}}\n{\"type\":\"turn.completed\"}", "", TimeSpan.Zero, false);
            };
            var completion = await connector.SendAsync(CliRequest(ConnectorId.Codex) with { Images = Images }, "default", TestContext.Current.CancellationToken);
            Assert.Equal("{\"ok\":true,\"echo\":\"voxclip\"}", completion.Text);
            Assert.Equal(Images.Select(image => image.Data), seen);
            var generation = runner.Requests[^1];
            var arguments = generation.Arguments.ToList();
            Assert.Equal(Path.Combine(io, "frame-01.jpg"), arguments[arguments.IndexOf("--image") + 1]);
            Assert.Equal(Path.Combine(io, "frame-02.jpg"), arguments[arguments.IndexOf("--image") + 2]);
            Assert.Equal("--output-schema", arguments[arguments.IndexOf("--image") + 3]);
            Assert.Equal(Path.Combine(io, "schema.json"), arguments[arguments.IndexOf("--output-schema") + 1]);
            // The same arguments as the text send, with --image after the --disable flags and before --output-schema.
            var plain = await PlainCodexAsync();
            var expected = plain.Arguments.ToList();
            var schema = expected.IndexOf("--output-schema");
            var plainIo = Path.Combine(Path.GetDirectoryName(plain.WorkingDirectory)!, "io");
            expected.InsertRange(schema, ["--image", Path.Combine(plainIo, "frame-01.jpg"), Path.Combine(plainIo, "frame-02.jpg")]);
            Assert.Equal(Normalize(expected, plain), Normalize(arguments, generation));
            Assert.Equal("The attached images, in order:\nImage 1: Frame 1 at 3.20 s\nImage 2: Frame 2 at 7.45 s\n\n" + CliRequest(ConnectorId.Codex).Instruction, generation.StandardInput);
            Assert.False(Directory.Exists(io), "the io folder is removed with its images");
        }
    }

    /// <summary>The arguments with the send's own temporary folders named generically, so two sends compare.</summary>
    private static string[] Normalize(IEnumerable<string> arguments, ProcessRequest request)
    {
        var root = Path.GetDirectoryName(request.WorkingDirectory!)!;
        return arguments.Select(argument => argument.Replace(root, "<root>", StringComparison.Ordinal)).ToArray();
    }

    private static async Task<ProcessRequest> PlainCodexAsync()
    {
        var (connector, runner) = Cli(ConnectorId.Codex);
        using (runner)
        {
            await connector.SendAsync(CliRequest(ConnectorId.Codex), "default", TestContext.Current.CancellationToken);
            return runner.Generations[^1];
        }
    }

    [Fact]
    public async Task CodexWithoutImagesIsUnchanged()
    {
        var plain = await PlainCodexAsync();
        Assert.DoesNotContain("--image", plain.Arguments);
        Assert.Equal(CliRequest(ConnectorId.Codex).Instruction, plain.StandardInput);
    }
}
