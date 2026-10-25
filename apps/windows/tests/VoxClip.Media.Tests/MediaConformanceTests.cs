using FFmpeg.AutoGen;
using VoxClip.Media.Audio;
using VoxClip.Media.Ffmpeg;
using VoxClip.Media.Pipeline;
using Xunit;

namespace VoxClip.Media.Tests;

public sealed class MediaConformanceTests
{
    [Theory]
    [InlineData(0, 4.01, 0, 4.1, 4.01)]
    [InlineData(0.25, 4.01, 0, 4.1, 4.26)]
    [InlineData(10, 4.01, 10, 4.1, 4.01)]
    [InlineData(0, null, 0, 4.1, 4.1)]
    public void StreamPresentationEndDefinesDuration(double start, double? duration, double origin, double fallback, double expected)
        => Assert.Equal(expected, FfmpegMediaProbe.PresentationDuration(start, duration, origin, fallback), 10);

    [Theory]
    [InlineData(AVColorRange.AVCOL_RANGE_MPEG, "limited")]
    [InlineData(AVColorRange.AVCOL_RANGE_JPEG, "full")]
    public void ToneMappingUsesExplicitZimgNames(AVColorRange range, string expected)
    {
        var filters = ToneMapper.Filters(range, AVColorPrimaries.AVCOL_PRI_BT2020,
            AVColorTransferCharacteristic.AVCOL_TRC_SMPTE2084, AVColorSpace.AVCOL_SPC_BT2020_NCL);
        Assert.Contains(":rin=" + expected, filters, StringComparison.Ordinal);
        Assert.Contains(":tin=smpte2084", filters, StringComparison.Ordinal);
        Assert.Contains(":pin=bt2020", filters, StringComparison.Ordinal);
        Assert.Contains(":min=2020_ncl", filters, StringComparison.Ordinal);
    }

    [Fact]
    public void UnspecifiedToneMappingMetadataIsNotGuessedFromEnumNumbers()
    {
        var filters = ToneMapper.Filters(AVColorRange.AVCOL_RANGE_UNSPECIFIED, AVColorPrimaries.AVCOL_PRI_UNSPECIFIED,
            AVColorTransferCharacteristic.AVCOL_TRC_UNSPECIFIED, AVColorSpace.AVCOL_SPC_UNSPECIFIED);
        Assert.DoesNotContain(":rin=", filters, StringComparison.Ordinal);
        Assert.DoesNotContain(":pin=", filters, StringComparison.Ordinal);
        Assert.DoesNotContain(":tin=", filters, StringComparison.Ordinal);
        Assert.DoesNotContain(":min=", filters, StringComparison.Ordinal);
    }

    [Fact]
    public async Task Pcm16ClampsBeforeScalingAndRoundsTiesAwayFromZero()
    {
        var directory = Directory.CreateTempSubdirectory("voxclip-media-tests-").FullName;
        Directory.CreateDirectory(directory);
        var path = Path.Combine(directory, "rounding.wav");
        try
        {
            using (var writer = new WaveWriter(path, 16_000, 1, false)) writer.Write([-2, -1, -0.5f, 0, 0.5f, 1, 2]);
            var bytes = await File.ReadAllBytesAsync(path, TestContext.Current.CancellationToken);
            Assert.Equal(new short[] { -32767, -32767, -16384, 0, 16384, 32767, 32767 },
                Enumerable.Range(0, 7).Select(index => BitConverter.ToInt16(bytes, 44 + index * 2)));
        }
        finally { Directory.Delete(directory, true); }
    }
}
