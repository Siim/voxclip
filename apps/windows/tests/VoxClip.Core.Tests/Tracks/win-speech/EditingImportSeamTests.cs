using System.Text.Json;
using VoxClip.Core.Domain.Editing;
using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Domain.Transcript;
using VoxClip.Tests.Support;
using Xunit;

namespace VoxClip.Core.Tests.Tracks.Speech;

public sealed class EditingImportSeamTests
{
    public static IEnumerable<object[]> Fixtures() => new[] { "pipeline", "tighten", "gaps" }
        .SelectMany(folder => Directory.GetFiles(Path.Combine(FixtureLoader.SharedRoot, "fixtures", "editing", folder), "*.json"))
        .Order(StringComparer.Ordinal).Select(path => new object[] { path });

    [Theory]
    [MemberData(nameof(Fixtures))]
    public void SharedEditingCasesReachTheSingleImportPipeline(string path)
    {
        using var document = JsonDocument.Parse(File.ReadAllText(path));
        var fixture = document.RootElement;
        var input = fixture.GetProperty("input");
        var words = input.TryGetProperty("rawWords", out var rawWords) ? rawWords : input.GetProperty("words");
        var tokens = words.EnumerateArray().Select(word => new RawToken(
            word.TryGetProperty("text", out var text) ? text.GetString()! : word.GetProperty("id").GetString()!, false,
            word.GetProperty("start").GetDouble(), word.GetProperty("end").GetDouble(),
            word.TryGetProperty("conf", out var confidence) ? confidence.GetDouble() : null, null,
            word.TryGetProperty("kind", out var kind) && kind.GetString() == "event" ? WordKind.Event : null, 0)).ToArray();
        var timing = input.TryGetProperty("timing", out var source) ? Enum.Parse<TimingSource>(source.GetString()!, true) : TimingSource.Native;
        var verbatim = input.TryGetProperty("verbatim", out var value) && value.GetBoolean();
        var audio = input.GetProperty("audio");
        var envelope = audio.ValueKind == JsonValueKind.Null ? null : Envelope(audio);
        var duration = audio.ValueKind == JsonValueKind.Null ? 10 : audio.GetProperty("seconds").GetDouble();
        var raw = new RawTranscript(new(TranscriptEngine.Elevenlabs, "scribe_v2", null, "fixture", null), 1,
            new(GroupingEnd.LastToken, GroupingConfidence.Single, false), tokens, "en", null, verbatim, timing, null);
        var expected = EditingImport.Pipeline(WordAssembler.Group(tokens, raw.Grouping, 0), envelope, timing, verbatim, duration);
        var actual = TranscriptPostProcessor.Process(raw, duration, envelope, new string('a', 64), DateTimeOffset.UnixEpoch);
        Assert.Equal(expected.Words, actual.Words);
        Assert.Equal(envelope is not null, actual.Refined);
        if (fixture.GetProperty("kind").GetString() == "import-pipeline")
        {
            var golden = fixture.GetProperty("expected").GetProperty("words").EnumerateArray().ToArray();
            Assert.Equal(golden.Length, actual.Words.Count);
            foreach (var pair in golden.Zip(actual.Words))
            {
                Assert.Equal(pair.First.GetProperty("text").GetString(), pair.Second.Text);
                Assert.Equal(pair.First.GetProperty("start").GetDouble(), pair.Second.Start, 6);
                Assert.Equal(pair.First.GetProperty("end").GetDouble(), pair.Second.End, 6);
            }
        }
    }

    private static AudioEnvelope Envelope(JsonElement audio)
    {
        var rate = audio.GetProperty("sampleRate").GetInt32();
        var samples = new float[(int)(audio.GetProperty("seconds").GetDouble() * rate)];
        double seed = 7;
        double Noise() { seed = seed * 16807 % 2147483647; return seed / 2147483647 * 2 - 1; }
        for (var sample = 0; sample < samples.Length; sample++) samples[sample] = (float)(0.002 * Noise());
        foreach (var section in audio.GetProperty("sections").EnumerateArray())
            for (var sample = (int)Math.Round(section[0].GetDouble() * rate); sample < (int)Math.Round(section[1].GetDouble() * rate); sample++)
                if (sample < samples.Length) samples[sample] = (float)(section[2].GetString() == "vowel"
                    ? 0.5 * Math.Sin(2 * Math.PI * 180 * sample / rate) : 0.1 * Noise());
        var builder = new AudioEnvelopeBuilder(rate, 1);
        builder.Append(samples);
        return builder.Finish();
    }
}
