using System.Security.Cryptography;
using System.Text.Json;
using System.Text.Json.Nodes;
using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Domain.VoiceLab;
using VoxClip.Core.Services.LLM;
using VoxClip.Core.Services.VoiceLab;
using VoxClip.Core.Domain.Transcript;
using VoxClip.Tests.Support;
using Xunit;

namespace VoxClip.Core.Tests.Tracks.VoiceLab;

public sealed class VoiceLabWordingFitTests
{
    private static JsonObject Fixture() => JsonNode.Parse(File.ReadAllText(Path.Combine(FixtureLoader.SharedRoot, "fixtures/voice-lab/autofit-cases.json")))!.AsObject();

    [Fact]
    public void SharedFixtureHasItsExactShapeAndBindsThePromptBytes()
    {
        var fixture = Fixture();
        Assert.Equal("voxclip-voice-lab-autofit-cases/1", fixture["schema"]!.GetValue<string>());
        Assert.Equal(["schema", "sources", "targets", "calibration", "rounds", "requests"], fixture.Select(pair => pair.Key).ToArray());
        Assert.Equal([6, 5, 6, 4], new[] { "targets", "calibration", "rounds", "requests" }.Select(key => fixture[key]!.AsArray().Count).ToArray());
        var bytes = File.ReadAllBytes(Path.Combine(FixtureLoader.SharedRoot, "prompts/voice-rewrite-fit.json")).Where(value => value != 0x0D).ToArray();
        Assert.Equal(Convert.ToHexStringLower(SHA256.HashData(bytes)), fixture["sources"]!["shared/prompts/voice-rewrite-fit.json"]!.GetValue<string>());
    }

    [Fact]
    public void WordTargetsReplayTheSharedVectorsExactly()
    {
        foreach (var row in Fixture()["targets"]!.AsArray())
        {
            var input = row!["input"]!;
            var target = VoiceLabWordingFit.WordTarget(input["wordsPerSecond"]!.GetValue<double>(), input["multiplier"]!.GetValue<double>(),
                input["minimumSeconds"]!.GetValue<double>(), input["maximumSeconds"]!.GetValue<double>(), input["overheadSeconds"]!.GetValue<double>(),
                input["bridgeWords"]!.GetValue<int>());
            Assert.Equal(new VoiceLabWordTarget(row["expected"]!["minimum"]!.GetValue<int>(), row["expected"]!["maximum"]!.GetValue<int>()), target);
        }
        Assert.Throws<VoiceLabLengthBudgetException>(() => VoiceLabWordingFit.WordTarget(0, 1, 1, 2, 0));
        Assert.Throws<VoiceLabLengthBudgetException>(() => VoiceLabWordingFit.WordTarget(2, 1, 3, 2, 0));
        Assert.Throws<VoiceLabLengthBudgetException>(() => VoiceLabWordingFit.WordTarget(2, double.NaN, 1, 2, 0));
    }

    [Fact]
    public void CalibrationMedianAndDefaultsReplayTheSharedVectorsExactly()
    {
        foreach (var row in Fixture()["calibration"]!.AsArray())
        {
            var samples = row!["ratios"]!.AsArray().Select((ratio, index) => new VoiceLabRateSample("take" + index, ratio!.GetValue<double>())).ToArray();
            Assert.Equal(row["expected"]!.GetValue<double>(), VoiceLabWordingFit.Multiplier(samples));
        }
        Assert.Equal(1, VoiceLabWordingFit.Multiplier(null));
        Assert.Equal(2, VoiceLabWordingFit.Multiplier([new("a", 2), new("b", double.NaN), new("c", 2), new("d", -1)]));
    }

    [Fact]
    public void RecordingAddsEachTakeOnceAndKeepsTheLastTen()
    {
        IReadOnlyList<VoiceLabRateSample> samples = [];
        for (var index = 0; index < 12; index++) samples = VoiceLabWordingFit.Recording(samples, "take" + index, 2 + index, 2);
        Assert.Equal(10, samples.Count);
        Assert.Equal("take2", samples[0].Id);
        Assert.Same(samples, VoiceLabWordingFit.Recording(samples, "take11", 9, 3));
        Assert.Same(samples, VoiceLabWordingFit.Recording(samples, "other", 0, 3));
        Assert.Same(samples, VoiceLabWordingFit.Recording(samples, "other", 1, double.PositiveInfinity));
        Assert.Same(samples, VoiceLabWordingFit.Recording(samples, "", 1, 1));
    }

