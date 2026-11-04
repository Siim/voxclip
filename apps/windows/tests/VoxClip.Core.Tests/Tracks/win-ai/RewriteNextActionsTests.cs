using System.Security.Cryptography;
using System.Text;
using System.Text.Json.Nodes;
using VoxClip.Core.Domain.Editing;
using VoxClip.Core.Domain.VoiceLab;
using VoxClip.Core.Services.LLM;
using VoxClip.Core.Services.VoiceLab;
using VoxClip.Tests.Support;
using Xunit;
using static VoxClip.Core.Tests.Tracks.WinAi.AiTestSupport;

namespace VoxClip.Core.Tests.Tracks.WinAi;

/// <summary>Rewrite next steps (voice-lab.md §8.2.1): the optional <c>nextActions</c> of both Rewrite replies, the scoped
/// feedback a next step sends and how a scoped reply lands on the asked phrases, replayed from the independent
/// generator's rewrite-next-actions-cases.json (the macOS Core replays the same file), then through both services with a
/// canned connector. Nothing is sent anywhere.</summary>
[Trait("Track", "win-ai")]
public sealed class RewriteNextActionsTests
{
    static readonly Lazy<JsonObject> Vectors = new(() => JsonNode.Parse(FixtureLoader.ReadText("fixtures/voice-lab/rewrite-next-actions-cases.json"))!.AsObject());
    static IEnumerable<JsonNode> Rows(string key) => Vectors.Value[key]!.AsArray().Select(row => row!);
    static string Describe(IEnumerable<RewriteNextAction> actions) =>
        string.Join(" | ", actions.Select(action => action.Label + " / " + action.Instruction + " / " + string.Join(",", action.Ordinals)));

    [Fact]
    public void SharedVectorsPinThePromptsTheyWereMadeFrom()
    {
        var root = Vectors.Value;
        Assert.Equal(new[] { "schema", "sources", "parsing", "feedback", "landing", "caseCount" }, root.Select(pair => pair.Key));
        Assert.Equal("voxclip-voice-lab-next-actions-cases/1", root["schema"]!.GetValue<string>());
        Assert.Equal(25, root["caseCount"]!.GetValue<int>());
        Assert.Equal(25, Rows("parsing").Count() + Rows("feedback").Count() + Rows("landing").Count());
        foreach (var (path, hash) in root["sources"]!.AsObject())
        {
            var text = File.ReadAllText(Path.Combine(FixtureLoader.SharedRoot, "..", path)).Replace("\r\n", "\n", StringComparison.Ordinal);
            Assert.True(Convert.ToHexStringLower(SHA256.HashData(Encoding.UTF8.GetBytes(text))) == hash!.GetValue<string>(), path);
        }
    }

    [Fact]
    public void ParsingKeepsAtMostFourValidActionsAndDropsBadEntries()
    {
        foreach (var row in Rows("parsing"))
        {
            var expected = row["expected"]!.AsArray().Select(item => new RewriteNextAction(item!["label"]!.GetValue<string>(), item["instruction"]!.GetValue<string>(),
                item["ordinals"]!.AsArray().Select(value => value!.GetValue<int>()).ToArray())).ToArray();
            var parsed = RewriteNextAction.Parse(row["input"]);
            Assert.True(expected.SequenceEqual(parsed), $"{row["id"]}: {Describe(parsed)}");
        }
        Assert.Empty(RewriteNextAction.Parse(null));
    }

