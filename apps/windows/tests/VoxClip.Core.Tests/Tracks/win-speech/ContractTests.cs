using System.Text.Json;
using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Domain.Transcript;
using VoxClip.Core.Services.Models;
using VoxClip.Core.Services.LLM;
using VoxClip.Core.Services.Project;
using VoxClip.Core.Services.Speech;
using VoxClip.Tests.Support;
using Xunit;

namespace VoxClip.Core.Tests.Tracks.Speech;

public sealed class ContractTests
{
    [Fact]
    public void UserCopyNeverTreatsAutoAsALanguageOrInventsAModelSize()
    {
        Assert.Equal("Which language is spoken?", SpeechCopy.Unsupported(TranscriptEngine.Whispercpp, "auto").Message);
        Assert.Equal("Whisper can't transcribe et.", SpeechCopy.Unsupported(TranscriptEngine.Whispercpp, "et").Message);
        Assert.Equal("Download the unknown-model model to transcribe on this PC.", SpeechCopy.ModelMissing(null, "unknown-model", 0).Message);
        Assert.Equal("Download the Whisper model to transcribe on this PC.", SpeechCopy.ModelMissing(null, null, 0).Message);
    }

    [Fact]
    public void CompositionSignaturesMatchW5()
    {
        Assert.NotNull(typeof(TranscriptionService).GetConstructor([typeof(IReadOnlyList<ITranscriber>), typeof(DataLocations)]));
        Assert.NotNull(typeof(ElevenLabsTranscriber).GetConstructor([typeof(IKeyProvider), typeof(ElevenLabsRegion), typeof(ModelCatalog), typeof(Core.Services.Logging.ILog)]));
        Assert.DoesNotContain(typeof(ElevenLabsTranscriber).GetConstructors().SelectMany(constructor => constructor.GetParameters()),
            parameter => parameter.ParameterType == typeof(HttpClient));
        Assert.NotNull(typeof(ModelStore).GetConstructor([typeof(IModelCatalog), typeof(DataLocations), typeof(HttpClient)]));
        Assert.NotNull(typeof(ITranscriptionService).GetMethod(nameof(ITranscriptionService.TranscribeAsync),
            [typeof(TranscriptionRequest), typeof(AudioEnvelope), typeof(IProgress<TranscriptionProgress>), typeof(CancellationToken)]));
    }

    [Theory]
    [InlineData("est", "taltech-et-verbatim-2604-q8_0")]
    [InlineData("eng", "whisper-small.en-q5_1")]
    [InlineData("de", "whisper-large-v3-turbo-q5_0")]
    public void PublicRouterUsesCatalogueInstalledModelPreference(string language, string expected)
    {
        var plan = LanguageRouter.Route(new LanguageChoice.Forced(language), TranscriptEngine.Whispercpp,
            ["whisper-large-v3-turbo-q5_0", "whisper-small.en-q5_1", "taltech-et-verbatim-2604-q8_0"]);
        Assert.Equal(expected, plan.Model);
        Assert.Equal(TranscriptEngine.Whispercpp, plan.Engine);
    }

    [Fact]
    public void PublicRouterDoesNotUploadForAutoDetection()
    {
        var error = Assert.Throws<VoxClipException>(() => LanguageRouter.Route(new LanguageChoice.Auto(), TranscriptEngine.Whispercpp, []));
        Assert.Equal(VoxClipErrorCode.TranscriptionLanguageUnsupported, error.Code);
        Assert.Equal("Which language is spoken?", error.Message);
        Assert.Equal("whisper-large-v3-turbo-q5_0", LanguageRouter.Route(new LanguageChoice.Auto(), TranscriptEngine.Whispercpp,
            ["whisper-large-v3-turbo-q5_0"]).Model);
        Assert.Equal(TranscriptEngine.Elevenlabs, LanguageRouter.Route(new LanguageChoice.Auto(), TranscriptEngine.Elevenlabs, []).Engine);
    }

    [Fact]
    public async Task CatalogueConstructorReadsTheSharedRoot()
    {
        var models = await new ModelCatalog(FixtureLoader.SharedRoot).GetModelsAsync(TestContext.Current.CancellationToken);
        Assert.Equal(9, models.Count);
    }

    [Theory]
    [InlineData("missing")]
    [InlineData("directory")]
    [InlineData("syntax")]
    [InlineData("schema")]
    public async Task CatalogueFailuresUseTheSharedResourcesError(string failure)
    {
        using var files = new SpeechFiles();
        var directory = Path.Combine(files.Root, "catalog");
        Directory.CreateDirectory(directory);
        var file = Path.Combine(directory, "transcription-models.json");
        if (failure == "directory") Directory.CreateDirectory(file);
        if (failure == "syntax") await File.WriteAllTextAsync(file, "{", TestContext.Current.CancellationToken);
        if (failure == "schema") await File.WriteAllTextAsync(file, "{}", TestContext.Current.CancellationToken);
        var error = await Assert.ThrowsAsync<VoxClipException>(() => new ModelCatalog(files.Root).GetModelsAsync(TestContext.Current.CancellationToken));
        Assert.Equal(VoxClipErrorCode.SharedResourcesMissing, error.Code);
        Assert.Equal("VoxClip is missing some of its files. Reinstall VoxClip.", error.Message);
    }

    [Theory]
    [InlineData(TranscriptEngine.Elevenlabs, "elevenlabs")]
    [InlineData(TranscriptEngine.Whispercpp, "whispercpp")]
    [InlineData(TranscriptEngine.AppleSpeech, "apple-speech")]
    public void EngineIdentityHasOneShapeInBothGeneratedContexts(TranscriptEngine engine, string wireValue)
    {
        var identity = new EngineRef(engine, null, null, "test-version", null);
        var rawJson = JsonSerializer.Serialize(identity, TranscriptJsonContext.Default.EngineRef);
        var projectJson = JsonSerializer.Serialize(identity, ProjectJsonContext.Default.EngineRef);
        foreach (var json in new[] { rawJson, projectJson })
        {
            using var document = JsonDocument.Parse(json);
            var root = document.RootElement;
            Assert.Equal(new[] { "id", "modelId", "modelSha256", "engineVersion", "locale" }, root.EnumerateObject().Select(property => property.Name));
            Assert.Equal(wireValue, root.GetProperty("id").GetString());
            Assert.Equal(JsonValueKind.Null, root.GetProperty("modelId").ValueKind);
            Assert.Equal(JsonValueKind.Null, root.GetProperty("modelSha256").ValueKind);
            Assert.Equal(JsonValueKind.Null, root.GetProperty("locale").ValueKind);
        }
        Assert.Equal(identity, JsonSerializer.Deserialize(rawJson, TranscriptJsonContext.Default.EngineRef));
        Assert.Equal(identity, JsonSerializer.Deserialize(projectJson, ProjectJsonContext.Default.EngineRef));
        Assert.Equal(typeof(EngineRef), typeof(Transcript).GetProperty(nameof(Transcript.Engine))!.PropertyType);
        Assert.Equal(typeof(EngineRef), typeof(RawTranscript).GetProperty(nameof(RawTranscript.Engine))!.PropertyType);
    }
}
