using System.Text.Json.Nodes;
using VoxClip.Core.Domain.Clips;
using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Domain.VoiceLab;
using VoxClip.Core.Services.LLM;
using VoxClip.Core.Services.Process;
using VoxClip.Core.Services.VoiceLab;
using Xunit;
using static VoxClip.Core.Tests.Tracks.WinAi.AiTestSupport;

namespace VoxClip.Core.Tests.Tracks.WinAi;

public sealed class RewriteShorterFeedbackTests
{
    [Fact]
    public async Task RewriteServicesRetainOnlyValidStructuredExpressions()
    {
        const string annotations = "[{\"beforeToken\":2,\"tag\":\"laughs\"},{\"beforeToken\":1,\"tag\":\"shouts\"},{\"beforeToken\":99,\"tag\":\"sighs\"}]";
        var voice = new VoiceRewriteService(Catalog());
        var connector = new CapturingLlmConnector("{\"rewrite\":\"Go now.\",\"audioTags\":" + annotations + "}");
        var request = new VoiceRewriteRequest(Guid.NewGuid(), VoiceRewriteScope.Passage, [Word(0, "Leave now.", 0, 1)], "Keep my tone", "en", 1, 1, 50);
        var prepared = await voice.PrepareAsync(request, connector, "chosen", TestContext.Current.CancellationToken);
        var proposal = await voice.ProposeAsync(request, connector, "chosen", voice.Approve(prepared, true), TestContext.Current.CancellationToken);
        Assert.Equal(new VoiceLabAudioTag(2, "laughs"), Assert.Single(proposal.AudioTags));
        var patch = new PatchRewriteService(Catalog());
        connector = new CapturingLlmConnector("{\"edits\":[{\"line\":\"[0-0]\",\"text\":\"Go now.\",\"reason\":\"Shorter\",\"audioTags\":" + annotations + "}]}");
        var scoped = new PatchRewriteRequest(Guid.NewGuid(), [new ClipWord(0, "Leave now.", 0, 1)], [new("[0-0]", 1, 30)], "Shorter", "en");
        prepared = await patch.PrepareAsync(scoped, connector, "chosen", TestContext.Current.CancellationToken);
        var edits = await patch.ProposeAsync(scoped, connector, "chosen", patch.Approve(prepared, true), TestContext.Current.CancellationToken);
        Assert.Equal(proposal.AudioTags, Assert.Single(edits.Edits).AudioTags);
    }
    [Fact]
    public async Task MixedFeedbackKeepsMeasuredAndEstimatedPhraseLinesDistinct()
    {
        var service = new PatchRewriteService(Catalog());
        var connector = new CapturingLlmConnector("{\"edits\":[{\"line\":\"[0-0]\",\"text\":\"Go.\",\"reason\":\"Shorter\"}]}");
        var request = new PatchRewriteRequest(Guid.NewGuid(), [new ClipWord(0, "Go now.", 0, 1)], [new("[0-0]", 1, 30)], "Shorter", "en")
        { ShorterPhrases = [new("Go now.", "Go right now.", 1.8, 1.1) { MeasuredSeconds = 2.4 }, new("Stay.", "Stay here.", 1.5, 1.2)] };
        var prepared = await service.PrepareAsync(request, connector, "chosen", TestContext.Current.CancellationToken);
        var approval = service.Approve(prepared, true);
        var changed = request with { ShorterPhrases = [request.ShorterPhrases[0] with { MeasuredSeconds = 2.5 }, request.ShorterPhrases[1]] };
        await Assert.ThrowsAsync<VoiceLabException>(() => service.ProposeAsync(changed, connector, "chosen", approval, TestContext.Current.CancellationToken));
        Assert.Empty(connector.Requests);
        await service.ProposeAsync(request, connector, "chosen", approval, TestContext.Current.CancellationToken);
        var instruction = Assert.Single(connector.Requests).Instruction;
        Assert.Contains("Measured take: 2.4 s; slot: 1.1 s.", instruction);
        Assert.Contains("Estimated: 1.5 s; slot: 1.2 s.", instruction);
        Assert.DoesNotContain("Estimated: 1.8", instruction);
    }
    [Fact]
    public async Task MeasuredFeedbackUsesMeasuredTemplateNotEstimatedCopy()
    {
        var service = new VoiceRewriteService(Catalog());
        var connector = new CapturingLlmConnector("{\"rewrite\":\"Go.\"}");
        var timing = System.Text.Json.JsonSerializer.Deserialize<VoiceRewriteTimingFeedback>(
            "{\"Original\":\"Go now.\",\"Proposed\":\"Go right now.\",\"EstimateSeconds\":1.8,\"SlotSeconds\":1.1,\"MeasuredSeconds\":2.4}")!;
        var request = new VoiceRewriteRequest(Guid.NewGuid(), VoiceRewriteScope.Passage, [Word(0, "Go now.", 0, 1)],
            "Shorter", "en", 1, 1, 50) { ShorterPhrases = [timing] };
        var prepared = await service.PrepareAsync(request, connector, "chosen", TestContext.Current.CancellationToken);
        await service.ProposeAsync(request, connector, "chosen", service.Approve(prepared, true), TestContext.Current.CancellationToken);
        var sent = Assert.Single(connector.Requests);
        Assert.Contains("Measured take: 2.4 s; slot: 1.1 s.", sent.Instruction);
        Assert.Contains("measured take durations and timing estimates", sent.Instruction);
        Assert.DoesNotContain("Estimated: 1.8", sent.Instruction);
    }

