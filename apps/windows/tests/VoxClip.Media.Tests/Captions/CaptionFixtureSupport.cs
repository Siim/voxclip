using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text.Json;
using VoxClip.Core.Domain.Captions;
using VoxClip.Core.Services.Captions;
using VoxClip.Core.Domain.Editing;
using VoxClip.Core.Domain.Shared;
using VoxClip.Media.Captions;
using VoxClip.Tests.Support;
using SkiaSharp;
using Xunit;

namespace VoxClip.Media.Tests.Captions;

internal static class CaptionFixtureSupport
{
    internal static readonly JsonSerializerOptions Json = new() { PropertyNamingPolicy = JsonNamingPolicy.CamelCase, WriteIndented = true };
    internal static string? GoldenRoot => Environment.GetEnvironmentVariable("VOXCLIP_GOLDEN_OUT") is { Length: > 0 } configured ? ValidateGoldenOutput(configured, FixtureLoader.SharedRoot) : null;

    internal static string ValidateGoldenOutput(string configured, string sharedRoot)
    {
        var output = ResolveLinks(configured);
        var shared = ResolveLinks(sharedRoot);
        var comparison = OperatingSystem.IsWindows() ? StringComparison.OrdinalIgnoreCase : StringComparison.Ordinal;
        if (output.Equals(shared, comparison) || output.StartsWith(shared + Path.DirectorySeparatorChar, comparison))
            throw new InvalidOperationException("VOXCLIP_GOLDEN_OUT must be outside the shared directory.");
        return output;
    }

    private static string ResolveLinks(string path)
    {
        var full = Path.GetFullPath(path);
        var root = Path.GetPathRoot(full)!;
        var current = root;
        foreach (var part in full[root.Length..].Split(Path.DirectorySeparatorChar, StringSplitOptions.RemoveEmptyEntries))
        {
            current = Path.Combine(current, part);
            if (Directory.Exists(current) && new DirectoryInfo(current).ResolveLinkTarget(true) is { } linked)
                current = linked.FullName;
        }
        return Path.TrimEndingDirectorySeparator(current);
    }
    internal static CaptionStyle Style(string id) => CaptionStyleResolver.Decode(FixtureLoader.ReadText($"caption-styles/styles/{id}.json"), CaptionDataLoader.Current);

    internal static async Task<CaptionTrack> Build(JsonElement input, JsonElement? overrides = null)
    {
        var style = Style(input.GetProperty("style").GetString()!);
        var captions = input.GetProperty("captions");
        CaptionPosition? Position(JsonElement value) => value.ValueKind == JsonValueKind.Null ? null : new(value.GetProperty("x").GetDouble(), value.GetProperty("y").GetDouble());
        var positions = captions.GetProperty("positionByAspect").EnumerateObject().ToDictionary(property => property.Name, property => Position(property.Value)!.Value);
        var frame = input.GetProperty("frame");
        var source = input.GetProperty("words").EnumerateArray().ToArray();
        var words = source.Select(word => new CaptionWord(word.GetProperty("id").GetString()!, word.GetProperty("text").GetString()!, word.GetProperty("start").GetDouble(), word.GetProperty("end").GetDouble())).ToArray();
        var hints = source.Select(word => new CaptionWordHints(word.TryGetProperty("emphasis", out var emphasis) && emphasis.ValueKind != JsonValueKind.Null ? emphasis.GetBoolean() : null,
            word.TryGetProperty("emoji", out var emoji) && emoji.ValueKind != JsonValueKind.Null ? emoji.GetString() : null)).ToArray();
        var request = new CaptionLayoutRequest(style, new(style.Id, overrides?.Clone() ?? captions.GetProperty("overrides").Clone(), Position(captions.GetProperty("position")), positions),
            new(frame.GetProperty("width").GetInt32(), frame.GetProperty("height").GetInt32()), words, input.GetProperty("language").GetString(), input.GetProperty("duration").GetDouble());
        return await CaptionLayoutBuilder.BuildAsync(request, new HarfBuzzGlyphShaper(), null, CancellationToken.None, CaptionDataLoader.Current, hints);
    }

    internal static object Rect(RectD rectangle) => new { rectangle.X, rectangle.Y, w = rectangle.Width, h = rectangle.Height };

    private static object Run(ShapedRun run, int reference) => new
    {
        run.File, run.Text, units = CaptionLayoutBuilder.RunUnits(run, reference), run.Glyphs, run.Advances,
        offsets = run.Offsets.Select(offset => new[] { offset.X, offset.Y }).ToArray(), run.Clusters
    };

