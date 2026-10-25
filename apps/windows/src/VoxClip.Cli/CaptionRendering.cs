using System.CommandLine;
using System.Globalization;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text.Json;
using System.Text.Json.Nodes;
using SkiaSharp;
using VoxClip.Core.Domain.Captions;
using VoxClip.Core.Domain.Editing;
using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Services.Project;
using VoxClip.Media.Captions;

namespace VoxClip.Cli;

internal static class CaptionRendering
{
    internal static CaptionStyle LoadStyle(string id)
    {
        if (id != Path.GetFileName(id) || id.Contains('/') || id.Contains('\\')) throw new CliUsageException("Invalid caption style id.");
        var path = Path.Combine(SharedResources.ResolveRoot(), "caption-styles", "styles", id + ".json");
        if (!File.Exists(path)) throw new CliUsageException("Unknown caption style id.");
        return JsonSerializer.Deserialize(File.ReadAllText(path), ProjectJsonContext.Default.CaptionStyle) ?? throw new JsonException("Invalid caption style.");
    }

    internal static async Task<JsonObject> RunAsync(ParseResult arguments, CancellationToken ct)
    {
        var output = Path.GetFullPath(CliOperations.Required(arguments, "--out"));
        var rasterizer = new Lazy<ICaptionRasterizer>(ServicesMergeAdapter.Rasterizer);
        var images = new JsonArray();
        if (arguments.GetValue<string?>("--case") is { } path)
        {
            var fixture = JsonNode.Parse(await File.ReadAllTextAsync(path, ct).ConfigureAwait(false))!;
            var input = fixture["input"]!;
            var id = fixture["id"]!.GetValue<string>();
            if (id != Path.GetFileName(id) || id.Contains('/') || id.Contains('\\')) throw new JsonException("Invalid case id.");
            var track = await BuildCaseAsync(input, ct).ConfigureAwait(false);
            var samples = fixture["expected"]!["samples"]!.AsArray();
            var selected = CliApplication.Sample(arguments);
            if (selected >= samples.Count) throw new CliUsageException("The sample index is outside this case.");
            for (var index = 0; index < samples.Count; index++)
            {
                ct.ThrowIfCancellationRequested();
                if (selected is { } requested ? index != requested : samples[index]?["golden"]?.GetValue<bool>() != true) continue;
                var time = samples[index]!["t"]!.GetValue<double>();
                var destination = selected is not null ? output : Path.Combine(output, id, $"s{index}.png");
                images.Add(await WriteImageAsync(rasterizer.Value, track, time, false, destination, index, null, ct).ConfigureAwait(false));
            }
            if (selected is null) await WriteIndexAsync(Path.Combine(output, id + ".json"), images, ct).ConfigureAwait(false);
        }
        else
        {
            var fixture = JsonNode.Parse(await File.ReadAllTextAsync(CliOperations.Required(arguments, "--tiles"), ct).ConfigureAwait(false))!;
            foreach (var tile in fixture["tiles"]!.AsArray())
            {
                ct.ThrowIfCancellationRequested();
                var style = LoadStyle(tile!["style"]!.GetValue<string>());
                var frame = Size(tile["frame"]!);
                var track = await BuildTileAsync(style, frame, ct).ConfigureAwait(false);
                var wordCount = style.Preview.Text.Split(' ', StringSplitOptions.RemoveEmptyEntries).Length;
                var time = 0.4 * Math.Min(style.Preview.ActiveWord, Math.Max(0, wordCount - 1)) + 0.35 * Math.Min(style.Preview.Progress, 0.98);
                images.Add(await WriteImageAsync(rasterizer.Value, track, time, true, Path.Combine(output, "tiles", $"{style.Id}-{frame.Width}x{frame.Height}.png"), null, style.Id, ct).ConfigureAwait(false));
            }
            await WriteIndexAsync(Path.Combine(output, "tiles.json"), images, ct).ConfigureAwait(false);
        }
        return new() { ["output"] = output, ["images"] = images };
    }

