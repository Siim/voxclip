using System.Text.Json.Nodes;
using VoxClip.Core.Domain.VoiceLab;
using VoxClip.Core.Services.LLM;
using VoxClip.Core.Services.VoiceLab;
using Xunit;
using static VoxClip.Core.Tests.Tracks.WinAi.AiTestSupport;

namespace VoxClip.Core.Tests.Tracks.WinAi;

public sealed partial class SharedFixtureTests
{
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
