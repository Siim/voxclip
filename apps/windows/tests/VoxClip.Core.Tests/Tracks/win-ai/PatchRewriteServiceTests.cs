using System.Text.Json.Nodes;
using VoxClip.Core.Domain.Clips;
using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Domain.VoiceLab;
using VoxClip.Core.Services.LLM;
using VoxClip.Core.Services.VoiceLab;
using Xunit;
using static VoxClip.Core.Tests.Tracks.WinAi.AiTestSupport;

namespace VoxClip.Core.Tests.Tracks.WinAi;

/// <summary>Fix with AI (voice-lab §8.1, path 3) from <c>shared/fixtures/voice-lab/patch-rewrite-cases.json</c>, with canned replies only.</summary>
[Trait("Track", "win-ai")]
public sealed class PatchRewriteServiceTests
{
    internal static JsonObject Cases() => VoiceRewriteBudgetTests.VoiceLabFixture("patch-rewrite-cases.json");

    internal static PatchRewriteRequest Request(JsonObject document, string instruction = "I said 2024; it's 2025.", JsonNode? entries = null,
        JsonNode? ranges = null) =>
        new(Guid.NewGuid(),
            (entries ?? document["entries"])!.AsArray().Select(entry => new ClipWord(entry!["index"]!.GetValue<int>(), entry["text"]!.GetValue<string>(),
                entry["start"]!.GetValue<double>(), entry["end"]!.GetValue<double>())).ToArray(),
            (ranges ?? document["ranges"])!.AsArray().Select(range => new PatchRewriteLineRange(range!["line"]!.GetValue<string>(),
                range["minChars"]!.GetValue<int>(), range["maxChars"]!.GetValue<int>())).ToArray(),
            instruction, document["language"]!.GetValue<string>());

    private static async Task<PatchRewriteProposal> Propose(PatchRewriteService service, PatchRewriteRequest request, CapturingLlmConnector connector,
        string model = "chosen")
    {
        var approval = service.Approve(await service.PrepareAsync(request, connector, model, TestContext.Current.CancellationToken), true);
        return await service.ProposeAsync(request, connector, model, approval, TestContext.Current.CancellationToken);
    }

    private static StopKind? Stop(JsonNode item) => item["stop"]?.GetValue<string>() is { } stop ? VoiceRewriteBudgetTests.Stop(stop) : null;

    private static LlmErrorKind Kind(JsonNode error) => error.GetValue<string>() switch
    {
        "invalidOutput" => LlmErrorKind.InvalidOutput, "refused" => LlmErrorKind.Refused, "truncated" => LlmErrorKind.Truncated,
        var other => throw new InvalidDataException(other)
    };

    [Fact]
    public async Task SharedBehaviourCases()
    {
        var document = Cases();
        var cases = document["cases"]!.AsArray();
        Assert.Equal(72, cases.Count);
        foreach (var item in cases)
        {
            var id = item!["id"]!.GetValue<string>();
            var expected = item["expected"]!;
            var request = Request(document, item["instruction"]!.GetValue<string>(), item["entries"], item["ranges"]);
            var connector = new CapturingLlmConnector(item["reply"]!.GetValue<string>(), stop: Stop(item));
            if (item["rewriteExpected"] is { } rewrite) await RewriteCase(id, item, rewrite, request);
            if (expected["error"] is { } error)
            {
                var thrown = await Assert.ThrowsAsync<LlmException>(() => Propose(new PatchRewriteService(Catalog()), request, connector));
                Assert.True(thrown.Error.Kind == Kind(error), id + ": " + error.GetValue<string>());
                continue;
            }
            var proposal = await Propose(new PatchRewriteService(Catalog()), request, connector);
            Assert.True(connector.Requests.Count == 1, id + ": one send");
            Assert.True(proposal.UnknownLines == expected["unknownLines"]!.GetValue<int>(), id + ": unknownLines");
            Assert.True(proposal.DuplicateLines == expected["duplicateLines"]!.GetValue<int>(), id + ": duplicateLines");
            Assert.True(proposal.MalformedItems == expected["malformedItems"]!.GetValue<int>(), id + ": malformedItems");
            Assert.True(proposal.CheckThisMessage == document["copy"]!["checkThis"]!.GetValue<string>(), id + ": badge copy");
            var edits = expected["edits"]!.AsArray();
            Assert.True(proposal.Edits.Count == edits.Count, id + ": edit count");
            foreach (var (edit, want) in proposal.Edits.Zip(edits))
            {
                Assert.True(edit.Line == want!["line"]!.GetValue<string>(), id + ": line");
                Assert.True(edit.Text == want["text"]!.GetValue<string>(), id + ": text kept as sent");
                Assert.True(edit.Reason == want["reason"]!.GetValue<string>(), id + ": reason");
                Assert.True(edit.Length == want["length"]!.GetValue<int>(), id + ": length");
                Assert.True(edit.InRange == want["inRange"]!.GetValue<bool>(), id + ": inRange");
                Assert.True(edit.CheckThis == want["checkThis"]!.GetValue<bool>(), id + ": checkThis");
                Assert.True(edit.IsDeletion == want["isDeletion"]!.GetValue<bool>(), id + ": isDeletion");
            }
        }
    }

