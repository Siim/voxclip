using System.Security.Cryptography;
using System.Text.Json.Nodes;
using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Domain.Transcript;
using VoxClip.Core.Domain.VoiceLab;
using VoxClip.Core.Services.LLM;
using VoxClip.Core.Services.VoiceLab;
using VoxClip.Tests.Support;
using Xunit;

namespace VoxClip.Core.Tests.Tracks.VoiceLab;

/// <summary>Rewrite writes within each slot (ai.md §12.9, ADR-R42; Mac <c>VoiceRewriteSlotsTests</c>): the spans, their seconds and word
/// budgets replayed from <c>rewrite-slot-cases.json</c>, the request that says why and lists each slot, and prompts that never pad.</summary>
public sealed class VoiceRewriteSlotsTests
{
    private static JsonObject Vectors() => JsonNode.Parse(FixtureLoader.ReadText("fixtures/voice-lab/rewrite-slot-cases.json"))!.AsObject();
    private static TimedWord[] Words(JsonNode? node) => node!.AsArray().Select(word => new TimedWord(word!["id"]!.GetValue<string>(),
        word["text"]!.GetValue<string>(), WordKind.Word, word["start"]!.GetValue<double>(), word["end"]!.GetValue<double>(), null, null, 1, null,
        TimingSource.Native)).ToArray();

    [Fact]
    public void TheSharedVectorsHaveTheirShapeConstantsAndPromptBytes()
    {
        var vectors = Vectors();
        Assert.Equal("voxclip-rewrite-slots/1", vectors["schema"]!.GetValue<string>());
        Assert.Equal(["schema", "caseCount", "sources", "constants", "cases"], vectors.Select(pair => pair.Key).ToArray());
        Assert.Equal(vectors["cases"]!.AsArray().Count, vectors["caseCount"]!.GetValue<int>());
        var constants = vectors["constants"]!;
        Assert.Equal(VoiceRewriteSlots.PauseSeconds, constants["pauseSeconds"]!.GetValue<double>());
        Assert.Equal(VoiceRewriteSlots.MaximumSlots, constants["maximumSlots"]!.GetValue<int>());
        Assert.Equal(VoiceRewriteSlots.Closing, constants["closing"]!.GetValue<string>());
        Assert.Equal(VoiceLabRewriteFit.OnsetSeconds, constants["onsetSeconds"]!.GetValue<double>());
        Assert.Equal(VoiceLabRewriteFit.ProviderSpeechRateMultiplier, constants["providerSpeechRateMultiplier"]!.GetValue<double>());
        Assert.Equal(VoiceLabRateCalibration.PriorSpread, constants["priorSpread"]!.GetValue<double>());
        var bytes = File.ReadAllBytes(Path.Combine(FixtureLoader.SharedRoot, "prompts/voice-rewrite.json")).Where(value => value != 0x0D).ToArray();
        Assert.Equal(Convert.ToHexStringLower(SHA256.HashData(bytes)), vectors["sources"]!["shared/prompts/voice-rewrite.json"]!.GetValue<string>());
    }

    /// <summary>Budgets never exceed a span's own words, tighten as the voice runs slower than the prior, and a pause or punctuation
    /// closes a span; more than 60 spans send none (Mac <c>budgetsNeverExceedTheSpansWords</c>, <c>aPauseClosesASpanAndTheCapHolds</c>).</summary>
    [Fact]
    public void SpansAndBudgetsReplayTheSharedVectors()
    {
        foreach (var row in Vectors()["cases"]!.AsArray())
        {
            var id = row!["id"]!.GetValue<string>();
            var words = Words(row["words"]);
            var wordsPerSecond = VoiceRewriteSlots.WordsPerSecond(words);
            Assert.True(Math.Abs(wordsPerSecond - row["wordsPerSecond"]!.GetValue<double>()) < 1e-12, id);
            var slots = VoiceRewriteSlots.Make(words, wordsPerSecond, row["multiplier"]!.GetValue<double>(), row["spread"]!.GetValue<double>());
            if (row["slots"] is null) { Assert.Null(slots); continue; }
            var expected = row["slots"]!.AsArray();
            Assert.Equal(expected.Count, slots!.Count);
            foreach (var (slot, want) in slots.Zip(expected))
            {
                Assert.Equal(want!["text"]!.GetValue<string>(), slot.Text);
                Assert.True(Math.Abs(want["seconds"]!.GetValue<double>() - slot.Seconds) < 1e-12, id);
                Assert.Equal(want["maxWords"]!.GetValue<int>(), slot.MaxWords);
                Assert.True(slot.MaxWords <= slot.Text.Split(' ').Length, id);
            }
            // The request renders exactly the shared block.
            var request = new VoiceRewriteRequest(Guid.NewGuid(), VoiceRewriteScope.Passage, words, "", "en", 9.5, 90, 100) { Slots = slots };
            var prompt = JsonNode.Parse(FixtureLoader.ReadText("prompts/voice-rewrite.json"))!.AsObject();
            Assert.Contains("\n\n" + row["slotsBlock"]!.GetValue<string>(), VoiceRewriteService.RequestText(request, "x", prompt).Instruction);
        }
        var slow = Vectors()["cases"]!.AsArray().Single(row => row!["id"]!.GetValue<string>() == "calibrated-voice-tightens")!["slots"]!.AsArray();
        var prior = Vectors()["cases"]!.AsArray().Single(row => row!["id"]!.GetValue<string>() == "punctuation-closes-spans")!["slots"]!.AsArray();
        Assert.All(slow.Zip(prior), pair => Assert.True(pair.First!["maxWords"]!.GetValue<int>() < pair.Second!["maxWords"]!.GetValue<int>()));
    }

