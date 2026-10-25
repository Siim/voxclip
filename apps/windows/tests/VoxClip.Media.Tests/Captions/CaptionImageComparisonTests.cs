using System.ComponentModel;
using System.Diagnostics;
using System.Text.Json;
using VoxClip.Tests.Support;
using Xunit;

namespace VoxClip.Media.Tests.Captions;

[Trait("Category", "Captions")]
public sealed class CaptionImageComparisonTests
{
    public static IEnumerable<object[]> SyntheticPairs()
    {
        var empty = Solid(32, 32, 0, 0);
        var black = Solid(32, 32, 0, 255);
        yield return ["both-empty", empty, empty, true];
        yield return ["one-empty", empty, black, false];
        yield return ["identical", black, black, true];
        yield return ["mean-limit", black, Solid(32, 32, 20, 255), false];
        yield return ["floor-96", black, Change(black, 96, 33), true];
        yield return ["floor-97", black, Change(black, 97, 33), false];
        yield return ["max-129", black, Change(black, 1, 129), false];
        yield return ["ssim-limit", Solid(32, 32, 0, 8), Solid(32, 32, 0, 24), false];
        yield return ["rounding-skip", Solid(32, 32, 255, 1), Solid(32, 32, 255, 2), true];
        var large = Solid(128, 128, 0, 255);
        yield return ["share-327", large, Change(large, 327, 33), true];
        yield return ["share-328", large, Change(large, 328, 33), false];
        yield return ["corner-padding", Solid(1, 1, 0, 128), Solid(1, 1, 0, 127), true];
        var hidden = new CaptionImageComparison.Image(32, 32, empty.Rgba.Select((value, index) => index % 4 == 3 ? value : (byte)255).ToArray());
        yield return ["hidden-rgb", empty, hidden, true];
    }

    [Theory]
    [MemberData(nameof(SyntheticPairs))]
    public void SyntheticVerdictsFollowCalibratedLimits(string name, object first, object second, bool expected)
    {
        var result = CaptionImageComparison.Compare((CaptionImageComparison.Image)first, (CaptionImageComparison.Image)second);
        Assert.True(result.Passed == expected, $"{name}: {JsonSerializer.Serialize(result)}");
    }

    [Fact]
    public void GoldenComparisonRequiresTheIndexEntryAndImage()
    {
        var directory = Directory.CreateTempSubdirectory("voxclip-caption-index-");
        try
        {
            var target = new VoxClip.Core.Domain.Captions.PixelBuffer(new byte[4], 1, 1, 4);
            void Compare() => CaptionImageComparison.AssertGolden(target, directory.FullName, "case", "0.png", 0, null, 0);
            Assert.ThrowsAny<Xunit.Sdk.XunitException>(Compare);
            var path = Path.Combine(directory.FullName, "case.json");
            File.WriteAllText(path, """{"images":[]}""");
            Assert.ThrowsAny<Xunit.Sdk.XunitException>(Compare);
            File.WriteAllText(path, """{"images":[{"file":"0.png","sample":0,"style":null,"t":0}]}""");
            Assert.ThrowsAny<Xunit.Sdk.XunitException>(Compare);
        }
        finally { directory.Delete(true); }
    }

    [Fact]
    public void DifferentImageDimensionsFail()
        => Assert.False(CaptionImageComparison.Compare(Solid(1, 1, 0, 255), Solid(2, 1, 0, 255)).Passed);

    [Theory]
    [InlineData(0.34299999999999997, true)]
    [InlineData(0.3430000005, true)]
    [InlineData(0.343000002, false)]
    public void GoldenTimeUsesTheSpecifiedOneNanosecondTolerance(double recordedTime, bool matches)
    {
        var directory = Directory.CreateTempSubdirectory("voxclip-caption-time-");
        try
        {
            var target = new VoxClip.Core.Domain.Captions.PixelBuffer(new byte[4], 1, 1, 4);
            var entry = CaptionFixtureSupport.WritePng(target, Path.Combine(directory.FullName, "case", "0.png"), 0, null, 0.343);
            var index = JsonSerializer.SerializeToNode(new { images = new[] { entry } }, CaptionFixtureSupport.Json)!;
            index["images"]![0]!["t"] = recordedTime;
            File.WriteAllText(Path.Combine(directory.FullName, "case.json"), index.ToJsonString());
            void Compare() => CaptionImageComparison.AssertGolden(target, directory.FullName, "case", "0.png", 0, null, 0.343);
            if (matches) Compare();
            else Assert.ThrowsAny<Xunit.Sdk.XunitException>(Compare);
        }
        finally { directory.Delete(true); }
    }