    internal static object Page(CaptionPage page) => new
    {
        page.Index, page.Words, page.Start, page.End, page.FontPx64, page.FontPx, page.Shrunk, page.Lines, page.WordRects,
        block = Rect(page.Block), visual = Rect(page.Visual), page.Boxes, page.Emphasised, page.Emoji, clampShift = new[] { page.ClampShift.X, page.ClampShift.Y }
    };

    internal static object Sample(CaptionTrack track, double time, bool reduced = false)
    {
        var frame = CaptionTimeline.Evaluate(track, time, reduced);
        if (frame is null) return new { t = time, page = (int?)null };
        string Paint(CaptionPaint paint) => paint is SolidPaint solid ? CaptionColor.Parse(solid.Color, track.Style).ToString() : "linear";
        var words = frame.Words.Select(word =>
        {
            var result = new Dictionary<string, object?>
            {
                ["word"] = word.Word, ["state"] = word.State, ["visible"] = word.Visible, ["opacity"] = word.Opacity,
                ["scale"] = word.Scale, ["dy"] = word.Dy, ["fill"] = Paint(word.Fill), ["fillSource"] = word.FillSource
            };
            if (word.Wipe is not null) { result["wipe"] = word.Wipe; result["wipeFrom"] = Paint(word.WipeFrom!); }
            if (word.VisibleClusters is not null) result["visibleClusters"] = word.VisibleClusters;
            return result;
        }).ToArray();
        return new { t = time, page = frame.Page.Index, frame.ActiveWord, frame.Progress, frame.PageAlpha, frame.PageScale, frame.PageDy, jitter = new[] { frame.Jitter.X, frame.Jitter.Y }, words, frame.Cursor };
    }

    internal static object ExpectedProjection(CaptionTrack track, JsonElement input, JsonElement expected)
    {
        var style = track.Style;
        var font = CaptionDataLoader.Current.Fonts[style.Font.File];
        var aspect = CaptionStyleResolver.Aspect(track.Frame);
        var safe = track.SafeRect;
        var insets = track.SafeInsets;
        var font64 = track.FontPx64;
        var limit64 = track.LimitPx64;
        var gap = track.GapUnits;
        var words = track.Words.Select(word =>
        {
            var result = new Dictionary<string, object?>
            {
                ["sourceIndex"] = word.SourceIndex, ["id"] = word.Id, ["raw"] = word.Raw, ["text"] = word.Text,
                ["start"] = word.Start, ["end"] = word.End, ["units"] = word.Units, ["clusters"] = word.Clusters,
                ["runs"] = word.Runs.Select(run => Run(run, font.UnitsPerEm)).ToArray(), ["emphasisPoints"] = word.EmphasisPoints, ["emphasisCandidate"] = word.EmphasisCandidate
            };
            if (word.EmphasisUnits is not null) { result["emphasisUnits"] = word.EmphasisUnits; result["emphasisRuns"] = word.EmphasisRuns!.Select(run => Run(run, font.UnitsPerEm)).ToArray(); }
            if (word.DroppedClusters is { Count: > 0 }) result["droppedClusters"] = word.DroppedClusters;
            return result;
        }).ToArray();
        var dropped = track.Dropped.Select(word => new { word.SourceIndex, word.Text, word.Reason }).ToArray();
        return new
        {
            aspect, preset = CaptionStyleResolver.Preset(track.Frame),
            resolved = new
            {
                style.Font.SizeSh, style.Font.SizeScale, style.Position.X, style.Position.Y,
                anchorX = style.Position.AnchorX.ToString().ToLowerInvariant(), anchorY = style.Position.AnchorY.ToString().ToLowerInvariant(),
                style.Layout.MaxLineWidthW, style.Layout.MaxWords, transform = style.Text.Transform.ToString().ToLowerInvariant(),
                punctuation = style.Text.Punctuation == CaptionTextPunctuationValue.Keep ? "keep" : "strip-keep-numeric", style.Accent
            },
            fontPx64 = font64, fontPx = font64 / 64.0, safeRect = Rect(safe),
            safeInsets = new { left = insets.Left, right = insets.Right, top = insets.Top, bottom = insets.Bottom },
            limitPx = track.LimitPx, limitPx64 = limit64, unitsPerEm = font.UnitsPerEm, gapUnits = gap, words, dropped,
            pages = track.Pages.Select(Page).ToArray(), samples = expected.GetProperty("samples").EnumerateArray().Select(sample => Sample(track, sample.GetProperty("t").GetDouble())).ToArray()
        };
    }