    /// <summary>The same reply through <see cref="VoiceRewriteService"/>, for a passage of the case's words: both services read a reply
    /// with one strict parse, so they agree on what is invalid output.</summary>
    private static async Task RewriteCase(string id, JsonNode item, JsonNode expected, PatchRewriteRequest patch)
    {
        var words = patch.Entries.Select(entry => Word(entry.Index, entry.Text, entry.Start, entry.End)).ToArray();
        var request = new VoiceRewriteRequest(Guid.NewGuid(), VoiceRewriteScope.Passage, words, patch.Instruction, patch.Language, 4.0, 10, 40);
        var connector = new CapturingLlmConnector(item["reply"]!.GetValue<string>(), stop: Stop(item));
        var service = new VoiceRewriteService(Catalog());
        var approval = service.Approve(await service.PrepareAsync(request, connector, "chosen", TestContext.Current.CancellationToken), true);
        Task<VoiceRewriteProposal> Send() => service.ProposeAsync(request, connector, "chosen", approval, TestContext.Current.CancellationToken);
        if (expected["error"] is { } error)
        {
            Assert.True((await Assert.ThrowsAsync<LlmException>(Send)).Error.Kind == Kind(error), id + ": rewrite " + error.GetValue<string>());
            return;
        }
        var proposal = await Send();
        Assert.True(proposal.ProposedText == expected["rewrite"]!.GetValue<string>(), id + ": rewrite kept as sent");
        Assert.True(proposal.ProposedLength == expected["proposedLength"]!.GetValue<int>(), id + ": rewrite length");
    }

    [Theory]
    [MemberData(nameof(VoiceRewriteBudgetTests.Answers), MemberType = typeof(VoiceRewriteBudgetTests))]
    public async Task OnlyTheQuotedModelMayAnswer(ConnectorId connectorId, string selected, string answered, bool accepted)
    {
        var connector = new CapturingLlmConnector("{\"edits\":[]}", connectorId, answered, models: [selected]);
        var service = new PatchRewriteService(Catalog());
        if (accepted) Assert.Equal(answered, (await Propose(service, Request(Cases()), connector, selected)).Model);
        else Assert.Equal(LlmErrorKind.InvalidOutput, (await Assert.ThrowsAsync<LlmException>(() => Propose(service, Request(Cases()), connector, selected))).Error.Kind);
        Assert.Single(connector.Requests);
    }

    [Theory]
    [MemberData(nameof(VoiceRewriteBudgetTests.Stops), MemberType = typeof(VoiceRewriteBudgetTests))]
    public async Task StopIsATypedErrorAfterTheModelCheck(string stop, string answered, LlmErrorKind kind, string message)
    {
        var connector = new CapturingLlmConnector("{\"edits\":[]}", answered: answered, stop: VoiceRewriteBudgetTests.Stop(stop));
        var error = (await Assert.ThrowsAsync<LlmException>(() => Propose(new PatchRewriteService(Catalog()), Request(Cases()), connector))).Error;
        Assert.Equal(kind, error.Kind);
        Assert.Equal(message, error.UserMessage);
    }

