using System.Globalization;
using System.Collections.Frozen;
using System.Runtime.CompilerServices;
using System.Text.Json;
using VoxClip.Core.Domain.Captions;
using VoxClip.Core.Services.Captions;
using VoxClip.Core.Domain.Editing;
using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Services.Settings;
using VoxClip.Media.Captions;
using VoxClip.Tests.Support;
using Xunit;

namespace VoxClip.Media.Tests.Captions;

[Trait("Category", "Captions")]
public sealed class CaptionConformanceTests
{
    [Fact]
    public async Task ProductionCaptionApiRendersWithoutCoreFriendGrant()
    {
        var friends = typeof(CaptionEngine).Assembly.GetCustomAttributes(typeof(InternalsVisibleToAttribute), false)
            .Cast<InternalsVisibleToAttribute>().Select(attribute => attribute.AssemblyName).ToArray();
        Assert.DoesNotContain(friends, name => name.Split(',')[0] == "VoxClip.Media");
        Assert.Contains(friends, name => name.Split(',')[0] == "VoxClip.Media.Tests");

        var style = CaptionStyleLibrary.Load(FixtureLoader.SharedRoot).Find("clean-subtitle")!;
        using var patch = JsonDocument.Parse("{}");
        var request = new CaptionLayoutRequest(style,
            new ProjectCaptions(style.Id, patch.RootElement.Clone(), null, new Dictionary<string, CaptionPosition>()),
            new PixelSize(320, 568), [new CaptionWord("word-1", "Hello", 0, 1)], "en", 1);
        var track = await CaptionEngine.BuildAsync(request, new HarfBuzzGlyphShaper(FixtureLoader.SharedRoot), null, CancellationToken.None);
        Assert.Single(track.Pages);
        var overlay = await new SkiaCaptionRasterizer(FixtureLoader.SharedRoot).RenderAsync(new(track, 0.5), CancellationToken.None);
        Assert.Contains(overlay.Pixels.Span.ToArray().Where((_, index) => index % 4 == 3), alpha => alpha > 0);
    }

    public static IEnumerable<object[]> LayoutCases() => Directory.EnumerateFiles(Path.Combine(FixtureLoader.SharedRoot, "fixtures", "captions", "layout"), "*.json").Order(StringComparer.Ordinal).Select(path => new object[] { path });

    [Theory]
    [MemberData(nameof(LayoutCases))]
    public async Task NativeShapingLayoutAndTimelineMatchEveryFixture(string path)
    {
        using var document = JsonDocument.Parse(File.ReadAllText(path));
        var input = document.RootElement.GetProperty("input");
        var expected = document.RootElement.GetProperty("expected");
        var track = await CaptionFixtureSupport.Build(input);
        CaptionFixtureSupport.Compare(expected, CaptionFixtureSupport.ExpectedProjection(track, input, expected), Path.GetFileNameWithoutExtension(path));
    }