    internal static void Compare(JsonElement expected, object actual, string path)
        => CompareElements(expected, JsonSerializer.SerializeToElement(actual, actual.GetType(), Json), path);

    private static void CompareElements(JsonElement expected, JsonElement actual, string path)
    {
        if (expected.ValueKind == JsonValueKind.Object)
        {
            Assert.Equal(JsonValueKind.Object, actual.ValueKind);
            foreach (var property in expected.EnumerateObject())
            {
                if (property.Name == "golden") continue;
                Assert.True(actual.TryGetProperty(property.Name, out var value), $"Missing {path}.{property.Name}");
                CompareElements(property.Value, value, $"{path}.{property.Name}");
            }
        }
        else if (expected.ValueKind == JsonValueKind.Array)
        {
            Assert.Equal(JsonValueKind.Array, actual.ValueKind);
            Assert.True(expected.GetArrayLength() == actual.GetArrayLength(), $"{path}: array length {expected.GetArrayLength()} != {actual.GetArrayLength()}");
            for (var index = 0; index < expected.GetArrayLength(); index++) CompareElements(expected[index], actual[index], $"{path}[{index}]");
        }
        else if (expected.ValueKind == JsonValueKind.Number)
        {
            var component = path.Split('.').Last().Split('[')[0];
            var pixels = new[] { "x", "y", "w", "h", "r", "top", "baseline", "width", "cx", "cy", "fontPx", "limitPx", "pageDy", "dy", "jitter", "clampShift" };
            var tolerance = pixels.Contains(component) ? 0.5 : new[] { "progress", "pageAlpha", "pageScale", "opacity", "scale", "wipe" }.Contains(component) ? 2e-6 : 1e-9;
            Assert.True(actual.ValueKind == JsonValueKind.Number && Math.Abs(expected.GetDouble() - actual.GetDouble()) <= tolerance,
                $"{path}: {expected} != {actual} (tolerance {tolerance})");
        }
        else Assert.True(JsonElement.DeepEquals(expected, actual), $"{path}: {expected} != {actual}");
    }

    internal static (int X, int Y, int W, int H) Crop(PixelBuffer pixels)
    {
        var bytes = pixels.Pixels.Span;
        var left = pixels.Width; var top = pixels.Height; var right = -1; var bottom = -1;
        for (var row = 0; row < pixels.Height; row++)
            for (var column = 0; column < pixels.Width; column++)
                if (bytes[row * pixels.Stride + column * 4 + 3] > 0) { left = Math.Min(left, column); top = Math.Min(top, row); right = Math.Max(right, column); bottom = Math.Max(bottom, row); }
        var empty = right < left;
        left = empty ? 0 : Math.Max(0, left - 8); top = empty ? 0 : Math.Max(0, top - 8);
        right = empty ? 0 : Math.Min(pixels.Width - 1, right + 8); bottom = empty ? 0 : Math.Min(pixels.Height - 1, bottom + 8);
        var width = right - left + 1; var height = bottom - top + 1;
        return (left, top, width, height);
    }

    internal static object WritePng(PixelBuffer pixels, string path, int? sample, string? style, double time)
    {
        var (left, top, width, height) = Crop(pixels);
        var cropped = new byte[width * height * 4];
        for (var row = 0; row < height; row++) pixels.Pixels.Span.Slice((row + top) * pixels.Stride + left * 4, width * 4).CopyTo(cropped.AsSpan(row * width * 4));
        var handle = GCHandle.Alloc(cropped, GCHandleType.Pinned);
        try
        {
            using var bitmap = new SKBitmap();
            Assert.True(bitmap.InstallPixels(new SKImageInfo(width, height, SKColorType.Bgra8888, SKAlphaType.Premul), handle.AddrOfPinnedObject(), width * 4));
            using var image = SKImage.FromBitmap(bitmap);
            using var encoded = image.Encode(SKEncodedImageFormat.Png, 100);
            Directory.CreateDirectory(Path.GetDirectoryName(path)!);
            File.WriteAllBytes(path, encoded.ToArray());
        }
        finally { handle.Free(); }
        return new { file = Path.GetFileName(path), sample, style, t = time, frame = new { width = pixels.Width, height = pixels.Height }, crop = new { x = left, y = top, w = width, h = height }, sha256 = Convert.ToHexStringLower(SHA256.HashData(File.ReadAllBytes(path))) };
    }
}
