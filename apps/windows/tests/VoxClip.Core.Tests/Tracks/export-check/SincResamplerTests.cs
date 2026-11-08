using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Domain.VoiceLab;
using Xunit;

namespace VoxClip.Core.Tests.Tracks.ExportChecks;

/// <summary>The streaming resampler the export check's 16 kHz copy uses: fed in pieces of any size it writes exactly what the
/// whole-signal resample (<see cref="VoiceConsentAudio.Resample(ReadOnlySpan{float}, int, int)"/>) writes.</summary>
public sealed class SincResamplerTests
{
    static float[] Signal(int length, int seed)
    {
        var random = new Random(seed);
        return Enumerable.Range(0, length).Select(index => (float)(0.4 * Math.Sin(index * 0.031) + 0.2 * (random.NextDouble() - 0.5))).ToArray();
    }

    [Theory]
    [InlineData(48_000, 16_000)]
    [InlineData(44_100, 16_000)]
    [InlineData(16_000, 48_000)]
    [InlineData(22_050, 16_000)]
    public void PiecesOfAnySizeResampleAsTheWholeSignal(int rate, int target)
    {
        var signal = Signal(rate / 2 + 37, rate);
        var whole = VoiceConsentAudio.Resample(signal, rate, target);
        Assert.Equal((long)signal.Length * target / rate, whole.Length);
        foreach (var piece in new[] { 1, 7, 480, 4093, signal.Length })
        {
            var resampler = new SincResampler(rate, target);
            var output = new List<float>();
            for (var offset = 0; offset < signal.Length; offset += piece)
                output.AddRange(resampler.Process(signal.AsSpan(offset, Math.Min(piece, signal.Length - offset))).ToArray());
            output.AddRange(resampler.Finish().ToArray());
            Assert.True(whole.SequenceEqual(output), $"{rate}->{target} in pieces of {piece}");
        }
    }

    [Fact]
    public void ShortAndEmptyInputs()
    {
        var empty = new SincResampler(48_000, 16_000);
        Assert.Equal(0, empty.Process([]).Length);
        Assert.Equal(0, empty.Finish().Length);
        float[] three = [0.5f, -0.5f, 0.25f];
        var resampler = new SincResampler(48_000, 16_000);
        float[] output = [.. resampler.Process(three).ToArray(), .. resampler.Finish().ToArray()];
        Assert.Equal(VoiceConsentAudio.Resample(three, 48_000, 16_000), output);
        Assert.Single(output);
    }
}
