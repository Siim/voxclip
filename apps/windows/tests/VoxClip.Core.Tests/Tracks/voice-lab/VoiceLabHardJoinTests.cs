using System.Text.Json;
using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Domain.Transcript;
using VoxClip.Core.Domain.VoiceLab;
using VoxClip.Tests.Support;
using Xunit;

namespace VoxClip.Core.Tests.Tracks.VoiceLab;

public sealed class VoiceLabHardJoinTests
{
    [Fact]
    public void NewRoomToneSelectionSkipsDigitalSilenceWithoutChangingLegacy()
    {
        var envelope = new AudioEnvelope(24000, 0.01, Enumerable.Repeat(0f, 50).Concat(Enumerable.Repeat(0.001f, 100)).ToArray());
        var legacy = VoiceLabRoomToneSelection.Select([], envelope, 24000, 36000);
        var matched = VoiceLabRoomToneSelection.Select([], envelope, 24000, 36000, true);
        Assert.Equal(0, legacy.SourceStartSample);
        Assert.Equal(12000, matched.SourceStartSample);
    }

    [Theory]
    [InlineData(0.0)]
    [InlineData(0.001)]
    public void PreflightKeepsDigitalSilenceOnlyForSilentNeighbours(double background)
    {
        const int rate = 24000;
        var source = Enumerable.Range(0, rate * 8).Select(index =>
        {
            var seconds = index / (double)rate;
            var amplitude = seconds < 0.5 ? 0 : seconds >= 1 && seconds < 4 ? 0.1 : background;
            return (float)(amplitude * Math.Sin(2 * Math.PI * 1000 * seconds));
        }).ToArray();
        var input = new VoiceLabTakeInput("word", "fixture", "fixture", "en", 1, "fixture", source, rate,
            [new TimedWord("w", "speech", WordKind.Word, 1, 4, null, null, null, null, TimingSource.Native)], new HashSet<string>(), Window(rate), null, null, false, true);
        var room = Assert.IsType<VoiceLabRoomTone>(VoiceLabTakeProcessing.Preflight(input).RoomTone);
        if (background == 0)
        {
            Assert.Equal(0, room.SourceStartSample);
            Assert.Equal(0, room.GainDb);
            Assert.Null(room.EndGainDb);
        }
        else Assert.True(room.SourceStartSample >= rate / 2);
    }

    private static readonly JsonSerializerOptions Options = new(JsonSerializerDefaults.Web);

    [Fact]
    public void SharedReviewBedAndShortSourceFades()
    {
        using var document = JsonDocument.Parse(FixtureLoader.ReadText("fixtures/voice-lab/hard-join-review-cases.json"));
        foreach (var row in document.RootElement.GetProperty("bedWeights").EnumerateArray())
            Assert.Equal(row.GetProperty("expected").GetDouble(), VoiceLabHardJoin.BedWeight(row.GetProperty("seconds").GetDouble(), 2,
                [new("first", 0.14, 0.44, true), new("second", 0.45, 1.86, true)], new(0.14, 0.44), new(-1.55, -0.14)));
        foreach (var row in document.RootElement.GetProperty("sourceFades").EnumerateArray())
        {
            var rate = row.GetProperty("rate").GetDouble();
            var count = VoiceLabHardJoin.SourceFadeFrames(rate, row.GetProperty("availableFrames").GetInt64());
            Assert.Equal(row.GetProperty("fadeFrames").GetInt64(), count);
            Assert.Equal(Math.Sqrt(0.5), VoiceLabHardJoin.SourceWeight(count / rate / 2, false, count / rate), 12);
        }
    }