    [Fact]
    public void PlacementAndDiffUsePremultipliedChannels()
    {
        var first = CaptionImageComparison.Place(Solid(1, 1, 255, 64), 32, 32, 7, 9);
        var second = CaptionImageComparison.Place(Solid(1, 1, 0, 64), 32, 32, 7, 9);
        var result = CaptionImageComparison.Compare(first, second);
        Assert.Equal(1, result.Pixels); Assert.Equal(48, result.Mean); Assert.Equal(64, result.Max);
        var diff = CaptionImageComparison.Diff(first, second);
        Assert.Equal(new byte[] { 255, 255, 255, 255 }, diff.Rgba.AsSpan((9 * 32 + 7) * 4, 4).ToArray());
        Assert.Equal(new byte[] { 0, 0, 0, 255 }, diff.Rgba.AsSpan(0, 4).ToArray());
        Assert.False(CaptionImageComparison.Compare(first, Solid(1, 1, 0, 0)).Passed);
    }

    [Fact]
    public async Task SyntheticVerdictsAndMetricsMatchPython()
    {
        var directory = Directory.CreateTempSubdirectory("voxclip-caption-comparison-");
        try
        {
            var script = Path.Combine(Path.GetDirectoryName(FixtureLoader.SharedRoot)!, "tools", "captions", "compare_overlays.py");
            foreach (var row in SyntheticPairs())
            {
                var name = (string)row[0]; var first = (CaptionImageComparison.Image)row[1]; var second = (CaptionImageComparison.Image)row[2];
                var firstPath = Path.Combine(directory.FullName, name + "-a.png"); var secondPath = Path.Combine(directory.FullName, name + "-b.png");
                CaptionImageComparison.WritePng(first, firstPath); CaptionImageComparison.WritePng(second, secondPath);
                var start = new ProcessStartInfo("python3") { RedirectStandardOutput = true, RedirectStandardError = true, UseShellExecute = false };
                foreach (var argument in new[] { "-I", script, firstPath, secondPath }) start.ArgumentList.Add(argument);
                Process? process = null;
                try { process = Process.Start(start); }
                catch (Win32Exception) { Assert.Skip("Python 3 with numpy is required to cross-check the executable caption comparison definition."); }
                Assert.NotNull(process);
                using (process)
                {
                    var standard = process.StandardOutput.ReadToEndAsync(TestContext.Current.CancellationToken); var error = process.StandardError.ReadToEndAsync(TestContext.Current.CancellationToken);
                    try { await process.WaitForExitAsync(TestContext.Current.CancellationToken).WaitAsync(TimeSpan.FromSeconds(60), TestContext.Current.CancellationToken); }
                    catch { process.Kill(entireProcessTree: true); throw; }
                    var text = await standard; var errors = await error;
                    Assert.SkipWhen(errors.Contains("No module named 'numpy'", StringComparison.Ordinal)
                        || errors.Contains("Python was not found; run without arguments to install from the Microsoft Store", StringComparison.Ordinal),
                        "Python 3 with numpy is required for the executable comparison definition.");
                    Assert.True(process.ExitCode is 0 or 1, errors);
                    var result = CaptionImageComparison.Compare(first, second);
                    Assert.Equal(result.Passed, process.ExitCode == 0);
                    var line = text.Split('\n')[0];
                    using var metrics = JsonDocument.Parse(line[line.IndexOf('{')..]);
                    if (!metrics.RootElement.TryGetProperty("mean", out var mean)) continue;
                    Assert.InRange(Math.Abs(mean.GetDouble() - result.Mean), 0, 0.000051);
                    Assert.Equal(metrics.RootElement.GetProperty("max").GetInt32(), result.Max);
                    Assert.Equal(metrics.RootElement.GetProperty("pixels").GetInt32(), result.Pixels);
                    Assert.InRange(Math.Abs(metrics.RootElement.GetProperty("shareOver32").GetDouble() - result.Over32 / (double)result.Pixels), 0, 0.0000051);
                    Assert.InRange(Math.Abs(metrics.RootElement.GetProperty("ssimAlpha").GetDouble() - result.SsimAlpha), 0, 0.0000051);
                }
            }
        }
        finally { directory.Delete(true); }
    }

    private static CaptionImageComparison.Image Solid(int width, int height, byte color, byte alpha)
    {
        var rgba = new byte[width * height * 4];
        for (var offset = 0; offset < rgba.Length; offset += 4)
        { rgba[offset] = color; rgba[offset + 1] = color; rgba[offset + 2] = color; rgba[offset + 3] = alpha; }
        return new(width, height, rgba);
    }

    private static CaptionImageComparison.Image Change(CaptionImageComparison.Image image, int pixels, byte difference)
    {
        var rgba = image.Rgba.ToArray();
        for (var index = 0; index < pixels; index++) rgba[index * 4] = difference;
        return image with { Rgba = rgba };
    }
}