    [Fact]
    public void RoundSelectionReplaysTheSharedVectorsExactly()
    {
        foreach (var row in Fixture()["rounds"]!.AsArray())
        {
            int[] Ints(string key) => row![key]!.AsArray().Select(value => value!.GetValue<int>()).ToArray();
            Assert.Equal(Ints("expected"), VoiceLabWordingFit.NextOrdinals(row!["roundsCompleted"]!.GetValue<int>(), Ints("candidates"),
                Ints("fitting").ToHashSet(), Ints("kept").ToHashSet(), row["stopped"]!.GetValue<bool>()));
        }
    }

    [Fact]
    public void RequestsReplayAllFourSharedFormsExactly()
    {
        var service = new VoiceLabWordingFitService(new LlmCatalog());
        foreach (var row in Fixture()["requests"]!.AsArray())
        {
            var phrase = row!["phrase"]!;
            var request = service.Request([Phrase(phrase)], ConnectorId.ClaudeCode, "en");
            var expected = row["expected"]!;
            Assert.Equal(expected["system"]!.GetValue<string>(), request.System);
            Assert.Equal(expected["cachedBlock"]!.GetValue<string>(), request.CachedBlock);
            Assert.Equal(expected["instruction"]!.GetValue<string>(), request.Instruction);
            Assert.Equal(expected["schemaName"]!.GetValue<string>(), request.SchemaName);
            Assert.True(JsonNode.DeepEquals(expected["schema"], request.Schema));
            Assert.Equal("voice-rewrite-fit", request.Tag);
        }
    }

    [Fact]
    public void RequestRefusesMalformedPhrasesBeforeAnySend()
    {
        var service = new VoiceLabWordingFitService(new LlmCatalog());
        var phrase = Sample();
        Assert.Throws<VoiceLabException>(() => service.Request([], ConnectorId.ClaudeCode, "en"));
        Assert.Throws<VoiceLabException>(() => service.Request([phrase, phrase], ConnectorId.ClaudeCode, "en"));
        Assert.Throws<VoiceLabException>(() => service.Request([phrase with { Direction = "sideways" }], ConnectorId.ClaudeCode, "en"));
        Assert.Throws<VoiceLabException>(() => service.Request([phrase with { Target = new(5, 3) }], ConnectorId.ClaudeCode, "en"));
        Assert.Throws<VoiceLabException>(() => service.Request([phrase with { MeasuredSeconds = 0 }], ConnectorId.ClaudeCode, "en"));
        Assert.Throws<VoiceLabException>(() => service.Request([phrase], ConnectorId.ClaudeCode, "not a language"));
    }

    [Fact]
    public async Task StructuredKeepOriginalIsTheOnlyWayToKeepARecording()
    {
        var service = new VoiceLabWordingFitService(new LlmCatalog());
        var phrases = new[] { Sample(), Sample() with { Ordinal = 4, Direction = "shorter" } };
        var connector = new Connector(new JsonArray(Row(2, "keepOriginal", ""), Row(4, "reword", "keep the original words")));
        var action = service.Prepare(phrases, connector.Id, "chosen", "en");
        var updates = await service.ProposeAsync(phrases, connector, "chosen", "en", service.Approve(action, true), CancellationToken.None);
        Assert.Equal([new(2, true, ""), new(4, false, "keep the original words")], updates);
        Assert.Equal(1, connector.Sends);
        Assert.Contains("Phrase 4", connector.Requests[0].CachedBlock);
        Assert.Throws<VoiceLabException>(() => service.Approve(action, true));
    }

    [Theory]
    [InlineData("missing")]
    [InlineData("unsolicited")]
    [InlineData("duplicate")]
    [InlineData("keep-with-text")]
    [InlineData("empty-reword")]
    [InlineData("tagged")]
    [InlineData("link")]
    [InlineData("fraction")]
    public async Task RepliesThatChangeOtherPhrasesOrAreNotPlainSpeechAreRefused(string reply)
    {
        var service = new VoiceLabWordingFitService(new LlmCatalog());
        var phrases = new[] { Sample(), Sample() with { Ordinal = 4 } };
        var rows = reply switch
        {
            "missing" => new JsonArray(Row(2, "reword", "fine")),
            "unsolicited" => new JsonArray(Row(2, "reword", "fine"), Row(4, "reword", "fine"), Row(5, "reword", "frozen")),
            "duplicate" => new JsonArray(Row(2, "reword", "fine"), Row(2, "reword", "again")),
            "keep-with-text" => new JsonArray(Row(2, "keepOriginal", "words"), Row(4, "reword", "fine")),
            "empty-reword" => new JsonArray(Row(2, "reword", "  "), Row(4, "reword", "fine")),
            "tagged" => new JsonArray(Row(2, "reword", "[laughs] fine"), Row(4, "reword", "fine")),
            "link" => new JsonArray(Row(2, "reword", "see https://example.com"), Row(4, "reword", "fine")),
            _ => new JsonArray(new JsonObject { ["ordinal"] = 2.5, ["action"] = "reword", ["text"] = "fine" }, Row(4, "reword", "fine"))
        };
        var connector = new Connector(rows);
        var action = service.Prepare(phrases, connector.Id, "chosen", "en");
        await Assert.ThrowsAsync<LlmException>(() => service.ProposeAsync(phrases, connector, "chosen", "en", service.Approve(action, true), CancellationToken.None));
    }

