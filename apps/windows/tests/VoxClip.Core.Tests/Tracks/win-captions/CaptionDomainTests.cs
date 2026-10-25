using System.Globalization;
using System.Collections.Frozen;
using System.Text.Json;
using System.Text.Json.Nodes;
using VoxClip.Core.Domain.Captions;
using VoxClip.Core.Services.Captions;
using VoxClip.Core.Domain.Editing;
using VoxClip.Core.Domain.Shared;
using VoxClip.Tests.Support;
using Xunit;

namespace VoxClip.Core.Tests.Tracks.WinCaptions;

public sealed class CaptionDomainTests
{
    [Theory]
    [InlineData("linear")]
    [InlineData("easeOutCubic")]
    [InlineData("easeInOutCubic")]
    [InlineData("easeOutBack")]
    public void EasingClampsProgressAndKeepsExactEndpoints(string easing)
    {
        foreach (var progress in new[] { double.NegativeInfinity, -2, 0 }) Assert.Equal(0, CaptionMath.Ease(easing, progress));
        foreach (var progress in new[] { 1, 2, double.PositiveInfinity }) Assert.Equal(1, CaptionMath.Ease(easing, progress));
    }

    [Fact]
    public void EasingDoesNotClampInteriorBackOvershoot()
        => Assert.True(CaptionMath.Ease("easeOutBack", 0.6) > 1);

    [Fact]
    public void CaptionDataCacheRetriesAFailedFirstLoad()
    {
        var directory = Directory.CreateTempSubdirectory("voxclip-caption-retry-");
        try
        {
            var cached = CaptionDataLoader.CreateCache(() => CaptionDataLoader.Load(directory.FullName));
            Assert.Throws<DirectoryNotFoundException>(() => _ = cached.Value);
            foreach (var relative in new[] { "fonts/fonts.json", "caption-styles/casemap.json", "caption-styles/stopwords.json", "caption-styles/emoji-keywords.json" })
            {
                var destination = Path.Combine(directory.FullName, relative);
                Directory.CreateDirectory(Path.GetDirectoryName(destination)!);
                File.Copy(Path.Combine(FixtureLoader.SharedRoot, relative), destination);
            }
            Assert.Equal(directory.FullName, cached.Value.Root);
        }
        finally { directory.Delete(true); }
    }

    [Theory]
    [InlineData("#FFFFFF\n")]
    [InlineData("$accent\n")]
    public async Task TrailingNewlineColourRejectsOverride(string color)
    {
        var style = CaptionStyleResolver.Decode(FixtureLoader.ReadText("caption-styles/styles/karaoke.json"), CaptionDataLoader.Current);
        var patch = JsonSerializer.SerializeToElement(new { fill = new { type = "solid", color } });
        var request = new CaptionLayoutRequest(style, new(style.Id, patch, null, new Dictionary<string, CaptionPosition>()),
            new(1080, 1920), [], "en", 1);
        var track = await CaptionEngine.BuildAsync(request, new UnusedShaper(), null, CancellationToken.None);
        Assert.True(track.OverridesRejected);
        Assert.Equal(style.Fill, track.Style.Fill);
        _ = CaptionColor.Parse(Assert.IsType<SolidPaint>(track.Style.Fill).Color, track.Style);
    }

    public static IEnumerable<object[]> TextCases()
    {
        using var document = FixtureLoader.ReadJson("fixtures/captions/text-normalization.json");
        return document.RootElement.GetProperty("cases").EnumerateArray().Select((item, index) => new object[] { index, item.Clone() }).ToArray();
    }