    [Fact]
    public void BlurGeometryAndGradientMathVectors()
    {
        using var document = FixtureLoader.ReadJson("fixtures/captions/math.json");
        var root = document.RootElement;
        foreach (var kernel in root.GetProperty("blur").GetProperty("kernels").EnumerateArray())
        {
            var actual = CaptionBlur.Kernel(kernel.GetProperty("sigma").GetDouble());
            Assert.Equal(kernel.GetProperty("radius").GetInt32() * 2 + 1, actual.Length);
            var expected = kernel.GetProperty("weights").EnumerateArray().Select(number => number.GetDouble()).ToArray();
            for (var index = 0; index < actual.Length; index++) Assert.InRange(Math.Abs(actual[index] - expected[index]), 0, 1e-12);
        }
        foreach (var box in root.GetProperty("blur").GetProperty("boxSizes").EnumerateArray())
        {
            var expected = box.GetProperty("passes").EnumerateArray().Select(pair => (pair[0].GetInt32(), pair[1].GetInt32())).ToArray();
            Assert.Equal(expected, CaptionBlur.Boxes(box.GetProperty("sigma").GetDouble()));
        }
        foreach (var row in root.GetProperty("blur").GetProperty("rows").EnumerateArray())
        {
            var pixels = row.GetProperty("input").EnumerateArray().Select(number => number.GetByte()).ToArray();
            CaptionBlur.Apply(pixels, pixels.Length, 1, row.GetProperty("sigma").GetDouble(), CancellationToken.None, true);
            Assert.Equal(row.GetProperty("output").EnumerateArray().Select(number => number.GetByte()).ToArray(), pixels);
        }
        foreach (var gradient in root.GetProperty("gradients").EnumerateArray())
        {
            var rect = gradient.GetProperty("rect").EnumerateArray().Select(number => number.GetDouble()).ToArray();
            var points = CaptionGeometry.GradientPoints(rect[0], rect[1], rect[2], rect[3], gradient.GetProperty("angleDeg").GetDouble());
            foreach (var pair in new[] { (gradient.GetProperty("p0"), points.Start), (gradient.GetProperty("p1"), points.End) })
            { Assert.InRange(Math.Abs(pair.Item1[0].GetDouble() - pair.Item2.X), 0, 1e-6); Assert.InRange(Math.Abs(pair.Item1[1].GetDouble() - pair.Item2.Y), 0, 1e-6); }
        }
        foreach (var rectangle in root.GetProperty("roundedRects").EnumerateArray())
        {
            var rect = rectangle.GetProperty("rect").EnumerateArray().Select(number => number.GetDouble()).ToArray();
            var commands = new CaptionGeometry.RoundedCommand[10];
            var count = CaptionGeometry.RoundedCommands(rect[0], rect[1], rect[2], rect[3], rectangle.GetProperty("radius").GetDouble(), commands);
            var expected = rectangle.GetProperty("path");
            Assert.Equal(expected.GetArrayLength(), count);
            for (var index = 0; index < count; index++)
            {
                Assert.Equal(expected[index][0].GetString(), commands[index].Verb.ToString());
                Assert.Equal(expected[index].GetArrayLength() - 1, commands[index].ValueCount);
                for (var value = 0; value < commands[index].ValueCount; value++) Assert.InRange(Math.Abs(expected[index][value + 1].GetDouble() - commands[index][value]), 0, 1e-6);
            }
            using var drawn = new SkiaSharp.SKPath();
            CaptionGeometry.Rounded(drawn, rect[0], rect[1], rect[2], rect[3], rectangle.GetProperty("radius").GetDouble());
            var points = drawn.Points;
            var point = 0;
            for (var index = 0; index < count; index++)
                for (var value = 0; value < commands[index].ValueCount; value += 2, point++)
                {
                    Assert.Equal((float)commands[index][value], points[point].X);
                    Assert.Equal((float)commands[index][value + 1], points[point].Y);
                }
            Assert.Equal(points.Length, point);
        }
    }

