using System.Buffers.Binary;
using System.Text.Json;
using VoxClip.Core.Domain.VoiceLab;
using VoxClip.Core.Services.Speech;
using Xunit;

namespace VoxClip.Core.Tests.Tracks.VoiceLab;

/// <summary>The tone match in take processing (voice-lab.md §8.7 item 2b; Mac <c>VoiceLabToneMatchTests</c>): a generated take is tilted
/// towards the speech beside it before its gain is measured; the user's own recorded take is left as it is.</summary>
public sealed class VoiceLabToneMatchTests
{
    private const int Rate = 24_000;

    private static float[] Signal(uint seed, int samples, string shape)
    {
        using var signal = JsonDocument.Parse($$"""{"seed":{{seed}},"samples":{{samples}},"shape":"{{shape}}","shift":2}""");
        return VoiceLabTiltReplayTests.Render(signal.RootElement);
    }

    /// <summary>Two seconds of a darker take (the mean of four noise samples) at 24 kHz, timed as "Hello there" from 0.3 to 0.8 s.</summary>
    private static VoiceLabAudioResult Take()
    {
        var samples = Signal(11, Rate * 2, "dark");
        var pcm = new byte[samples.Length * 2];
        for (var index = 0; index < samples.Length; index++)
            BinaryPrimitives.WriteInt16LittleEndian(pcm.AsSpan(index * 2), (short)Math.Round(samples[index] * 32_767.0, MidpointRounding.AwayFromZero));
        var receipt = new VoiceLabReceipt("elevenlabs", ElevenLabsRegion.Default, "fixture", "eleven_v3", null, Guid.NewGuid(), null, null);
        return new(pcm, Rate, [new("Hello", .3, .5), new(" ", .5, .6), new("there", .6, .8)], receipt);
    }

    private static VoiceLabTakeInput Input()
    {
        var window = new VoiceLabWindow("a", "b", [], [], 1, 2.5, 24_000, 60_000,
            new(VoiceLabSeamKind.Gap, 1, 24_000, 288), new(VoiceLabSeamKind.Gap, 2.5, 60_000, 288));
        return new("Hello there", "eleven_v3", "fixture", "en", 1, "fixture", Enumerable.Repeat(.1f, Rate * 4).ToArray(), Rate, [],
            new HashSet<string>(), window, 1, 1, true, true, HardJoinSmoothing: false);
    }

    /// <summary>The brighter original speech beside the window: white noise on both sides.</summary>
    private static VoiceLabTakePreflight Preflight() =>
        new(-20, null, VoiceLabTilt.NeighbourhoodBands(VoiceLabSourceExcerpt.Whole(Signal(12, Rate * 4, "white")), Rate, 24_000, 60_000));

    private static float[] Samples(VoiceLabAudioResult result) => Enumerable.Range(0, result.Pcm.Length / 2)
        .Select(index => BinaryPrimitives.ReadInt16LittleEndian(result.Pcm.AsSpan(index * 2)) / 32768f).ToArray();

    [Fact]
    public void AGeneratedTakeIsTiltedBeforeItsGainIsMeasured()
    {
        var plain = VoiceLabTakeProcessing.Process(Take(), Input(), Preflight());
        var matched = VoiceLabTakeProcessing.Process(Take(), Input(), Preflight(), matchTone: true);
        // A recorded take (and every caller that doesn't ask) is left as it is.
        Assert.Null(plain.TiltDbPerOctave);
        // The take is about 2 dB/octave darker than the speech beside it: the tilt is the clamp's most.
        Assert.Equal(2, matched.TiltDbPerOctave);
        Assert.Equal(plain.Trimmed.Length, matched.Trimmed.Length);
        Assert.False(plain.Trimmed.AsSpan().SequenceEqual(matched.Trimmed));
        // The cascade ran from the asset's first frame, then the trim was taken.
        var samples = Samples(Take());
        var start = Enumerable.Range(0, samples.Length - plain.Trimmed.Length + 1).First(index => samples.AsSpan(index, plain.Trimmed.Length).SequenceEqual(plain.Trimmed));
        var tilted = VoiceLabTilt.Apply(samples, VoiceLabTilt.Sections(2, Rate));
        Assert.True(tilted.AsSpan(start, matched.Trimmed.Length).SequenceEqual(matched.Trimmed));
        // The level is measured on the tilted take, so the gain still meets the speech beside it.
        var gain = VoiceLabLoudness.LevelGainDb(-20, VoiceLabLoudness.VoicedRmsDb(matched.Trimmed, Rate), VoiceLabLoudness.TruePeakDbtp(matched.Trimmed, Rate));
        Assert.Equal(gain, matched.GainDb);
        Assert.NotEqual(plain.GainDb, matched.GainDb);
    }

    [Fact]
    public void WithoutTheSpeechBesideItNothingIsTilted()
    {
        Assert.Null(VoiceLabTakeProcessing.Process(Take(), Input(), new(-20, null), matchTone: true).TiltDbPerOctave);
        var silent = new VoiceLabTakePreflight(-20, null,
            VoiceLabTilt.NeighbourhoodBands(VoiceLabSourceExcerpt.Whole(new float[Rate * 4]), Rate, 24_000, 60_000));
        Assert.Null(VoiceLabTakeProcessing.Process(Take(), Input(), silent, matchTone: true).TiltDbPerOctave);
    }

    [Fact]
    public void ThePreflightMeasuresTheSpeechBesideTheWindow()
    {
        // The source is the input's own: the level match's sides, the window excluded.
        var preflight = VoiceLabTakeProcessing.Preflight(Input() with { CleanAudioOn = true });
        Assert.NotNull(preflight.SourceTone);
        Assert.Equal(VoiceLabTilt.NeighbourhoodBands(Input().Source, Rate, 24_000, 60_000)!.Power, preflight.SourceTone!.Power);
    }
}
