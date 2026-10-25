using VoxClip.Core.Domain.Transcript;
using VoxClip.Core.Services.Models;
using VoxClip.Core.Services.Speech;
using VoxClip.Tests.Support;
using Xunit;

namespace VoxClip.Core.Tests.Tracks.Speech;

public sealed class ElevenLabsLiveTests
{
    public static bool LiveEnabled => Environment.GetEnvironmentVariable("VOXCLIP_LIVE_TESTS") == "1" &&
        !string.IsNullOrWhiteSpace(Environment.GetEnvironmentVariable("VOXCLIP_ELEVENLABS_API_KEY"));

    [Fact(Skip = "Requires VOXCLIP_LIVE_TESTS=1 and VOXCLIP_ELEVENLABS_API_KEY; makes one paid call.", SkipUnless = nameof(LiveEnabled))]
    public async Task ScribeKeepsEnglishFiller()
    {
        var path = Environment.GetEnvironmentVariable("VOXCLIP_TEST_WAV") ??
            Path.Combine(FixtureLoader.SharedRoot, "fixtures", "transcription", "hello-um.wav");
        Assert.SkipUnless(File.Exists(path), "Provide the annotated hello-um.wav fixture or VOXCLIP_TEST_WAV.");
        using var files = new SpeechFiles();
        var sampleCount = (new FileInfo(path).Length - 44) / 2;
        var request = files.Request(language: new LanguageChoice.Forced("en")) with
        {
            Audio = new(path, sampleCount, sampleCount / 16000.0, 0, 0)
        };
        var engine = new ElevenLabsTranscriber(ElevenLabsTranscriber.CreateEnvironmentKeyProvider(), modelCatalog: new ModelCatalog());
        var transcript = await new TranscriptionService([engine], dataRoot: files.Root)
            .TranscribeAsync(request, new CaptureProgress<TranscriptionProgress>(), TestContext.Current.CancellationToken);
        Assert.Equal("en", transcript.Language);
        Assert.Contains(transcript.Words, word => System.Text.RegularExpressions.Regex.IsMatch(word.Text,
            "^(um+|uh+|erm+|hmm+)[,.!?]?$", System.Text.RegularExpressions.RegexOptions.IgnoreCase | System.Text.RegularExpressions.RegexOptions.CultureInvariant));
    }
}
