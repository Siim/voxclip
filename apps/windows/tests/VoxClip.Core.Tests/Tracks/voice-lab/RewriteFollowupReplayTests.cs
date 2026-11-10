using System.Text.Json.Nodes;
using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Domain.VoiceLab;
using VoxClip.Core.Services.LLM;
using VoxClip.Core.Services.VoiceLab;
using VoxClip.Core.Tests.Tracks.WinAi;
using VoxClip.Tests.Support;
using Xunit;

namespace VoxClip.Core.Tests.Tracks.VoiceLab;

/// <summary>shared/fixtures/rewrite-thread/request-cases.json: "Talk back to Claude" (design.md §6.3, ai.md §12.10, ADR-R50). Each
/// request renders byte for byte as the independent generator (tools/fixtures/rewrite-thread/generate_request_cases.py) renders it, and
/// each stub reply checks as it expects. The macOS Core replays the same file (RewriteFollowupReplayTests).</summary>
public sealed class RewriteFollowupReplayTests
{
    static readonly Lazy<JsonObject> Vectors = new(() => JsonNode.Parse(FixtureLoader.ReadText("fixtures/rewrite-thread/request-cases.json"))!.AsObject());
    static RewriteFollowupPrompt Prompt() => RewriteFollowupPrompt.Load(FixtureLoader.SharedRoot);
    static IEnumerable<JsonObject> Rows(string key) => Vectors.Value[key]!.AsArray().Select(row => row!.AsObject());
    static string[] Strings(JsonNode? node) => node!.AsArray().Select(value => value!.GetValue<string>()).ToArray();
    static RewriteFollowupRequest Input(JsonNode value) => new(value["kind"]!.GetValue<string>() == "versions" ? RewriteFollowupKind.Versions : RewriteFollowupKind.Reply,
        value["scope"]!.GetValue<string>(), value["language"]!.GetValue<string>(), value["source"]!.GetValue<string>(), value["ordinal"]!.GetValue<int>(),
        value["recorded"]!.GetValue<string>(), Strings(value["versions"]), Strings(value["messages"]));
    static readonly RewriteFollowupRequest Good = new(RewriteFollowupKind.Reply, "passage", "en", "a b c", 1, "a", ["b"], ["c"]);

    [Fact]
    public void TheFixtureIsCurrentForThePromptFileAndHoldsExactlyItsKeysAndCounts()
    {
        var root = Vectors.Value;
        Assert.Equal(new[] { "schema", "promptSha256", "requestCount", "replyCount", "requests", "replies" }, root.Select(pair => pair.Key));
        Assert.Equal("voxclip-rewrite-thread-cases/1", root["schema"]!.GetValue<string>());
        Assert.Equal(Prompt().Sha256, root["promptSha256"]!.GetValue<string>());
        Assert.Equal(5, root["requestCount"]!.GetValue<int>());
        Assert.Equal(5, Rows("requests").Count());
        Assert.Equal(6, root["replyCount"]!.GetValue<int>());
        Assert.Equal(6, Rows("replies").Count());
        Assert.All(Rows("requests"), row => Assert.Equal(new[] { "id", "input", "expected" }, row.Select(pair => pair.Key)));
        Assert.All(Rows("requests"), row => Assert.Equal(new[] { "system", "cachedBlock", "instruction", "schemaName", "tag", "maxOutputTokens" },
            row["expected"]!.AsObject().Select(pair => pair.Key)));
        Assert.All(Rows("replies"), row => Assert.Equal(new[] { "id", "input", "reply", "expect" }, row.Select(pair => pair.Key)));
    }

    [Fact]
    public void EachRequestCarriesTheRecordedWordsEveryVersionAndEveryMessageInOrderAsTheGeneratorRendersIt()
    {
        var prompt = Prompt();
        foreach (var row in Rows("requests"))
        {
            var id = row["id"]!.GetValue<string>();
            var input = Input(row["input"]!);
            var expected = row["expected"]!;
            var request = prompt.Request(input, TimeSpan.FromSeconds(60));
            Assert.True(expected["system"]!.GetValue<string>() == request.System, id + " system");
            Assert.True(expected["cachedBlock"]!.GetValue<string>() == request.CachedBlock, id + " cached block");
            Assert.True(expected["instruction"]!.GetValue<string>() == request.Instruction, id + " instruction:\n" + request.Instruction);
            Assert.True(expected["schemaName"]!.GetValue<string>() == request.SchemaName, id + " schema name");
            Assert.True(expected["tag"]!.GetValue<string>() == request.Tag, id + " tag");
            Assert.True(expected["maxOutputTokens"]!.GetValue<int>() == request.MaxOutputTokens, id + " output tokens");
            Assert.Equal((LlmFeature.VoiceRewrite, Effort.XHigh, "en"), (request.Feature, request.Effort!.Value, request.Language));
            // In order: the recorded words, then each version, then each message, the newest last.
            var cursor = 0;
            foreach (var part in new[] { input.Recorded }.Concat(input.Versions).Concat(input.Messages).Where(part => part.Length > 0))
            {
                var found = request.Instruction.IndexOf(part, cursor, StringComparison.Ordinal);
                Assert.True(found >= 0, $"{id}: {part} is missing or out of order");
                cursor = found + part.Length;
            }
        }
    }

