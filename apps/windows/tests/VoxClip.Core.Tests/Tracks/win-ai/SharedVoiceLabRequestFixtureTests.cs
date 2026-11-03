using System.Text.Json.Nodes;
using VoxClip.Core.Domain.VoiceLab;
using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Services.LLM;
using VoxClip.Core.Services.VoiceLab;
using Xunit;
using static VoxClip.Core.Tests.Tracks.WinAi.AiTestSupport;

namespace VoxClip.Core.Tests.Tracks.WinAi;

public sealed partial class SharedFixtureTests
{
    [Theory]
    [InlineData("voice-rewrite-requests")]
    [InlineData("patch-rewrite-requests")]
    public async Task OptionalRewriteAnnotationsAreRequiredOnlyOnTheHttpWire(string fixture)
    {
        var expected = Load(fixture)["cases"]![0]!["expected"]!["request"]!;
        var canonical = expected["schema"]!.DeepClone().AsObject();
        var request = new LlmRequest(LlmFeature.VoiceRewrite, Text(expected, "system"), Text(expected, "cachedBlock"),
            Text(expected, "instruction"), Text(expected, "schemaName"), canonical, 16000, Effort.Medium,
            TimeSpan.FromSeconds(30), "en", "fixture");
        foreach (var provider in new[] { ConnectorId.OpenAI, ConnectorId.Xai, ConnectorId.LmStudio, ConnectorId.Anthropic, ConnectorId.Gemini, ConnectorId.Ollama })
        {
            using var client = new HttpClient(new StubHttp((_, _, _) => Task.FromResult(Response(200,
                "{\"model_info\":{\"model.context_length\":100000},\"capabilities\":[\"completion\"]}"))));
            var connector = new LlmConnector(provider, Catalog(), client, new MemoryKeys("synthetic-key"), new Redactor());
            var body = await connector.BodyAsync(request, "fixture-model", TestContext.Current.CancellationToken);
            var schema = provider switch
            {
                ConnectorId.OpenAI => body["text"]!["format"]!["schema"]!,
                ConnectorId.Anthropic => body["output_config"]!["format"]!["schema"]!,
                ConnectorId.Gemini => body["generationConfig"]!["responseJsonSchema"]!,
                ConnectorId.Ollama => body["format"]!,
                _ => body["response_format"]!["json_schema"]!["schema"]!
            };
            AssertStrictObjects(schema);
            EqualJson(expected["schema"], canonical);
        }
        var annotationOwner = fixture == "voice-rewrite-requests" ? canonical : canonical["properties"]!["edits"]!["items"]!;
        Assert.DoesNotContain(annotationOwner["required"]!.AsArray(), value => value!.GetValue<string>() == "audioTags");
    }

    private static void AssertStrictObjects(JsonNode schema)
    {
        if (schema["properties"] is JsonObject properties)
        {
            Assert.Equal(properties.Select(pair => pair.Key).Order(StringComparer.Ordinal),
                schema["required"]!.AsArray().Select(value => value!.GetValue<string>()).Order(StringComparer.Ordinal));
            foreach (var property in properties) AssertStrictObjects(property.Value!);
        }
        if (schema["items"] is { } items) AssertStrictObjects(items);
    }

    /// <summary><c>voice-rewrite-requests.json</c>: the case goes through <see cref="VoiceRewriteService"/>, and the request it sends must match.</summary>
    private static async Task VoiceRewriteRequestCase(JsonNode input, JsonNode expected)
    {
        var words = input["sourceWords"]!.AsArray().Select(word => Word(0, Text(word!, "text"), word!["start"]!.GetValue<double>(), word["end"]!.GetValue<double>()) with { Id = Text(word, "id") }).ToArray();
        var scope = Text(input, "scope") switch { "passage" => VoiceRewriteScope.Passage, "fullTake" => VoiceRewriteScope.FullTake, var other => throw new InvalidDataException(other) };
        var request = new VoiceRewriteRequest(Guid.NewGuid(), scope, words, Text(input, "instruction"), Text(input, "language"),
            input["targetSeconds"]!.GetValue<double>(), Integer(input, "minChars"), Integer(input, "maxChars"));
        var service = new VoiceRewriteService(Catalog());
        var connector = new CapturingLlmConnector("{\"rewrite\":\"Fine.\"}");
        var prepared = await service.PrepareAsync(request, connector, "chosen", TestContext.Current.CancellationToken);
        EqualEstimate(expected["estimate"]!, VoiceLabOperation.VoiceRewrite, prepared.Estimate);
        await service.ProposeAsync(request, connector, "chosen", service.Approve(prepared, true), TestContext.Current.CancellationToken);
        var sent = Assert.Single(connector.Requests);
        EqualVoiceLabRequest(expected["request"]!, sent);
        await EqualPreflight(expected["preflight"]!, sent, "{\"rewrite\":\"Fine.\"}", async stub =>
            await service.ProposeAsync(request, stub, "chosen", service.Approve(await service.PrepareAsync(request, stub, "chosen", TestContext.Current.CancellationToken), true),
                TestContext.Current.CancellationToken));
    }

