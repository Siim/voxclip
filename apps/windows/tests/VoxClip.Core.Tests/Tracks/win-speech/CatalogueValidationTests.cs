using System.Text.Json.Nodes;
using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Services.Models;
using VoxClip.Core.Services.Speech;
using VoxClip.Tests.Support;
using Xunit;

namespace VoxClip.Core.Tests.Tracks.Speech;

public sealed class CatalogueValidationTests
{
    [Theory]
    [InlineData("iso-missing")]
    [InlineData("iso-value")]
    [InlineData("whisper-map")]
    [InlineData("whisper-map-value")]
    [InlineData("limits-missing")]
    [InlineData("min-duration")]
    [InlineData("max-duration")]
    [InlineData("max-upload")]
    [InlineData("finite")]
    [InlineData("defaults-missing")]
    [InlineData("wildcard")]
    [InlineData("auto")]
    [InlineData("windows")]
    [InlineData("macos")]
    [InlineData("local")]
    [InlineData("local-item")]
    [InlineData("recommended")]
    [InlineData("low-memory")]
    [InlineData("whisper-metadata")]
    [InlineData("multilingual")]
    [InlineData("prompt-map")]
    [InlineData("preset")]
    [InlineData("vad")]
    public async Task EveryConsumedSectionFailsWithTheReinstallCopyBeforeUpload(string section)
    {
        using var files = new SpeechFiles();
        var source = JsonNode.Parse(await File.ReadAllTextAsync(Path.Combine(FixtureLoader.SharedRoot, "catalog", "transcription-models.json"),
            TestContext.Current.CancellationToken))!;
        var codes = source["languageCodes"]!;
        var limits = source["engines"]!.AsArray().Single(engine => engine!["id"]!.GetValue<string>() == "elevenlabs")!["limits"]!;
        var defaults = source["defaults"]!["byLanguage"]!;
        var whisper = source["models"]![0]!["whisper"]!;
        switch (section)
        {
            case "iso-missing": codes.AsObject().Remove("iso639_3"); break;
            case "iso-value": codes["iso639_3"]!["eng"] = null; break;
            case "whisper-map": codes["whisperCodeFor"] = new JsonArray(); break;
            case "whisper-map-value": codes["whisperCodeFor"]!["jv"] = 42; break;
            case "limits-missing": source["engines"]![0]!.AsObject().Remove("limits"); break;
            case "min-duration": limits["minDurationSeconds"] = "0.1"; break;
            case "max-duration": limits["maxDurationSeconds"] = null; break;
            case "max-upload": limits["maxUploadBytes"] = "3000000000"; break;
            case "finite": limits["maxDurationSeconds"] = JsonNode.Parse("1e400"); break;
            case "defaults-missing": source["defaults"]!.AsObject().Remove("byLanguage"); break;
            case "wildcard": defaults.AsObject().Remove("*"); break;
            case "auto": defaults.AsObject().Remove("auto"); break;
            case "windows": defaults["et"]!.AsObject().Remove("windows"); break;
            case "macos": defaults["et"]!["macos"] = 42; break;
            case "local": defaults["*"]!["windows"]!["local"] = null; break;
            case "local-item": defaults["auto"]!["windows"]!["local"]![0] = null; break;
            case "recommended": defaults["en"]!["windows"]!["recommendedDownload"] = 42; break;
            case "low-memory": defaults["en"]!["windows"]!["lowMemoryDownload"] = null; break;
            case "whisper-metadata": source["models"]![0]!.AsObject().Remove("whisper"); break;
            case "multilingual": whisper["multilingual"] = "true"; break;
            case "prompt-map": whisper["initialPromptByLanguage"]!["et"] = 42; break;
            case "preset": whisper["dtwAheadsPreset"] = null; break;
            case "vad": whisper["vadModel"] = 42; break;
        }
        var path = Path.Combine(files.Root, "catalog.json");
        await File.WriteAllTextAsync(path, source.ToJsonString(), TestContext.Current.CancellationToken);
        var catalog = ModelCatalog.FromFile(path);
        using var handler = new StubHttp((_, _) => throw new InvalidOperationException("Must not upload."));
        using var http = new HttpClient(handler);
        using var transcriber = new ElevenLabsTranscriber(new TestKeys(), http, baseUri: null, modelCatalog: catalog);
        var error = await Assert.ThrowsAsync<VoxClipException>(() => transcriber.TranscribeAsync(files.Request(),
            new CaptureProgress<Core.Domain.Transcript.TranscriptionProgress>(), TestContext.Current.CancellationToken));
        Assert.Equal(VoxClipErrorCode.SharedResourcesMissing, error.Code);
        Assert.Equal("VoxClip is missing some of its files. Reinstall VoxClip.", error.Message);
        Assert.Equal(0, handler.Calls);
    }
}
