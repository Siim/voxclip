using System.Security.Cryptography;
using System.Text.Json;
using VoxClip.Core.Domain.Captions;
using VoxClip.Core.Domain.Clips;
using VoxClip.Core.Domain.Shared;
using VoxClip.Media.Pipeline;
using VoxClip.Tests.Support;
using Xunit;

namespace VoxClip.Media.Tests;

/// <summary>The Windows grade and finish (looks spec 2026-11-28, sections 5, 6 and 11.1): ClipPicture's 8-bit pass replays
/// shared/fixtures/clip-render/clip-grade-cases.json within one level, follows the Core reference on every colour, keeps
/// today's looks byte for byte, and draws the shared integer grain field exactly.</summary>
public sealed class ClipGradeMediaTests(ITestOutputHelper output)
{
    private static JsonElement Cases() => FixtureLoader.ReadJson("fixtures/clip-render/clip-grade-cases.json").RootElement.Clone();

    private static ProjectClipControls Controls(JsonElement value) =>
        JsonSerializer.Deserialize(value.GetRawText(), ProjectJsonContext.Default.ProjectClipControls)!;

    private static int[] Ints(JsonElement value) => value.EnumerateArray().Select(item => item.GetInt32()).ToArray();
    private static int Int(JsonElement item, string key) => item.GetProperty(key).GetInt32();

    internal static ProjectClipControls Basis { get; } = new("c", 1, null, ClipLook.Original, 0, 0, 0, false, false, 0);

    /// <summary>A one-row frame of <paramref name="colours"/> (RGB bytes), opaque.</summary>
    private static PixelBuffer Row(IReadOnlyList<int[]> colours)
    {
        var pixels = new byte[colours.Count * 4];
        for (var index = 0; index < colours.Count; index++)
        {
            pixels[index * 4] = (byte)colours[index][2];
            pixels[index * 4 + 1] = (byte)colours[index][1];
            pixels[index * 4 + 2] = (byte)colours[index][0];
            pixels[index * 4 + 3] = 255;
        }
        return new(pixels, colours.Count, 1, colours.Count * 4);
    }

    private static int[] Rgb(PixelBuffer frame, int x, int y = 0)
    {
        var offset = y * frame.Stride + x * 4;
        var span = frame.Pixels.Span;
        return [span[offset + 2], span[offset + 1], span[offset]];
    }

    private static int Distance(IReadOnlyList<int> first, IReadOnlyList<int> second) => first.Zip(second).Max(pair => Math.Abs(pair.First - pair.Second));

    private static ClipGradeRecipe Recipe(JsonElement item)
    {
        ClipLook? replacement = item.TryGetProperty("override", out var value) ? value.GetString() switch
        {
            "muted" => ClipLook.Muted, "warm" => ClipLook.Warm, "bw" => ClipLook.Bw, _ => ClipLook.Original
        } : null;
        return ClipGradeRecipe.For(Controls(item.GetProperty("controls")), replacement);
    }

    /// <summary>Every 8-bit colour once: 4096 × 4096 pixels, red in the low byte of the index.</summary>
    private static PixelBuffer EveryColour()
    {
        const int edge = 4096;
        var pixels = new byte[edge * edge * 4];
        for (var index = 0; index < edge * edge; index++)
        {
            pixels[index * 4] = (byte)(index >> 16);
            pixels[index * 4 + 1] = (byte)(index >> 8);
            pixels[index * 4 + 2] = (byte)index;
            pixels[index * 4 + 3] = 255;
        }
        return new(pixels, edge, edge, edge * 4);
    }

    // SHA-256 of every colour graded by the pre-2026-11-28 ClipPicture.Grade (the base look, then the adjustments with no byte in
    // between): today's looks and the Mac's four value presets must keep these bytes (looks spec §1.4 and §11.4).
    public static TheoryData<ClipLook, int[]?, string> LegacyGrades => new()
    {
        { ClipLook.Muted, null, "e4ca8167de6d92a06da6785ec446ed70f59b4fde42dcfca0a34c57db726c7712" },
        { ClipLook.Warm, null, "821f328c7fc331b0896ee5a56fe9144b34e5e6df43db058131ea06c1dc0ed086" },
        { ClipLook.Bw, null, "737bb7268097dfefedf4779c4ca29582300c941deeb821d1ad3e496bb5486861" },
        { ClipLook.Original, [25, 20, -50, 50], "b709820392c27f4b01e290b606c949d410739138c091de7f42889d82833a9e4d" },
        { ClipLook.Original, [8, 22, 18, 0], "e9158a7482183d40f54ca1c5e0dbe8978c8fed36672354f26b9f82a10895eba8" },
        { ClipLook.Muted, [26, -16, -8, 0], "dd2fda3712c349ed821182e6666c72d57732ac86a863dc3d83584ffd5579a668" },
        { ClipLook.Warm, [-10, 40, 60, -70], "34160b8f7e4fbeea39ca0d9d8c413ad28e1624b3eb9aeba29d878de40749edd1" },
        { ClipLook.Bw, [8, -36, -32, 30], "471c4dc705b4a9a3bf7ca1189f0634c08fb5ebfb7c4e8a64e3e906f78428d775" },
    };