    [Fact]
    public async Task ApprovalIsBoundToTheExactPhrasesAndIsSpentOnce()
    {
        var service = new VoiceLabWordingFitService(new LlmCatalog());
        var phrase = Sample();
        var connector = new Connector(new JsonArray(Row(2, "reword", "We made the right call in the end")));
        var approval = service.Approve(service.Prepare([phrase], connector.Id, "chosen", "en"), true);
        await Assert.ThrowsAsync<VoiceLabException>(() => service.ProposeAsync([phrase with { Proposed = "Other" }], connector, "chosen", "en", approval, CancellationToken.None));
        Assert.Equal(0, connector.Sends);
        Assert.Single(await service.ProposeAsync([phrase], connector, "chosen", "en", approval, CancellationToken.None));
        await Assert.ThrowsAsync<VoiceLabException>(() => service.ProposeAsync([phrase], connector, "chosen", "en", approval, CancellationToken.None));
        Assert.Equal(1, connector.Sends);
    }

    [Fact]
    public void SpeakingRateSamplesAreOptionalValidatedAndPreserved()
    {
        var text = File.ReadAllText(Path.Combine(FixtureLoader.SharedRoot, "fixtures/projects/interview-take.voxclip"));
        var old = ProjectSerialization.Deserialize(text);
        Assert.Null(old.VoiceLab.SpeakingRateSamples);
        Assert.DoesNotContain("speakingRateSamples", ProjectSerialization.Serialize(old));
        var node = JsonNode.Parse(text)!;
        node["voiceLab"]!["speakingRateSamples"] = new JsonObject { ["eleven_v4"] = new JsonArray(new JsonObject { ["id"] = "take-1", ["ratio"] = 1.25 },
            new JsonObject { ["id"] = "take-2", ["ratio"] = 1.75 }) };
        var calibrated = ProjectSerialization.Deserialize(node.ToJsonString());
        var samples = calibrated.VoiceLab.SpeakingRateSamples!["eleven_v4"];
        Assert.Equal([new("take-1", 1.25), new("take-2", 1.75)], samples);
        Assert.Equal(1.5, VoiceLabWordingFit.Multiplier(samples));
        var saved = ProjectSerialization.Serialize(calibrated);
        Assert.Equal(samples, ProjectSerialization.Deserialize(saved).VoiceLab.SpeakingRateSamples!["eleven_v4"]);
        Assert.Equal(samples, VoiceLabProject.UpgradeToV3(calibrated).VoiceLab.SpeakingRateSamples!["eleven_v4"]);
        foreach (var bad in new JsonNode[]
        {
            new JsonObject { ["eleven_v4"] = new JsonArray(new JsonObject { ["id"] = "take", ["ratio"] = 0 }) },
            new JsonObject { ["eleven_v4"] = new JsonArray(new JsonObject { ["id"] = "", ["ratio"] = 1 }) },
            new JsonObject { ["eleven_v4"] = new JsonArray(new JsonObject { ["id"] = "take", ["ratio"] = 1, ["extra"] = 1 }) },
            new JsonObject { ["eleven_v4"] = new JsonArray(Enumerable.Range(0, 11).Select(index => (JsonNode)new JsonObject { ["id"] = "t" + index, ["ratio"] = 1 }).ToArray()) },
            new JsonArray()
        })
        {
            node["voiceLab"]!["speakingRateSamples"] = bad;
            Assert.Throws<VoxClipException>(() => ProjectSerialization.Deserialize(node.ToJsonString()));
        }
    }