    [Theory]
    [InlineData(0.0)]
    [InlineData(6.0)]
    public void ReservedPauseLevelIsAnAdvisoryIndependentOfSpeech(double gainDb)
    {
        const int rate = 24000;
        var source = Enumerable.Range(0, rate * 5).Select(index =>
            (float)((index >= rate && index < rate * 4 ? 0.1 : 0.001) * Math.Sin(2 * Math.PI * 1000 * index / rate))).ToArray();
        var input = new VoiceLabTakeInput("word", "fixture", "fixture", "en", 1, "fixture", source, rate,
            [new TimedWord("w", "speech", WordKind.Word, 1, 4, null, null, null, null, TimingSource.Native)], new HashSet<string>(), Window(rate), null, null, false, true);
        var mixed = Enumerable.Range(0, rate * 2).Select(index => (float)(0.001 * Math.Pow(10, gainDb / 20) * Math.Sin(2 * Math.PI * 1000 * index / rate))).ToArray();
        var excess = VoiceLabHardJoin.PauseExcess(mixed, rate, rate / 2, new(0.14, 0.44), true, input);
        Assert.InRange(Math.Abs(excess - gainDb), 0, 0.1);
        var qa = VoiceLabTakeQuality.Evaluate("word", ["word"], mixed, rate, [rate / 2], 1, 0.5, seamExcesses: [excess]);
        Assert.DoesNotContain(qa.Failures, failure => failure != VoiceLabTakeQaFailure.Loudness);
        Assert.Equal(gainDb > 2, qa.Failures.Contains(VoiceLabTakeQaFailure.Loudness));
    }
    private static JsonDocument Fixture() => JsonDocument.Parse(FixtureLoader.ReadText("fixtures/voice-lab/hard-join-cases.json"));
    private static VoiceLabMicroPause Pause(JsonElement element) => JsonSerializer.Deserialize<VoiceLabMicroPause>(element, Options)!;
    private static VoiceLabWindow Window(int rate, double duration = 1)
    {
        var start = rate * 2L;
        var end = start + (long)Math.Floor(duration * rate + 0.5);
        return new("w", "w", [], [], 2, 2 + duration, start, end,
            new(VoiceLabSeamKind.Hard, 2, start, (long)(rate * 0.012)), new(VoiceLabSeamKind.Hard, 2 + duration, end, (long)(rate * 0.012)));
    }

    [Fact]
    public void SharedFadeAndGainCurvesReplayOnBothGrids()
    {
        using var document = Fixture();
        var fixture = document.RootElement;
        Assert.Equal("voxclip-hard-join/1", fixture.GetProperty("schema").GetString());
        Assert.Equal(42, fixture.GetProperty("caseCount").GetInt32());
        var incoming = Pause(fixture.GetProperty("incoming"));
        var outgoing = Pause(fixture.GetProperty("outgoing"));
        var gain = new VoiceLabEdgeGain(new(6, incoming), new(6, outgoing));
        foreach (var rateElement in fixture.GetProperty("rates").EnumerateArray())
        {
            var rate = rateElement.GetInt32();
            foreach (var row in fixture.GetProperty("fades").EnumerateArray())
            {
                var seconds = Math.Floor(row.GetProperty("seconds").GetDouble() * rate + 0.5) / rate;
                var curve = row.GetProperty("curve").GetString();
                var measured = curve == "generated" ? VoiceLabHardJoin.GeneratedWeight(seconds, 2, incoming, outgoing) : VoiceLabHardJoin.SourceWeight(seconds, curve == "source-in");
                Assert.InRange(Math.Abs(measured - row.GetProperty("expected").GetDouble()), 0, 1e-10);
            }
            foreach (var row in fixture.GetProperty("gains").EnumerateArray())
            {
                var seconds = Math.Floor(row.GetProperty("seconds").GetDouble() * rate + 0.5) / rate;
                Assert.InRange(Math.Abs(VoiceLabHardJoin.EdgeGainDb(seconds, 2, gain) - row.GetProperty("expectedDb").GetDouble()), 0, 1e-10);
            }
        }
    }