    [Fact]
    public async Task BundledOnlyKerningAndCancellation()
    {
        var shaper = new HarfBuzzGlyphShaper();
        var metadata = CaptionDataLoader.Current.Fonts["DMSans-Black.ttf"];
        var kerned = await shaper.ShapeAsync(new(metadata.File, "AVATAR õäöüšž 03:15", metadata.UnitsPerEm), CancellationToken.None);
        var plain = await shaper.ShapeAsync(new(metadata.File, "AVATAR õäöüšž 03:15", metadata.UnitsPerEm, Kern: false), CancellationToken.None);
        Assert.True(kerned.Advances.Sum() < plain.Advances.Sum());
        Assert.DoesNotContain(0u, kerned.Glyphs);
        await Assert.ThrowsAsync<ArgumentException>(() => shaper.ShapeAsync(new("/System/Library/Fonts/Helvetica.ttc", "test", 1000), CancellationToken.None));
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => shaper.ShapeAsync(new(metadata.File, "test", metadata.UnitsPerEm), new CancellationToken(true)));
        foreach (var font in CaptionDataLoader.Current.Fonts.Keys) Assert.True(File.Exists(CaptionFontFiles.Path(CaptionResources.Current, font)));
    }

    [Fact]
    public void FontVerificationRejectsBadChecksumsAndEscapingPaths()
    {
        var directory = Directory.CreateTempSubdirectory("voxclip-caption-font-");
        try
        {
            Directory.CreateDirectory(Path.Combine(directory.FullName, "fonts"));
            File.WriteAllText(Path.Combine(directory.FullName, "fonts", "invalid.ttf"), "not a bundled font");
            var data = CaptionDataLoader.Current;
            var font = data.Fonts["DMSans-Black.ttf"];
            var corrupt = font with { Path = "invalid.ttf" };
            var corruptData = data with { Root = directory.FullName, Fonts = new[] { corrupt }.ToFrozenDictionary(item => item.File, StringComparer.Ordinal) };
            var checksum = Assert.Throws<InvalidDataException>(() => CaptionFontFiles.Path(new CaptionResources(corruptData), corrupt.File));
            Assert.Contains("checksum", checksum.Message, StringComparison.Ordinal);
            var escaping = font with { File = "escaping.ttf", Path = "../../outside.ttf" };
            var escapingData = data with { Root = directory.FullName, Fonts = new[] { escaping }.ToFrozenDictionary(item => item.File, StringComparer.Ordinal) };
            var traversal = Assert.Throws<InvalidDataException>(() => CaptionFontFiles.Path(new CaptionResources(escapingData), escaping.File));
            Assert.Contains("path", traversal.Message, StringComparison.Ordinal);
        }
        finally { directory.Delete(true); }
    }

    [Fact]
    public void GoldenCropsUseTransparentSentinelAndEightPixelPadding()
    {
        var pixels = new PixelBuffer(new byte[32 * 32 * 4], 32, 32, 32 * 4);
        Assert.Equal((0, 0, 1, 1), CaptionFixtureSupport.Crop(pixels));
        pixels.Pixels.Span[16 * pixels.Stride + 16 * 4 + 3] = 255;
        Assert.Equal((8, 8, 17, 17), CaptionFixtureSupport.Crop(pixels));
        pixels.Pixels.Span.Clear();
        pixels.Pixels.Span[3] = 1;
        Assert.Equal((0, 0, 9, 9), CaptionFixtureSupport.Crop(pixels));
    }

    [Fact]
    public Task GoldenRendersEveryStyleAndGalleryTile() => RenderEveryGolden(false);

    [Fact]
    public Task CommittedGoldensMatchEverySampleAndGalleryTile() => RenderEveryGolden(true);

    private async Task RenderEveryGolden(bool compareGoldens)
    {
        var committedRoot = Path.Combine(FixtureLoader.SharedRoot, "fixtures", "captions", "golden");
        if (compareGoldens) Assert.SkipUnless(Directory.Exists(committedRoot), "The macOS caption goldens have not yet landed in shared/fixtures/captions/golden.");
        var rasterizer = new SkiaCaptionRasterizer();
        var samples = 0;
        var expectedSamples = 0;
        var goldenRoot = CaptionFixtureSupport.GoldenRoot;
        var styles = new HashSet<(string Style, int Width, int Height)>();
        foreach (var row in LayoutCases())
        {
            var path = (string)row[0];
            using var document = JsonDocument.Parse(File.ReadAllText(path));
            var track = await CaptionFixtureSupport.Build(document.RootElement.GetProperty("input"));
            var glyphTrack = GlyphOnly(track);
            var entries = new List<object>();
            var source = document.RootElement.GetProperty("expected").GetProperty("samples").EnumerateArray().ToArray();
            expectedSamples += source.Count(sample => sample.TryGetProperty("golden", out var golden) && golden.GetBoolean());
            for (var index = 0; index < source.Length; index++)
            {
                if (!source[index].TryGetProperty("golden", out var golden) || !golden.GetBoolean()) continue;
                var time = source[index].GetProperty("t").GetDouble();
                var pixels = await rasterizer.RenderAsync(new(track, time), CancellationToken.None);
                AssertPremultiplied(pixels);
                var glyphPixels = await rasterizer.RenderAsync(new(glyphTrack, time), CancellationToken.None);
                AssertContent(glyphPixels, glyphTrack, source[index]);
                var id = Path.GetFileNameWithoutExtension(path);
                if (compareGoldens) CaptionImageComparison.AssertGolden(pixels, committedRoot, id, $"s{index}.png", index, null, time);
                if (goldenRoot is not null) entries.Add(CaptionFixtureSupport.WritePng(pixels, Path.Combine(goldenRoot, id, $"s{index}.png"), index, null, time));
                styles.Add((track.Style.Id, track.Frame.Width, track.Frame.Height));
                samples++;
            }
            if (goldenRoot is not null) File.WriteAllText(Path.Combine(goldenRoot, Path.GetFileName(path)), JsonSerializer.Serialize(new { images = entries }, CaptionFixtureSupport.Json));
        }
        foreach (var style in Directory.EnumerateFiles(Path.Combine(FixtureLoader.SharedRoot, "caption-styles", "styles"), "*.json").Select(Path.GetFileNameWithoutExtension))
        {
            Assert.Contains((style!, 1080, 1920), styles);
            Assert.Contains((style!, 1920, 1080), styles);
        }
        using var tiles = FixtureLoader.ReadJson("fixtures/captions/preview-tiles.json");
        var tileEntries = new List<object>();
        var tileCount = 0;
        foreach (var tile in tiles.RootElement.GetProperty("tiles").EnumerateArray())
        {
            var style = CaptionFixtureSupport.Style(tile.GetProperty("style").GetString()!);
            var text = style.Preview.Text.Split(' ', StringSplitOptions.RemoveEmptyEntries);
            var words = text.Select((word, index) => new CaptionWord($"preview-{index}", word, 0.4 * index, 0.4 * index + 0.35)).ToArray();
            var frame = tile.GetProperty("frame");
            var track = await CaptionEngine.BuildAsync(new(style, new(style.Id, JsonDocument.Parse("{}").RootElement.Clone(), null, new Dictionary<string, CaptionPosition>()), new(frame.GetProperty("width").GetInt32(), frame.GetProperty("height").GetInt32()), words, "en", 0.4 * words.Length + 0.5), new HarfBuzzGlyphShaper(), null, CancellationToken.None);
            var time = tile.GetProperty("t").GetDouble();
            var evaluated = CaptionTimeline.Evaluate(track, time, true)!;
            CaptionFixtureSupport.Compare(tile.GetProperty("page"), CaptionFixtureSupport.Page(evaluated.Page), $"tile.{style.Id}.page");
            CaptionFixtureSupport.Compare(tile.GetProperty("sample"), CaptionFixtureSupport.Sample(track, time, true), $"tile.{style.Id}.sample");
            var pixels = await rasterizer.RenderAsync(new(track, time, ReduceMotion: true), CancellationToken.None);
            AssertPremultiplied(pixels);
            var glyphTrack = GlyphOnly(track);
            var glyphPixels = await rasterizer.RenderAsync(new(glyphTrack, time, ReduceMotion: true), CancellationToken.None);
            AssertContent(glyphPixels, glyphTrack, tile.GetProperty("sample"));
            if (compareGoldens) CaptionImageComparison.AssertGolden(pixels, committedRoot, "tiles", $"{style.Id}-{track.Frame.Width}x{track.Frame.Height}.png", null, style.Id, time);
            if (goldenRoot is not null) tileEntries.Add(CaptionFixtureSupport.WritePng(pixels, Path.Combine(goldenRoot, "tiles", $"{style.Id}-{track.Frame.Width}x{track.Frame.Height}.png"), null, style.Id, time));
            tileCount++;
        }
        if (goldenRoot is not null) File.WriteAllText(Path.Combine(goldenRoot, "tiles.json"), JsonSerializer.Serialize(new { images = tileEntries }, CaptionFixtureSupport.Json));
        Assert.Equal(expectedSamples, samples);
        Assert.Equal(tiles.RootElement.GetProperty("tiles").GetArrayLength(), tileCount);
    }

    [Fact]
    public async Task DrawAndRenderAreIdenticalAndSeekingIsStateless()
    {
        using var fixture = FixtureLoader.ReadJson("fixtures/captions/layout/vhs-portrait-frames.json");
        var track = await CaptionFixtureSupport.Build(fixture.RootElement.GetProperty("input"));
        var rasterizer = new SkiaCaptionRasterizer();
        var first = await rasterizer.RenderAsync(new(track, 0.35), CancellationToken.None);
        await rasterizer.RenderAsync(new(track, 0.95), CancellationToken.None);
        var second = new PixelBuffer(new byte[first.Stride * first.Height], first.Width, first.Height, first.Stride);
        rasterizer.Draw(new(track, 0.35), second, CancellationToken.None);
        Assert.Equal(first.Pixels.ToArray(), second.Pixels.ToArray());
        var scaled = await rasterizer.RenderAsync(new(track, 0.35, Scale: 0.25), CancellationToken.None);
        Assert.Equal(270, scaled.Width); Assert.Equal(480, scaled.Height);
        var output = Enumerable.Repeat((byte)0x71, first.Stride * first.Height).ToArray();
        var target = new PixelBuffer(output, first.Width, first.Height, first.Stride);
        rasterizer.Draw(new(track, -1), target, CancellationToken.None);
        Assert.All(output, value => Assert.Equal((byte)0x71, value));
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => rasterizer.RenderAsync(new(track, 0.35), new CancellationToken(true)));
    }

    [Fact]
    public async Task ShortEdgeSizingStaysEqualAcrossPortraitAndLandscape()
    {
        var style = CaptionFixtureSupport.Style("karaoke");
        var captions = new ProjectCaptions(style.Id, JsonDocument.Parse("{}").RootElement.Clone(), null, new Dictionary<string, CaptionPosition>());
        var shaper = new HarfBuzzGlyphShaper();
        foreach (var sizeReference in Enum.GetValues<CaptionFontSizeRefValue>())
        {
            var sized = style with { Font = style.Font with { SizeRef = sizeReference } };
            foreach (var frame in new[] { new PixelSize(1080, 1920), new PixelSize(1920, 1080) })
            {
                var track = await CaptionEngine.BuildAsync(new(sized, captions, frame, [new CaptionWord("test", "TEST", 0, 1)], "en", 2), shaper, null, CancellationToken.None);
                var reference = sizeReference switch { CaptionFontSizeRefValue.Height => frame.Height, CaptionFontSizeRefValue.Width => frame.Width, _ => 1080 };
                Assert.Equal(CaptionMath.RoundHalfUp(style.Font.SizeSh * reference * style.Font.SizeScale * 64), Assert.Single(track.Pages).FontPx64);
                if (sizeReference == CaptionFontSizeRefValue.ShortEdge) Assert.Equal(4285, track.Pages[0].FontPx64);
            }
        }
    }

    [Fact]
    public async Task BgraDrawBlendsInGammaEncodedSpaceAndPreservesStridePadding()
    {
        var style = CaptionFixtureSupport.Style("vox-highlight");
        style = style with { Box = style.Box! with { Color = "#00000080" } };
        var captions = new ProjectCaptions(style.Id, JsonDocument.Parse("{}").RootElement.Clone(), null, new Dictionary<string, CaptionPosition>());
        var track = await CaptionEngine.BuildAsync(new(style, captions, new(1080, 1920), [new CaptionWord("test", "TEST", 0, 1)], "en", 2), new HarfBuzzGlyphShaper(), null, CancellationToken.None);
        var rasterizer = new SkiaCaptionRasterizer();
        var overlay = await rasterizer.RenderAsync(new(track, 0.3), CancellationToken.None);
        var source = overlay.Pixels.ToArray();
        var black = Enumerable.Range(0, overlay.Width * overlay.Height).First(index => source[index * 4] == 0 && source[index * 4 + 1] == 0 && source[index * 4 + 2] == 0 && source[index * 4 + 3] == 128);
        var stride = overlay.Stride + 16;
        var target = new PixelBuffer(Enumerable.Repeat((byte)255, stride * overlay.Height).ToArray(), overlay.Width, overlay.Height, stride);
        rasterizer.Draw(new(track, 0.3), target, CancellationToken.None);
        var offset = black / overlay.Width * stride + black % overlay.Width * 4;
        Assert.Equal(new byte[] { 127, 127, 127, 255 }, target.Pixels.Slice(offset, 4).ToArray());
        for (var row = 0; row < target.Height; row++) Assert.All(target.Pixels.Slice(row * stride + overlay.Stride, 16).ToArray(), value => Assert.Equal((byte)255, value));
    }

    [Fact]
    public void EmojiFiltersPreservePremultipliedChannels()
    {
        var source = CaptionEmojiImages.Source(CaptionResources.Current, "1f525");
        Assert.Equal(source, CaptionEmojiImages.Resize(source, 128, CancellationToken.None));
        foreach (var size in new[] { 1, 16, 96, 129, 240 })
        {
            var output = CaptionEmojiImages.Resize(source, size, CancellationToken.None);
            for (var offset = 0; offset < output.Length; offset += 4)
                for (var channel = 0; channel < 3; channel++) Assert.True(output[offset + channel] <= output[offset + 3]);
        }
    }

    [Theory]
    [InlineData("pill")]
    [InlineData("typewriter")]
    public async Task BoxesAloneNeverSatisfyGlyphContentAssertions(string style)
    {
        using var document = FixtureLoader.ReadJson($"fixtures/captions/layout/{style}-portrait-en.json");
        var track = await CaptionFixtureSupport.Build(document.RootElement.GetProperty("input"));
        var glyphTrack = GlyphOnly(track);
        var transparent = new SolidPaint("#00000000");
        glyphTrack = glyphTrack with { Style = glyphTrack.Style with { Fill = transparent, Stroke = null, Emphasis = null, Words = null } };
        var time = track.Pages[0].Start + 0.8;
        var sample = JsonSerializer.SerializeToElement(CaptionFixtureSupport.Sample(glyphTrack, time), CaptionFixtureSupport.Json);
        var rasterizer = new SkiaCaptionRasterizer { CacheEnabled = false };
        var background = await rasterizer.RenderAsync(new(track with { Style = glyphTrack.Style with { Box = track.Style.Box } }, time), CancellationToken.None);
        Assert.True(CaptionFixtureSupport.Crop(background).W > 1);
        var pixels = await rasterizer.RenderAsync(new(glyphTrack, time), CancellationToken.None);
        Assert.ThrowsAny<Xunit.Sdk.XunitException>(() => AssertContent(pixels, glyphTrack, sample));
    }

    private static CaptionTrack GlyphOnly(CaptionTrack track)
    {
        var style = track.Style;
        return track with
        {
            Pages = track.Pages.Select(page => page with { Emoji = null }).ToArray(),
            Style = style with
            {
                Box = null,
                Shadows = [],
                Effects = style.Effects is { } effects ? effects with { RgbSplit = null } : null,
                Reveal = style.Reveal is { } reveal ? reveal with { Cursor = null } : null,
                Words = style.Words is { } words ? words with
                {
                    Past = words.Past is { } past ? past with { Box = null } : null,
                    Active = words.Active is { } active ? active with { Box = null } : null,
                    Future = words.Future is { } future ? future with { Box = null } : null
                } : null
            }
        };
    }

    private static void AssertContent(PixelBuffer pixels, CaptionTrack track, JsonElement sample)
    {
        if (sample.GetProperty("page").ValueKind == JsonValueKind.Null) return;
        var pageAlpha = sample.GetProperty("pageAlpha").GetDouble();
        if (pageAlpha <= 0) return;
        var visible = sample.GetProperty("words").EnumerateArray().Where(word => word.GetProperty("visible").GetBoolean()
            && word.GetProperty("opacity").GetDouble() * pageAlpha * 255 >= 1
            && (!word.TryGetProperty("visibleClusters", out var clusters) || clusters.ValueKind == JsonValueKind.Null || clusters.GetInt32() > 0)).ToArray();
        if (visible.Length == 0) return;
        var crop = CaptionFixtureSupport.Crop(pixels);
        Assert.True(crop.W > 1 && crop.H > 1, $"{track.Style.Id}: visible caption has no ink");
        if (pageAlpha < 1) return;
        var page = track.Pages[sample.GetProperty("page").GetInt32()];
        var scale = sample.GetProperty("pageScale").GetDouble();
        var centerX = page.Block.X + page.Block.Width / 2;
        var centerY = page.Block.Y + page.Block.Height / 2;
        var jitter = sample.GetProperty("jitter");
        foreach (var word in visible)
        {
            if (word.GetProperty("opacity").GetDouble() < 1) continue;
            var rect = page.WordRects.First(rect => rect.Word == word.GetProperty("word").GetInt32());
            var wordScale = word.GetProperty("scale").GetDouble();
            var left = Math.Clamp((int)Math.Floor(centerX + scale * (rect.Cx + (rect.X - rect.Cx) * wordScale - centerX) + jitter[0].GetDouble()), 0, pixels.Width);
            var top = Math.Clamp((int)Math.Floor(centerY + scale * (rect.Cy + (rect.Y - rect.Cy) * wordScale + word.GetProperty("dy").GetDouble() - centerY) + jitter[1].GetDouble() + sample.GetProperty("pageDy").GetDouble()), 0, pixels.Height);
            var right = Math.Clamp((int)Math.Ceiling(left + rect.W * wordScale * scale), 0, pixels.Width);
            var bottom = Math.Clamp((int)Math.Ceiling(top + rect.H * wordScale * scale), 0, pixels.Height);
            var solid = 0;
            for (var row = top; row < bottom; row++)
                for (var column = left; column < right; column++)
                    if (pixels.Pixels.Span[row * pixels.Stride + column * 4 + 3] > 200) solid++;
            Assert.True(solid >= Math.Max(1, (right - left) * (bottom - top) * 0.005), $"{track.Style.Id}: word {rect.Word} has no solid glyph ink ({solid} pixels)");
        }
    }

    private static void AssertPremultiplied(PixelBuffer buffer)
    {
        var pixels = buffer.Pixels.Span;
        for (var offset = 0; offset < pixels.Length; offset += 4)
            for (var channel = 0; channel < 3; channel++) Assert.True(pixels[offset + channel] <= pixels[offset + 3], $"Nonpremultiplied caption at {offset}");
    }
}
