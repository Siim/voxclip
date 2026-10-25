using System.Collections.Frozen;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace VoxClip.Core.Domain.Captions;

internal sealed record CaptionFontInfo(string File, string Path, string Family, int Weight, bool Italic,
    int UnitsPerEm, int CapHeight, int SpaceAdvance, string Sha256, IReadOnlyList<(int Start, int End)> Coverage)
{
    internal bool Covers(int scalar) => Coverage.Any(range => scalar >= range.Start && scalar <= range.End);
}

internal sealed record CaptionData(string Root, FrozenDictionary<string, CaptionFontInfo> Fonts,
    FrozenDictionary<int, int> Upper, FrozenDictionary<int, int> Lower,
    JsonElement Rules, JsonElement Stopwords, JsonElement Emoji)
{
    internal string NotoFor(int weight) => new[] { 400, 600, 700, 900 }.OrderBy(value => Math.Abs(value - weight)).ThenByDescending(value => value).First() switch
    {
        400 => "NotoSans-Regular.ttf",
        600 => "NotoSans-SemiBold.ttf",
        700 => "NotoSans-Bold.ttf",
        _ => "NotoSans-Black.ttf"
    };
}

[JsonSourceGenerationOptions(PropertyNamingPolicy = JsonKnownNamingPolicy.CamelCase, DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull,
    UnmappedMemberHandling = JsonUnmappedMemberHandling.Disallow, RespectNullableAnnotations = true, RespectRequiredConstructorParameters = true,
    AllowOutOfOrderMetadataProperties = true)]
[JsonSerializable(typeof(CaptionStyle))]
internal partial class CaptionJsonContext : JsonSerializerContext;

/// <summary>Bundled font metadata needed by the native caption shaper and rasterizer.</summary>
public sealed record CaptionFontResource(string Path, int UnitsPerEm, string Sha256);

/// <summary>Read-only access to one validated caption resource snapshot.</summary>
public sealed class CaptionResources
{
    internal CaptionResources(CaptionData data) => Data = data;

    internal CaptionData Data { get; }

    /// <summary>The absolute shared-resource directory used for this snapshot.</summary>
    public string Root => Data.Root;

    /// <summary>Load caption metadata from the application's shared-resource directory.</summary>
    public static CaptionResources Current => new(Services.Captions.CaptionDataLoader.Current);

    /// <summary>Load caption metadata from an explicit shared-resource directory.</summary>
    public static CaptionResources Load(string sharedRoot) => new(Services.Captions.CaptionDataLoader.Load(sharedRoot));

    /// <summary>Get metadata for a bundled font; unlisted files are rejected.</summary>
    public CaptionFontResource Font(string file)
    {
        if (!Data.Fonts.TryGetValue(file, out var font)) throw new ArgumentException("The caption font is not bundled.", nameof(file));
        return new(font.Path, font.UnitsPerEm, font.Sha256);
    }
}

/// <summary>Shaper with a fixed resource snapshot and language-aware glyph shaping.</summary>
public interface ICaptionResourceShaper : IGlyphShaper
{
    /// <summary>The resources used for shaping and layout.</summary>
    CaptionResources Resources { get; }

    /// <summary>Shape text with the requested language using this shaper's resources.</summary>
    Task<ShapedRun> ShapeAsync(ShapingRequest request, string language, CancellationToken ct);
}
