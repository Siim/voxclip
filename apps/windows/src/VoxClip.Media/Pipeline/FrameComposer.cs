using System.Buffers;
using System.Runtime.CompilerServices;
using FFmpeg.AutoGen;
using SkiaSharp;
using VoxClip.Core.Domain.Captions;
using VoxClip.Core.Domain.Clips;
using VoxClip.Core.Domain.Effects;
using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Domain.VoiceLab;
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
    private readonly string? sharedRoot;
    private readonly ThreadLocal<ScaleState> state = new(() => new());
    private readonly Dictionary<ComposeSnapshot, VoiceLabDisclosureOverlay> disclosures = new(ReferenceEqualityComparer.Instance);
    private readonly ConditionalWeakTable<ClipEffectsRenderInput, EffectFrames> effectFrames = new();
    /// <summary>Use the platform caption rasterizer for every frame.</summary>
    public FrameComposer() : this(SharedResources.ResolveRoot()) { }
    private FrameComposer(string sharedRoot) : this(new SkiaCaptionRasterizer(sharedRoot), sharedRoot) { }
    internal FrameComposer(ICaptionRasterizer rasterizer, string? sharedRoot = null) { this.rasterizer = rasterizer; this.sharedRoot = sharedRoot; }

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
        var controls = snapshot.Clip?.Controls;
        byte[]? oriented = null;
        byte[]? turned = null;
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
            // The clip's flip and quarter turns act on the oriented source before the frame's crop, so every shape fills.
            if (ClipPicture.Orients(controls))
            {
                var (width, height) = ClipPicture.OrientedSize(decoded.Width, decoded.Height, controls);
                turned = ArrayPool<byte>.Shared.Rent(checked(width * height * 4));
                ClipPicture.Orient(decoded, turned, controls!, ct);
                decoded = new(turned.AsMemory(0, width * height * 4), width, height, width * 4);
            }
            var crop = ExportPresets.CenterCrop(new(decoded.Width, decoded.Height), new(output.Width, output.Height), snapshot.Output.PreserveSource);
            crop = VideoCrop(snapshot, crop, decoded.Width, decoded.Height, editedTime);
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
            FinishClipFrame(output, snapshot, editedTime, decoded.Width, decoded.Height, new(left, top, widthCrop, heightCrop), ct, forPreview);
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
        finally
        {
            if (oriented is not null) ArrayPool<byte>.Shared.Return(oriented);
            if (turned is not null) ArrayPool<byte>.Shared.Return(turned);
        }
    }

    /// <summary>The clip's look, Ask Claude's picture effects and its motion on the scaled frame, before captions (Mac FrameCompositor
    /// order): the look grades the picture first, so censors cover graded pixels and pointers, titles and stickers keep their colours;
    /// then censors and pointers in picture space through <paramref name="crop"/> of the <paramref name="pictureWidth"/> ×
    /// <paramref name="pictureHeight"/> oriented source, at the freeze-held source time; then the clip's motion cue crops the finished
    /// picture (in output coordinates, so a flipped or turned clip zooms where it is seen); then titles, lower thirds, stickers and the
    /// progress bar in the output frame, unzoomed.</summary>
    internal void FinishClipFrame(PixelBuffer output, ComposeSnapshot snapshot, double editedTime, int pictureWidth, int pictureHeight, RectD crop,
        CancellationToken ct, bool forPreview = false)
    {
        if (snapshot.Clip is not { } clip) return;
        if (clip.Controls is { Look: not ClipLook.Original } controls) ClipPicture.Look(output, controls.Look, ct);
        var timeline = snapshot.Timeline;
        var sourceTime = timeline.SourceTime(editedTime);
        var frames = clip.Effects is { } input ? effectFrames.GetValue(input, key => new EffectFrames(key, sharedRoot)) : null;
        if (frames is { HasPicture: true }) frames.DrawPicture(output, pictureWidth, pictureHeight, crop, clip.Effects!.PictureTime(sourceTime), clip.Controls, ct);
        if (clip.Motion.Count > 0 && !(forPreview && clip.ReduceMotionInPreview))
            ClipPicture.Motion(output, VoxClip.Core.Domain.ContextDemo.MotionCueRendering.Transform(clip.Motion, sourceTime), forPreview, ct);
        if (frames is { HasPicture: true }) frames.DrawFrame(output, sourceTime, editedTime, timeline.MapTime, ct);
    }

    /// <summary>The changed-duration crop for this output time: a zoomed span (Match video's 1.12× crop, a cut's 1.06×
    /// punch-in) crops the aspect crop in around its anchor, as Mac FrameCompositor does. Zoom-1 spans and legacy plans keep
    /// the center crop untouched.</summary>
    internal static RectD VideoCrop(ComposeSnapshot snapshot, RectD crop, int width, int height, double editedTime)
    {
        if (snapshot.VoiceLab is not { Prepared.OutputPlan.RequiresSyntheticRendering: true } input) return crop;
        var span = input.Framing.At(editedTime);
        if (span.Zoom <= 1) return crop;
        // Anchors are on the source as filmed; a flipped or turned clip moves them with the picture.
        var anchor = snapshot.Clip?.Controls is { } controls ? controls.MapAnchor(span.AnchorX, span.AnchorY) : (span.AnchorX, span.AnchorY);
        return VoiceLabVideoFraming.FaceCrop(new(0, 0, width, height), crop, span.Zoom, anchor.Item1, anchor.Item2);
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
