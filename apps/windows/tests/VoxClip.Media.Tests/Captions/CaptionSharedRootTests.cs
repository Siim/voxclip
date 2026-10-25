using System.Text.Json;
using System.Runtime.CompilerServices;
using System.Text.Json.Nodes;
using VoxClip.Core.Domain.Captions;
using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Services.Captions;
using VoxClip.Core.Services.Settings;
using VoxClip.Media.Captions;
using VoxClip.Tests.Support;
using Xunit;

namespace VoxClip.Media.Tests.Captions;

[Trait("Category", "Captions")]
public sealed class CaptionSharedRootTests
{
    [Fact]
    public void StyleLibraryProvidesOrderedExactLookupAndStrictDecoding()
    {
        var library = CaptionStyleLibrary.Load(FixtureLoader.SharedRoot);
        Assert.NotEmpty(library.Styles);
        Assert.Equal(library.Styles.OrderBy(style => style.Order).Select(style => style.Id), library.Styles.Select(style => style.Id));
        foreach (var style in library.Styles) Assert.Same(style, library.Find(style.Id));
        Assert.Null(library.Find("missing")); Assert.Null(library.Find("TYPEWRITER"));
        var directory = CreateRoot(copyFont: false);
        try
        {
            Assert.Single(CaptionStyleLibrary.Load(directory.FullName).Styles);
            var path = Path.Combine(directory.FullName, "caption-styles", "styles", "typewriter.json");
            var invalid = JsonNode.Parse(File.ReadAllText(path))!.AsObject();
            invalid["unexpected"] = true;
            File.WriteAllText(path, invalid.ToJsonString());
            Assert.Throws<JsonException>(() => CaptionStyleLibrary.Load(directory.FullName));
        }
        finally { directory.Delete(true); }
    }

    [Fact]
    public async Task ExplicitShaperKeepsBuildMetadataAndOverrideFallbackInItsRoot()
    {
        var directory = CreateRoot();
        try
        {
            var data = CaptionDataLoader.Load(directory.FullName);
            var style = Assert.IsType<CaptionStyle>(CaptionStyleLibrary.Load(directory.FullName).Find("typewriter"));
            var shaper = new HarfBuzzGlyphShaper(directory.FullName);
            var metadata = data.Fonts[style.Font.File];
            var shaped = await shaper.ShapeAsync(new(metadata.File, "Hello", metadata.UnitsPerEm), CancellationToken.None);
            Assert.Equal(metadata.UnitsPerEm, shaped.UnitsPerEm);
            var request = Request(style);
            var track = await CaptionEngine.BuildAsync(request, shaper, null, CancellationToken.None);
            var expected = await CaptionLayoutBuilder.BuildAsync(request, shaper, null, CancellationToken.None, data);
            Assert.Equal(metadata.UnitsPerEm, track.Words[0].Runs[0].UnitsPerEm);
            Assert.Equal(expected.Pages[0].WordRects, track.Pages[0].WordRects);
            Assert.Equal(expected.Words[0].Units, track.Words[0].Units);
            using var patch = JsonDocument.Parse("""{"font":{"file":"missing.ttf"}}""");
            var fallback = await CaptionEngine.BuildAsync(request with { Captions = request.Captions with { Overrides = patch.RootElement.Clone() } }, shaper, null, CancellationToken.None);
            Assert.True(fallback.OverridesRejected);
            Assert.Equal(track.Pages[0].WordRects, fallback.Pages[0].WordRects);
            var pixels = await new SkiaCaptionRasterizer(directory.FullName).RenderAsync(new(track, 0.2, Scale: 0.25), CancellationToken.None);
            Assert.True(CaptionFixtureSupport.Crop(pixels).W > 1);
        }
        finally { directory.Delete(true); }
    }

    [Fact]
    public async Task ExplicitRasterizerNeverFallsBackToGlobalFontFiles()
    {
        var directory = CreateRoot(copyFont: false);
        try
        {
            var style = Assert.IsType<CaptionStyle>(CaptionStyleLibrary.Load(FixtureLoader.SharedRoot).Find("typewriter"));
            var track = await CaptionEngine.BuildAsync(Request(style), new HarfBuzzGlyphShaper(), null, CancellationToken.None);
            var rasterizer = new SkiaCaptionRasterizer(directory.FullName) { CacheEnabled = false };
            var request = new CaptionRenderRequest(track, 0.2, Scale: 0.25);
            Assert.True(rasterizer.IsAnimating(request));
            await Assert.ThrowsAsync<FileNotFoundException>(() => rasterizer.RenderAsync(request, CancellationToken.None));
        }
        finally { directory.Delete(true); }
    }

    [Fact]
    public async Task ExistingConstructorsMatchExplicitBundledRoots()
    {
        var data = CaptionDataLoader.Current;
        var style = Assert.IsType<CaptionStyle>(CaptionStyleLibrary.Load(FixtureLoader.SharedRoot).Find("typewriter"));
        var shaping = new ShapingRequest(style.Font.File, "AVATAR", data.Fonts[style.Font.File].UnitsPerEm);
        var existing = await new HarfBuzzGlyphShaper().ShapeAsync(shaping, CancellationToken.None);
        var selected = await new HarfBuzzGlyphShaper(FixtureLoader.SharedRoot).ShapeAsync(shaping, CancellationToken.None);
        Assert.Equal(existing.Glyphs, selected.Glyphs); Assert.Equal(existing.Advances, selected.Advances);
        var track = await CaptionEngine.BuildAsync(Request(style), new HarfBuzzGlyphShaper(), null, CancellationToken.None);
        var request = new CaptionRenderRequest(track, 0.2, Scale: 0.25);
        var expected = await new SkiaCaptionRasterizer().RenderAsync(request, CancellationToken.None);
        var actual = await new SkiaCaptionRasterizer(FixtureLoader.SharedRoot).RenderAsync(request, CancellationToken.None);
        Assert.Equal(expected.Pixels.ToArray(), actual.Pixels.ToArray());
    }

