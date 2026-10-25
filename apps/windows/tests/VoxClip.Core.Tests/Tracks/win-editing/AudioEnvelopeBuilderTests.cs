using VoxClip.Core.Domain.Editing;
using Xunit;

namespace VoxClip.Core.Tests.Tracks.WinEditing;

public sealed class AudioEnvelopeBuilderTests
{
    [Theory]
    [InlineData(1, 1)]
    [InlineData(1000, 2)]
    [InlineData(11025, 3)]
    [InlineData(22050, 2)]
    [InlineData(44100, 3)]
    [InlineData(48000, 2)]
    public void OddChunksMatchChannelOrderedBinary64Analysis(int rate, int channels)
    {
        var frameSize = Math.Max(1, (int)Math.Floor(rate * 0.01 + 0.5));
        var samples = frameSize * 12 + frameSize - 1;
        var pcm = Enumerable.Range(0, samples * channels).Select(index => (float)(Math.Sin(index * 0.31) / (index % 13 + 1))).ToArray();
        var expected = new List<float>();
        for (var frame = 0; frame < samples / frameSize; frame++)
        {
            var sum = 0.0;
            for (var channel = 0; channel < channels; channel++)
                for (var sample = frame * frameSize; sample < (frame + 1) * frameSize; sample++)
                {
                    var value = (double)pcm[sample * channels + channel];
                    sum += value * value;
                }
            expected.Add((float)Math.Sqrt(sum / (frameSize * channels)));
        }
        var builder = new AudioEnvelopeBuilder(rate, channels);
        builder.Append([]);
        for (var offset = 0; offset < pcm.Length;)
        {
            var count = Math.Min(offset % 19 * 2 + 1, pcm.Length - offset);
            builder.Append(pcm.AsSpan(offset, count));
            offset += count;
        }
        var result = builder.Finish();
        Assert.Equal(rate, result.SampleRate);
        Assert.Equal(0.01, result.FrameSeconds);
        Assert.Equal(expected, result.Rms);
        var planar = Enumerable.Range(0, channels).Select(channel => (ReadOnlyMemory<float>)Enumerable.Range(0, samples).Select(sample => pcm[sample * channels + channel]).ToArray()).ToArray();
        Assert.Equal(expected, EditingAlgorithms.Analyze(planar, rate).Rms);
        Assert.Equal(result.Rms, builder.Finish().Rms);
        builder.Append(new float[frameSize * channels]);
        Assert.Equal(expected, result.Rms);
    }

    [Theory]
    [InlineData(0, 1)]
    [InlineData(-1, 1)]
    [InlineData(48000, 0)]
    [InlineData(48000, -1)]
    public void InvalidNativeFormatsAreRejected(int rate, int channels)
        => Assert.Throws<ArgumentOutOfRangeException>(() => new AudioEnvelopeBuilder(rate, channels));

    [Fact]
    public void PartialChannelFramesMaySpanCallsAndEmptyInputHasNoLevels()
    {
        var builder = new AudioEnvelopeBuilder(100, 2);
        Assert.Empty(builder.Finish().Rms);
        builder.Append([0.5f]);
        Assert.Empty(builder.Finish().Rms);
        builder.Append([-0.5f, 1f]);
        Assert.Equal([0.5f], builder.Finish().Rms);
        builder.Append([-1f]);
        Assert.Equal([0.5f, 1f], builder.Finish().Rms);
    }
}