    [Fact]
    public void FeedbackIsRenderedFromTheSharedTemplatesOnly()
    {
        var catalog = Catalog();
        foreach (var row in Rows("feedback"))
        {
            var instruction = row["instruction"]!.GetValue<string>();
            var phrases = row["phrases"]!.AsArray().Select(item => new RewriteBlockedPhrase(item!["ordinal"]!.GetValue<int>(),
                Enum.Parse<RewriteBlockedReason>(item["reason"]!.GetValue<string>(), ignoreCase: true), item["original"]!.GetValue<string>(),
                item["proposed"]!.GetValue<string>(), item["estimateSeconds"]?.GetValue<double>(), item["slotSeconds"]?.GetValue<double>())).ToArray();
            var rendered = row["merge"] is JsonArray merge ? RewriteNextActionFeedback.Merge(merge[0]!.GetValue<int>(), merge[1]!.GetValue<int>(), catalog)
                : row["limit"] is { } limit ? RewriteNextActionFeedback.FewerWords(limit.GetValue<int>(), catalog)
                : phrases.Length == 0 ? RewriteNextActionFeedback.Open(instruction, catalog)
                : RewriteNextActionFeedback.Scoped(instruction, phrases, row["budget"] is JsonObject budget
                    ? new(budget["voiceWords"]!.GetValue<int>(), budget["scopeWords"]!.GetValue<int>()) : null, catalog);
            Assert.True(row["expected"]!.GetValue<string>() == rendered, $"{row["id"]}: {rendered}");
        }
        // No instruction, no phrase, or a repeated phrase is invalid input, never an empty request.
        var phrase = new RewriteBlockedPhrase(1, RewriteBlockedReason.Asked, "a", "b");
        Assert.Throws<VoiceLabException>(() => RewriteNextActionFeedback.Scoped(" \n", [phrase], null, catalog));
        Assert.Throws<VoiceLabException>(() => RewriteNextActionFeedback.Scoped("Shorter", [], null, catalog));
        Assert.Throws<VoiceLabException>(() => RewriteNextActionFeedback.Scoped("Shorter", [phrase, phrase], null, catalog));
        Assert.Throws<VoiceLabException>(() => RewriteNextActionFeedback.Open(new string('x', 1_001), catalog));
    }

    [Fact]
    public void AScopedReplyChangesOnlyTheAskedPhrases()
    {
        static VoiceLabDiffHunk Hunk(JsonNode span)
        {
            int start = span[0]!.GetValue<int>(), end = span[1]!.GetValue<int>();
            return new(VoiceLabDiffHunkKind.Voice, start == end ? [] : Enumerable.Range(start, end - start).Select(index => "w" + index).ToArray(), ["x"], [], [], [],
                start, end, null);
        }
        foreach (var row in Rows("landing"))
        {
            var outcomes = RewriteScopedReply.Assign(row["current"]!.AsArray().Select(span => Hunk(span!)).ToArray(),
                row["asked"]!.AsArray().Select(value => value!.GetValue<int>()).ToHashSet(), row["reply"]!.AsArray().Select(span => Hunk(span!)).ToArray());
            var named = outcomes.OrderBy(pair => pair.Key).Select(pair => pair.Key + "=" + pair.Value.Kind switch
            {
                RewriteScopedReply.OutcomeKind.Replace => "replace:" + pair.Value.Index,
                RewriteScopedReply.OutcomeKind.KeepOriginal => "keepOriginal",
                RewriteScopedReply.OutcomeKind.Absorbed => "absorbed:" + pair.Value.Index,
                _ => "conflict",
            });
            var expected = row["expected"]!.AsObject().OrderBy(pair => int.Parse(pair.Key, System.Globalization.CultureInfo.InvariantCulture))
                .Select(pair => pair.Key + "=" + pair.Value!.GetValue<string>());
            Assert.True(expected.SequenceEqual(named), $"{row["id"]}: {string.Join(", ", named)}");
        }
    }