    [Fact]
    public async Task QuoteBindsThePromptFileButNotItsLineEndings()
    {
        var root = VoiceRewriteBudgetTests.SharedCopy("prompts/patch-rewrite.json");
        try
        {
            var path = Path.Combine(root.FullName, "prompts", "patch-rewrite.json");
            var original = File.ReadAllText(path);
            Assert.StartsWith("{", original, StringComparison.Ordinal);
            Assert.DoesNotContain('\r', original);
            var service = new PatchRewriteService(new LlmCatalog(root.FullName));
            var connector = new CapturingLlmConnector("{\"edits\":[]}");
            var request = Request(Cases());
            var approval = service.Approve(await service.PrepareAsync(request, connector, "chosen", TestContext.Current.CancellationToken), true);
            Task Send() => service.ProposeAsync(request, connector, "chosen", approval, TestContext.Current.CancellationToken);
            // One more space changes no rendered field, yet the quote is for other prompt bytes, so nothing is sent.
            File.WriteAllText(path, "{ " + original[1..]);
            Assert.Equal(VoiceLabErrorKind.ConsentRequired, (await Assert.ThrowsAsync<VoiceLabException>(Send)).Kind);
            Assert.Empty(connector.Requests);
            // CRLF line endings are the same prompt, so the unused quote still sends.
            File.WriteAllText(path, original.ReplaceLineEndings("\r\n"));
            await Send();
            Assert.Single(connector.Requests);
        }
        finally
        {
            root.Delete(true);
        }
    }

    [Fact]
    public void PromptIsThePatchEditsSchemaWithTheBadgeCopy()
    {
        var prompt = Catalog().ReadAsset("prompts/patch-rewrite.json");
        JsonNode Line() => new JsonObject { ["type"] = "string" };
        var item = new JsonObject
        {
            ["type"] = "object", ["additionalProperties"] = false, ["required"] = new JsonArray("line", "text", "reason"),
            ["properties"] = new JsonObject { ["line"] = Line(), ["text"] = Line(), ["reason"] = Line() }
        };
        var schema = new JsonObject
        {
            ["type"] = "object", ["additionalProperties"] = false, ["required"] = new JsonArray("edits"),
            ["properties"] = new JsonObject { ["edits"] = new JsonObject { ["type"] = "array", ["items"] = item } }
        };
        Assert.Equal(1, prompt["promptVersion"]!.GetValue<int>());
        Assert.Equal("patch_edits", prompt["schemaName"]!.GetValue<string>());
        EqualJson(schema, prompt["schema"]);
        Assert.Equal("Check this: it adds something you didn't say.", prompt["messages"]!["checkThis"]!.GetValue<string>());
        Assert.Equal(Cases()["copy"]!["checkThis"]!.GetValue<string>(), prompt["messages"]!["checkThis"]!.GetValue<string>());
    }

    [Fact]
    public async Task RequestBoundsAreInvalidInput()
    {
        var good = Request(Cases());
        var entries = good.Entries.ToArray();
        var ranges = good.Ranges.ToArray();
        PatchRewriteLineRange[] First(PatchRewriteLineRange range) => [range, .. ranges.Skip(1)];
        ClipWord[] Entry(int position, ClipWord entry)
        {
            var changed = entries.ToArray();
            changed[position] = entry;
            return changed;
        }
        (string Label, PatchRewriteRequest Request)[] bad =
        [
            ("no entries", good with { Entries = [], Ranges = [] }),
            ("missing range", good with { Ranges = ranges[..^1] }),
            ("extra range", good with { Ranges = [.. ranges, new("[90-91]", 1, 2)] }),
            ("ranges out of order", good with { Ranges = [ranges[1], ranges[0], .. ranges.Skip(2)] }),
            ("minChars 0", good with { Ranges = First(ranges[0] with { MinChars = 0, MaxChars = 5 }) }),
            ("min above max", good with { Ranges = First(ranges[0] with { MinChars = 6, MaxChars = 5 }) }),
            ("max above 5000", good with { Ranges = First(ranges[0] with { MinChars = 1, MaxChars = 5001 }) }),
            ("blank instruction", good with { Instruction = " \n\t" }),
            ("long instruction", good with { Instruction = new string('x', 1001) }),
            ("language", good with { Language = "en\n" }),
            ("repeated index", good with { Entries = Entry(1, entries[1] with { Index = entries[0].Index }) }),
            ("bad timing", good with { Entries = Entry(2, entries[2] with { End = -1 }) })
        ];
        var service = new PatchRewriteService(Catalog());
        var connector = new CapturingLlmConnector("{\"edits\":[]}");
        var approval = service.Approve(await service.PrepareAsync(good, connector, "chosen", TestContext.Current.CancellationToken), true);
        foreach (var (label, request) in bad)
        {
            var prepared = await Assert.ThrowsAsync<VoiceLabException>(() => service.PrepareAsync(request, connector, "chosen", TestContext.Current.CancellationToken));
            Assert.True(prepared.Kind == VoiceLabErrorKind.InvalidInput, label + ": prepare");
            var proposed = await Assert.ThrowsAsync<VoiceLabException>(() => service.ProposeAsync(request, connector, "chosen", approval, TestContext.Current.CancellationToken));
            Assert.True(proposed.Kind == VoiceLabErrorKind.InvalidInput, label + ": propose");
        }
        Assert.Empty(connector.Requests);
    }