    [Theory]
    [MemberData(nameof(TextCases))]
    public void TextNormalization(int index, JsonElement item)
    {
        _ = index;
        var data = CaptionDataLoader.Current;
        var language = CaptionTextRules.Language(item.GetProperty("language").GetString());
        foreach (var result in item.GetProperty("results").EnumerateObject())
        {
            var parts = result.Name.Split('|');
            var transform = parts[1] switch { "uppercase" => CaptionTextTransformValue.Uppercase, "lowercase" => CaptionTextTransformValue.Lowercase, _ => CaptionTextTransformValue.None };
            var punctuation = parts[0] == "keep" ? CaptionTextPunctuationValue.Keep : CaptionTextPunctuationValue.StripKeepNumeric;
            Assert.Equal(result.Value.GetString(), CaptionTextRules.Normalize(item.GetProperty("input").GetString()!, new(transform, punctuation), language, data));
        }
        var input = item.GetProperty("input").GetString()!;
        Assert.Equal(item.GetProperty("matchingKey").GetString(), CaptionTextRules.Key(CaptionTextRules.Raw(input), language, data));
        Assert.Equal(item.GetProperty("endsSentence").GetBoolean(), CaptionTextRules.Ends(input, true));
        Assert.Equal(item.GetProperty("endsClause").GetBoolean(), CaptionTextRules.Ends(input, false));
    }

    public static IEnumerable<object[]> Styles() => Directory.EnumerateFiles(Path.Combine(FixtureLoader.SharedRoot, "caption-styles", "styles"), "*.json").Order(StringComparer.Ordinal).Select(path => new object[] { path });

    [Theory]
    [MemberData(nameof(Styles))]
    public void AllBundledStylesStrictlyDecode(string path)
    {
        var style = CaptionStyleResolver.Decode(File.ReadAllText(path), CaptionDataLoader.Current);
        Assert.Equal(Path.GetFileNameWithoutExtension(path), style.Id);
        Assert.NotEmpty(style.Font.FallbackFiles.Append(style.Font.File));
    }

    [Fact]
    public void SchemaDefaultsMatchTypedRecords()
    {
        using var document = FixtureLoader.ReadJson("caption-styles/schema.json");
        var root = document.RootElement;
        var definitions = root.GetProperty("$defs");
        var examples = new Dictionary<string, object>
        {
            ["font"] = new CaptionFont(),
            ["text"] = new CaptionText(),
            ["layout"] = new CaptionLayout(),
            ["position"] = new CaptionStylePosition(),
            ["boxShape"] = new CaptionBoxShape(),
            ["box"] = new CaptionBox(),
            ["wordBox"] = new CaptionWordBox(),
            ["wordState"] = new CaptionWordState(),
            ["wordStates"] = new CaptionWordStates(),
            ["reveal"] = new CaptionReveal(),
            ["anim"] = new CaptionAnimationSpec(),
            ["animation"] = new CaptionAnimation(),
            ["emphasis"] = new CaptionEmphasis(),
            ["emoji"] = new CaptionEmoji(),
            ["effects"] = new CaptionEffects(),
            ["preview"] = new CaptionPreview()
        };
        var options = new JsonSerializerOptions { PropertyNamingPolicy = JsonNamingPolicy.CamelCase };
        var count = 0;
        void Check(JsonElement schema, JsonElement value)
        {
            if (schema.TryGetProperty("$ref", out var reference))
            {
                schema = root;
                foreach (var part in reference.GetString()![2..].Split('/')) schema = schema.GetProperty(part);
            }
            if (!schema.TryGetProperty("properties", out var properties) || value.ValueKind != JsonValueKind.Object) return;
            foreach (var property in properties.EnumerateObject())
            {
                var child = property.Value;
                if (child.TryGetProperty("$ref", out var childReference))
                {
                    child = root;
                    foreach (var part in childReference.GetString()![2..].Split('/')) child = child.GetProperty(part);
                }
                var hasDefault = property.Value.TryGetProperty("default", out var expected) || child.TryGetProperty("default", out expected);
                if (hasDefault)
                {
                    if (!value.TryGetProperty(property.Name, out var actual) && expected.ValueKind == JsonValueKind.Null) { count++; continue; }
                    Assert.True(value.TryGetProperty(property.Name, out actual), property.Name);
                    if (expected.ValueKind != JsonValueKind.Object) Assert.True(JsonElement.DeepEquals(expected, actual), $"Default {property.Name}: {expected} != {actual}");
                    count++;
                }
                if (value.TryGetProperty(property.Name, out var nested)) Check(child, nested);
            }
        }
        foreach (var example in examples) Check(definitions.GetProperty(example.Key), JsonSerializer.SerializeToElement(example.Value, example.Value.GetType(), options));
        Check(definitions.GetProperty("reveal").GetProperty("properties").GetProperty("cursor"), JsonSerializer.SerializeToElement(new CaptionRevealCursor(), options));
        var linear = new LinearPaint(0, [new(0, "#000000"), new(1, "#FFFFFF")]);
        Check(definitions.GetProperty("paint").GetProperty("oneOf")[1], JsonSerializer.SerializeToElement(linear, options));
        Check(root, JsonSerializer.SerializeToElement(new CaptionStyle(), CaptionJsonContext.Default.CaptionStyle));
        Assert.True(count >= 65, $"Only {count} defaults checked.");
    }