    [Theory]
    [MemberData(nameof(LegacyGrades))]
    public void TodaysLooksKeepTheirBytes(ClipLook look, int[]? values, string expected)
    {
        var frame = EveryColour();
        var adjustments = values is null ? null : new ClipColorAdjustments(values[0], values[1], values[2], values[3]);
        ClipPicture.Grade(frame, new ClipGradeRecipe(look, adjustments, null), CancellationToken.None);
        Assert.Equal(expected, Convert.ToHexStringLower(SHA256.HashData(frame.Pixels.Span)));
    }

    [Fact]
    public void TheGradeReplaysEverySharedColourCaseWithinOneLevel()
    {
        var corpus = Cases();
        var tolerance = 1;
        var worst = 0;
        var count = 0;
        foreach (var item in corpus.GetProperty("controls").EnumerateArray().Concat(corpus.GetProperty("chains").EnumerateArray()))
        {
            var frame = Row([Ints(item.GetProperty("input"))]);
            ClipPicture.Grade(frame, Recipe(item), CancellationToken.None);
            var distance = Distance(Rgb(frame, 0), Ints(item.GetProperty("bytes")));
            worst = Math.Max(worst, distance);
            count++;
            Assert.True(distance <= tolerance, $"{item.GetProperty("id").GetString()}: {string.Join(",", Rgb(frame, 0))}");
        }
        var swatches = corpus.GetProperty("swatches8").EnumerateObject().ToDictionary(property => property.Name, property => Ints(property.Value));
        foreach (var item in corpus.GetProperty("looksOnSwatches").EnumerateArray().Concat(corpus.GetProperty("adjustments").EnumerateArray()))
        {
            var expected = item.GetProperty("bytes").EnumerateObject().ToArray();
            var frame = Row(expected.Select(property => swatches[property.Name]).ToArray());
            ClipPicture.Grade(frame, Recipe(item), CancellationToken.None);
            for (var index = 0; index < expected.Length; index++)
            {
                var distance = Distance(Rgb(frame, index), Ints(expected[index].Value));
                worst = Math.Max(worst, distance);
                count++;
                var name = item.TryGetProperty("id", out var id) ? id.GetString() : $"{item.GetProperty("look").GetString()} {Int(item, "amount")}%";
                Assert.True(distance <= tolerance, $"{name} {expected[index].Name}: {string.Join(",", Rgb(frame, index))}");
            }
        }
        output.WriteLine($"grade: {count} colours, largest channel difference from the vectors {worst}");
    }

    /// <summary>Grades that switch on every stage: each of the 24 looks at 100% and 70% over a Fix, both vibrance signs, every
    /// curve channel and the B&amp;W cubic under the T steps.</summary>
    private static IEnumerable<(string Name, ProjectClipControls Controls)> RichGrades()
    {
        var library = ClipLookLibrary.Load(FixtureLoader.SharedRoot);
        var fix = new ClipColorFix(30, -40, 20);
        foreach (var look in library.Looks)
            foreach (var amount in new[] { 100, 70 })
                yield return ($"{look.Id} {amount}% over a Fix", Basis.WithLook(look, amount, fix));
        var every = new ClipColorGrade
        {
            Amount = 55, Exposure = -25, Temperature = 35, Tint = -15, Highlights = -45, Shadows = 40, Vibrance = 70, Fade = 30,
            Curve = new(new(30, 260, 520, 760, 980), new(0, 240, 500, 770, 1000), new(10, 250, 500, 750, 990), new(0, 270, 510, 740, 960)),
            SplitTone = new(210, 40, 30, 35, -30)
        };
        yield return ("every stage", Basis with { Look = ClipLook.Muted, ColorAdjustments = new(10, 25, -20, 15), ColorGrade = every });
        yield return ("negative vibrance on B&W", Basis with { Look = ClipLook.Bw, ColorAdjustments = new(0, 10, 0, 40), ColorGrade = every with { Vibrance = -80, Amount = 100 } });
        yield return ("Fix alone at amount 0", Basis with { Look = ClipLook.Warm, ColorGrade = new() { Amount = 0, Exposure = 60, Temperature = -70, Tint = 45 } });
        yield return ("Fix alone", Basis with { ColorGrade = new() { Exposure = -90, Temperature = 100, Tint = -100 } });
    }

