using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Domain.Transcript;
using VoxClip.Core.Domain.VoiceLab;
using VoxClip.Media.VoiceLab;
using Xunit;

namespace VoxClip.Media.Tests.VoiceLab;

/// <summary>The take run's guard speech on a noisy recording (voice-lab.md §6.9, ADR-R40; Mac <c>noisyRawWindowFailsButTheSpeechPasses</c>,
/// <c>aTranscriptWithoutWordsReadsThePatchesOwnTenSeconds</c>), and which refusals settle a window.</summary>
public sealed class VoiceLabGuardSpeechMediaTests
{
    private const int Rate = 16_000;

    /// <summary>Words of quiet speech between stretches of loud road noise, at 16 kHz so no resampler blurs the reading.</summary>
    private static VoiceLabTakeInput NoisyInput(TimedWord[] words, int seconds, double start, double end)
    {
        var samples = new float[seconds * Rate];
        for (var index = 0; index < samples.Length; index++) samples[index] = index % 2 == 0 ? 0.9f : -0.9f;
        foreach (var word in words)
            for (var index = (int)(word.Start * Rate); index < (int)(word.End * Rate); index++)
                samples[index] = (float)(0.1 + 0.05 * Math.Sin(index * 0.05));
        long startSample = (long)(start * Rate), endSample = (long)(end * Rate);
        var window = new VoiceLabWindow("p", "p", [], [], start, end, startSample, endSample,
            new(VoiceLabSeamKind.Hard, start, startSample, 320), new(VoiceLabSeamKind.Hard, end, endSample, 320));
        return new("new words", "eleven_v3", "r", "en", 1, "car-video", samples, Rate, words, new HashSet<string>(), window, null, null, false, true);
    }

    [Fact]
    public void TheGuardReadsTheWordsNotTheRoadNoiseBetweenThem()
    {
        // One-second words with 1.5 s of road noise between them, over 30 s; the patch is the word at 12.5–13.5 s.
        var words = Enumerable.Range(0, 12).Select(index => new TimedWord("w" + index, "w" + index, WordKind.Word, index * 2.5, index * 2.5 + 1,
            null, null, 1, null, TimingSource.Native)).ToArray();
        var input = NoisyInput(words, 30, 12.5, 13.5);
        // What the guard read before: 10 s of raw source centred on the patch, mostly noise.
        var raw = input.Source.Samples(128_000, 288_000)!.Value.ToArray();
        Assert.True(raw.Count(sample => Math.Abs(sample) > 0.5) * 2 > raw.Length);
        var speech = VoiceLabTakeRun.GuardSpeech(input);
        Assert.Equal(10 * Rate, speech.Length);
        Assert.True(speech.All(sample => Math.Abs(sample) < 0.5), "no road noise between the words");
    }

    [Fact]
    public void ATranscriptWithoutWordsReadsThePatchsOwnTenSeconds()
    {
        var input = NoisyInput([], 30, 12.5, 13.5);
        Assert.Equal(input.Source.Samples(128_000, 288_000)!.Value.ToArray(), VoiceLabTakeRun.GuardSpeech(input));
    }

    /// <summary>Only the guard's own verdicts settle a window; every other consent failure still ends the run.</summary>
    [Fact]
    public void OnlyTheGuardsOwnRefusalsSettleAWindow()
    {
        Assert.True(VoiceLabTakeRun.GuardSettles(new VoiceConsentException(VoiceConsentError.VoiceOwnerMismatch)));
        Assert.True(VoiceLabTakeRun.GuardSettles(new VoiceConsentException(VoiceConsentError.SpeakerMismatch)));
        Assert.False(VoiceLabTakeRun.GuardSettles(new VoiceConsentException(VoiceConsentError.SpeakerUnavailable)));
        Assert.False(VoiceLabTakeRun.GuardSettles(new VoiceConsentException(VoiceConsentError.InvalidRecord)));
        Assert.False(VoiceLabTakeRun.GuardSettles(new VoiceLabException(VoiceLabErrorKind.SpeakerMismatch)));
    }
}
