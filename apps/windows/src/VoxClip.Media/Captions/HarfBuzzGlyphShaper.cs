using VoxClip.Core.Domain.Captions;
using HarfBuzzSharp;
namespace VoxClip.Media.Captions;

/// <summary>Direct bundled-font HarfBuzz shaping at integer design scale; captions §4.3.</summary>
public sealed class HarfBuzzGlyphShaper : ICaptionResourceShaper
{
    /// <inheritdoc />
    public CaptionResources Resources { get; }

    /// <summary>Use the application's bundled shared resources.</summary>
    public HarfBuzzGlyphShaper() => Resources = CaptionResources.Current;

    /// <summary>Use only fonts and caption metadata from the selected shared directory.</summary>
    public HarfBuzzGlyphShaper(string sharedRoot) => Resources = CaptionResources.Load(sharedRoot);

    /// <inheritdoc />
    public Task<ShapedRun> ShapeAsync(ShapingRequest request, CancellationToken ct)
        => Shape(request, "und", Resources, ct);

    /// <inheritdoc />
    public Task<ShapedRun> ShapeAsync(ShapingRequest request, string language, CancellationToken ct) => Shape(request, language, Resources, ct);

    private static Task<ShapedRun> Shape(ShapingRequest request, string language, CaptionResources resources, CancellationToken ct)
    {
        ct.ThrowIfCancellationRequested();
        var metadata = resources.Font(request.FontFile);
        if (request.UnitsPerEm != metadata.UnitsPerEm) throw new ArgumentException("Caption shaping requires a bundled font at its design scale.", nameof(request));
        using var blob = Blob.FromFile(CaptionFontFiles.Path(resources, request.FontFile));
        using var face = new Face(blob, 0);
        using var font = new Font(face);
        font.SetScale(request.UnitsPerEm, request.UnitsPerEm);
        font.SetFunctionsOpenType();
        using var buffer = new HarfBuzzSharp.Buffer();
        buffer.AddUtf32(request.Text.EnumerateRunes().Select(rune => (uint)rune.Value).ToArray());
        buffer.GuessSegmentProperties();
        buffer.Direction = Direction.LeftToRight;
        buffer.Language = new Language(language);
        font.Shape(buffer, new[] { new Feature(new Tag('k', 'e', 'r', 'n'), request.Kern ? 1u : 0u), new Feature(new Tag('l', 'i', 'g', 'a'), request.Liga ? 1u : 0u), new Feature(new Tag('c', 'a', 'l', 't'), request.Calt ? 1u : 0u) });
        ct.ThrowIfCancellationRequested();
        var infos = buffer.GlyphInfos;
        var positions = buffer.GlyphPositions;
        return Task.FromResult(new ShapedRun(request.FontFile, request.Text, request.UnitsPerEm, infos.Select(info => info.Codepoint).ToArray(),
            positions.Select(position => (long)position.XAdvance).ToArray(), positions.Select(position => new GlyphOffset(position.XOffset, position.YOffset)).ToArray(),
            infos.Select(info => checked((int)info.Cluster)).ToArray()));
    }
}

/// <summary>Single glyph-outline renderer; implementation is in SkiaCaptionRasterizer.cs, captions §12–13.</summary>
public sealed partial class SkiaCaptionRasterizer;