    /// <summary><c>patch-rewrite-requests.json</c>: the case goes through <see cref="PatchRewriteService"/>, and the request it sends must match.</summary>
    private static async Task PatchRewriteRequestCase(JsonNode input, JsonNode expected)
    {
        var ranges = input["ranges"]!.AsArray().Select(range => new PatchRewriteLineRange(Text(range!, "line"), Integer(range!, "minChars"), Integer(range!, "maxChars"))).ToArray();
        var request = new PatchRewriteRequest(Guid.NewGuid(), Entries(input["entries"]!), ranges, Text(input, "instruction"), Text(input, "language"));
        var service = new PatchRewriteService(Catalog());
        var connector = new CapturingLlmConnector("{\"edits\":[]}");
        var prepared = await service.PrepareAsync(request, connector, "chosen", TestContext.Current.CancellationToken);
        EqualEstimate(expected["estimate"]!, VoiceLabOperation.PatchRewrite, prepared.Estimate);
        await service.ProposeAsync(request, connector, "chosen", service.Approve(prepared, true), TestContext.Current.CancellationToken);
        var sent = Assert.Single(connector.Requests);
        EqualVoiceLabRequest(expected["request"]!, sent);
        Assert.Equal("patch-rewrite", sent.Tag);
        await EqualPreflight(expected["preflight"]!, sent, "{\"edits\":[]}", async stub =>
            await service.ProposeAsync(request, stub, "chosen", service.Approve(await service.PrepareAsync(request, stub, "chosen", TestContext.Current.CancellationToken), true),
                TestContext.Current.CancellationToken));
    }

    /// <summary>ai.md §12.8: the case's send has the stated output cap, fits the smallest context the generator found, and a context
    /// one token smaller refuses it before any send.</summary>
    private static async Task EqualPreflight(JsonNode preflight, LlmRequest sent, string reply, Func<CapturingLlmConnector, Task> propose)
    {
        Assert.Equal(Integer(preflight, "maxOutputTokens"), sent.MaxOutputTokens);
        var smallest = Integer(preflight, "smallestContext");
        var fits = new CapturingLlmConnector(reply, context: smallest);
        await propose(fits);
        Assert.Single(fits.Requests);
        var refuses = new CapturingLlmConnector(reply, context: smallest - 1);
        Assert.Equal(LlmErrorKind.ContextTooLong, (await Assert.ThrowsAsync<LlmException>(() => propose(refuses))).Error.Kind);
        Assert.Empty(refuses.Requests);
    }

    /// <summary>voice-lab §8.9.1: the quote is <c>est()</c> of the whole rendered request, in tokens, at no known price.</summary>
    private static void EqualEstimate(JsonNode expected, VoiceLabOperation operation, VoiceLabEstimate estimate) =>
        Assert.Equal(new VoiceLabEstimate("openai", operation, expected["units"]!.GetValue<double>(), Text(expected, "unit"), null, null,
            Text(expected, "basis")), estimate);

    /// <summary>Prompt strings compare ordinally, which for well-formed text is the same as comparing their UTF-8 bytes.</summary>
    private static void EqualVoiceLabRequest(JsonNode expected, LlmRequest sent)
    {
        Assert.Equal(Text(expected, "feature"), LlmCatalog.FeatureId(sent.Feature));
        Assert.Equal(Text(expected, "system"), sent.System);
        Assert.Equal(Text(expected, "cachedBlock"), sent.CachedBlock);
        Assert.Equal(Text(expected, "instruction"), sent.Instruction);
        Assert.Equal(Text(expected, "schemaName"), sent.SchemaName);
        EqualJson(expected["schema"], sent.Schema);
        Assert.Equal(Text(expected, "effort"), sent.Effort?.ToString().ToLowerInvariant());
        Assert.Equal(Text(expected, "language"), sent.Language);
    }
}