    [Fact]
    public void StubRepliesCheckAsTheFixtureExpects()
    {
        var prompt = Prompt();
        foreach (var row in Rows("replies"))
        {
            var id = row["id"]!.GetValue<string>();
            var input = Input(row["input"]!);
            var expect = row["expect"]!;
            if (expect["error"]?.GetValue<string>() == "invalidOutput")
            {
                var refused = Assert.Throws<LlmException>(() => prompt.Reply(row["reply"]!.AsObject(), input));
                Assert.True(refused.Error.Kind == LlmErrorKind.InvalidOutput, id);
                continue;
            }
            var reply = prompt.Reply(row["reply"]!.AsObject(), input);
            Assert.True(Strings(expect["texts"]).SequenceEqual(reply.Texts), id + " texts: " + string.Join(" | ", reply.Texts));
            Assert.True(expect["note"]!.GetValue<string>() == reply.Note, id + " note: " + reply.Note);
            Assert.True(Strings(expect["nextSteps"]).SequenceEqual(reply.NextSteps), id + " next steps: " + string.Join(" | ", reply.NextSteps));
        }
    }

    [Fact]
    public void ARequestWithNoMessageOrNoVersionOrOverTheLimitsIsRefusedBeforeAnythingIsSent()
    {
        var prompt = Prompt();
        _ = prompt.Request(Good, TimeSpan.FromSeconds(1));
        RewriteFollowupRequest[] refused =
        [
            Good with { Messages = [] }, Good with { Messages = ["  "] }, Good with { Versions = [] }, Good with { Ordinal = 0 },
            Good with { Source = " " }, Good with { Language = "english!" }, Good with { Messages = Enumerable.Repeat("again", prompt.MaxMessages + 1).ToArray() },
            Good with { Versions = Enumerable.Repeat("b", prompt.MaxVersions + 1).ToArray() }, Good with { Messages = [new string('m', prompt.MaxMessageChars + 1)] },
            Good with { Versions = [new string('v', prompt.MaxTextChars + 1)] }, Good with { Recorded = new string('r', prompt.MaxTextChars + 1) },
            Good with { Source = new string('s', 20_001) },
        ];
        foreach (var input in refused)
            Assert.Equal(VoiceLabErrorKind.InvalidInput, Assert.Throws<VoiceLabException>(() => prompt.Request(input, TimeSpan.FromSeconds(1))).Kind);
        // An empty version is a cut, and an empty recording is an insertion: both are sent.
        Assert.Contains("1. \n", prompt.Request(Good with { Versions = [""] }, TimeSpan.FromSeconds(1)).Instruction);
        Assert.Contains("(none: this change adds words", prompt.Request(Good with { Recorded = "" }, TimeSpan.FromSeconds(1)).Instruction);
    }

    [Fact]
    public void TheBlocksTheirReturnLinesAndTheLimitsComeFromThePromptFile()
    {
        var prompt = Prompt();
        Assert.Equal((1, 24, 1000, 40, 4000, 20, 2, 6, 3, 4000), (prompt.PromptVersion, prompt.MaxMessages, prompt.MaxMessageChars, prompt.MaxVersions,
            prompt.MaxTextChars, prompt.MaxNoteWords, prompt.MaxNextSteps, prompt.MaxNextStepWords, prompt.Alternatives, prompt.MaxOutputTokens));
        Assert.Equal(["Shorter", "Closer to my words", "3 more versions"], prompt.SteadyBubbles);
        Assert.Equal("✓ That's it, keep it", prompt.KeepBubble);
        var versions = prompt.Request(Good with { Kind = RewriteFollowupKind.Versions, Messages = ["3 more versions"] }, TimeSpan.FromSeconds(1));
        Assert.Equal(("rewrite_followup_versions", "rewrite-followup-versions"), (versions.SchemaName, versions.Tag));
        Assert.Contains("Return alternatives: 3 new versions", versions.Instruction);
        Assert.DoesNotContain("{count}", versions.Instruction);
        Assert.Contains("alternatives", versions.Schema["required"]!.AsArray().Select(item => item!.GetValue<string>()));
        var reply = prompt.Request(Good, TimeSpan.FromSeconds(1));
        Assert.Equal(("rewrite_followup", "rewrite-followup"), (reply.SchemaName, reply.Tag));
        Assert.StartsWith("CHANGE 1. THE SPEAKER'S RECORDED WORDS FOR IT:\na\n\nVERSIONS OF ITS NEW WORDS SO FAR", reply.Instruction);
        Assert.EndsWith("Return text: the new spoken words for this change only, replacing the recorded words above. Also return note and nextSteps.", reply.Instruction);
        Assert.Equal("SOURCE TRANSCRIPT (passage, en):\na b c", reply.CachedBlock);
    }

