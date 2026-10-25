using HarfBuzzSharp;
using SkiaSharp;
using VoxClip.Core.Domain.Shared;
using VoxClip.Media.Ffmpeg;
using VoxClip.Media.Pipeline;
using Xunit;
namespace VoxClip.Media.Tests;

public sealed class MediaContractTests
{
    [Fact]
    public void NativeCaptionDependenciesLoadOnThisPlatform()
    {
        using var surface = SKSurface.Create(new SKImageInfo(8, 8, SKColorType.Bgra8888, SKAlphaType.Premul));
        Assert.NotNull(surface);
        surface.Canvas.Clear(SKColors.Transparent);
        using var buffer = new HarfBuzzSharp.Buffer();
        Assert.Equal(0, buffer.Length);
    }
    [Theory]
    [InlineData("--enable-gpl")]
    [InlineData("--enable-nonfree")]
    public void RejectsForbiddenNativeBuilds(string flag)
    {
        var exception = Assert.Throws<VoxClipException>(() => FfmpegLoader.ValidateConfiguration(flag));
        Assert.Equal(VoxClipErrorCode.FfmpegLicenceGate, exception.Code);
    }
    [Fact]
    public void EncoderLadderContainsOnlyTheSpecifiedHardwareEncoders()
        => Assert.Equal(new[] { "h264_nvenc", "h264_qsv", "h264_amf", "h264_mf" }, EncoderProbe.Ladder);
    [Fact(Skip = "win-media: implement sample-exact media fixture conformance.")]
    [Trait("Category", "RequiresFFmpeg")]
    public void FfmpegConformance() { }
    [Fact(Skip = "win-media: implement WASAPI and hardware encoder conformance on Windows.")]
    [Trait("Category", "RequiresWindows")]
    public void WindowsConformance() { }
}
