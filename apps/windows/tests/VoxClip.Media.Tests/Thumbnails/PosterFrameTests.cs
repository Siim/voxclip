using SkiaSharp;
using VoxClip.Core.Domain.Captions;
using VoxClip.Media.Thumbnails;
using Xunit;

namespace VoxClip.Media.Tests;

/// <summary>Poster frame timing and the black-frame test (design §5.4.7). Owned by win-ui with
/// src/VoxClip.Media/Thumbnails (apps/windows/CONTRACTS.md, 2026-10-27).</summary>
public sealed class PosterFrameTests
{
    [Theory]
    [InlineData(2.0, 0, 16, 16, new[] { 2.0, 3.0, 5.0, 1.6 })]
    [InlineData(15.5, 0, 16, 16, new[] { 15.5, 15.95, 1.6 })]
    [InlineData(4.0, 4.0, 5.0, 16, new[] { 4.0, 5.0, 7.0, 4.5 })]
    [InlineData(double.NaN, 0, 0, double.NaN, new[] { 0.0, 1.0, 3.0 })]
    public void CandidatesRetryAfterTheFirstKeptWord(double first, double scopeStart, double scopeLength, double source, double[] expected)
        => Assert.Equal(expected, PosterFrames.Candidates(first, scopeStart, scopeLength, source).Select(time => Math.Round(time, 6)));

    [Fact]
    public void BlackFramesAreFlatAndDark()
    {
        static PixelBuffer Frame(Func<int, int, byte> luma)
        {
            const int width = 64, height = 36;
            var pixels = new byte[width * height * 4];
            for (var y = 0; y < height; y++)
                for (var x = 0; x < width; x++)
                {
                    var value = luma(x, y);
                    pixels[(y * width + x) * 4] = pixels[(y * width + x) * 4 + 1] = pixels[(y * width + x) * 4 + 2] = value;
                    pixels[(y * width + x) * 4 + 3] = 255;
                }
            return new(pixels, width, height, width * 4);
        }
        Assert.True(PosterFrames.IsBlack(Frame((_, _) => 0)));
        Assert.True(PosterFrames.IsBlack(Frame((_, _) => 10)));
        Assert.False(PosterFrames.IsBlack(Frame((_, _) => 40)));
        // A dark frame with a bright title is content, not black.
        Assert.False(PosterFrames.IsBlack(Frame((x, y) => (byte)(y is > 14 and < 22 && x is > 10 and < 54 ? 230 : 4))));
    }
}

/// <summary>The FFmpeg decode Home tiles and sidebar rows rely on: hosted Windows CI runs it with the pinned test-only
/// FFmpeg and VOXCLIP_REQUIRE_NATIVE=1; elsewhere it skips with its remedy.</summary>
[Trait("Category", "RequiresFFmpeg")]
public sealed class NativePosterFrameTests : IAsyncLifetime
{
    public async ValueTask InitializeAsync() => await NativeTest.RequireAsync();
    public ValueTask DisposeAsync() => ValueTask.CompletedTask;

    [Fact]
    public async Task PosterFrameDecodesAnMkvAndCoversTheTile()
    {
        // 640 × 360 SMPTE bars in Matroska, which the Windows shell answers with a file-type icon.
        var jpeg = await PosterFrames.ReadJpegAsync(NativeTest.Fixture("bars-two-audio.mkv"), [0.5, 1.5], 0, 480, 270, TestContext.Current.CancellationToken);
        Assert.NotNull(jpeg);
        using var bitmap = SKBitmap.Decode(jpeg);
        Assert.Equal((480, 270), (bitmap.Width, bitmap.Height));
        Assert.False(Black(bitmap), "The bars frame decoded as black.");
        // The seven bars run across the top two thirds of the frame.
        Assert.True(Spread(bitmap, bitmap.Height * 35 / 100, 0.05, 0.95) > 0.3, "The bars are not side by side.");
    }

    [Fact]
    public async Task PosterFrameTurnsARotatedVideoUpright()
    {
        var jpeg = await PosterFrames.ReadJpegAsync(NativeTest.Fixture("bars-two-audio.mkv"), [0.5], 90, 270, 480, TestContext.Current.CancellationToken);
        Assert.NotNull(jpeg);
        using var bitmap = SKBitmap.Decode(jpeg);
        Assert.Equal((270, 480), (bitmap.Width, bitmap.Height));
        // A quarter turn stacks the bars: across the middle of the upright frame one bar's colour fills the row.
        Assert.True(Spread(bitmap, bitmap.Height / 2, 0.35, 0.6) < 0.12, "The poster was not turned upright.");
    }

    [Fact]
    public async Task AllBlackCandidatesGiveNoPosterFrame()
    {
        // 60 s of black video: every candidate fails the §5.4.7 test, so the caption card stands in.
        Assert.Null(await PosterFrames.ReadJpegAsync(NativeTest.Fixture("coarse-clock.mkv"), [0, 1, 3, 6], 0, 480, 270, TestContext.Current.CancellationToken));
    }

    private static double Luma(SKColor pixel) => (0.2126 * pixel.Red + 0.7152 * pixel.Green + 0.0722 * pixel.Blue) / 255;

    private static bool Black(SKBitmap bitmap)
    {
        double sum = 0;
        var count = 0;
        for (var y = 4; y < bitmap.Height; y += 8)
            for (var x = 4; x < bitmap.Width; x += 8) { sum += Luma(bitmap.GetPixel(x, y)); count++; }
        return sum / count < 0.06;
    }

    /// <summary>The luma range along one row between two fractions of the width.</summary>
    private static double Spread(SKBitmap bitmap, int row, double from, double to)
    {
        var lumas = new List<double>();
        for (var x = (int)(bitmap.Width * from); x <= (int)(bitmap.Width * to); x += 2) lumas.Add(Luma(bitmap.GetPixel(x, row)));
        return lumas.Max() - lumas.Min();
    }
}
