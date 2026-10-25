using VoxClip.Core.Domain.Captions;
using VoxClip.Core.Domain.Shared;
namespace VoxClip.Media.Captions;

/// <summary>Direct HarfBuzz shaper placeholder; captions §4.3. Never use SKShaper or unshaped text measurement.</summary>
public sealed class HarfBuzzGlyphShaper : IGlyphShaper
{
    /// <inheritdoc />
    public Task<ShapedRun> ShapeAsync(ShapingRequest request, CancellationToken ct)
        => Task.FromException<ShapedRun>(new VoxClipException(VoxClipErrorCode.NotImplemented, "win-captions"));
}
/// <summary>Single glyph-outline Skia renderer placeholder; captions §13. No DrawText, SKTextBlob or platform text renderer.</summary>
public sealed class SkiaCaptionRasterizer : ICaptionRasterizer
{
    /// <inheritdoc />
    public void Draw(CaptionRenderRequest request, PixelBuffer target, CancellationToken ct)
        => throw new VoxClipException(VoxClipErrorCode.NotImplemented, "win-captions");
    /// <inheritdoc />
    public Task<PixelBuffer> RenderAsync(CaptionRenderRequest request, CancellationToken ct)
        => Task.FromException<PixelBuffer>(new VoxClipException(VoxClipErrorCode.NotImplemented, "win-captions"));
}