    [Fact]
    public void AnOldProjectWithMultilingualV2TakesStillOpensValidatesAndKeepsItsTakes()
    {
        var node = JsonNode.Parse(File.ReadAllText(Path.Combine(FixtureLoader.SharedRoot, "fixtures/voice-lab/passage-render-v3.voxclip"))
            .Replace("\"fixture-model\"", "\"eleven_multilingual_v2\"", StringComparison.Ordinal))!;
        var old = ProjectSerialization.Deserialize(node.ToJsonString());
        Assert.Null(old.VoiceLab.SpeakingRateSamples);
        Assert.All(old.VoiceLab.Segments, segment => Assert.Equal("eleven_multilingual_v2", segment.Provenance.Model));
        VoiceLabProject.Validate(old);
        node["voiceLab"]!["speakingRateSamples"] = new JsonObject { ["eleven_v4"] = new JsonArray(new JsonObject { ["id"] = "take", ["ratio"] = 1.1 }) };
        var calibrated = ProjectSerialization.Deserialize(node.ToJsonString());
        Assert.Equal(ProjectSerialization.Serialize(old with { VoiceLab = old.VoiceLab with { SpeakingRateSamples = calibrated.VoiceLab.SpeakingRateSamples } }),
            ProjectSerialization.Serialize(calibrated));
    }

    [Fact]
    public void CalibratedRateScalesTheEstimateAndTheFitRangeHasALowerEnd()
    {
        var window = new VoiceLabWindow("first", "last", [], [], 0, 3, 0, 144_000,
            new(VoiceLabSeamKind.Hard, 0, 0, 240), new(VoiceLabSeamKind.Hard, 3, 144_000, 240));
        var envelope = new AudioEnvelope(48_000, .01, Enumerable.Repeat(.5f, 400).ToArray());
        var plain = VoiceLabPaceMatching.Measure("we made the right call", 12, window, null, null, 48_000, true, supportsPace: false, sourceEnvelope: envelope);
        var slower = VoiceLabPaceMatching.Measure("we made the right call", 12, window, null, null, 48_000, true, supportsPace: false, sourceEnvelope: envelope, rateMultiplier: 1.5);
        Assert.Equal(plain.EstimateSeconds * 1.5, slower.EstimateSeconds, 12);
        Assert.NotNull(plain.MinimumSeconds);
        Assert.True(plain.MinimumSeconds <= plain.SlotSeconds);
        Assert.Throws<VoiceLabLengthBudgetException>(() => VoiceLabPaceMatching.Measure("words", 12, window, null, null, 48_000, true, rateMultiplier: 0));
    }

    private static VoiceLabFitPhrase Sample() => new(2, "We made the right call", "We chose well", .9, 2, "longer", new(5, 7));
    private static VoiceLabFitPhrase Phrase(JsonNode phrase) => new(phrase["ordinal"]!.GetValue<int>(), phrase["original"]!.GetValue<string>(),
        phrase["proposed"]!.GetValue<string>(), phrase["estimateSeconds"]!.GetValue<double>(), phrase["slotSeconds"]!.GetValue<double>(),
        phrase["direction"]!.GetValue<string>(), new(phrase["target"]!["minimum"]!.GetValue<int>(), phrase["target"]!["maximum"]!.GetValue<int>()),
        phrase["measuredSeconds"]?.GetValue<double>(), phrase["calibrated"]!.GetValue<bool>());
    private static JsonObject Row(int ordinal, string action, string text) => new() { ["ordinal"] = ordinal, ["action"] = action, ["text"] = text };

    private sealed class Connector(JsonArray rows) : ILlmConnector
    {
        internal int Sends { get; private set; }
        internal List<LlmRequest> Requests { get; } = [];
        public ConnectorId Id => ConnectorId.OpenAI;
        public Task<ConnectorStatus> GetStatusAsync(CancellationToken ct) => Task.FromResult<ConnectorStatus>(new ConnectorStatus.Ready());
        public Task<IReadOnlyList<LlmModel>> GetModelsAsync(bool refresh, CancellationToken ct) =>
            Task.FromResult<IReadOnlyList<LlmModel>>([new("chosen", "Chosen", null, 32768, ModelSource.Discovered)]);
        public Task<int?> GetContextTokensAsync(string model, CancellationToken ct) => Task.FromResult<int?>(32768);
        public Task<RawCompletion> SendAsync(LlmRequest request, string model, CancellationToken ct)
        {
            Sends++; Requests.Add(request);
            return Task.FromResult(new RawCompletion(null, new JsonObject { ["phrases"] = rows.DeepClone() }, model, new StopKind.Complete(), null, "fake"));
        }
    }
}
