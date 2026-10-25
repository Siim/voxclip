using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Domain.Transcript;
using VoxClip.Core.Services.Speech;
using Xunit;

namespace VoxClip.Core.Tests.Tracks.Speech;

public sealed class LocalValidationTests
{
    [Theory]
    [InlineData("speakers-off", "Speaker count needs diarization and a value from 1 to 32")]
    [InlineData("speakers-zero", "Speaker count needs diarization and a value from 1 to 32")]
    [InlineData("speakers-33", "Speaker count needs diarization and a value from 1 to 32")]
    [InlineData("count", "At most 1000 keyterms are allowed")]
    [InlineData("markup", "Invalid keyterm: bad[term]")]
    [InlineData("empty", "Invalid keyterm: ")]
    [InlineData("words", "Invalid keyterm: one two three four five six")]
    [InlineData("newline", "Invalid keyterm: first\nsecond")]
    [InlineData("model", "ElevenLabs requires the scribe_v2 model")]
    public async Task DirectAndServiceValidationUseExactMacCopyBeforeUploading(string invalid, string reason)
    {
        var options = invalid switch
        {
            "speakers-off" => new TranscriptionOptions(NumSpeakers: 2),
            "speakers-zero" => new(Diarize: true, NumSpeakers: 0),
            "speakers-33" => new(Diarize: true, NumSpeakers: 33),
            "count" => new(Keyterms: Enumerable.Repeat("term", 1001).ToArray()),
            "markup" => new(Keyterms: ["bad[term]"]),
            "empty" => new(Keyterms: [""]),
            "words" => new(Keyterms: ["one two three four five six"]),
            "newline" => new(Keyterms: ["first\nsecond"]),
            _ => new()
        };
        using var files = new SpeechFiles();
        using var handler = new StubHttp((_, _) => throw new InvalidOperationException("Must not upload."));
        using var http = new HttpClient(handler);
        using var engine = new ElevenLabsTranscriber(new TestKeys(), http, baseUri: null);
        var request = files.Request(options);
        if (invalid == "model") request = request with { Plan = request.Plan with { Model = "not-scribe" } };
        var service = new TranscriptionService([engine], dataRoot: files.Root);
        var direct = await Assert.ThrowsAsync<VoxClipException>(() => engine.TranscribeAsync(request,
            new CaptureProgress<TranscriptionProgress>(), TestContext.Current.CancellationToken));
        var orchestrated = await Assert.ThrowsAsync<VoxClipException>(() => service.TranscribeAsync(request, null, null, TestContext.Current.CancellationToken));
        foreach (var error in new[] { direct, orchestrated })
        {
            Assert.Equal(VoxClipErrorCode.TranscriptionFailed, error.Code);
            Assert.Equal($"Transcription stopped: {reason}. Your video is still here.", error.Message);
        }
        Assert.Equal(0, handler.Calls);
        Assert.False(Directory.Exists(Path.Combine(files.Root, "Cache")));
    }

    [Fact]
    public async Task FiftyUnicodeScalarsAreRejectedWithTheOffendingTerm()
    {
        using var files = new SpeechFiles();
        using var engine = new ElevenLabsTranscriber(new TestKeys());
        var term = string.Concat(Enumerable.Repeat("õ", 50));
        var error = await Assert.ThrowsAsync<VoxClipException>(() => engine.TranscribeAsync(files.Request(new(Keyterms: [term])),
            new CaptureProgress<TranscriptionProgress>(), TestContext.Current.CancellationToken));
        Assert.Equal(VoxClipErrorCode.TranscriptionFailed, error.Code);
        Assert.Equal($"Transcription stopped: Invalid keyterm: {term}. Your video is still here.", error.Message);
    }

    [Theory]
    [InlineData("../en")]
    [InlineData("12")]
    public async Task InvalidForcedLanguageUsesTheUnsupportedCopyDirectlyAndThroughService(string language)
    {
        using var files = new SpeechFiles();
        using var engine = new ElevenLabsTranscriber(new TestKeys());
        var request = files.Request(language: new LanguageChoice.Forced(language));
        var service = new TranscriptionService([engine], dataRoot: files.Root);
        var direct = await Assert.ThrowsAsync<VoxClipException>(() => engine.TranscribeAsync(request,
            new CaptureProgress<TranscriptionProgress>(), TestContext.Current.CancellationToken));
        var orchestrated = await Assert.ThrowsAsync<VoxClipException>(() => service.TranscribeAsync(request, null, null, TestContext.Current.CancellationToken));
        foreach (var error in new[] { direct, orchestrated })
        {
            Assert.Equal(VoxClipErrorCode.TranscriptionLanguageUnsupported, error.Code);
            Assert.Equal($"ElevenLabs can't transcribe {language}.", error.Message);
        }
    }

    [Fact]
    public async Task WrongEngineUsesTheMacUnsupportedCodeAndCopy()
    {
        using var files = new SpeechFiles();
        using var engine = new ElevenLabsTranscriber(new TestKeys());
        var request = files.Request(language: new LanguageChoice.Forced("en"));
        request = request with { Plan = request.Plan with { Engine = TranscriptEngine.Whispercpp } };
        var error = await Assert.ThrowsAsync<VoxClipException>(() => engine.TranscribeAsync(request,
            new CaptureProgress<TranscriptionProgress>(), TestContext.Current.CancellationToken));
        Assert.Equal(VoxClipErrorCode.TranscriptionLanguageUnsupported, error.Code);
        Assert.Equal("ElevenLabs can't transcribe en.", error.Message);
    }
}
