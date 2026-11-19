using System.Text.Json;
using System.Text.Json.Nodes;
using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Domain.Transcript;
using VoxClip.Core.Domain.VoiceLab;
using VoxClip.Core.Services.Speech;
using VoxClip.Tests.Support;
using Xunit;

namespace VoxClip.Core.Tests.Tracks.Speech;

/// <summary>Scribe v3 upgrade, twin of the Mac <c>ScribeV3Tests</c>: one model id from the catalogue, legacy scribe_v2 plans
/// and projects, tolerant replies; transcription §8.</summary>
public sealed class ScribeV3Tests
{
    [Fact]
    public void ModelIdMatchesBothCatalogues()
    {
        var models = JsonNode.Parse(File.ReadAllText(Path.Combine(FixtureLoader.SharedRoot, "catalog", "transcription-models.json")))!;
        var engine = models["engines"]!.AsArray().Single(entry => entry!["id"]!.GetValue<string>() == "elevenlabs")!;
        Assert.Equal(ElevenLabsScribe.ModelId, engine["modelId"]!.GetValue<string>());
        var prices = JsonNode.Parse(File.ReadAllText(Path.Combine(FixtureLoader.SharedRoot, "catalog", "voice-lab.json")))!;
        var row = Assert.Single(prices["entries"]!.AsArray(), entry => entry!["operation"]!.GetValue<string>() == "speechToText")!;
        Assert.Equal(ElevenLabsScribe.ModelId, row["model"]!.GetValue<string>());
        Assert.Equal("scribe_v3", ElevenLabsScribe.ModelId);
        Assert.DoesNotContain(ElevenLabsScribe.ModelId, ElevenLabsScribe.LegacyModelIds);
    }

    [Theory]
    [InlineData(null)]
    [InlineData("scribe_v2")]
    [InlineData("scribe_v3")]
    public async Task EveryAcceptedPlanSendsTheCurrentModelWithoutV3OnlyFields(string? model)
    {
        using var files = new SpeechFiles();
        using var handler = new StubHttp(async (message, ct) =>
        {
            var parts = Assert.IsAssignableFrom<MultipartFormDataContent>(message.Content).ToArray();
            var names = parts.Select(part => part.Headers.ContentDisposition!.Name!.Trim('"')).ToArray();
            Assert.Equal("model_id", names[0]);
            Assert.Equal("scribe_v3", await parts[0].ReadAsStringAsync(ct));
            Assert.DoesNotContain("numbers_format", names);
            Assert.DoesNotContain("secondary_language_codes", names);
            return StubHttp.Json(ElevenLabsTests.Response);
        });
        var engine = ElevenLabsTranscriber.ForTesting(new TestKeys(), handler, region: ElevenLabsRegion.Default);
        var service = new TranscriptionService([engine], dataRoot: files.Root);
        var request = files.Request(language: new LanguageChoice.Forced("et"));
        request = request with { Plan = request.Plan with { Model = model } };
        var transcript = await service.TranscribeAsync(request, new CaptureProgress<TranscriptionProgress>(), TestContext.Current.CancellationToken);
        Assert.Equal(1, handler.Calls);
        Assert.Equal(new EngineRef(TranscriptEngine.Elevenlabs, "scribe_v3", null, "scribe_v3", null), transcript.Engine);
        var cache = Assert.Single(Directory.EnumerateFiles(Path.Combine(files.Root, "Cache"), "*.json", SearchOption.AllDirectories));
        Assert.StartsWith("elevenlabs-scribe_v3-et-", Path.GetFileName(cache));
    }

    [Fact]
    public async Task AnUnknownModelNamesTheCurrentOne()
    {
        using var files = new SpeechFiles();
        using var handler = new StubHttp((_, _) => throw new InvalidOperationException("Must not upload."));
        var engine = ElevenLabsTranscriber.ForTesting(new TestKeys(), handler, region: ElevenLabsRegion.Default);
        var request = files.Request();
        request = request with { Plan = request.Plan with { Model = "scribe_v1" } };
        var error = await Assert.ThrowsAsync<VoxClipException>(() => new TranscriptionService([engine], dataRoot: files.Root)
            .TranscribeAsync(request, null, null, TestContext.Current.CancellationToken));
        Assert.Equal("Transcription stopped: ElevenLabs requires the scribe_v3 model. Your video is still here.", error.Message);
        Assert.Equal(0, handler.Calls);
    }