    private static PixelSize Size(JsonNode value) => new(value["width"]!.GetValue<int>(), value["height"]!.GetValue<int>());
    internal static Task<CaptionTrack> BuildCaseAsync(JsonNode input, CancellationToken ct)
    {
        var style = LoadStyle(input["style"]!.GetValue<string>());
        var source = input["words"]!.AsArray();
        var words = source.Select(word => new CaptionWord(word!["id"]!.GetValue<string>(), word["text"]!.GetValue<string>(),
            word["start"]!.GetValue<double>(), word["end"]!.GetValue<double>())).ToArray();
        var hints = source.Select(word => new CaptionWordHints(word!["emphasis"]?.GetValue<bool>(), word["emoji"]?.GetValue<string>())).ToArray();
        var settings = JsonSerializer.Deserialize(input["captions"]!.ToJsonString(), CaptionCliJson.Default.FixtureCaptions)!;
        return BuildAsync(style, Size(input["frame"]!), words, input["language"]?.GetValue<string>(),
            input["duration"]!.GetValue<double>(), settings, ct, hints);
    }
    internal static Task<CaptionTrack> BuildTileAsync(CaptionStyle style, PixelSize frame, CancellationToken ct)
    {
        var words = style.Preview.Text.Split(' ', StringSplitOptions.RemoveEmptyEntries).Select((word, index) =>
            new CaptionWord("tile-" + index.ToString(CultureInfo.InvariantCulture), word, 0.4 * index, 0.4 * index + 0.35)).ToArray();
        return BuildAsync(style, frame, words, "en", words.Length * 0.4 + 0.5,
            new(JsonDocument.Parse("{}").RootElement.Clone(), null, new Dictionary<string, CaptionPosition>()), ct);
    }
    private static Task<CaptionTrack> BuildAsync(CaptionStyle style, PixelSize frame, IReadOnlyList<CaptionWord> words, string? language,
        double duration, FixtureCaptions settings, CancellationToken ct, IReadOnlyList<CaptionWordHints>? hints = null) => CaptionEngine.BuildAsync(new CaptionLayoutRequest(style,
            new(style.Id, settings.Overrides, settings.Position, settings.PositionByAspect), frame, words, language, duration) { WordHints = hints }, ServicesMergeAdapter.GlyphShaper(), null, ct);
    private static Task WriteIndexAsync(string path, JsonArray images, CancellationToken ct) =>
        CliOperations.AtomicWriteAsync(path, new JsonObject { ["images"] = images.DeepClone() }.ToJsonString(), ct);

    private static async Task<JsonObject> WriteImageAsync(ICaptionRasterizer rasterizer, CaptionTrack track, double time, bool reduceMotion,
        string path, int? sample, string? style, CancellationToken ct)
    {
        var pixels = await rasterizer.RenderAsync(new(track, time, reduceMotion), ct).ConfigureAwait(false);
        var left = pixels.Width; var right = -1; var top = pixels.Height; var bottom = -1;
        for (var row = 0; row < pixels.Height; row++)
        {
            ct.ThrowIfCancellationRequested();
            for (var column = 0; column < pixels.Width; column++)
            {
                if (pixels.Pixels.Span[row * pixels.Stride + column * 4 + 3] == 0) continue;
                left = Math.Min(left, column); right = Math.Max(right, column); top = Math.Min(top, row); bottom = Math.Max(bottom, row);
            }
        }
        if (right < 0) { left = 0; top = 0; right = 0; bottom = 0; }
        else { left = Math.Max(0, left - 8); top = Math.Max(0, top - 8); right = Math.Min(pixels.Width - 1, right + 8); bottom = Math.Min(pixels.Height - 1, bottom + 8); }
        var width = right - left + 1; var height = bottom - top + 1;
        var rgba = new byte[checked(width * height * 4)];
        for (var row = 0; row < height; row++)
        {
            for (var column = 0; column < width; column++)
            {
                var source = (top + row) * pixels.Stride + (left + column) * 4;
                var target = (row * width + column) * 4;
                var alpha = pixels.Pixels.Span[source + 3];
                rgba[target + 3] = alpha;
                if (alpha == 0) continue;
                rgba[target] = (byte)Math.Min(255, (pixels.Pixels.Span[source + 2] * 255 + alpha / 2) / alpha);
                rgba[target + 1] = (byte)Math.Min(255, (pixels.Pixels.Span[source + 1] * 255 + alpha / 2) / alpha);
                rgba[target + 2] = (byte)Math.Min(255, (pixels.Pixels.Span[source] * 255 + alpha / 2) / alpha);
            }
        }
        using var bitmap = new SKBitmap(new SKImageInfo(width, height, SKColorType.Rgba8888, SKAlphaType.Unpremul));
        Marshal.Copy(rgba, 0, bitmap.GetPixels(), rgba.Length);
        using var encoded = bitmap.Encode(SKEncodedImageFormat.Png, 100);
        var bytes = encoded.ToArray();
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        await File.WriteAllBytesAsync(path, bytes, ct).ConfigureAwait(false);
        return new() { ["file"] = Path.GetFileName(path), ["sample"] = sample, ["style"] = style, ["t"] = time,
            ["frame"] = new JsonObject { ["width"] = track.Frame.Width, ["height"] = track.Frame.Height },
            ["crop"] = new JsonObject { ["x"] = left, ["y"] = top, ["w"] = width, ["h"] = height },
            ["sha256"] = Convert.ToHexStringLower(SHA256.HashData(bytes)) };
    }
}

internal sealed record FixtureCaptions(JsonElement Overrides, CaptionPosition? Position, IReadOnlyDictionary<string, CaptionPosition> PositionByAspect);
[System.Text.Json.Serialization.JsonSourceGenerationOptions(PropertyNamingPolicy = System.Text.Json.Serialization.JsonKnownNamingPolicy.CamelCase)]
[System.Text.Json.Serialization.JsonSerializable(typeof(FixtureCaptions))]
internal partial class CaptionCliJson : System.Text.Json.Serialization.JsonSerializerContext;