    [Fact]
    public void TheChecksCutTheNoteDropSteadyBubblesAndRepeatsAndRefuseUnspokenWords()
    {
        var prompt = Prompt();
        static JsonObject Reply(string text, string note, params string[] steps) => new()
        {
            ["text"] = text, ["note"] = note, ["nextSteps"] = new JsonArray(steps.Select(step => (JsonNode)JsonValue.Create(step)!).ToArray())
        };
        var cut = prompt.Reply(Reply("New words.", string.Join(" ", Enumerable.Range(1, 25).Select(index => "w" + index))), Good);
        Assert.Equal(string.Join(" ", Enumerable.Range(1, 20).Select(index => "w" + index)) + "…", cut.Note);
        Assert.Equal("Twenty words or fewer stay.", prompt.Reply(Reply("New words.", "  Twenty   words or fewer stay. "), Good).Note);
        var steps = prompt.Reply(Reply("New words.", "", "✓ That's it, keep it", "3 MORE VERSIONS!", "Name the buyer", "name the buyer.", "See https://x.y",
            "One two three four five six seven", "End on the bill", "A third one"), Good);
        Assert.Equal(["Name the buyer", "End on the bill"], steps.NextSteps);
        foreach (var bad in new[] { "", "   ", "Line\nbreak", "Visit http://example.com", "Bell\u0007" })
            Assert.Equal(LlmErrorKind.InvalidOutput, Assert.Throws<LlmException>(() => prompt.Reply(Reply(bad, "n"), Good)).Error.Kind);
        Assert.Equal(LlmErrorKind.InvalidOutput, Assert.Throws<LlmException>(() => prompt.Reply(new JsonObject { ["note"] = "n" }, Good)).Error.Kind);
        var versions = Good with { Kind = RewriteFollowupKind.Versions, Versions = ["Already, there."] };
        var more = prompt.Reply(new JsonObject
        {
            ["alternatives"] = new JsonArray("already there", "One.", "one", "Two.", 3, "Three.", "Four."), ["note"] = "", ["nextSteps"] = new JsonArray()
        }, versions);
        Assert.Equal(["One.", "Two.", "Three."], more.Texts);
        Assert.Equal("already there", RewriteFollowupPrompt.Key("  Already,   THERE. "));
        Assert.Equal("it's ok", RewriteFollowupPrompt.Key("“It's ok!”"));
    }

    [Fact]
    public async Task TheServiceSendsOneRequestThroughTheRunnerAndReturnsTheCheckedReply()
    {
        var catalog = new LlmCatalog(FixtureLoader.SharedRoot);
        var service = new RewriteFollowupService(new LlmRunner(new MemoryKeys(null), catalog, new Redactor()), catalog, Prompt());
        const string answer = "{\"text\":\"My travel pass got its first buyer. I was so happy. Then I found out it was a scammer.\",\"note\":\"The joy is about the sale now.\",\"nextSteps\":[\"More suspense before the scammer\"]}";
        var connector = new ScriptedConnector(ConnectorId.Ollama, (_, model, _) => Task.FromResult(new RawCompletion(answer, null, model, new StopKind.Complete(), null, null)));
        var input = new RewriteFollowupRequest(RewriteFollowupKind.Reply, "passage", "en", "Somebody purchased my product. I was quite happy.", 1,
            "Somebody purchased my product. I was quite happy.", ["My travel pass got its first buyer. A scammer. I was so happy."],
            ["It reads like I was happy about the scammer. I was happy about the sale."]);
        var reply = await service.SendAsync(input, connector, "fixture", TestContext.Current.CancellationToken);
        Assert.Equal(["My travel pass got its first buyer. I was so happy. Then I found out it was a scammer."], reply.Texts);
        Assert.Equal(("The joy is about the sale now.", "More suspense before the scammer"), (reply.Note, Assert.Single(reply.NextSteps)));
        var sent = Assert.Single(connector.Requests);
        Assert.Equal("rewrite-followup", sent.Tag);
        Assert.Contains(input.Messages[0], sent.Instruction);
        Assert.Equal(service.Request(input, ConnectorId.Ollama).Instruction, sent.Instruction);
        var silent = new ScriptedConnector(ConnectorId.Ollama, (_, model, _) => Task.FromResult(new RawCompletion(answer, null, model, new StopKind.Complete(), null, null)));
        await Assert.ThrowsAsync<VoiceLabException>(() => service.SendAsync(input with { Messages = [] }, silent, "fixture", TestContext.Current.CancellationToken));
        Assert.Empty(silent.Requests);
    }
}
