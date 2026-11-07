using System.Buffers;
using System.Runtime.CompilerServices;
using FFmpeg.AutoGen;
using SkiaSharp;
using VoxClip.Core.Domain.Captions;
using VoxClip.Core.Domain.Clips;
using VoxClip.Core.Domain.ContextDemo;
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
    // Screen recordings by their layers' identity (data folder, project, assets): snapshots that only change captions share one copy.
    private readonly Dictionary<string, (IContextDemoFrames Frames, int Count)> demos = new(StringComparer.Ordinal);
    private readonly Func<ContextDemoRenderLayers, IContextDemoFrames> openDemo;
    /// <summary>Use the platform caption rasterizer for every frame.</summary>
    public FrameComposer() : this(SharedResources.ResolveRoot()) { }
    private FrameComposer(string sharedRoot) : this(new SkiaCaptionRasterizer(sharedRoot), sharedRoot) { }
    internal FrameComposer(ICaptionRasterizer rasterizer, string? sharedRoot = null, Func<ContextDemoRenderLayers, IContextDemoFrames>? openDemo = null)
    {
        this.rasterizer = rasterizer; this.sharedRoot = sharedRoot;
        this.openDemo = openDemo ?? (layers => ContextDemoFrames.Open(layers, CancellationToken.None));
    }

    private static string? DemoKey(ComposeSnapshot? snapshot) => snapshot?.ContextDemo is { } layers
        ? string.Join('\n', [layers.DataRoot, layers.Input.ProjectId, .. layers.Input.Assets.Select(asset => asset.Id + ":" + asset.Sha256 + ":" + asset.ByteSize)])
        : null;

    /// <summary>Opens what composing <paramref name="snapshot"/>'s frames needs: its screen recordings (checked and copied) and its
    /// Voice Lab disclosure. Pair with <see cref="ReleaseSnapshot"/>.</summary>
    internal void PrepareSnapshot(ComposeSnapshot snapshot)
    {
        if (DemoKey(snapshot) is { } key)
        {
            lock (demos)
            {
                if (demos.TryGetValue(key, out var shared)) demos[key] = (shared.Frames, shared.Count + 1);
                else demos[key] = (openDemo(snapshot.ContextDemo!), 1);
            }
        }
        try { PrepareDisclosureOverlay(snapshot); }
        catch { ReleaseDemo(snapshot); throw; }
    }

    private void ReleaseDemo(ComposeSnapshot? snapshot)
    {
        if (DemoKey(snapshot) is not { } key) return;
        lock (demos)
        {
            if (!demos.TryGetValue(key, out var shared)) return;
            if (shared.Count > 1) { demos[key] = (shared.Frames, shared.Count - 1); return; }
            demos.Remove(key);
            shared.Frames.Dispose();
        }
    }

    private void PrepareDisclosureOverlay(ComposeSnapshot snapshot)
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

    internal void ReleaseSnapshot(ComposeSnapshot? snapshot)
    {
        if (snapshot is null) return;
        ReleaseDemo(snapshot);
        lock (disclosures)
            if (disclosures.Remove(snapshot, out var overlay)) overlay.Dispose();
    }

    /// <summary>The screen recording placed over <paramref name="editedTime"/>, if any, in place of the scaled source picture (Mac
    /// FrameCompositor: after the source's orientation and crop, before the look, Ask Claude's effects and the clip's motion). It keeps
    /// its own orientation: the clip's flip and quarter turns never reach it (design §6.9).</summary>
    internal void DrawContextDemo(PixelBuffer output, ComposeSnapshot snapshot, double editedTime, bool forPreview, CancellationToken ct)
    {
        if (snapshot.ContextDemo?.At(editedTime) is not { } layer) return;
        IContextDemoFrames frames;
        lock (demos)
            frames = demos.TryGetValue(DemoKey(snapshot)!, out var shared) ? shared.Frames
                : throw new InvalidOperationException("Prepare the context demo before composing frames.");
        var (frame, rotation) = frames.Read(layer.AssetId, layer.SourceTime, ct);
        ContextDemoPicture.Fill(frame, rotation, output, forPreview, ct);
    }

    /// <inheritdoc />
    public void Compose(PixelBuffer decoded, PixelBuffer output, ComposeSnapshot snapshot, double editedTime, bool forPreview, CancellationToken ct)
        => Compose(decoded, output, snapshot, editedTime, forPreview, null, ct);

    /// <summary>As <see cref="Compose(PixelBuffer, PixelBuffer, ComposeSnapshot, double, bool, CancellationToken)"/>, reporting a preview's
    /// failed or degraded frames to <paramref name="failures"/> (design.md §5.4.4 g). In preview, a caption or title that can't be drawn is
    /// left out of the frame; a missing disclosure, context-demo frame or other failure still fails the frame, marked with its reason. An
    /// export (<paramref name="forPreview"/> false) fails exactly as before.</summary>
    internal unsafe void Compose(PixelBuffer decoded, PixelBuffer output, ComposeSnapshot snapshot, double editedTime, bool forPreview,
        PreviewFrameFailures? failures, CancellationToken ct)
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
            try { DrawContextDemo(output, snapshot, editedTime, forPreview, ct); }
            catch (Exception exception) { PreviewFrameFailures.Failed(failures, forPreview, PreviewFailureReason.DemoFrame, exception); throw; }
            FinishClipFrame(output, snapshot, editedTime, decoded.Width, decoded.Height, new(left, top, widthCrop, heightCrop), ct, forPreview, failures);
            DrawOverlays(output, snapshot, editedTime, forPreview, failures, ct);
        }
        finally
        {
            if (oriented is not null) ArrayPool<byte>.Shared.Return(oriented);
            if (turned is not null) ArrayPool<byte>.Shared.Return(turned);
        }
    }

    /// <summary>The captions, then the Voice Lab disclosure, over the finished frame. In preview with <paramref name="failures"/>, a caption
    /// band that can't be drawn is left out and reported (<c>resources</c> when the bundled files are missing, otherwise
    /// <c>caption-layout</c>); an export fails with it. The disclosure is never left out: a frame that can't carry it fails, reported as
    /// <c>disclosure</c> in preview.</summary>
    internal void DrawOverlays(PixelBuffer output, ComposeSnapshot snapshot, double editedTime, bool forPreview, PreviewFrameFailures? failures,
        CancellationToken ct)
    {
        if (snapshot.Captions is { } captions)
        {
            try { rasterizer.Draw(new(captions, editedTime, false, output.Width / (double)captions.Frame.Width), output, ct); }
            catch (Exception exception) when (forPreview && failures is not null && exception is not OperationCanceledException)
            {
                failures.Report(exception is FileNotFoundException or DirectoryNotFoundException or VoxClipException { Code: VoxClipErrorCode.SharedResourcesMissing }
                    ? PreviewFailureReason.Resources : PreviewFailureReason.CaptionLayout);
            }
        }
        if (snapshot.VoiceLab is { Prepared.OutputPlan.RequiresSyntheticRendering: true })
        {
            try
            {
                lock (disclosures)
                {
                    if (!disclosures.TryGetValue(snapshot, out var overlay))
                        throw new InvalidOperationException("Prepare the Voice Lab disclosure before composing frames.");
                    overlay.Draw(output, editedTime, ct);
                }
            }
            catch (Exception exception) { PreviewFrameFailures.Failed(failures, forPreview, PreviewFailureReason.Disclosure, exception); throw; }
        }
    }

    /// <summary>The clip's look, Ask Claude's picture effects and its motion on the scaled frame, before captions (Mac FrameCompositor
    /// order): the look grades the picture first, so censors cover graded pixels and pointers, titles and stickers keep their colours;
    /// then censors and pointers in picture space through <paramref name="crop"/> of the <paramref name="pictureWidth"/> ×
    /// <paramref name="pictureHeight"/> oriented source, at the freeze-held source time; then the clip's motion cue crops the finished
    /// picture (in output coordinates, so a flipped or turned clip zooms where it is seen); then titles, lower thirds, stickers and the
    /// progress bar in the output frame, unzoomed. In preview, a title or lower third that can't be drawn is reported to
    /// <paramref name="failures"/> as <c>title</c>; it is left out of the frame either way.</summary>
    internal void FinishClipFrame(PixelBuffer output, ComposeSnapshot snapshot, double editedTime, int pictureWidth, int pictureHeight, RectD crop,
        CancellationToken ct, bool forPreview = false, PreviewFrameFailures? failures = null)
    {
        if (snapshot.Clip is not { } clip) return;
        if (clip.Controls is { Look: not ClipLook.Original } controls) ClipPicture.Look(output, controls.Look, ct);
        var timeline = snapshot.Timeline;
        var sourceTime = timeline.SourceTime(editedTime);
        var frames = clip.Effects is { } input ? effectFrames.GetValue(input, key => new EffectFrames(key, sharedRoot)) : null;
        if (frames is { HasPicture: true }) frames.DrawPicture(output, pictureWidth, pictureHeight, crop, clip.Effects!.PictureTime(sourceTime), clip.Controls, ct);
        if (clip.Motion.Count > 0 && !(forPreview && clip.ReduceMotionInPreview))
            ClipPicture.Motion(output, VoxClip.Core.Domain.ContextDemo.MotionCueRendering.Transform(clip.Motion, sourceTime), forPreview, ct);
        if (frames is { HasPicture: true })
            frames.DrawFrame(output, sourceTime, editedTime, timeline.MapTime, ct,
                forPreview && failures is not null ? () => failures.Report(PreviewFailureReason.Title) : null);
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