    [Fact]
    public void TheGradeFollowsTheCoreReferenceOnEveryColourWithinOneLevel()
    {
        // 30 levels per channel (0, 9, … 252 and 255): 27,000 colours in a 151-pixel-wide frame, so the last block is ragged.
        var levels = Enumerable.Range(0, 29).Select(level => level * 9).Append(255).ToArray();
        var colours = (from red in levels from green in levels from blue in levels select new[] { red, green, blue }).ToArray();
        const int width = 151;
        var height = (colours.Length + width - 1) / width;
        var worst = 0;
        foreach (var (name, controls) in RichGrades())
        {
            var recipe = ClipGradeRecipe.For(controls);
            var pixels = new byte[width * height * 4];
            for (var index = 0; index < colours.Length; index++)
            {
                pixels[index * 4] = (byte)colours[index][2]; pixels[index * 4 + 1] = (byte)colours[index][1];
                pixels[index * 4 + 2] = (byte)colours[index][0]; pixels[index * 4 + 3] = 255;
            }
            var frame = new PixelBuffer(pixels, width, height, width * 4);
            ClipPicture.Grade(frame, recipe, CancellationToken.None);
            var largest = 0;
            for (var index = 0; index < colours.Length; index++)
            {
                var expected = recipe.Apply(colours[index].Select(value => value / 255.0).ToArray()).Select(ClipGradeRecipe.Byte).ToArray();
                var found = Rgb(frame, index % width, index / width);
                var distance = Distance(found, expected);
                largest = Math.Max(largest, distance);
                Assert.True(distance <= 1, $"{name} on {string.Join(",", colours[index])}: {string.Join(",", found)} vs {string.Join(",", expected)}");
                Assert.Equal(255, pixels[index * 4 + 3]);
            }
            worst = Math.Max(worst, largest);
        }
        output.WriteLine($"dense: largest channel difference from the Core reference {worst}");
    }

    private static PixelBuffer Filled(int width, int height, int[] rgb)
    {
        var pixels = new byte[width * height * 4];
        for (var index = 0; index < width * height; index++)
        {
            pixels[index * 4] = (byte)rgb[2]; pixels[index * 4 + 1] = (byte)rgb[1]; pixels[index * 4 + 2] = (byte)rgb[0]; pixels[index * 4 + 3] = 255;
        }
        return new(pixels, width, height, width * 4);
    }

    [Fact]
    public void TheFinishReplaysEverySharedCaseWithinOneLevel()
    {
        var worst = 0;
        foreach (var item in Cases().GetProperty("finish").EnumerateArray())
        {
            var id = item.GetProperty("id").GetString()!;
            var recipe = new ClipGradeRecipe(ClipLook.Original, null,
                new ClipColorGrade { Amount = Int(item, "amount"), Vignette = Int(item, "vignette"), Grain = Int(item, "grain") });
            ClipGrain.Hole? hole = null;
            if (item.TryGetProperty("hole", out var rect))
            {
                var edges = rect.EnumerateArray().Select(value => value.GetDouble()).ToArray();
                hole = new(edges[0], edges[1], edges[2], edges[3]);
            }
            var frame = Filled(Int(item, "width"), Int(item, "height"), Ints(item.GetProperty("input")));
            ClipPicture.Finish(frame, recipe, ClipGrain.FrameHash(item.GetProperty("n").GetUInt32()), hole, CancellationToken.None);
            var found = Rgb(frame, Int(item, "x"), Int(item, "y"));
            var distance = Distance(found, Ints(item.GetProperty("bytes")));
            worst = Math.Max(worst, distance);
            Assert.True(distance <= 1, $"{id}: {string.Join(",", found)}");
        }
        output.WriteLine($"finish: largest channel difference from the vectors {worst}");
    }