    [Fact]
    public async Task TransientFontFailureRetriesVerificationOutlinesAndTrackPaths()
    {
        var directory = CreateRoot(copyFont: false);
        try
        {
            var style = CaptionFixtureSupport.Style("typewriter");
            var track = await CaptionEngine.BuildAsync(Request(style), new HarfBuzzGlyphShaper(), null, CancellationToken.None);
            var request = new CaptionRenderRequest(track, 0.2, Scale: 0.25);
            var rasterizer = new SkiaCaptionRasterizer(directory.FullName);
            await Assert.ThrowsAsync<FileNotFoundException>(() => rasterizer.RenderAsync(request, CancellationToken.None));
            var metadata = CaptionDataLoader.Current.Fonts[style.Font.File];
            File.Copy(Path.Combine(FixtureLoader.SharedRoot, "fonts", metadata.Path), Path.Combine(directory.FullName, "fonts", "selected.ttf"));
            var actual = await rasterizer.RenderAsync(request, CancellationToken.None);
            var expected = await new SkiaCaptionRasterizer(directory.FullName).RenderAsync(request, CancellationToken.None);
            Assert.True(CaptionFixtureSupport.Crop(actual).W > 1);
            Assert.True(expected.Pixels.Span.SequenceEqual(actual.Pixels.Span));
            var shaper = new HarfBuzzGlyphShaper(directory.FullName);
            var shaped = await shaper.ShapeAsync(new(style.Font.File, "Hello", CaptionDataLoader.Load(directory.FullName).Fonts[style.Font.File].UnitsPerEm), CancellationToken.None);
            Assert.NotEmpty(shaped.Glyphs);
        }
        finally { directory.Delete(true); }
    }

    private static CaptionLayoutRequest Request(CaptionStyle style) => new(style,
        new(style.Id, default, null, new Dictionary<string, CaptionPosition>()), new(1080, 1920), [new("word", "Hello", 0, 1)], "en", 2);

    [Fact]
    public async Task AFontRetryFactoryDoesNotKeepTheFailedTrackAlive()
    {
        var directory = CreateRoot(copyFont: false);
        try
        {
            var source = await CaptionEngine.BuildAsync(Request(CaptionFixtureSupport.Style("typewriter")), new HarfBuzzGlyphShaper(), null, CancellationToken.None);
            var rasterizer = new SkiaCaptionRasterizer(directory.FullName);
            var failedTrack = DrawDroppedTrackWithMissingFont(rasterizer, source);
            GC.Collect(); GC.WaitForPendingFinalizers(); GC.Collect();
            Assert.False(failedTrack.IsAlive);
            GC.KeepAlive(rasterizer);
            GC.KeepAlive(source);
        }
        finally { directory.Delete(true); }
    }

    [MethodImpl(MethodImplOptions.NoInlining)]
    private static WeakReference DrawDroppedTrackWithMissingFont(SkiaCaptionRasterizer rasterizer, CaptionTrack source)
    {
        var dropped = source with { };
        var target = new PixelBuffer(new byte[270 * 480 * 4], 270, 480, 270 * 4);
        Assert.Throws<FileNotFoundException>(() => rasterizer.Draw(new(dropped, 0.2, Scale: 0.25), target, CancellationToken.None));
        return new(dropped);
    }

    private static DirectoryInfo CreateRoot(bool copyFont = true)
    {
        var directory = Directory.CreateTempSubdirectory("voxclip-caption-root-");
        try
        {
            foreach (var relative in new[] { "fonts/fonts.json", "caption-styles/casemap.json", "caption-styles/stopwords.json", "caption-styles/emoji-keywords.json", "caption-styles/styles/typewriter.json" })
            {
                var path = Path.Combine(directory.FullName, relative);
                Directory.CreateDirectory(Path.GetDirectoryName(path)!);
                File.Copy(Path.Combine(FixtureLoader.SharedRoot, relative), path);
            }
            var fontFile = CaptionFixtureSupport.Style("typewriter").Font.File;
            var metadataPath = Path.Combine(directory.FullName, "fonts", "fonts.json");
            var manifest = JsonNode.Parse(File.ReadAllText(metadataPath))!;
            var font = manifest["fonts"]!.AsArray().Single(item => item!["file"]!.GetValue<string>() == fontFile)!;
            var bundledPath = font["path"]!.GetValue<string>();
            font["path"] = "selected.ttf";
            font["unitsPerEm"] = font["unitsPerEm"]!.GetValue<int>() + 113;
            font["capHeight"] = font["capHeight"]!.GetValue<int>() / 2;
            File.WriteAllText(metadataPath, manifest.ToJsonString());
            if (copyFont) File.Copy(Path.Combine(FixtureLoader.SharedRoot, "fonts", bundledPath), Path.Combine(directory.FullName, "fonts", "selected.ttf"));
            return directory;
        }
        catch { directory.Delete(true); throw; }
    }
}