    [Theory]
    [InlineData("entryText")]
    [InlineData("entryTiming")]
    [InlineData("range")]
    [InlineData("instruction")]
    [InlineData("language")]
    [InlineData("connector")]
    [InlineData("model")]
    [InlineData("same")]
    public async Task QuoteBindsTheWholeRequest(string field)
    {
        var service = new PatchRewriteService(Catalog());
        var good = Request(Cases());
        var connector = new CapturingLlmConnector("{\"edits\":[]}");
        var quoted = field == "connector" ? new CapturingLlmConnector("{\"edits\":[]}", ConnectorId.Anthropic) : connector;
        var approval = service.Approve(await service.PrepareAsync(good, quoted, "chosen", TestContext.Current.CancellationToken), true);
        var entries = good.Entries.ToArray();
        var ranges = good.Ranges.ToArray();
        if (field == "entryText") entries[0] = entries[0] with { Text = "Then" };
        if (field == "entryTiming") entries[0] = entries[0] with { End = entries[0].End + 0.01 };
        if (field == "range") ranges[1] = ranges[1] with { MaxChars = ranges[1].MaxChars + 1 };
        var changed = good with
        {
            Entries = entries, Ranges = ranges, Instruction = field == "instruction" ? "I said 2023." : good.Instruction,
            Language = field == "language" ? "et" : good.Language
        };
        Task Send() => service.ProposeAsync(changed, connector, field == "model" ? "other" : "chosen", approval, TestContext.Current.CancellationToken);
        if (field == "same") await Send();
        else Assert.Equal(VoiceLabErrorKind.ConsentRequired, (await Assert.ThrowsAsync<VoiceLabException>(Send)).Kind);
        Assert.Equal(field == "same" ? 1 : 0, connector.Requests.Count);
        // A refused check sends nothing and leaves the quote usable; a send consumes it.
        Task Replay() => service.ProposeAsync(good, connector, "chosen", approval, TestContext.Current.CancellationToken);
        if (field is "same" or "connector") Assert.Equal(VoiceLabErrorKind.ConsentRequired, (await Assert.ThrowsAsync<VoiceLabException>(Replay)).Kind);
        else await Replay();
        Assert.Equal(field == "connector" ? 0 : 1, connector.Requests.Count);
    }

    [Fact]
    public async Task DeclinedApprovalAndReplaySendNothing()
    {
        var service = new PatchRewriteService(Catalog());
        var request = Request(Cases());
        var connector = new CapturingLlmConnector("{\"edits\":[]}");
        var prepared = await service.PrepareAsync(request, connector, "chosen", TestContext.Current.CancellationToken);
        Assert.Equal(VoiceLabOperation.PatchRewrite, prepared.Review.Operation);
        Assert.Equal("patch-rewrite", prepared.Review.Endpoint);
        Assert.Equal(VoiceLabErrorKind.ConsentRequired, Assert.Throws<VoiceLabException>(() => service.Approve(prepared, false)).Kind);
        Assert.Empty(connector.Requests);
        var approval = service.Approve(prepared, true);
        var proposal = await service.ProposeAsync(request, connector, "chosen", approval, TestContext.Current.CancellationToken);
        Assert.Empty(proposal.Edits);
        var sent = Assert.Single(connector.Requests);
        Assert.Equal(LlmFeature.VoiceRewrite, sent.Feature);
        Assert.Equal("patch_edits", sent.SchemaName);
        Assert.Equal("patch-rewrite", sent.Tag);
        Assert.Equal(VoiceLabErrorKind.ConsentRequired, (await Assert.ThrowsAsync<VoiceLabException>(() =>
            service.ProposeAsync(request, connector, "chosen", approval, TestContext.Current.CancellationToken))).Kind);
        Assert.Single(connector.Requests);
    }

    [Fact]
    public void RangeTemplateWithoutItsPlaceholdersIsAMissingResource()
    {
        var prompt = Catalog().ReadAsset("prompts/patch-rewrite.json");
        prompt["request"]!["rangeLine"] = "{line} is fine.";
        var request = Request(Cases());
        Assert.Equal(VoxClipErrorCode.SharedResourcesMissing, Assert.Throws<VoxClipException>(() =>
            PatchRewriteService.RequestText(request, ClipText.Render(ClipText.Lines(request.Entries)), prompt)).Code);
    }
}
