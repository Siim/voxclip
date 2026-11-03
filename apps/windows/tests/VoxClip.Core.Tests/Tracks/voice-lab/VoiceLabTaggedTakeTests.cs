using System.Buffers.Binary;
using VoxClip.Core.Domain.VoiceLab;
using VoxClip.Core.Services.Speech;
using Xunit;

namespace VoxClip.Core.Tests.Tracks.VoiceLab;

public sealed class VoiceLabTaggedTakeTests
{
    private static VoiceLabTakeAnalysis Process(IReadOnlyList<VoiceLabAudioTag> tags, bool burst = false, bool hard = true,
        bool leading = false, bool tagCharacters = false, bool smoothing = true)
    {
        const int rate = 24000;
        var pcm = new byte[rate * 2 * 2];
        for (var index = 0; index < pcm.Length / 2; index++)
        {
            var expression = leading ? index is >= 2400 and < 4800 : index is >= 24000 and < 28800;
            var active = index is >= 7200 and < 19200 || burst && expression;
            var value = active ? (short)Math.Round(.1 * Math.Sin(2 * Math.PI * 200 * index / rate) * 32768) : (short)0;
            BinaryPrimitives.WriteInt16LittleEndian(pcm.AsSpan(index * 2), value);
        }
        var kind = hard ? VoiceLabSeamKind.Hard : VoiceLabSeamKind.Gap;
        var window = new VoiceLabWindow("a", "b", [], [], 1, 2.5, 24000, 60000,
            new(kind, 1, 24000, 288), new(kind, 2.5, 60000, 288));
        var input = new VoiceLabTakeInput("Hello there", "eleven_v3", "fixture", "en", 1, "fixture",
            Enumerable.Repeat(.1f, rate * 4).ToArray(), rate, [], new HashSet<string>(), window,
            hard ? null : 1, hard ? null : 1, true, true, HardJoinSmoothing: smoothing) { AudioTags = tags };
        var receipt = new VoiceLabReceipt("elevenlabs", ElevenLabsRegion.Default, "fixture", input.ModelId, null, Guid.NewGuid(), null, null);
        List<VoiceLabCharacterTiming> alignment = [new("Hello", .3, .5), new(" ", .5, .6), new("there", .6, .8)];
        if (tagCharacters)
        {
            var tag = new VoiceLabCharacterTiming(leading ? "[sighs]" : "[laughs]", leading ? .1 : 1, leading ? .2 : 1.2);
            if (leading) alignment.Insert(0, tag); else alignment.Add(tag);
        }
        return VoiceLabTakeProcessing.Process(new(pcm, rate, alignment, receipt), input, new(-20, null));
    }

    [Theory]
    [InlineData(false, false, false)]
    [InlineData(false, false, true)]
    [InlineData(false, true, false)]
    [InlineData(false, true, true)]
    [InlineData(true, false, false)]
    [InlineData(true, false, true)]
    [InlineData(true, true, false)]
    [InlineData(true, true, true)]
    public void EdgeSoundSurvivesNormalTrimOnEverySeam(bool leading, bool characters, bool hard)
    {
        var plain = Process([], hard: hard);
        var tagged = Process([new(leading ? 0 : 2, leading ? "sighs" : "laughs")], true, hard, leading, characters);
        Assert.Equal(plain.Trimmed.Length + (leading ? 4800 : 9600), tagged.Trimmed.Length);
        Assert.Contains(leading ? tagged.Trimmed.Take(2400) : tagged.Trimmed.TakeLast(2400), sample => Math.Abs(sample) > .05);
    }

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public void MidPhraseTagsLeaveTrimmedSamplesAndFitUnchanged(bool hard)
    {
        var plain = Process([], hard: hard);
        var tagged = Process([new(1, "short pause")], hard: hard);
        Assert.Equal(plain.Trimmed, tagged.Trimmed);
        Assert.Equal(plain.Fit.Plan.OutputFrames, tagged.Fit.Plan.OutputFrames);
        Assert.Equal(plain.Fit.Plan.Words, tagged.Fit.Plan.Words);
    }

    [Fact]
    public void TrailingExpressionPrecedesTheExistingMicroPause()
    {
        var plain = Process([]);
        var tagged = Process([new(2, "laughs")], true);
        Assert.Equal(plain.Fit.Plan.OutputFrames + 9600, tagged.Fit.Plan.OutputFrames);
        var duration = tagged.Fit.Plan.OutputFrames / 24000.0;
        var pause = Assert.IsType<VoiceLabMicroPause>(VoiceLabHardJoin.Pause(tagged.Fit.Plan.Words, duration, false));
        Assert.Equal(-VoiceLabHardJoin.PauseSeconds, pause.WordEndSeconds, 9);
        Assert.True(tagged.Fit.Plan.Words[^1].End - tagged.Fit.Plan.Words[^2].End > .5);
    }

    [Fact]
    public void EdgeSoundSurvivesWithHardJoinSmoothingOff()
    {
        var plain = Process([], smoothing: false);
        var tagged = Process([new(2, "laughs")], true, smoothing: false);
        Assert.Equal(plain.Trimmed.Length + 9600, tagged.Trimmed.Length);
    }
}