    [Fact]
    public void MathVectorsAndBalancedTies()
    {
        using var document = FixtureLoader.ReadJson("fixtures/captions/math.json");
        var root = document.RootElement;
        foreach (var pair in root.GetProperty("roundHalfUp").EnumerateArray()) Assert.Equal(pair[1].GetInt64(), CaptionMath.RoundHalfUp(pair[0].GetDouble()));
        foreach (var easing in root.GetProperty("easing").EnumerateObject())
        {
            var name = easing.Name.Split('(')[0];
            var overshoot = easing.Name.Contains('(') ? double.Parse(easing.Name.Split('(')[1].TrimEnd(')'), CultureInfo.InvariantCulture) : 1.70158;
            foreach (var pair in easing.Value.EnumerateArray()) Assert.InRange(Math.Abs(pair[1].GetDouble() - CaptionMath.Ease(name, pair[0].GetDouble(), overshoot)), 0, 1e-9);
        }
        foreach (var sequence in root.GetProperty("mulberry32").EnumerateObject())
        {
            var random = new Mulberry32(uint.Parse(sequence.Name, CultureInfo.InvariantCulture));
            foreach (var number in sequence.Value.EnumerateArray()) Assert.Equal(number.GetDouble(), random.Next());
        }
        foreach (var jitter in root.GetProperty("jitter").EnumerateArray())
        {
            var key = (long)Math.Floor(jitter.GetProperty("t").GetDouble() * jitter.GetProperty("rateHz").GetDouble() + 1e-6);
            Assert.Equal(jitter.GetProperty("k").GetInt64(), key);
            var random = new Mulberry32(unchecked((uint)(jitter.GetProperty("seed").GetInt64() ^ key)));
            foreach (var number in jitter.GetProperty("r").EnumerateArray()) Assert.Equal(number.GetDouble(), random.Next());
        }
        var lines = CaptionMath.BreakLines([3, 3, 3], 1, 7, 2, true);
        Assert.Equal(new[] { 0 }, lines[0]);
        Assert.Equal(new[] { 1, 2 }, lines[1]);
    }

    [Fact]
    public void InvalidOverridesFallBackAndRequiredDefaultsAreRestored()
    {
        var style = CaptionStyleResolver.Decode(FixtureLoader.ReadText("caption-styles/styles/karaoke.json"), CaptionDataLoader.Current);
        CaptionStyle Resolve(string patch) => CaptionStyleResolver.Resolve(new(style, new(style.Id, JsonDocument.Parse(patch).RootElement.Clone(), null, new Dictionary<string, CaptionPosition>()), new(1080, 1920), [], "en", 1), CaptionDataLoader.Current);
        Assert.Equal(style.Font.SizeSh, Resolve("{\"font\":{\"sizeSh\":9}}").Font.SizeSh);
        Assert.Equal(style.Font.SizeSh, Resolve("{\"font\":{\"sizeSh\":null}}").Font.SizeSh);
        Assert.Equal(style.Font.SizeSh, Resolve("{\"id\":\"changed\"}").Font.SizeSh);
        Assert.Equal(style.Font.SizeSh, Resolve("{\"words\":{\"past\":{\"box\":{\"color\":\"#FFFFFF\"}}}}").Font.SizeSh);
        Assert.Equal(1, Resolve("{\"font\":{\"sizeScale\":null}}").Font.SizeScale);
        Assert.Equal(1.2, Resolve("{\"font\":{\"sizeScale\":1.2}}").Font.SizeScale);
        Assert.Throws<JsonException>(() => CaptionStyleResolver.Decode(FixtureLoader.ReadText("caption-styles/styles/karaoke.json").Replace("\"schemaVersion\": 1", "\"schemaVersion\": 2", StringComparison.Ordinal), CaptionDataLoader.Current));
    }