    [Fact]
    public void SharedValidationAndOptionalFieldRoundTrips()
    {
        using var document = Fixture();
        foreach (var row in document.RootElement.GetProperty("validation").EnumerateArray())
        {
            var pause = row.GetProperty("microPause").ValueKind == JsonValueKind.Null ? null : Pause(row.GetProperty("microPause"));
            var kind = row.GetProperty("kind").GetString() == "hard" ? VoiceLabSeamKind.Hard : VoiceLabSeamKind.Gap;
            var seam = new VoiceLabSeam(kind, 576, 288, 144, pause);
            var gain = row.GetProperty("gainDb").ValueKind == JsonValueKind.Null ? null : new VoiceLabEdgeGain(Out: new(row.GetProperty("gainDb").GetDouble(), pause ?? new(-0.44, -0.14)));
            var seams = new VoiceLabSeams(new(VoiceLabSeamKind.None, 0, 0, 0), seam);
            if (row.GetProperty("valid").GetBoolean()) VoiceLabHardJoin.Validate(seams, gain, 2);
            else Assert.Throws<VoiceLabProjectException>(() => VoiceLabHardJoin.Validate(seams, gain, 2));
            var encoded = JsonSerializer.Serialize(seam, Options);
            Assert.Equal(seam, JsonSerializer.Deserialize<VoiceLabSeam>(encoded, Options));
            Assert.Equal(pause is not null, encoded.Contains("microPause", StringComparison.Ordinal));
        }
    }

    [Fact]
    public void SharedReserveCountsBeforePaceAndLeavesLegacyUnchanged()
    {
        using var document = Fixture();
        var row = document.RootElement.GetProperty("reserve");
        foreach (var rateElement in document.RootElement.GetProperty("rates").EnumerateArray())
        {
            var rate = rateElement.GetInt32();
            var window = Window(rate);
            var seconds = row.GetProperty("speechSeconds").GetDouble();
            var legacy = VoiceLabRewriteFit.Hypothetical(window, null, null, seconds, rate);
            var fit = VoiceLabRewriteFit.Hypothetical(window, null, null, seconds, rate, hardJoinSmoothing: true);
            Assert.Equal(row.GetProperty("legacyOutputSeconds").GetDouble(), legacy.Plan.OutputFrames / (double)rate, 9);
            Assert.Equal(row.GetProperty("outputSeconds").GetDouble(), fit.Plan.OutputFrames / (double)rate, 9);
            Assert.Equal((long)(row.GetProperty("padSeconds").GetDouble() * rate), fit.Plan.Incoming.PadFrames);
            Assert.Equal(fit.Plan.Incoming.PadFrames, fit.Plan.Outgoing.PadFrames);
            Assert.Equal(window.StartSample, fit.Plan.WindowStartSample);
            Assert.Equal(window.EndSample, fit.Plan.WindowEndSample);
            var timing = VoiceLabPaceMatching.Match(seconds, window, null, null, rate);
            Assert.Equal(row.GetProperty("pace").GetDouble(), timing.Pace);
            Assert.Equal(row.GetProperty("fits").GetBoolean(), timing.Fits);
        }
    }

    [Fact]
    public void SpeechCheckExcludesPauseAndGainKeepsItsPeakCap()
    {
        const int rate = 24000;
        using var document = Fixture();
        var row = document.RootElement.GetProperty("joinCheck");
        foreach (var pause in row.GetProperty("pauseSeconds").EnumerateArray().Select(value => value.GetDouble()))
        {
            var edge = new VoiceLabMicroPause(-pause - 0.3, -pause);
            var samples = Enumerable.Range(0, rate * 2).Select(index =>
            {
                var seconds = index / (double)rate;
                return seconds >= 1 - pause && seconds < 1 ? 0f : (float)(0.1 * Math.Sin(2 * Math.PI * 1000 * seconds));
            }).ToArray();
            Assert.InRange(Math.Abs(VoiceLabHardJoin.SpeechStep(samples, rate, rate, edge, false) - row.GetProperty("speechStepDb").GetDouble()), 0, 1e-4);
        }
        var quiet = Enumerable.Range(0, rate).Select(index => (float)(0.1 * Math.Sin(2 * Math.PI * 1000 * index / rate))).ToArray();
        Assert.Equal(6, VoiceLabHardJoin.MatchingGain(quiet, quiet.Select(sample => sample * 5).ToArray(), rate));
        var nearPeak = quiet.Select(sample => sample * 9).ToArray();
        Assert.Equal(0, VoiceLabHardJoin.MatchingGain(nearPeak, nearPeak.Select(sample => sample * 2).ToArray(), rate));
        Assert.Equal(1, VoiceLabHardJoin.BedWeight(1, 2, [new("speech", 0.14, 1.86, true)], new(0.14, 1.86), new(-1.86, -0.14)));
        var shared = new VoiceLabEdgeGain(new(6, new(0.14, 0.86)), new(6, new(-0.86, -0.14)));
        Assert.Equal(6, VoiceLabHardJoin.EdgeGainDb(0.5, 1, shared));
    }

