using System.Buffers;
using FFmpeg.AutoGen;
using SkiaSharp;
using VoxClip.Core.Domain.Captions;
using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Services.Media;
using VoxClip.Core.Services.Project;
using VoxClip.Media.Captions;
using VoxClip.Media.Ffmpeg;
using VoxClip.Media.VoiceLab;

namespace VoxClip.Media.Pipeline;

/// <summary>The single preview/export BGRA compose path; architecture §6.3.5 and §6.4.</summary>
public sealed class FrameComposer : IFrameComposer
{
    private readonly ICaptionRasterizer rasterizer;
    private readonly ThreadLocal<ScaleState> state = new(() => new());
    private readonly Dictionary<ComposeSnapshot, VoiceLabDisclosureOverlay> disclosures = new(ReferenceEqualityComparer.Instance);
    /// <summary>Use the platform caption rasterizer for every frame.</summary>
    public FrameComposer() : this(new SkiaCaptionRasterizer(SharedResources.ResolveRoot())) { }
    internal FrameComposer(ICaptionRasterizer rasterizer) => this.rasterizer = rasterizer;

    internal void PrepareDisclosure(ComposeSnapshot snapshot)
    {
        if (snapshot.VoiceLab is not { Prepared.OutputPlan.RequiresSyntheticRendering: true } input) return;
        var blocks = new List<VoiceLabDisclosureCaptionBlock>();
        if (snapshot.Captions is { } captions)
        {
            var x = snapshot.Output.Size.Width / (double)captions.Frame.Width;
            var y = snapshot.Output.Size.Height / (double)captions.Frame.Height;
            foreach (var page in captions.Pages)
            {
                if (page.End <= page.Start) continue;
                var visual = page.Visual;
                var block = page.Block;
                var bounds = SKRect.Union(
                    new SKRect((float)(visual.X * x), (float)(visual.Y * y),
                        (float)((visual.X + visual.Width) * x), (float)((visual.Y + visual.Height) * y)),
                    new SKRect((float)(block.X * x), (float)(block.Y * y),
                        (float)((block.X + block.Width) * x), (float)((block.Y + block.Height) * y)));
                blocks.Add(new(page.Start, page.End, bounds));
            }
        }
        var font = Path.Combine(SharedResources.ResolveRoot(), "fonts", "dm-sans", "DMSans-Bold.ttf");
        var overlay = new VoiceLabDisclosureOverlay(input.Prepared.Disclosure, snapshot.Output.Size.Width,
            snapshot.Output.Size.Height, font, blocks);
        lock (disclosures)
        {
            if (!disclosures.TryAdd(snapshot, overlay))
            {
                overlay.Dispose();
                throw new InvalidOperationException("The disclosure snapshot is already prepared.");
            }
        }
    }

    internal void ReleaseDisclosure(ComposeSnapshot? snapshot)
    {
        if (snapshot is null) return;
        lock (disclosures)
            if (disclosures.Remove(snapshot, out var overlay)) overlay.Dispose();
    }

    /// <inheritdoc />
    public unsafe void Compose(PixelBuffer decoded, PixelBuffer output, ComposeSnapshot snapshot, double editedTime, bool forPreview, CancellationToken ct)
    {
        ct.ThrowIfCancellationRequested();
        Validate(decoded); Validate(output);
        var rotation = snapshot.Media.Video?.RotationDegrees ?? 0;
        byte[]? oriented = null;
        try
        {
            if (rotation != 0)
            {
                var width = rotation is 90 or 270 ? decoded.Height : decoded.Width;
                var height = rotation is 90 or 270 ? decoded.Width : decoded.Height;
                oriented = ArrayPool<byte>.Shared.Rent(checked(width * height * 4));
                Rotate(decoded, oriented, rotation, width, ct);
                decoded = new(oriented.AsMemory(0, width * height * 4), width, height, width * 4);
            }
            var crop = ExportPresets.CenterCrop(new(decoded.Width, decoded.Height), new(output.Width, output.Height));
            var left = (int)Math.Floor(crop.X);
            var top = (int)Math.Floor(crop.Y);
            var widthCrop = Math.Clamp((int)Math.Round(crop.Width), 1, decoded.Width - left);
            var heightCrop = Math.Clamp((int)Math.Round(crop.Height), 1, decoded.Height - top);
            var scaling = state.Value!;
            var key = (widthCrop, heightCrop, output.Width, output.Height, forPreview);
            if (scaling.Key != key)
            {
                scaling.Handle?.Dispose();
                scaling.Handle = NativeHandle.Own(ffmpeg.sws_getContext(widthCrop, heightCrop, AVPixelFormat.AV_PIX_FMT_BGRA,
                    output.Width, output.Height, AVPixelFormat.AV_PIX_FMT_BGRA,
                    (int)(forPreview ? SwsFlags.SWS_BILINEAR : SwsFlags.SWS_LANCZOS), null, null, null), NativeKind.Scale);
                scaling.Key = key;
            }
            using var sourceMemory = decoded.Pixels.Pin();
            using var outputMemory = output.Pixels.Pin();
            var source = new byte_ptrArray4(); source[0] = (byte*)sourceMemory.Pointer + top * decoded.Stride + left * 4;
            var sourceStride = new int_array4(); sourceStride[0] = decoded.Stride;
            var target = new byte_ptrArray4(); target[0] = (byte*)outputMemory.Pointer;
            var targetStride = new int_array4(); targetStride[0] = output.Stride;
            Native.Check(ffmpeg.sws_scale((SwsContext*)scaling.Handle!.Pointer, source, sourceStride, 0, heightCrop, target, targetStride), "Crop and scale video");
            if (snapshot.Captions is { } captions)
                rasterizer.Draw(new(captions, editedTime, false, output.Width / (double)captions.Frame.Width), output, ct);
            if (snapshot.VoiceLab is { Prepared.OutputPlan.RequiresSyntheticRendering: true })
            {
                lock (disclosures)
                {
                    if (!disclosures.TryGetValue(snapshot, out var overlay))
                        throw new InvalidOperationException("Prepare the Voice Lab disclosure before composing frames.");
                    overlay.Draw(output, editedTime, ct);
                }
            }
        }
        finally { if (oriented is not null) ArrayPool<byte>.Shared.Return(oriented); }
    }

    internal void ReleaseThreadResources() { state.Value?.Handle?.Dispose(); state.Value = new(); }

    private static void Validate(PixelBuffer buffer)
    {
        if (buffer.Width <= 0 || buffer.Height <= 0 || buffer.Stride < checked(buffer.Width * 4) || buffer.Pixels.Length < checked(buffer.Stride * buffer.Height))
            throw new ArgumentException("A BGRA buffer must contain every declared row.");
    }

    private static void Rotate(PixelBuffer source, byte[] target, int rotation, int width, CancellationToken ct)
    {
        var input = source.Pixels.Span;
        for (var row = 0; row < source.Height; row++)
        {
            ct.ThrowIfCancellationRequested();
            for (var column = 0; column < source.Width; column++)
            {
                var outputColumn = rotation switch { 90 => source.Height - row - 1, 180 => source.Width - column - 1, 270 => row, _ => column };
                var outputRow = rotation switch { 90 => column, 180 => source.Height - row - 1, 270 => source.Width - column - 1, _ => row };
                input.Slice(row * source.Stride + column * 4, 4).CopyTo(target.AsSpan((outputRow * width + outputColumn) * 4, 4));
            }
        }
    }

    private sealed class ScaleState
    {
        internal (int, int, int, int, bool) Key;
        internal NativeHandle? Handle;
    }
}