    [Theory]
    [InlineData("{\"emphasis\":{\"source\":\"rule\",\"fill\":{\"color\":\"#FF0000\",\"type\":\"solid\"}}}", false)]
    [InlineData("{\"emphasis\":{\"source\":\"rule\",\"fill\":{\"color\":\"#FF0000\"}}}", true)]
    public async Task PaintPatchOrderingAndMissingDiscriminators(string patch, bool rejected)
    {
        var style = CaptionStyleResolver.Decode(FixtureLoader.ReadText("caption-styles/styles/karaoke.json"), CaptionDataLoader.Current);
        using var document = JsonDocument.Parse(patch);
        var request = new CaptionLayoutRequest(style, new(style.Id, document.RootElement.Clone(), null, new Dictionary<string, CaptionPosition>()), new(1080, 1920), [], "en", 1);
        var track = await CaptionEngine.BuildAsync(request, new UnusedShaper(), null, CancellationToken.None);
        Assert.Equal(rejected, track.OverridesRejected);
        if (rejected) Assert.Equal(style.Emphasis, track.Style.Emphasis);
        else Assert.Equal("#FF0000", Assert.IsType<SolidPaint>(track.Style.Emphasis!.Fill).Color);
    }

    [Theory]
    [InlineData("{}")]
    [InlineData("{\"font\":{\"sizeScale\":1.2}}")]
    public void NullGapSurvivesUnrelatedPatches(string patch)
    {
        var style = CaptionStyleResolver.Decode(FixtureLoader.ReadText("caption-styles/styles/clean-subtitle.json"), CaptionDataLoader.Current);
        style = style with { Layout = style.Layout with { BreakOnGapSec = null } };
        using var document = JsonDocument.Parse(patch);
        var resolved = CaptionStyleResolver.Resolve(new(style, new(style.Id, document.RootElement.Clone(), null, new Dictionary<string, CaptionPosition>()), new(1080, 1920), [], "en", 3), CaptionDataLoader.Current);
        Assert.Null(resolved.Layout.BreakOnGapSec);
    }

    [Fact]
    public async Task DroppedWordsDistinguishEmptyTextFromMissingGlyphs()
    {
        var style = CaptionStyleResolver.Decode(FixtureLoader.ReadText("caption-styles/styles/karaoke.json"), CaptionDataLoader.Current);
        var request = new CaptionLayoutRequest(style, new(style.Id, default, null, new Dictionary<string, CaptionPosition>()), new(1080, 1920),
            [new("empty", "—", 0, 0.2), new("emoji", "🔥", 0.3, 0.5), new("cjk", "你好", 0.6, 0.8)], "en", 1);
        var track = await CaptionEngine.BuildAsync(request, new UnusedShaper(), null, CancellationToken.None);
        Assert.Equal(new[] { (0, "—", "empty"), (1, "🔥", "no-glyphs"), (2, "你好", "no-glyphs") }, track.Dropped);
        Assert.False(track.OverridesRejected);
    }

