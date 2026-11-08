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
            {
                var length = Math.Min(piece, signal.Length - offset);
                var buffer = new float[resampler.MaximumOutput(length)];
                output.AddRange(buffer.AsSpan(0, resampler.Process(signal.AsSpan(offset, length), buffer)).ToArray());
            }
            var tail = new float[resampler.MaximumOutput(0)];
            output.AddRange(tail.AsSpan(0, resampler.Finish(tail)).ToArray());
            Assert.True(whole.SequenceEqual(output), $"{rate}->{target} in pieces of {piece}");
        }
    }

    [Fact]
    public void ShortAndEmptyInputs()
    {
        var empty = new SincResampler(48_000, 16_000);
        Assert.Equal(0, empty.Process([], []));
        Assert.Equal(0, empty.Finish([]));
        float[] three = [0.5f, -0.5f, 0.25f];
        var resampler = new SincResampler(48_000, 16_000);
        var output = new float[resampler.MaximumOutput(3)];
        Assert.Single(output);
        var written = resampler.Process(three, output);
        written += resampler.Finish(output.AsSpan(written));
        Assert.Equal(1, written);
        Assert.Equal(VoiceConsentAudio.Resample(three, 48_000, 16_000), output);
        // An output without room for what is ready is refused.
        Assert.Throws<ArgumentException>(() =>
        {
            var up = new SincResampler(16_000, 48_000);
            Assert.Equal(0, up.Process(three, new float[9]));
            up.Finish(new float[2]);
        });
    }
}