    /// <summary>A diagonal gradient with a fine check, so neighbouring pixels differ.</summary>
    internal static PixelBuffer Gradient(int width, int height)
    {
        var pixels = new byte[width * height * 4];
        for (var y = 0; y < height; y++)
            for (var x = 0; x < width; x++)
            {
                var offset = (y * width + x) * 4;
                var check = ((x >> 3) + (y >> 3)) % 2 * 40;
                pixels[offset] = (byte)(255 * y / Math.Max(1, height - 1));
                pixels[offset + 1] = (byte)Math.Min(255, 40 + check + 160 * x / Math.Max(1, width - 1));
                pixels[offset + 2] = (byte)(255 - 255 * x / Math.Max(1, width - 1));
                pixels[offset + 3] = 255;
            }
        return new(pixels, width, height, width * 4);
    }

    [Theory]
    [InlineData(360, 640, 4u)]
    [InlineData(1080, 1920, 17u)]
    public void TheFinishFollowsTheCoreReferenceOnEveryPixelWithinOneLevel(int width, int height, uint index)
    {
        var recipe = new ClipGradeRecipe(ClipLook.Original, null, new ClipColorGrade { Amount = 80, Vignette = 70, Grain = 100 });
        var source = Gradient(width, height);
        var frame = new PixelBuffer(source.Pixels.ToArray(), width, height, width * 4);
        var hash = ClipGrain.FrameHash(index);
        var hole = new ClipGrain.Hole(width * 0.25, height * 0.3, width * 0.6, height * 0.55);
        ClipPicture.Finish(frame, recipe, hash, hole, CancellationToken.None);
        var step = width * height > 1_000_000 ? 3 : 1;
        var worst = 0;
        for (var y = 0; y < height; y += step)
            for (var x = 0; x < width; x += step)
            {
                var input = Rgb(source, x, y).Select(value => value / 255.0).ToArray();
                var expected = recipe.Finish(input, x, y, width, height, hash, hole).Select(ClipGradeRecipe.Byte).ToArray();
                var distance = Distance(Rgb(frame, x, y), expected);
                worst = Math.Max(worst, distance);
                Assert.True(distance <= 1, $"({x},{y}): {string.Join(",", Rgb(frame, x, y))} vs {string.Join(",", expected)}");
            }
        output.WriteLine($"finish {width}x{height}: largest channel difference from the Core reference {worst}");
    }

    [Theory]
    [InlineData(1080, 1920, 0u)]
    [InlineData(1920, 1080, 7u)]
    [InlineData(719, 1281, 3u)]
    [InlineData(640, 360, 12u)]
    [InlineData(3, 5, 9u)]
    [InlineData(1, 1, 0u)]
    public void TheGrainFieldIsTheSharedIntegerField(int width, int height, uint index)
    {
        var hash = ClipGrain.FrameHash(index);
        using var field = new ClipGrainField(width, height, hash);
        var totals = new int[width];
        var expected = new int[width];
        var rows = Enumerable.Range(0, height).Where(row => height < 400 || row % 37 == 0 || row >= height - 2);
        foreach (var row in rows)
        {
            field.Row(row, totals);
            for (var x = 0; x < width; x++) expected[x] = ClipGrain.Total(x, row, width, height, hash);
            Assert.True(expected.AsSpan().SequenceEqual(totals), $"{width}x{height} frame {index} row {row}");
        }
    }

    [Fact]
    public void GrainLeavesTheDemoHoleAndTheVignetteStillDarkensIt()
    {
        var hole = new ClipGrain.Hole(10.5, 4, 30.2, 20.5);
        var grained = new ClipGradeRecipe(ClipLook.Original, null, new ClipColorGrade { Vignette = 60, Grain = 100 });
        var vignetteOnly = new ClipGradeRecipe(ClipLook.Original, null, new ClipColorGrade { Vignette = 60 });
        var hash = ClipGrain.FrameHash(3);
        var first = Filled(48, 32, [128, 128, 128]);
        var second = Filled(48, 32, [128, 128, 128]);
        ClipPicture.Finish(first, grained, hash, hole, CancellationToken.None);
        ClipPicture.Finish(second, vignetteOnly, hash, null, CancellationToken.None);
        var inside = 0;
        for (var y = 0; y < 32; y++)
            for (var x = 0; x < 48; x++)
            {
                if (hole.Contains(x, y)) { inside++; Assert.Equal(Rgb(second, x, y), Rgb(first, x, y)); }
            }
        Assert.Equal(20 * 16, inside);
        Assert.NotEqual(second.Pixels.ToArray(), first.Pixels.ToArray());
        // Without grain, a tile's finish is the vignette alone.
        var tile = Filled(48, 32, [128, 128, 128]);
        ClipPicture.Finish(tile, grained, hash, null, CancellationToken.None, grain: false);
        Assert.Equal(second.Pixels.ToArray(), tile.Pixels.ToArray());
    }
}