    [Theory]
    [InlineData("font", "sizeRef", "0")]
    [InlineData("font", "sizeRef", "\"SHORTEDGE\"")]
    [InlineData("font", "sizeSh", "0.009")]
    [InlineData("font", "sizeScale", "1.61")]
    [InlineData("font", "wordSpacingEm", "null")]
    [InlineData("font", "fallbackFiles", "[null]")]
    [InlineData("layout", "maxWords", "17")]
    [InlineData("layout", "maxLines", "4")]
    [InlineData("layout", "maxLineWidthW", "0.19")]
    [InlineData("layout", "maxPageSec", "0.49")]
    [InlineData("position", "x", "1.01")]
    [InlineData("text", "transform", "\"UPPERCASE\"")]
    [InlineData("preview", "activeWord", "16")]
    [InlineData("preview", "background", "\"#FFFFFF80\"")]
    [InlineData("", "emoji", "{\"placement\":\"below-page\"}")]
    [InlineData("", "tags", "[\"test\",\"test\"]")]
    [InlineData("", "accent", "\"$accent\"")]
    [InlineData("", "shadows", "[null]")]
    [InlineData("", "fill", "{\"type\":\"solid\"}")]
    [InlineData("", "fill", "{\"type\":\"linear\",\"stops\":[{\"offset\":0,\"color\":\"#FFFFFF\"},{\"offset\":1,\"color\":\"#000000\"}]}")]
    [InlineData("", "fill", "{\"type\":\"solid\",\"color\":\"#FFFFFF\",\"unknown\":true}")]
    [InlineData("", "fill", "{\"type\":\"linear\",\"angleDeg\":0,\"stops\":[{\"offset\":0,\"color\":\"#FFFFFF80\"},{\"offset\":1,\"color\":\"#000000\"}]}")]
    public void TypedDecodingRejectsInvalidValues(string section, string property, string value)
    {
        var style = JsonNode.Parse(FixtureLoader.ReadText("caption-styles/styles/karaoke.json"))!;
        var target = section.Length == 0 ? style : style[section]!;
        target[property] = JsonNode.Parse(value);
        Assert.Throws<JsonException>(() => CaptionStyleResolver.Decode(style.ToJsonString(), CaptionDataLoader.Current));
    }

    [Fact]
    public void TypedDecodingRejectsMissingAndDuplicateProperties()
    {
        var style = JsonNode.Parse(FixtureLoader.ReadText("caption-styles/styles/karaoke.json"))!.AsObject();
        style.Remove("text");
        Assert.Throws<JsonException>(() => CaptionStyleResolver.Decode(style.ToJsonString(), CaptionDataLoader.Current));
        var original = FixtureLoader.ReadText("caption-styles/styles/karaoke.json");
        var duplicate = original.Insert(original.LastIndexOf('}'), ",\"schemaVersion\":1");
        Assert.Throws<JsonException>(() => CaptionStyleResolver.Decode(duplicate, CaptionDataLoader.Current));
    }