    [Fact]
    public async Task ApprovedShorterFeedbackReachesOnlyTheStubCliAndCannotReuseAnOldApproval()
    {
        var catalog = Catalog();
        using var runner = new FixtureProcessRunner(ConnectorId.ClaudeCode, catalog, new());
        string? prompt = null;
        runner.Override = process =>
        {
            if (!process.Arguments.Contains("-p")) return null;
            prompt = process.StandardInput;
            return new ProcessResult(0, "{\"type\":\"result\",\"is_error\":false,\"structured_output\":{\"rewrite\":\"let's go.\"}}", "", TimeSpan.Zero, false);
        };
        using var http = new HttpClient(new StubHttp((_, _, _) => throw new InvalidOperationException("A text-only CLI send must not use HTTP.")));
        var connector = new LlmConnector(ConnectorId.ClaudeCode, catalog, http, new MemoryKeys(null), new Redactor(),
            processes: runner, binaryOverride: runner.BinaryPath);
        var service = new VoiceRewriteService(catalog);
        var original = new VoiceRewriteRequest(Guid.NewGuid(), VoiceRewriteScope.Passage, [Word(0, "and let's go.", 0, 1)],
            "Keep my casual tone", "en", 1, 1, 50);
        var previous = service.Approve(await service.PrepareAsync(original, connector, "default", TestContext.Current.CancellationToken), true);
        var shorter = original with { RequestId = Guid.NewGuid(), ShorterPhrases = [new("and let's go.", "then, well, let's get going.", 1.8, 1.1)] };
        await Assert.ThrowsAsync<VoiceLabException>(() => service.ProposeAsync(shorter, connector, "default", previous, TestContext.Current.CancellationToken));
        Assert.Null(prompt);
        var action = await service.PrepareAsync(shorter, connector, "default", TestContext.Current.CancellationToken);
        var result = await service.ProposeAsync(shorter, connector, "default", service.Approve(action, true), TestContext.Current.CancellationToken);
        Assert.Equal("let's go.", result.ProposedText);
        Assert.Contains("Original words: and let's go.", prompt);
        Assert.Contains("Proposed words: then, well, let's get going.", prompt);
        Assert.Contains("Estimated: 1.8 s; slot: 1.1 s.", prompt);
        Assert.Contains("Say it in fewer words; keep the other changes as they are.", prompt);
    }

    [Fact]
    public async Task ScopedShorterFeedbackPreservesTheInstructionLimitAndRendersLiteralPlaceholdersAsData()
    {
        var service = new PatchRewriteService(Catalog());
        var connector = new CapturingLlmConnector("{\"edits\":[{\"line\":\"[0-0]\",\"text\":\"Go.\",\"reason\":\"Shorter\"}]}");
        var request = new PatchRewriteRequest(Guid.NewGuid(), [new ClipWord(0, "Go now.", 0, 1)], [new("[0-0]", 1, 30)],
            new string('a', 1000), "en")
        {
            ShorterPhrases = [new("original {proposed}", "proposed {estimateSeconds}", 1.8, 1.1)]
        };
        var prepared = await service.PrepareAsync(request, connector, "chosen", TestContext.Current.CancellationToken);
        Assert.Empty(connector.Requests);
        var result = await service.ProposeAsync(request, connector, "chosen", service.Approve(prepared, true), TestContext.Current.CancellationToken);
        Assert.Equal("Go.", Assert.Single(result.Edits).Text);
        var sent = Assert.Single(connector.Requests);
        Assert.Contains("Original words: original {proposed}", sent.Instruction);
        Assert.Contains("Proposed words: proposed {estimateSeconds}", sent.Instruction);
        Assert.Contains(new string('a', 1000), sent.Instruction);
    }

    [Fact]
    public async Task FeedbackCannotExceedItsSeparateTwentyThousandByteBound()
    {
        var service = new VoiceRewriteService(Catalog());
        var connector = new CapturingLlmConnector("{\"rewrite\":\"Go.\"}");
        var request = new VoiceRewriteRequest(Guid.NewGuid(), VoiceRewriteScope.Passage, [Word(0, "Go now.", 0, 1)],
            "Shorter", "en", 1, 1, 50) { ShorterPhrases = [new(new string('é', 10_000), "go", 1.8, 1.1)] };
        await Assert.ThrowsAsync<VoiceLabException>(() => service.PrepareAsync(request, connector, "chosen", TestContext.Current.CancellationToken));
        Assert.Empty(connector.Requests);
    }
}