    [Fact]
    public void TheRequestSaysWhyAndListsEachSlot()
    {
        var prompt = JsonNode.Parse(FixtureLoader.ReadText("prompts/voice-rewrite.json"))!.AsObject();
        Assert.Equal(4, prompt["promptVersion"]!.GetValue<int>());
        var system = prompt["system"]!.GetValue<string>();
        Assert.Contains("picture keeps running", system);
        Assert.Contains("never pad", system);
        var words = new[] { new TimedWord("w0", "that", WordKind.Word, 1, 1.4, null, null, 1, null, TimingSource.Native) };
        var input = new VoiceRewriteRequest(Guid.NewGuid(), VoiceRewriteScope.Passage, words, "Viral YouTuber", "en", 9.5, 90, 100);
        var plain = VoiceRewriteService.RequestText(input, "x", prompt).Instruction;
        Assert.DoesNotContain("TIME IN THE VIDEO", plain);
        Assert.Contains("no more time than that: at most 100", plain);
        var text = VoiceRewriteService.RequestText(input with
        {
            Slots = [new("that is", 1.1, 2), new("{index} of course, it doesn't mean that", 3.7, 6)]
        }, "x", prompt).Instruction;
        Assert.Contains("TIME IN THE VIDEO (the picture keeps running", text);
        Assert.Contains("1. “that is”: 1.1 s, at most 2 words", text);
        Assert.Contains("2. “{index} of course, it doesn't mean that”: 3.7 s, at most 6 words", text);
        // Slots come after the length line and before any feedback.
        Assert.True(text.IndexOf("at most 100", StringComparison.Ordinal) < text.IndexOf("TIME IN THE VIDEO", StringComparison.Ordinal));
    }

    [Fact]
    public async Task ARequestWithMalformedSlotsIsRefusedBeforeAnySend()
    {
        var ct = TestContext.Current.CancellationToken;
        var service = new VoiceRewriteService(new LlmCatalog());
        var connector = new Connector();
        var words = new[] { new TimedWord("w0", "that", WordKind.Word, 1, 1.4, null, null, 1, null, TimingSource.Native) };
        var input = new VoiceRewriteRequest(Guid.NewGuid(), VoiceRewriteScope.Passage, words, "", "en", 9.5, 90, 100);
        Assert.NotNull(await service.PrepareAsync(input with { Slots = [new("that", 0.4, 1)] }, connector, "model", ct));
        foreach (var slots in new IReadOnlyList<VoiceRewriteSlot>[]
        {
            [new("that", 0, 1)], [new("that", double.NaN, 1)], [new("that", 1, 0)], [new("", 1, 1)],
            Enumerable.Range(0, 61).Select(index => new VoiceRewriteSlot("w" + index, 1, 1)).ToArray()
        })
            await Assert.ThrowsAnyAsync<Exception>(() => service.PrepareAsync(input with { Slots = slots }, connector, "model", ct));
        Assert.Equal(0, connector.Sends);
    }

    private sealed class Connector : ILlmConnector
    {
        internal int Sends { get; private set; }
        public ConnectorId Id => ConnectorId.Ollama;
        public Task<ConnectorStatus> GetStatusAsync(CancellationToken ct) => Task.FromResult<ConnectorStatus>(new ConnectorStatus.Ready());
        public Task<IReadOnlyList<LlmModel>> GetModelsAsync(bool refresh, CancellationToken ct) =>
            Task.FromResult<IReadOnlyList<LlmModel>>([new("model", "Model", null, 32768, ModelSource.Discovered)]);
        public Task<int?> GetContextTokensAsync(string model, CancellationToken ct) => Task.FromResult<int?>(32768);
        public Task<RawCompletion> SendAsync(LlmRequest request, string model, CancellationToken ct)
        { Sends++; throw new InvalidOperationException("No send in this test."); }
    }

    [Fact]
    public void TheFitAndPatchPromptsSayWhyAndNeverAskForPadding()
    {
        var fit = JsonNode.Parse(FixtureLoader.ReadText("prompts/voice-rewrite-fit.json"))!;
        Assert.Equal(2, fit["promptVersion"]!.GetValue<int>());
        Assert.Contains("picture keeps running", fit["system"]!.GetValue<string>());
        Assert.Contains("Never add filler", fit["request"]!["longerPhraseLine"]!.GetValue<string>());
        Assert.Contains("fewer words are fine", fit["request"]!["fitFeedbackBlock"]!.GetValue<string>());
        var patch = JsonNode.Parse(FixtureLoader.ReadText("prompts/patch-rewrite.json"))!;
        Assert.Contains("The video keeps running under the new words", patch["system"]!.GetValue<string>());
        Assert.DoesNotContain("same number of syllables", patch["request"]!["rangesLine"]!.GetValue<string>());
        foreach (var tone in JsonNode.Parse(FixtureLoader.ReadText("data/rewrite-tones.json"))!["tones"]!.AsArray())
        {
            var instruction = tone!["instruction"]!.GetValue<string>();
            Assert.True(instruction.Contains("never pad", StringComparison.Ordinal) || instruction.Contains("Never pad", StringComparison.Ordinal), tone["id"]!.ToString());
            Assert.DoesNotContain("about as long as", instruction);
            Assert.DoesNotContain("close to the length", instruction);
        }
    }
}