    [Fact]
    public void AcousticSearchKeepsDecayBeyondTheOldTrim()
    {
        const int rate = 24000;
        using var document = Fixture();
        var row = document.RootElement.GetProperty("acoustic");
        var samples = Enumerable.Range(0, rate).Select(index =>
        {
            var seconds = index / (double)rate;
            return seconds >= row.GetProperty("audioStart").GetDouble() && seconds < row.GetProperty("audioEnd").GetDouble() ? (float)(0.1 * Math.Sin(2 * Math.PI * 1000 * seconds)) : 0f;
        }).ToArray();
        var words = VoiceLabHardJoin.Refine([new("word", row.GetProperty("alignedStart").GetDouble(), row.GetProperty("alignedEnd").GetDouble(), true)], samples, rate);
        Assert.InRange(Math.Abs(words[0].Start - row.GetProperty("audioStart").GetDouble()), 0, 0.005);
        Assert.InRange(Math.Abs(words[0].End - row.GetProperty("audioEnd").GetDouble()), 0, 0.005);
        Assert.Equal(VoiceLabHardJoin.AcousticSearchSeconds, row.GetProperty("searchLimitSeconds").GetDouble());
        Assert.True(VoiceLabAlignment.Trim(words, 1).End >= 0.85);
    }

    [Fact]
    public void RoomToneMatchesNeighbourPausesBeyondTheLegacyTwelveDbCap()
    {
        const int rate = 24000;
        using var document = Fixture();
        var row = document.RootElement.GetProperty("roomTone");
        var source = Enumerable.Range(0, rate * 8).Select(index =>
        {
            var seconds = index / (double)rate;
            var amplitude = seconds < 0.5 ? row.GetProperty("runAmplitude").GetDouble() : seconds >= 1 && seconds < 6 ? 0.1 : row.GetProperty("pauseAmplitude").GetDouble();
            return (float)(amplitude * Math.Sin(2 * Math.PI * 1000 * seconds));
        }).ToArray();
        var input = new VoiceLabTakeInput("word", "fixture", "fixture", "en", 1, "fixture", source, rate,
            [new TimedWord("w", "speech", WordKind.Word, 1, 6, null, null, null, null, TimingSource.Native)], new HashSet<string>(), Window(rate), null, null, false, true);
        var room = VoiceLabHardJoin.MatchedRoomTone(new(0, rate / 2, 0), input, -23);
        Assert.InRange(Math.Abs(room.GainDb - row.GetProperty("gainDb").GetDouble()), 0, 0.1);
        var filled = source.Take(rate / 2).Select(sample => sample * (float)Math.Pow(10, room.GainDb / 20)).ToArray();
        var target = source.Skip(rate * 7).Take(rate / 2).ToArray();
        Assert.InRange(Math.Abs(VoiceLabLoudness.MomentaryLufs(filled, rate, 0) - VoiceLabLoudness.MomentaryLufs(target, rate, 0)), 0, row.GetProperty("toleranceLu").GetDouble());
    }
}