    [Fact]
    public async Task AScribeV2CacheEntryIsNotServedForAV3Request()
    {
        using var files = new SpeechFiles();
        using var handler = new StubHttp((_, _) => Task.FromResult(StubHttp.Json(ElevenLabsTests.Response)));
        var engine = ElevenLabsTranscriber.ForTesting(new TestKeys(), handler, region: ElevenLabsRegion.Default);
        var service = new TranscriptionService([engine], dataRoot: files.Root);
        var ct = TestContext.Current.CancellationToken;
        await service.TranscribeAsync(files.Request(), new CaptureProgress<TranscriptionProgress>(), ct);
        var cache = Assert.Single(Directory.EnumerateFiles(Path.Combine(files.Root, "Cache"), "*.json", SearchOption.AllDirectories));
        Assert.True((await service.TranscribeAsync(files.Request(), new CaptureProgress<TranscriptionProgress>(), ct)).FromCache);
        // The same entry recorded for scribe_v2, even at the v3 path, is a different key and never served.
        var entry = JsonNode.Parse(await File.ReadAllTextAsync(cache, ct))!;
        Assert.Equal("scribe_v3", entry["key"]!["model"]!.GetValue<string>());
        entry["key"]!["model"] = "scribe_v2";
        await File.WriteAllTextAsync(cache, entry.ToJsonString(), ct);
        var fresh = await service.TranscribeAsync(files.Request(), new CaptureProgress<TranscriptionProgress>(), ct);
        Assert.False(fresh.FromCache);
        Assert.Equal(2, handler.Calls);
    }

    [Theory]
    [InlineData("projects", "interview-take.voxclip")]
    [InlineData("projects", "five-questions.voxclip")]
    [InlineData("voice-lab", "full-take-project.voxclip")]
    public void AScribeV2ProjectOpensWithItsTranscriptAndEngineUnchanged(string folder, string name)
    {
        var json = File.ReadAllText(Path.Combine(FixtureLoader.SharedRoot, "fixtures", folder, name));
        var recorded = JsonNode.Parse(json)!["transcript"]!;
        var project = ProjectSerialization.Deserialize(json);
        var transcript = Assert.IsType<Transcript>(project.Transcript);
        Assert.Equal(TranscriptEngine.Elevenlabs, transcript.Engine.Id);
        Assert.Equal("scribe_v2", transcript.Engine.ModelId);
        Assert.Equal(recorded["engine"]!["engineVersion"]!.GetValue<string>(), transcript.Engine.EngineVersion);
        Assert.Equal(recorded["words"]!.AsArray().Select(word => word!["id"]!.GetValue<string>()), transcript.Words.Select(word => word.Id));
        Assert.Equal(recorded["words"]!.AsArray().Select(word => word!["text"]!.GetValue<string>()), transcript.Words.Select(word => word.Text));
        var saved = JsonNode.Parse(ProjectSerialization.Serialize(project))!;
        Assert.Equal("scribe_v2", saved["transcript"]!["engine"]!["modelId"]!.GetValue<string>());
    }

    [Theory]
    [InlineData("\"language_code\":null,")]
    [InlineData("")]
    public async Task AReplyWithoutALanguageCodeKeepsItsWords(string field)
    {
        var reply = "{" + field + "\"language_probability\":0.9,\"future_field\":{\"nested\":[1,2]},\"words\":[" +
            "{\"text\":\"Tere\",\"type\":\"word\",\"start\":0.1,\"end\":0.4,\"logprob\":-0.01,\"new_word_field\":\"x\"}," +
            "{\"text\":\" \",\"type\":\"spacing\",\"start\":0.4,\"end\":0.5}," +
            "{\"text\":\"täna\",\"type\":\"word\",\"start\":0.5,\"end\":0.9,\"logprob\":-0.1}],\"transcription_id\":\"abc123\"}";
        using var body = JsonDocument.Parse(reply);
        using var handler = new StubHttp((_, _) => throw new InvalidOperationException("Must not upload."));
        using var engine = ElevenLabsTranscriber.ForTesting(new TestKeys(), handler, region: ElevenLabsRegion.Default);
        var ct = TestContext.Current.CancellationToken;
        var forced = await engine.MapResponseAsync(body.RootElement, false, new LanguageChoice.Forced("et"), ct);
        Assert.Equal("et", forced.Language);
        Assert.Equal(["Tere", "täna"], forced.Tokens.Select(token => token.Text));
        var auto = await engine.MapResponseAsync(body.RootElement, false, new LanguageChoice.Auto(), ct);
        Assert.Null(auto.Language);
        Assert.Equal(["Tere", "täna"], auto.Tokens.Select(token => token.Text));
    }

    [Fact]
    public void AnAudioHourCostsTwentyCents()
    {
        var prices = VoiceLabPriceCatalog.Parse(File.ReadAllBytes(Path.Combine(FixtureLoader.SharedRoot, "catalog", "voice-lab.json")));
        var hour = VoiceLabPricing.Estimate(VoiceLabPricedOperation.ElevenLabsSpeechToText, ElevenLabsScribe.ModelId, 3600, 1, null, prices);
        Assert.Equal(0.20m, hour.Usd);
        Assert.Equal("list-2026-11-19", hour.Basis);
    }
}