    [Fact]
    public void BothPromptsOfferOptionalNextActionsThatStrictShapingRequires()
    {
        foreach (var name in new[] { "voice-rewrite", "patch-rewrite" })
        {
            var prompt = JsonNode.Parse(FixtureLoader.ReadText($"prompts/{name}.json"))!;
            Assert.Equal(3, prompt["promptVersion"]!.GetValue<int>());
            var schema = prompt["schema"]!;
            Assert.DoesNotContain("nextActions", schema["required"]!.AsArray().Select(key => key!.GetValue<string>()));
            Assert.Equal(new[] { "instruction", "label" }, schema["properties"]!["nextActions"]!["items"]!["required"]!.AsArray().Select(key => key!.GetValue<string>()).Order());
            var strict = LlmConnector.HttpStructuredSchema(schema);
            Assert.Contains("nextActions", strict["required"]!.AsArray().Select(key => key!.GetValue<string>()));
            Assert.Equal(new[] { "instruction", "label", "ordinals" },
                strict["properties"]!["nextActions"]!["items"]!["required"]!.AsArray().Select(key => key!.GetValue<string>()).Order());
            Assert.Contains("nextActions", prompt["system"]!.GetValue<string>());
        }
    }

    [Fact]
    public async Task PatchRepliesCarryTheirNextActionsWithoutCountingThemAsMalformedEdits()
    {
        var request = PatchRewriteServiceTests.Request(PatchRewriteServiceTests.Cases());
        var actions = string.Join(",", Enumerable.Range(1, 6).Select(index => $$"""{"label":"Fix {{index}}","instruction":"Fix phrase {{index}}.","ordinals":[{{index}}]}"""));
        var reply = """{"edits":[],"nextActions":[{"label":7},{"label":"Too many words in this one label","instruction":"x"},""" + actions + "]}";
        async Task<PatchRewriteProposal> Propose(string text, CapturingLlmConnector connector)
        {
            var service = new PatchRewriteService(Catalog());
            var approval = service.Approve(await service.PrepareAsync(request, connector, "chosen", TestContext.Current.CancellationToken), true);
            return await service.ProposeAsync(request, connector, "chosen", approval, TestContext.Current.CancellationToken);
        }
        var connector = new CapturingLlmConnector(reply);
        var proposal = await Propose(reply, connector);
        Assert.Equal(new[] { "Fix 1", "Fix 2", "Fix 3", "Fix 4" }, proposal.NextActions.Select(action => action.Label));
        Assert.Equal(new[] { 1 }, proposal.NextActions[0].Ordinals);
        Assert.Equal(0, proposal.MalformedItems);
        Assert.Single(connector.Requests);
        // A reply without the field has no next steps.
        Assert.Empty((await Propose("""{"edits":[]}""", new CapturingLlmConnector("""{"edits":[]}"""))).NextActions);
    }

    [Fact]
    public async Task PassageRepliesCarryTheirNextActionsAndAMalformedOneDoesNotRefuseTheReply()
    {
        var request = new VoiceRewriteRequest(Guid.NewGuid(), VoiceRewriteScope.Passage, [Word(0, "We", 0, .2), Word(1, "shipped", .25, .6)],
            "Shorter", "en", 1, 4, 20);
        async Task<VoiceRewriteProposal> Propose(string reply)
        {
            var service = new VoiceRewriteService(Catalog());
            var connector = new CapturingLlmConnector(reply);
            var approval = service.Approve(await service.PrepareAsync(request, connector, "chosen", TestContext.Current.CancellationToken), true);
            return await service.ProposeAsync(request, connector, "chosen", approval, TestContext.Current.CancellationToken);
        }
        var proposal = await Propose("""{"rewrite":"We shipped","nextActions":[{"label":"Drop 'shipped'","instruction":"Drop the word shipped.","ordinals":[1, 1.5]},{"label":7},{"label":"Say it in 6 words","instruction":"Say it in six words."}]}""");
        Assert.Equal("We shipped", proposal.ProposedText);
        Assert.Equal(new[] { new RewriteNextAction("Say it in 6 words", "Say it in six words.", []) }, proposal.NextActions);
        Assert.Empty((await Propose("""{"rewrite":"We shipped"}""")).NextActions);
        // Any other malformed item still refuses the reply, as before.
        await Assert.ThrowsAsync<LlmException>(() => Propose("""{"rewrite":"We shipped","audioTags":[7]}"""));
    }
}
