#if DEBUG
using System.Text.Json;
using VoxClip.Core.Domain.Transcript;
using VoxClip.Core.Domain.VoiceLab;

namespace VoxClip.App.Services;

internal static class DebugAvailableSpeakerCheck
{
    internal static bool Available => true;
}

internal sealed class DebugConsentScribe(string directory)
{
    internal int Calls { get; private set; }
    internal Task<RawTranscript> TranscribeAsync(VoiceConsentStatement statement, TranscriptionRequest request, CancellationToken ct)
    {
        ct.ThrowIfCancellationRequested();
        using var document = JsonDocument.Parse(File.ReadAllBytes(Path.Combine(directory, "consent-scribe.json")));
        var fixture = document.RootElement;
        if (fixture.GetProperty("language_code").GetString() != "eng" || request.Plan.Options.Diarize || request.Plan.Language is not LanguageChoice.Forced { Code: "en" })
            throw new InvalidOperationException("The consent probe requires forced English without diarization.");
        var tokens = statement.Text.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries);
        var duration = fixture.GetProperty("words").EnumerateArray().Last().GetProperty("end").GetDouble();
        Calls++;
        return Task.FromResult(new RawTranscript(new(TranscriptEngine.Elevenlabs, "scribe_v2", null, "debug-fixture", "en"), 1,
            new(GroupingEnd.LastToken, GroupingConfidence.Single, false), tokens.Select((word, index) => new RawToken(word, false,
                duration * index / tokens.Length, duration * (index + 1) / tokens.Length, 1, null, null, index)).ToArray(),
            "en", 1, true, TimingSource.Native, "consent-scribe-fixture"));
    }
}
#endif