    [Fact]
    public async Task OffAndCancellationDoNotShape()
    {
        var style = CaptionStyleResolver.Decode(FixtureLoader.ReadText("caption-styles/styles/karaoke.json"), CaptionDataLoader.Current);
        var request = new CaptionLayoutRequest(style, new("off", JsonDocument.Parse("{}").RootElement.Clone(), null, new Dictionary<string, CaptionPosition>()), new(1080, 1920), [new CaptionWord("word", "hello", 0, 1)], "en", 2);
        Assert.Empty((await CaptionEngine.BuildAsync(request, new UnusedShaper(), null, CancellationToken.None)).Pages);
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => CaptionEngine.BuildAsync(request, new UnusedShaper(), null, new CancellationToken(true)));
    }

    [Fact]
    public async Task CursorFramesRemainPureAfterBundledDataBecomesUnavailable()
    {
        var directory = Directory.CreateTempSubdirectory("voxclip-caption-data-");
        try
        {
            foreach (var relative in new[] { "fonts/fonts.json", "caption-styles/casemap.json", "caption-styles/stopwords.json", "caption-styles/emoji-keywords.json" })
            {
                var destination = Path.Combine(directory.FullName, relative);
                Directory.CreateDirectory(Path.GetDirectoryName(destination)!);
                File.Copy(Path.Combine(FixtureLoader.SharedRoot, relative), destination);
            }
            var data = CaptionDataLoader.Load(directory.FullName);
            var style = CaptionStyleResolver.Decode(FixtureLoader.ReadText("caption-styles/styles/typewriter.json"), data);
            var bundled = data.Fonts[style.Font.File];
            var changed = bundled with { CapHeight = bundled.CapHeight / 2, UnitsPerEm = bundled.UnitsPerEm + 113 };
            data = data with { Fonts = data.Fonts.Values.Select(font => font.File == changed.File ? changed : font).ToFrozenDictionary(font => font.File, StringComparer.Ordinal) };
            style = style with { Font = style.Font with { LetterSpacingEm = 0.037 } };
            var request = new CaptionLayoutRequest(style, new(style.Id, default, null, new Dictionary<string, CaptionPosition>()),
                new(1080, 1920), [new("word", "hello", 0, 1)], "en", 2);
            var track = await CaptionLayoutBuilder.BuildAsync(request, new SnapshotShaper(), null, CancellationToken.None, data);
            directory.Delete(true);
            Assert.Throws<DirectoryNotFoundException>(() => CaptionDataLoader.Load(directory.FullName));
            var page = Assert.Single(track.Pages);
            var rect = Assert.Single(page.WordRects);
            var cap = 2 * (rect.Baseline - rect.Cy);
            var options = style.Reveal!.Cursor!;
            var duration = Math.Min(1, 5.0 / style.Reveal.MaxCharsPerSec);
            foreach (var time in new[] { 0.0, 0.05, 0.2, 0.8 })
            {
                var actual = CaptionTimeline.Evaluate(track, time, false)!;
                var cursor = Assert.IsType<CaptionCursorFrame>(actual.Cursor);
                var clusters = Enumerable.Range(0, 5).Count(cluster => time >= cluster / 5.0 * duration);
                var pen = clusters * 500.0 * page.FontPx / changed.UnitsPerEm + Math.Max(0, clusters - 1) * page.LetterSpacingPx;
                Assert.Equal(time < duration || options.BlinkHz == 0 || Math.Floor((time - duration) * options.BlinkHz * 2) % 2 == 0, cursor.Visible);
                Assert.InRange(Math.Abs(cursor.X - (rect.X + pen + 0.05 * page.FontPx)), 0, 1e-9);
                Assert.InRange(Math.Abs(cursor.Y - (rect.Baseline - cap - 0.1 * page.FontPx)), 0, 1e-9);
                Assert.Equal(options.WidthEm * page.FontPx, cursor.W);
                Assert.InRange(Math.Abs(cursor.H - (cap + 0.2 * page.FontPx)), 0, 1e-9);
            }
        }
        finally { if (directory.Exists) directory.Delete(true); }
    }

    private sealed class SnapshotShaper : IGlyphShaper
    {
        public Task<ShapedRun> ShapeAsync(ShapingRequest request, CancellationToken ct)
        {
            var count = request.Text.Length;
            return Task.FromResult(new ShapedRun(request.FontFile, request.Text, request.UnitsPerEm,
                Enumerable.Repeat(1u, count).ToArray(), Enumerable.Repeat(500L, count).ToArray(), new GlyphOffset[count], Enumerable.Range(0, count).ToArray()));
        }
    }

    private sealed class UnusedShaper : IGlyphShaper
    {
        public Task<ShapedRun> ShapeAsync(ShapingRequest request, CancellationToken ct) => throw new InvalidOperationException("Off must not shape.");
    }

    [Fact]
    public async Task UnshapeableWordsAreReportedRatherThanFailingLayout()
    {
        var style = CaptionStyleResolver.Decode(FixtureLoader.ReadText("caption-styles/styles/karaoke.json"), CaptionDataLoader.Current);
        var request = new CaptionLayoutRequest(style, new(style.Id, default, null, new Dictionary<string, CaptionPosition>()), new(1080, 1920), [new("empty-shape", "hello", 0, 1)], "en", 2);
        var track = await CaptionEngine.BuildAsync(request, new EmptyShaper(), null, CancellationToken.None);
        Assert.Empty(track.Words);
        Assert.Equal(new[] { (0, "hello", "no-glyphs") }, track.Dropped);
    }

    private sealed class EmptyShaper : IGlyphShaper
    {
        public Task<ShapedRun> ShapeAsync(ShapingRequest request, CancellationToken ct)
            => Task.FromResult(new ShapedRun(request.FontFile, request.Text, request.UnitsPerEm, [], [], [], []));
    }
}
