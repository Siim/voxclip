using System.Collections.Concurrent;
using System.Buffers;
using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;
using System.Runtime.ExceptionServices;
using SkiaSharp;
using VoxClip.Core.Domain.Captions;

namespace VoxClip.Media.Captions;

/// <summary>Single unhinted glyph-outline BGRA renderer for preview, export and goldens; captions §12–13.</summary>
public sealed partial class SkiaCaptionRasterizer : ICaptionRasterizer
{
    private readonly CaptionResources data;

    /// <summary>Use the application's bundled shared resources.</summary>
    public SkiaCaptionRasterizer() => data = CaptionResources.Current;

    /// <summary>Use only fonts and caption metadata from the selected shared directory.</summary>
    public SkiaCaptionRasterizer(string sharedRoot) => data = CaptionResources.Load(sharedRoot);

    private static readonly ConcurrentDictionary<(string Root, string File, uint Glyph), Lazy<SKPath>> Outlines = new();
    private sealed record FontResources(SKTypeface Typeface, SKFont Font);
    private static readonly ConcurrentDictionary<(string Root, string File), Lazy<FontResources>> Fonts = new();
    private readonly ConditionalWeakTable<CaptionTrack, TrackGeometry> geometries = new();
    private static int nextGeometryId;
    private int cachedGeometryId;
    private readonly List<ShadowBuffer> shadows = [];
    private readonly List<ShadowBuffer> masks = [];
    private readonly object sync = new();
    private const long CacheLimit = 64L * 1024 * 1024;
    private readonly Dictionary<CacheKey, LinkedListNode<CachedPage>> cache = new();
    private readonly LinkedList<CachedPage> recency = new();
    private long cachedBytes;
    private readonly WrappedTarget?[] targets = new WrappedTarget?[8];
    private int nextTarget;
    private SKBitmap? overlayBitmap;
    private SKCanvas? overlayCanvas;
    private readonly SKPaint solidPaint = new();
    private readonly SKPaint strokePaint = new();
    private readonly SKPaint gradientPaint = new();
    private readonly SKPaint layerPaint = new();
    private readonly SKPath boxPath = new();
    private readonly SKPath localBoxPath = new();
    private readonly SKPath borderPath = new();
    private const int GradientLimit = 32;
    private readonly Dictionary<GradientKey, LinkedListNode<CachedGradient>> gradients = new();
    private readonly LinkedList<CachedGradient> gradientRecency = new();
    private readonly CaptionEmojiBuffer emojiPixels = new();
    internal bool CacheEnabled { get; set; } = true;
    internal bool ShareShadowMasks { get; set; } = true;
    internal bool PrecolorShadows { get; set; } = true;
    internal bool QueueShadowBlurs { get; set; } = true;
    internal enum RenderCheckpoint { OverlayBounds, ShadowPrepareGrowth, ShadowBlur, ShadowStart }
    internal Action<RenderCheckpoint>? TestCheckpoint { get; set; }
    internal int LastShadowMaskCount { get; private set; }
    internal long CachedBytes => cachedBytes;
    internal long RetainedShadowBytes => shadows.Sum(buffer => buffer.RetainedBytes) + masks.Sum(buffer => buffer.RetainedBytes);
    internal int InvalidatedShadowViewCount => shadows.Concat(masks).Count(buffer => !buffer.HasViews);
    internal long RetainedMaskColorBytes => masks.Sum(buffer => buffer.ColorBytes);
    internal long RetainedGeometryBytes(CaptionTrack track) => geometries.TryGetValue(track, out var geometry) ? geometry.RetainedBytes : 0;
    internal int RetainedTargetCount => targets.Count(target => target is not null);
    internal int RetainedTargetCanvasSaveCount => targets.First(target => target is not null)!.Canvas.SaveCount;
    internal int OverlayCanvasSaveCount => overlayCanvas?.SaveCount ?? 0;
    internal int LastOverlayClearPixels { get; private set; }
    internal int LastOverlayCopyPixels { get; private set; }
    internal int GradientShaderCount => gradients.Count;
    internal SKShader? OldestGradientShader => gradientRecency.Last?.Value.Shader;
    private readonly record struct GradientKey(SKPoint Start, SKPoint End, IReadOnlyList<GradientStop> Stops, string? Accent)
    {
        public bool Equals(GradientKey other)
        {
            if (Start != other.Start || End != other.End || Accent != other.Accent || Stops.Count != other.Stops.Count) return false;
            for (var index = 0; index < Stops.Count; index++) if (Stops[index] != other.Stops[index]) return false;
            return true;
        }

        public override int GetHashCode()
        {
            var hash = new HashCode();
            hash.Add(Start); hash.Add(End); hash.Add(Accent);
            for (var index = 0; index < Stops.Count; index++) hash.Add(Stops[index]);
            return hash.ToHashCode();
        }
    }
    private sealed record CachedGradient(GradientKey Key, SKShader Shader);
    private readonly record struct CacheKey(int GeometryId, int Page, int Active, int Clusters, int Width, int Height, double Scale, bool ReduceMotion);
    private sealed record CachedPage(CacheKey Key, SKBitmap Bitmap, SKImage Image, int Left, int Top, long Bytes);

    private sealed class WrappedTarget : IDisposable
    {
        internal PixelBuffer Target { get; }
        internal SKSurface Surface { get; }
        internal SKCanvas Canvas { get; }
        private MemoryHandle pin;
        private bool disposed;
        internal unsafe WrappedTarget(PixelBuffer target)
        {
            Target = target;
            pin = target.Pixels.Pin();
            try
            {
                Surface = SKSurface.Create(new SKImageInfo(target.Width, target.Height, SKColorType.Bgra8888, SKAlphaType.Premul), (IntPtr)pin.Pointer, target.Stride)
                    ?? throw new InvalidOperationException("Could not wrap the caption BGRA frame.");
                Canvas = Surface.Canvas;
            }
            catch { pin.Dispose(); throw; }
        }
        public void Dispose()
        {
            if (disposed) return;
            disposed = true;
            Surface?.Dispose();
            pin.Dispose();
            GC.SuppressFinalize(this);
        }
        ~WrappedTarget() => Dispose();
    }

    private sealed class ShadowBuffer : IThreadPoolWorkItem
    {
        private byte[] pixels = [];
        private GCHandle pin;
        internal SKSurface Surface { get; private set; } = null!;
        internal SKCanvas Canvas { get; private set; } = null!;
        internal SKBitmap Bitmap { get; } = new();
        internal SKImage Image { get; private set; } = null!;
        private byte[] coloredPixels = [];
        private GCHandle colorPin;
        private readonly SKBitmap coloredBitmap = new();
        internal SKImage ColoredImage { get; private set; } = null!;
        private readonly int[] tint = new int[256];
        private SKColor? tintColor;
        private bool precolor;
        internal CaptionBlurBuffers Blur { get; } = new();
        internal int Width { get; private set; }
        internal int Height { get; private set; }
        internal int Stride => Width;
        internal long ColorBytes => coloredPixels.LongLength;
        internal long RetainedBytes => pixels.LongLength + coloredPixels.LongLength + Blur.RetainedBytes;
        internal int Left { get; set; }
        internal int Top { get; set; }
        internal SKRect Ink { get; set; }
        internal double Sigma { get; set; }
        internal SKRect Content { get; private set; }
        internal bool HasInk => Content.Width > 0 && Content.Height > 0;
        internal bool HasViews => Surface is not null && Image is not null;
        internal Span<byte> Pixels => pixels.AsSpan(0, checked(Width * Height));
        private readonly ManualResetEventSlim completed = new(true);
        private CancellationToken cancellation;
        private ExceptionDispatchInfo? failure;
        private Action<RenderCheckpoint>? checkpoint;
        private int state = 2;

        internal void Start(CancellationToken ct, bool queued, SKColor color, bool colorize, Action<RenderCheckpoint>? testCheckpoint)
        {
            failure = null;
            Content = SKRect.Empty;
            checkpoint = testCheckpoint;
            cancellation = ct;
            precolor = colorize;
            if (precolor && tintColor != color) PrepareTint(color);
            completed.Reset();
            Volatile.Write(ref state, 0);
            if (queued) ThreadPool.UnsafeQueueUserWorkItem(this, preferLocal: false);
            else Execute();
        }

        public void Execute()
        {
            if (Interlocked.CompareExchange(ref state, 1, 0) != 0) return;
            try
            {
                checkpoint?.Invoke(RenderCheckpoint.ShadowBlur);
                cancellation.ThrowIfCancellationRequested();
                Blur.Apply(Pixels, Width, Height, Sigma, cancellation);
                var bounds = CaptionBlurBuffers.InkBounds(Pixels, Width, Height);
                if (bounds.Right <= bounds.Left || bounds.Bottom <= bounds.Top) return;
                Content = new(bounds.Left, bounds.Top, bounds.Right, bounds.Bottom);
                if (precolor)
                {
                    var output = MemoryMarshal.Cast<byte, int>(coloredPixels.AsSpan());
                    var input = Pixels;
                    for (var row = bounds.Top; row < bounds.Bottom; row++)
                        for (var index = row * Width + bounds.Left; index < row * Width + bounds.Right; index++) output[index] = tint[input[index]];
                }
            }
            catch (Exception error) { failure = ExceptionDispatchInfo.Capture(error); }
            finally { checkpoint = null; Volatile.Write(ref state, 2); completed.Set(); }
        }

        internal ExceptionDispatchInfo? Join() { Execute(); completed.Wait(); return failure; }

        internal Span<byte> Prepare(int requestedWidth, int requestedHeight, bool colorize = false, Action<RenderCheckpoint>? testCheckpoint = null)
        {
            Content = SKRect.Empty;
            if (Width != requestedWidth || Height != requestedHeight || colorize && ColoredImage is null)
            {
                InvalidateViews();
                try
                {
                    var length = checked(requestedWidth * requestedHeight);
                    var grows = pixels.Length < length;
                    Grow(ref pixels, ref pin, length);
                    if (grows) testCheckpoint?.Invoke(RenderCheckpoint.ShadowPrepareGrowth);
                    var info = new SKImageInfo(requestedWidth, requestedHeight, SKColorType.Alpha8, SKAlphaType.Premul);
                    Surface = SKSurface.Create(info, pin.AddrOfPinnedObject(), requestedWidth) ?? throw new InvalidOperationException("Could not wrap caption alpha mask.");
                    Canvas = Surface.Canvas;
                    if (!Bitmap.InstallPixels(info, pin.AddrOfPinnedObject(), requestedWidth)) throw new InvalidOperationException("Could not wrap caption alpha image.");
                    using var pixmap = Bitmap.PeekPixels();
                    Image = SKImage.FromPixels(pixmap) ?? throw new InvalidOperationException("Could not wrap caption alpha pixels.");
                    if (colorize)
                    {
                        var colorLength = checked(length * 4);
                        grows = coloredPixels.Length < colorLength;
                        Grow(ref coloredPixels, ref colorPin, colorLength);
                        if (grows) testCheckpoint?.Invoke(RenderCheckpoint.ShadowPrepareGrowth);
                        var colorInfo = new SKImageInfo(requestedWidth, requestedHeight, SKColorType.Bgra8888, SKAlphaType.Premul);
                        if (!coloredBitmap.InstallPixels(colorInfo, colorPin.AddrOfPinnedObject(), requestedWidth * 4)) throw new InvalidOperationException("Could not wrap caption shadow pixels.");
                        using var coloredPixmap = coloredBitmap.PeekPixels();
                        ColoredImage = SKImage.FromPixels(coloredPixmap) ?? throw new InvalidOperationException("Could not wrap caption shadow image.");
                    }
                    Width = requestedWidth;
                    Height = requestedHeight;
                }
                catch { InvalidateViews(); throw; }
            }
            var mask = Pixels;
            mask.Clear();
            Canvas.RestoreToCount(1);
            Canvas.ResetMatrix();
            return mask;
        }

        private static void Grow(ref byte[] storage, ref GCHandle handle, int length)
        {
            if (storage.Length >= length) return;
            var replacement = new byte[length];
            var replacementPin = GCHandle.Alloc(replacement, GCHandleType.Pinned);
            if (handle.IsAllocated) handle.Free();
            storage = replacement;
            handle = replacementPin;
        }

        private void InvalidateViews()
        {
            Width = Height = 0;
            Surface?.Dispose(); Surface = null!; Canvas = null!;
            Image?.Dispose(); Image = null!;
            ColoredImage?.Dispose(); ColoredImage = null!;
            Bitmap.Reset();
            coloredBitmap.Reset();
        }

        ~ShadowBuffer()
        {
            Surface?.Dispose();
            Image?.Dispose();
            ColoredImage?.Dispose();
            Bitmap.Dispose();
            coloredBitmap.Dispose();
            if (pin.IsAllocated) pin.Free();
            if (colorPin.IsAllocated) colorPin.Free();
            completed.Dispose();
        }

        private void PrepareTint(SKColor color)
        {
            using var mask = new SKBitmap(new SKImageInfo(256, 1, SKColorType.Alpha8, SKAlphaType.Premul));
            var ramp = new byte[256];
            for (var index = 0; index < ramp.Length; index++) ramp[index] = (byte)index;
            Marshal.Copy(ramp, 0, mask.GetPixels(), ramp.Length);
            using var colored = new SKBitmap(new SKImageInfo(256, 1, SKColorType.Bgra8888, SKAlphaType.Premul));
            colored.Erase(SKColors.Transparent);
            using var canvas = new SKCanvas(colored);
            using var paint = new SKPaint { Color = color, IsAntialias = true };
            canvas.DrawBitmap(mask, 0, 0, paint);
            canvas.Flush();
            Marshal.Copy(colored.GetPixels(), tint, 0, tint.Length);
            tintColor = color;
        }
    }

    private sealed class TrackGeometry(CaptionTrack track, CaptionResources data)
    {
        private readonly Dictionary<(int Page, int Word, int Clusters), SKPath> paths = new();
        private readonly LinkedList<int> recentPages = new();
        private readonly Dictionary<int, CaptionWordFrame[]> frames = new();
        internal int Id { get; } = Interlocked.Increment(ref nextGeometryId);
        internal CaptionResources Data { get; } = data;
        internal CaptionFrame? Frame { get; set; }
        internal long RetainedBytes => frames.Sum(entry => (long)entry.Value.Length * 128) + paths.Sum(entry => 64L + entry.Value.PointCount * 8L);
        internal CaptionWordFrame[] Frames(CaptionPage page)
        {
            if (!frames.TryGetValue(page.Words.Count, out var result)) frames.Add(page.Words.Count, result = new CaptionWordFrame[page.Words.Count]);
            return result;
        }
        internal SKPath Path(CaptionPage page, CaptionWordFrame frame)
        {
            var key = (page.Index, frame.Word, frame.VisibleClusters ?? int.MaxValue);
            Touch(page.Index);
            if (paths.TryGetValue(key, out var existing)) return existing;
            var path = Build(page, frame);
            paths.Add(key, path);
            return path;
        }

        private void Touch(int page)
        {
            var existing = recentPages.Find(page);
            if (existing is not null) recentPages.Remove(existing);
            recentPages.AddFirst(page);
            if (recentPages.Count <= 2) return;
            var evicted = recentPages.Last!.Value;
            recentPages.RemoveLast();
            foreach (var key in paths.Keys.Where(key => key.Page == evicted).ToArray())
            {
                paths.Remove(key, out var path);
                path!.Dispose();
            }
        }

        private SKPath Build(CaptionPage page, CaptionWordFrame frame)
        {
            var path = new SKPath { FillType = SKPathFillType.Winding };
            var style = track.Style;
            var word = track.Words[frame.Word];
            var emphasised = page.Emphasised.Any(choice => choice.Word == frame.Word);
            var runs = emphasised ? word.EmphasisRuns ?? word.Runs : word.Runs;
            var scale = emphasised ? style.Emphasis?.Scale ?? 1 : 1;
            var rect = page.WordRects.First(rect => rect.Word == frame.Word);
            var primary = Data.Font(style.Font.File);
            var spacing = CaptionMath.RoundHalfUp(style.Font.LetterSpacingEm * primary.UnitsPerEm) * page.FontPx / primary.UnitsPerEm;
            var total = runs.Sum(run => run.Glyphs.Count);
            var glyphIndex = 0;
            var pen = 0.0;
            foreach (var run in runs)
            {
                var factor = page.FontPx / run.UnitsPerEm;
                for (var index = 0; index < run.Glyphs.Count; index++, glyphIndex++)
                {
                    if (frame.VisibleClusters is null || run.Clusters[index] < frame.VisibleClusters)
                    {
                        var outline = Outlines.GetOrAdd((Data.Root, run.File, run.Glyphs[index]), static (key, captionData) => new(() =>
                        {
                            var resources = Fonts.GetOrAdd((key.Root, key.File), static (fontKey, source) => new(() =>
                            {
                                var typeface = SKTypeface.FromFile(CaptionFontFiles.Path(source, fontKey.File)) ?? throw new InvalidDataException("Invalid bundled caption font.");
                                var font = new SKFont(typeface, source.Font(fontKey.File).UnitsPerEm)
                                { Hinting = SKFontHinting.None, Subpixel = true, LinearMetrics = true, Embolden = false, ForceAutoHinting = false };
                                return new FontResources(typeface, font);
                            }, LazyThreadSafetyMode.PublicationOnly), captionData).Value;
                            return resources.Font.GetGlyphPath(checked((ushort)key.Glyph)) ?? new SKPath();
                        }, LazyThreadSafetyMode.PublicationOnly), Data).Value;
                        var offset = run.Offsets[index];
                        var matrix = new SKMatrix((float)(scale * factor), 0, (float)(rect.X + scale * (pen + offset.X * factor)),
                            0, (float)(scale * factor), (float)(rect.Baseline - scale * offset.Y * factor), 0, 0, 1);
                        path.AddPath(outline, matrix);
                    }
                    pen += run.Advances[index] * factor;
                    if (glyphIndex < total - 1) pen += spacing;
                }
            }
            return path;
        }
    }

    /// <inheritdoc />
    public void Draw(CaptionRenderRequest request, PixelBuffer target, CancellationToken ct)
        => DrawCore(request, target, ct, retainTarget: true);

    private void DrawCore(CaptionRenderRequest request, PixelBuffer target, CancellationToken ct, bool retainTarget)
    {
        lock (sync)
        {
            ct.ThrowIfCancellationRequested();
            if (!geometries.TryGetValue(request.Track, out var geometry))
                geometries.Add(request.Track, geometry = new(request.Track, data));
            using var transient = retainTarget ? null : new WrappedTarget(target);
            DrawLocked(request, target, geometry, ct, transient);
        }
    }

    internal bool IsAnimating(CaptionRenderRequest request)
    {
        lock (sync)
        {
            if (!geometries.TryGetValue(request.Track, out var geometry))
                geometries.Add(request.Track, geometry = new(request.Track, data));
            return StableKey(request, geometry, 0, 0) is null;
        }
    }

    private void DrawLocked(CaptionRenderRequest request, PixelBuffer target, TrackGeometry geometry, CancellationToken ct, WrappedTarget? wrappedTarget = null)
    {
        ct.ThrowIfCancellationRequested();
        if (!double.IsFinite(request.Scale) || request.Scale <= 0 || target.Width <= 0 || target.Height <= 0 || target.Stride < checked(target.Width * 4)
            || target.Pixels.Length < checked((target.Height - 1) * target.Stride + target.Width * 4)) throw new ArgumentException("Invalid caption pixel buffer or preview scale.");
        if (cachedGeometryId != geometry.Id)
        {
            ClearPageCache();
            cachedGeometryId = geometry.Id;
        }
        for (var index = 0; wrappedTarget is null && index < targets.Length; index++)
            if (targets[index] is { } candidate && candidate.Target == target) { wrappedTarget = candidate; break; }
        if (wrappedTarget is null)
        {
            var replacement = new WrappedTarget(target);
            targets[nextTarget]?.Dispose();
            targets[nextTarget] = wrappedTarget = replacement;
            nextTarget = (nextTarget + 1) % targets.Length;
        }
        var canvas = wrappedTarget.Canvas;
        canvas.RestoreToCount(1);
        canvas.ResetMatrix();
        LastOverlayClearPixels = LastOverlayCopyPixels = 0;
        var key = StableKey(request, geometry, target.Width, target.Height);
        if (CacheEnabled && key is { } stable && cache.TryGetValue(stable, out var cached))
        {
            recency.Remove(cached);
            recency.AddFirst(cached);
            canvas.DrawImage(cached.Value.Image, cached.Value.Left, cached.Value.Top);
            canvas.Flush();
            return;
        }
        var visiblePage = CaptionEvaluator.PageAt(request.Track, request.Time);
        var frame = CaptionEvaluator.Evaluate(request.Track, request.Time, request.ReduceMotion, visiblePage is null ? null : geometry.Frames(visiblePage), geometry.Frame);
        if (frame is null || frame.PageAlpha <= 0 || frame.PageScale <= 0) return;
        geometry.Frame = frame;
        if (key is { } cacheKey)
        {
            var bounds = OverlayBounds(canvas, request, frame, geometry);
            var left = Math.Clamp((int)Math.Floor(bounds.Left), 0, target.Width - 1);
            var top = Math.Clamp((int)Math.Floor(bounds.Top), 0, target.Height - 1);
            var right = Math.Clamp((int)Math.Ceiling(bounds.Right), left + 1, target.Width);
            var bottom = Math.Clamp((int)Math.Ceiling(bounds.Bottom), top + 1, target.Height);
            if (overlayBitmap is null || overlayBitmap.Width != target.Width || overlayBitmap.Height != target.Height)
            {
                overlayCanvas?.Dispose();
                overlayBitmap?.Dispose();
                overlayBitmap = new(new SKImageInfo(target.Width, target.Height, SKColorType.Bgra8888, SKAlphaType.Premul));
                overlayCanvas = new(overlayBitmap);
            }
            var band = new SKRectI(left, top, right, bottom);
            overlayBitmap.Erase(SKColors.Transparent, band);
            LastOverlayClearPixels = band.Width * band.Height;
            var saved = overlayCanvas!.Save();
            try
            {
                overlayCanvas.ClipRect(band, SKClipOperation.Intersect, false);
                DrawPage(overlayCanvas, request, frame, geometry, ct);
            }
            finally { overlayCanvas.RestoreToCount(saved); }
            using var subset = new SKBitmap();
            if (!overlayBitmap.ExtractSubset(subset, band)) throw new InvalidOperationException("Could not crop the caption overlay.");
            if (!CacheEnabled)
            {
                canvas.DrawBitmap(subset, left, top);
                canvas.Flush();
                return;
            }
            var bitmap = subset.Copy();
            LastOverlayCopyPixels = band.Width * band.Height;
            try
            {
                canvas.DrawBitmap(bitmap, left, top);
                if (CacheEnabled && bitmap.ByteCount <= CacheLimit)
                {
                    while (cachedBytes + bitmap.ByteCount > CacheLimit && recency.Last is { } oldest)
                    {
                        cache.Remove(oldest.Value.Key);
                        recency.RemoveLast();
                        cachedBytes -= oldest.Value.Bytes;
                        oldest.Value.Image.Dispose();
                        oldest.Value.Bitmap.Dispose();
                    }
                    bitmap.SetImmutable();
                    var entry = new CachedPage(cacheKey, bitmap, SKImage.FromBitmap(bitmap), left, top, bitmap.ByteCount);
                    cache.Add(cacheKey, recency.AddFirst(entry));
                    cachedBytes += entry.Bytes;
                    bitmap = null!;
                }
            }
            finally { bitmap?.Dispose(); }
            canvas.Flush();
            return;
        }
        DrawPage(canvas, request, frame, geometry, ct);
    }

    private static CacheKey? StableKey(CaptionRenderRequest request, TrackGeometry geometry, int width, int height)
    {
        if (!double.IsFinite(request.Time)) return null;
        var track = request.Track;
        var page = CaptionEvaluator.PageAt(track, request.Time);
        if (page is null) return null;
        var style = track.Style;
        if (style.Reveal?.Cursor is not null || !request.ReduceMotion && style.Effects?.Jitter is not null) return null;
        bool Running(CaptionAnimationSpec? animation, double start) => !request.ReduceMotion && animation is { Type: not CaptionAnimationSpecTypeValue.None, DurationSec: > 0 } && request.Time < start + animation.DurationSec;
        if (Running(style.Animation?.PageIn, page.Start) || !request.ReduceMotion && style.Animation?.PageOut is { Type: not CaptionAnimationSpecTypeValue.None, DurationSec: > 0 } exit && request.Time >= page.End - exit.DurationSec) return null;
        var activeLocal = 0;
        for (var local = 0; local < page.Words.Count; local++)
            if (track.Words[page.Words[local]].Start <= request.Time) activeLocal = local;
        for (var local = 0; local <= activeLocal; local++)
            if (Running(style.Animation?.WordIn, track.Words[page.Words[local]].Start)) return null;
        var active = track.Words[page.Words[activeLocal]];
        if (Running(style.Animation?.ActiveIn, active.Start)) return null;
        if (style.Reveal?.Unit == CaptionRevealUnitValue.Wipe && request.Time < active.Start + Math.Max(0.001, active.End - active.Start)) return null;
        var clusters = active.Clusters;
        if (style.Reveal is { Unit: CaptionRevealUnitValue.Char } reveal)
        {
            clusters = 0;
            var duration = Math.Min(active.End - active.Start, active.Clusters / reveal.MaxCharsPerSec);
            for (var cluster = 0; cluster < active.Clusters; cluster++)
                if (request.Time >= active.Start + cluster / (double)active.Clusters * duration) clusters = cluster + 1;
        }
        return new(geometry.Id, page.Index, page.Words[activeLocal], clusters, width, height, request.Scale, request.ReduceMotion);
    }

    internal void ClearPageCache()
    {
        foreach (var entry in recency) { entry.Image.Dispose(); entry.Bitmap.Dispose(); }
        recency.Clear();
        cache.Clear();
        cachedBytes = 0;
    }

    private void DrawPage(SKCanvas canvas, CaptionRenderRequest request, CaptionFrame frame, TrackGeometry geometry, CancellationToken ct)
    {
        var layer = canvas.Save();
        try
        {
            if (frame.PageAlpha < 1)
            {
                layerPaint.Color = SKColors.White.WithAlpha(Alpha(frame.PageAlpha));
                var bounds = OverlayBounds(canvas, request, frame, geometry);
                if (!canvas.TotalMatrix.TryInvert(out var inverse)) throw new InvalidOperationException("Invalid caption canvas transform.");
                canvas.SaveLayer(inverse.MapRect(bounds), layerPaint);
            }
            canvas.Scale((float)request.Scale);
            PageTransform(canvas, frame);
            Boxes(canvas, request.Track.Style, frame);
            DrawShadows(canvas, request, frame, geometry, ct);
            if (request.Track.Style.Effects?.RgbSplit is { } split)
            {
                foreach (var word in frame.Words)
                {
                    if (!word.Visible) continue;
                    for (var offset = -1; offset <= 1; offset += 2)
                    {
                        var saved = canvas.Save();
                        canvas.Translate((float)(offset * split.OffsetEm * frame.Page.FontPx), 0);
                        WordTransform(canvas, frame.Page, word);
                        var paint = Solid(offset < 0 ? split.LeftColor : split.RightColor, request.Track.Style, word.Opacity);
                        canvas.DrawPath(geometry.Path(frame.Page, word), paint);
                        canvas.RestoreToCount(saved);
                    }
                }
            }
            foreach (var word in frame.Words) if (word.Visible && word.Word != frame.ActiveWord) DrawWord(canvas, request.Track.Style, frame.Page, word, geometry, true);
            foreach (var word in frame.Words) if (word.Visible && word.Word != frame.ActiveWord) DrawWord(canvas, request.Track.Style, frame.Page, word, geometry, false);
            var active = Active(frame);
            if (active.Visible)
            {
                DrawWord(canvas, request.Track.Style, frame.Page, active, geometry, true);
                DrawWord(canvas, request.Track.Style, frame.Page, active, geometry, false);
            }
            if (frame.Cursor is { Visible: true } cursor && request.Track.Style.Reveal?.Cursor is { } cursorStyle)
            {
                var paint = Solid(cursorStyle.Color, request.Track.Style, 1);
                canvas.DrawRect(new SKRect((float)cursor.X, (float)cursor.Y, (float)(cursor.X + cursor.W), (float)(cursor.Y + cursor.H)), paint);
            }
            if (frame.Page.Emoji is { } emoji) Emoji(canvas, emoji, frame, request.Scale, geometry.Data, ct);
        }
        finally { canvas.RestoreToCount(layer); }
        canvas.Flush();
    }

    private SKRect OverlayBounds(SKCanvas canvas, CaptionRenderRequest request, CaptionFrame frame, TrackGeometry geometry)
    {
        var saved = canvas.Save();
        try
        {
            canvas.Scale((float)request.Scale);
            PageTransform(canvas, frame);
            TestCheckpoint?.Invoke(RenderCheckpoint.OverlayBounds);
            var pageMatrix = canvas.TotalMatrix;
            var visual = frame.Page.Visual;
            var bounds = pageMatrix.MapRect(new SKRect((float)visual.X, (float)visual.Y, (float)(visual.X + visual.Width), (float)(visual.Y + visual.Height)));
            foreach (var word in frame.Words)
            {
                if (!word.Visible || word.Opacity <= 0) continue;
                var wordSave = canvas.Save();
                WordTransform(canvas, frame.Page, word);
                var ink = canvas.TotalMatrix.MapRect(geometry.Path(frame.Page, word).Bounds);
                var stroke = word.Appearance?.HideStroke == true ? 0 : request.Track.Style.Stroke?.WidthEm ?? 0;
                ink.Inflate((float)(stroke * frame.Page.FontPx * frame.PageScale * request.Scale * Math.Abs(word.Scale) / 2), (float)(stroke * frame.Page.FontPx * frame.PageScale * request.Scale * Math.Abs(word.Scale) / 2));
                bounds = SKRect.Union(bounds, ink);
                for (var shadowIndex = 0; shadowIndex < request.Track.Style.Shadows.Count; shadowIndex++)
                {
                    var shadow = request.Track.Style.Shadows[shadowIndex];
                    var shadowBounds = ink;
                    var offset = pageMatrix.MapVector((float)(shadow.DxEm * frame.Page.FontPx), (float)(shadow.DyEm * frame.Page.FontPx));
                    shadowBounds.Offset(offset);
                    var padding = (float)(Math.Ceiling(3 * shadow.SigmaEm * frame.Page.FontPx * frame.PageScale * request.Scale) + 3);
                    shadowBounds.Inflate(padding, padding);
                    bounds = SKRect.Union(bounds, shadowBounds);
                }
                for (var boxIndex = 0; boxIndex < frame.Page.Boxes.Count; boxIndex++)
                {
                    var box = frame.Page.Boxes[boxIndex];
                    if (box.Word == word.Word) bounds = SKRect.Union(bounds, canvas.TotalMatrix.MapRect(new SKRect((float)box.X, (float)box.Y, (float)(box.X + box.W), (float)(box.Y + box.H))));
                }
                if (word.Appearance?.Box is { } activeBox)
                {
                    var rect = Rectangle(frame.Page, word.Word);
                    var paddingX = activeBox.PaddingXEm * frame.Page.FontPx;
                    var paddingY = activeBox.PaddingYEm * frame.Page.FontPx;
                    bounds = SKRect.Union(bounds, canvas.TotalMatrix.MapRect(new SKRect((float)(rect.X - paddingX), (float)(rect.Y - paddingY), (float)(rect.X + rect.W + paddingX), (float)(rect.Y + rect.H + paddingY))));
                }
                canvas.RestoreToCount(wordSave);
            }
            if (frame.Page.Emoji is { } emoji) bounds = SKRect.Union(bounds, pageMatrix.MapRect(new SKRect((float)emoji.X, (float)emoji.Y, (float)(emoji.X + emoji.Size), (float)(emoji.Y + emoji.Size))));
            if (frame.Cursor is { Visible: true } cursor) bounds = SKRect.Union(bounds, pageMatrix.MapRect(new SKRect((float)cursor.X, (float)cursor.Y, (float)(cursor.X + cursor.W), (float)(cursor.Y + cursor.H))));
            var split = (float)((request.Track.Style.Effects?.RgbSplit?.OffsetEm ?? 0) * frame.Page.FontPx * frame.PageScale * request.Scale);
            bounds.Inflate(8 + split, 8);
            return bounds;
        }
        finally { canvas.RestoreToCount(saved); }
    }

    /// <inheritdoc />
    public Task<PixelBuffer> RenderAsync(CaptionRenderRequest request, CancellationToken ct)
    {
        ct.ThrowIfCancellationRequested();
        if (!double.IsFinite(request.Scale) || request.Scale <= 0) throw new ArgumentOutOfRangeException(nameof(request));
        var width = Math.Max(1, checked((int)CaptionMath.RoundHalfUp(request.Track.Frame.Width * request.Scale)));
        var height = Math.Max(1, checked((int)CaptionMath.RoundHalfUp(request.Track.Frame.Height * request.Scale)));
        var buffer = new PixelBuffer(new byte[checked(width * height * 4)], width, height, checked(width * 4));
        DrawCore(request, buffer, ct, retainTarget: false);
        return Task.FromResult(buffer);
    }

    private static byte Alpha(double value) => (byte)Math.Clamp(CaptionMath.RoundHalfUp(value * 255), 0, 255);
    private static SKColor Color(string value, CaptionStyle style)
    {
        var color = CaptionMath.ParseColor(value, style);
        return new(color.R, color.G, color.B, color.A);
    }
    private SKPaint Solid(string value, CaptionStyle style, double opacity)
    {
        ConfigureSolid(solidPaint, value, style, opacity);
        return solidPaint;
    }

    private static void ConfigureSolid(SKPaint paint, string value, CaptionStyle style, double opacity)
    {
        var color = Color(value, style);
        paint.IsAntialias = true;
        paint.Style = SKPaintStyle.Fill;
        paint.Shader = null;
        paint.Color = color.WithAlpha(Alpha(color.Alpha / 255.0 * opacity));
    }

    private static CaptionWordFrame Active(CaptionFrame frame)
    {
        foreach (var word in frame.Words) if (word.Word == frame.ActiveWord) return word;
        throw new InvalidOperationException("Caption active word is missing.");
    }

    private static CaptionWordRect Rectangle(CaptionPage page, int word)
    {
        for (var index = 0; index < page.WordRects.Count; index++) if (page.WordRects[index].Word == word) return page.WordRects[index];
        throw new InvalidOperationException("Caption word rectangle is missing.");
    }

    private static CaptionBoxLayout BoxRectangle(CaptionPage page, int word)
    {
        for (var index = 0; index < page.Boxes.Count; index++) if (page.Boxes[index].Word == word) return page.Boxes[index];
        throw new InvalidOperationException("Caption word box is missing.");
    }

    private static void PageTransform(SKCanvas canvas, CaptionFrame frame)
    {
        var centerX = frame.Page.Block.X + frame.Page.Block.Width / 2;
        var centerY = frame.Page.Block.Y + frame.Page.Block.Height / 2;
        canvas.Translate((float)(frame.Jitter.X + centerX), (float)(frame.Jitter.Y + frame.PageDy + centerY));
        canvas.Scale((float)frame.PageScale);
        canvas.Translate((float)-centerX, (float)-centerY);
    }

    private static void WordTransform(SKCanvas canvas, CaptionPage page, CaptionWordFrame word)
    {
        var rect = Rectangle(page, word.Word);
        canvas.Translate((float)rect.Cx, (float)(word.Dy + rect.Cy));
        canvas.Scale((float)word.Scale);
        canvas.Translate((float)-rect.Cx, (float)-rect.Cy);
    }

    private void Boxes(SKCanvas canvas, CaptionStyle style, CaptionFrame frame)
    {
        if (style.Box is { } box)
        {
            var path = boxPath;
            path.Reset();
            path.FillType = SKPathFillType.Winding;
            if (box.Scope is CaptionBoxScopeValue.Line or CaptionBoxScopeValue.Page)
            {
                for (var index = 0; index < frame.Page.Boxes.Count; index++)
                {
                    var rect = frame.Page.Boxes[index];
                    CaptionGeometry.Rounded(path, rect.X, rect.Y, rect.W, rect.H, rect.R);
                }
                var paint = Solid(box.Color, style, 1);
                canvas.DrawPath(path, paint);
                for (var index = 0; index < frame.Page.Boxes.Count; index++) Border(canvas, frame.Page.Boxes[index], box.BorderWidthEm * frame.Page.FontPx, box.BorderColor, style, 1);
            }
            else
            {
                Span<bool> grouped = stackalloc bool[frame.Words.Length];
                grouped.Clear();
                for (var groupIndex = 0; groupIndex < frame.Words.Length; groupIndex++)
                {
                    var first = frame.Words[groupIndex];
                    if (!first.Visible || grouped[groupIndex]) continue;
                    path.Reset();
                    path.FillType = SKPathFillType.Winding;
                    for (var wordIndex = groupIndex; wordIndex < frame.Words.Length; wordIndex++)
                    {
                        var word = frame.Words[wordIndex];
                        if (!word.Visible || word.Opacity != first.Opacity) continue;
                        grouped[wordIndex] = true;
                        var rect = BoxRectangle(frame.Page, word.Word);
                        var local = localBoxPath;
                        local.Reset();
                        CaptionGeometry.Rounded(local, rect.X, rect.Y, rect.W, rect.H, rect.R);
                        var saved = canvas.Save();
                        WordTransform(canvas, frame.Page, word);
                        var pageMatrix = canvas.TotalMatrix;
                        canvas.RestoreToCount(saved);
                        var outer = canvas.TotalMatrix;
                        if (!outer.TryInvert(out var inverse)) continue;
                        local.Transform(SKMatrix.Concat(inverse, pageMatrix));
                        path.AddPath(local);
                    }
                    var paint = Solid(box.Color, style, first.Opacity);
                    canvas.DrawPath(path, paint);
                }
                foreach (var word in frame.Words)
                {
                    if (!word.Visible) continue;
                    var saved = canvas.Save(); WordTransform(canvas, frame.Page, word);
                    Border(canvas, BoxRectangle(frame.Page, word.Word), box.BorderWidthEm * frame.Page.FontPx, box.BorderColor, style, word.Opacity);
                    canvas.RestoreToCount(saved);
                }
            }
        }
        var active = Active(frame);
        if (active.Visible && active.Appearance?.Box is { } activeBox)
        {
            var size = frame.Page.FontPx;
            var rect = Rectangle(frame.Page, active.Word);
            var width = rect.W + 2 * activeBox.PaddingXEm * size;
            var height = rect.H + 2 * activeBox.PaddingYEm * size;
            var left = rect.X - activeBox.PaddingXEm * size;
            var top = rect.Y - activeBox.PaddingYEm * size;
            var radius = CaptionMath.BoxRadius(activeBox.Pill, activeBox.RadiusEm, width, height, size);
            var saved = canvas.Save(); WordTransform(canvas, frame.Page, active);
            var path = boxPath; path.Reset(); CaptionGeometry.Rounded(path, left, top, width, height, radius);
            var paint = Solid(activeBox.Color, style, active.Opacity);
            canvas.DrawPath(path, paint);
            Border(canvas, left, top, width, height, radius, activeBox.BorderWidthEm * size, activeBox.BorderColor, style, active.Opacity);
            canvas.RestoreToCount(saved);
        }
    }

    private void Border(SKCanvas canvas, CaptionBoxLayout rect, double width, string? color, CaptionStyle style, double opacity)
        => Border(canvas, rect.X, rect.Y, rect.W, rect.H, rect.R, width, color, style, opacity);

    private void Border(SKCanvas canvas, double left, double top, double boxWidth, double height, double radius, double width, string? color, CaptionStyle style, double opacity)
    {
        if (width <= 0 || color is null || boxWidth <= width || height <= width) return;
        var path = borderPath;
        path.Reset();
        CaptionGeometry.Rounded(path, left + width / 2, top + width / 2, boxWidth - width, height - width, Math.Max(0, radius - width / 2));
        var paint = Solid(color, style, opacity);
        paint.Style = SKPaintStyle.Stroke; paint.StrokeWidth = (float)width;
        canvas.DrawPath(path, paint);
    }

    private SKPaint? Stroke(CaptionStyle style, CaptionPage page, CaptionWordFrame word, bool mask = false)
    {
        if (style.Stroke is not { WidthEm: > 0 } stroke || word.Appearance?.HideStroke == true) return null;
        var paint = strokePaint;
        ConfigureSolid(paint, mask ? "#FFFFFF" : word.Appearance?.StrokeColor ?? stroke.Color, style, word.Opacity);
        paint.Style = SKPaintStyle.Stroke; paint.StrokeWidth = (float)(stroke.WidthEm * page.FontPx);
        paint.StrokeJoin = SKStrokeJoin.Round; paint.StrokeCap = SKStrokeCap.Round;
        return paint;
    }

    private SKPaint Fill(CaptionStyle style, CaptionPage page, CaptionWordFrame word, CaptionPaint fill)
    {
        if (fill is SolidPaint solid) return Solid(solid.Color, style, word.Opacity);
        var linear = (LinearPaint)fill;
        var rect = Rectangle(page, word.Word);
        var line = page.Lines[rect.Line];
        var gradient = linear.Space switch
        {
            GradientSpace.Word => CaptionGeometry.Gradient(rect.X, rect.Y, rect.W, rect.H, linear.AngleDeg),
            GradientSpace.Page => CaptionGeometry.Gradient(page.Block.X, page.Block.Y, page.Block.Width, page.Block.Height, linear.AngleDeg),
            _ => CaptionGeometry.Gradient(line.X, line.Top, line.Width, rect.H, linear.AngleDeg)
        };
        var key = new GradientKey(gradient.Start, gradient.End, linear.Stops, style.Accent);
        if (!gradients.TryGetValue(key, out var cached))
        {
            var colors = new SKColor[linear.Stops.Count];
            var positions = new float[linear.Stops.Count];
            for (var index = 0; index < linear.Stops.Count; index++) { colors[index] = Color(linear.Stops[index].Color, style); positions[index] = (float)linear.Stops[index].Offset; }
            var shader = SKShader.CreateLinearGradient(gradient.Start, gradient.End, colors, positions, SKShaderTileMode.Clamp);
            if (gradients.Count == GradientLimit && gradientRecency.Last is { } oldest)
            {
                gradients.Remove(oldest.Value.Key);
                gradientRecency.RemoveLast();
                oldest.Value.Shader.Dispose();
            }
            cached = gradientRecency.AddFirst(new CachedGradient(key, shader));
            gradients.Add(key, cached);
        }
        else { gradientRecency.Remove(cached); gradientRecency.AddFirst(cached); }
        gradientPaint.IsAntialias = true;
        gradientPaint.Color = SKColors.White.WithAlpha(Alpha(word.Opacity));
        gradientPaint.Shader = cached.Value.Shader;
        return gradientPaint;
    }

    private void DrawWord(SKCanvas canvas, CaptionStyle style, CaptionPage page, CaptionWordFrame word, TrackGeometry geometry, bool stroke)
    {
        var saved = canvas.Save();
        WordTransform(canvas, page, word);
        var path = geometry.Path(page, word);
        if (stroke)
        {
            var paint = Stroke(style, page, word);
            if (paint is not null) canvas.DrawPath(path, paint);
        }
        else if (word.Wipe is { } progress && word.WipeFrom is { } future)
        {
            var futurePaint = Fill(style, page, word, future);
            canvas.DrawPath(path, futurePaint);
            if (progress < 1)
            {
                var rect = Rectangle(page, word.Word);
                canvas.ClipRect(new((float)(rect.X - page.FontPx), (float)(rect.Y - page.FontPx), (float)(rect.X + progress * rect.W), (float)(rect.Y + rect.H + page.FontPx)), SKClipOperation.Intersect, true);
            }
            var activePaint = Fill(style, page, word, word.Fill);
            canvas.DrawPath(path, activePaint);
        }
        else
        {
            var paint = Fill(style, page, word, word.Fill);
            canvas.DrawPath(path, paint);
        }
        canvas.RestoreToCount(saved);
    }

    private void DrawShadows(SKCanvas canvas, CaptionRenderRequest request, CaptionFrame frame, TrackGeometry geometry, CancellationToken ct)
    {
        var definitions = request.Track.Style.Shadows;
        LastShadowMaskCount = 0;
        if (definitions.Count == 0) return;
        Span<int> groups = stackalloc int[definitions.Count];
        for (var index = 0; index < definitions.Count; index++)
        {
            ct.ThrowIfCancellationRequested();
            if (shadows.Count <= index) { shadows.Add(new()); masks.Add(new()); }
            var definition = definitions[index];
            groups[index] = index;
            for (var previous = 0; ShareShadowMasks && previous < index; previous++)
                if (definition.DxEm == definitions[previous].DxEm && definition.DyEm == definitions[previous].DyEm) { groups[index] = groups[previous]; break; }
            if (groups[index] == index)
            {
                var largest = definition.SigmaEm;
                for (var next = index + 1; ShareShadowMasks && next < definitions.Count; next++)
                    if (definition.DxEm == definitions[next].DxEm && definition.DyEm == definitions[next].DyEm) largest = Math.Max(largest, definitions[next].SigmaEm);
                RasterizeMask(canvas, request, frame, geometry, definition, largest, masks[index]);
                LastShadowMaskCount++;
            }
            var source = masks[groups[index]];
            var buffer = shadows[index];
            buffer.Ink = source.Ink;
            if (source.Ink.IsEmpty) continue;
            buffer.Sigma = definition.SigmaEm * frame.Page.FontPx * frame.PageScale * request.Scale;
            var padding = checked((int)Math.Ceiling(3 * buffer.Sigma) + 3);
            buffer.Left = checked((int)Math.Floor(source.Ink.Left) - padding);
            buffer.Top = checked((int)Math.Floor(source.Ink.Top) - padding);
            var width = checked((int)Math.Ceiling(source.Ink.Right) + padding - buffer.Left);
            var height = checked((int)Math.Ceiling(source.Ink.Bottom) + padding - buffer.Top);
            var pixels = buffer.Prepare(width, height, PrecolorShadows, TestCheckpoint);
            var offsetX = buffer.Left - source.Left;
            var offsetY = buffer.Top - source.Top;
            for (var row = 0; row < height; row++) source.Pixels.Slice((row + offsetY) * source.Stride + offsetX, width).CopyTo(pixels.Slice(row * buffer.Stride, width));
        }
        var started = 0;
        ExceptionDispatchInfo? failure = null;
        try
        {
            for (var index = 0; index < definitions.Count; index++)
            {
                if (!shadows[index].Ink.IsEmpty) shadows[index].Start(ct, queued: QueueShadowBlurs && index < definitions.Count - 1, Color(definitions[index].Color, request.Track.Style), PrecolorShadows, TestCheckpoint);
                started = index + 1;
                if (index == 0) TestCheckpoint?.Invoke(RenderCheckpoint.ShadowStart);
            }
        }
        finally
        {
            for (var index = started - 1; index >= 0; index--) if (!shadows[index].Ink.IsEmpty) shadows[index].Execute();
            for (var index = started - 1; index >= 0; index--)
                if (!shadows[index].Ink.IsEmpty) { var error = shadows[index].Join(); failure ??= error; }
        }
        failure?.Throw();
        var saved = canvas.Save();
        try
        {
            canvas.ResetMatrix();
            for (var index = 0; index < definitions.Count; index++)
            {
                var buffer = shadows[index];
                if (buffer.Ink.IsEmpty || !buffer.HasInk) continue;
                buffer.Bitmap.NotifyPixelsChanged();
                var clipped = canvas.Save();
                var content = buffer.Content;
                content.Offset(buffer.Left, buffer.Top);
                canvas.ClipRect(content, SKClipOperation.Intersect, false);
                if (PrecolorShadows) canvas.DrawImage(buffer.ColoredImage, buffer.Left, buffer.Top);
                else canvas.DrawImage(buffer.Image, buffer.Left, buffer.Top, Solid(definitions[index].Color, request.Track.Style, 1));
                canvas.RestoreToCount(clipped);
            }
        }
        finally { canvas.RestoreToCount(saved); }
    }

    private void RasterizeMask(SKCanvas canvas, CaptionRenderRequest request, CaptionFrame frame, TrackGeometry geometry, CaptionShadow shadow, double largestSigma, ShadowBuffer buffer)
    {
        var sigma = largestSigma * frame.Page.FontPx * frame.PageScale * request.Scale;
        var bounds = SKRect.Empty;
        var any = false;
        foreach (var word in frame.Words)
        {
            if (!word.Visible || word.Opacity <= 0) continue;
            var saved = canvas.Save();
            canvas.Translate((float)(shadow.DxEm * frame.Page.FontPx), (float)(shadow.DyEm * frame.Page.FontPx));
            WordTransform(canvas, frame.Page, word);
            var pathBounds = canvas.TotalMatrix.MapRect(geometry.Path(frame.Page, word).Bounds);
            if (!pathBounds.IsEmpty)
            {
                var stroke = word.Appearance?.HideStroke == true ? 0 : request.Track.Style.Stroke?.WidthEm ?? 0;
                var inflation = stroke * frame.Page.FontPx * frame.PageScale * request.Scale * Math.Abs(word.Scale) / 2;
                pathBounds.Inflate((float)inflation, (float)inflation);
                bounds = any ? SKRect.Union(bounds, pathBounds) : pathBounds;
                any = true;
            }
            canvas.RestoreToCount(saved);
        }
        buffer.Ink = bounds;
        if (!any) return;
        var padding = checked((int)Math.Ceiling(3 * sigma) + 3);
        var left = checked((int)Math.Floor(bounds.Left) - padding);
        var top = checked((int)Math.Floor(bounds.Top) - padding);
        var width = checked((int)Math.Ceiling(bounds.Right) + padding - left);
        var height = checked((int)Math.Ceiling(bounds.Bottom) + padding - top);
        buffer.Left = left;
        buffer.Top = top;
        buffer.Prepare(width, height, testCheckpoint: TestCheckpoint);
        var maskCanvas = buffer.Canvas;
        {
            maskCanvas.SetMatrix(SKMatrix.Concat(SKMatrix.CreateTranslation(-left, -top), canvas.TotalMatrix));
            maskCanvas.Translate((float)(shadow.DxEm * frame.Page.FontPx), (float)(shadow.DyEm * frame.Page.FontPx));
            foreach (var word in frame.Words)
            {
                if (!word.Visible) continue;
                var saved = maskCanvas.Save(); WordTransform(maskCanvas, frame.Page, word);
                var fill = Solid("#FFFFFF", request.Track.Style, word.Opacity);
                var stroke = Stroke(request.Track.Style, frame.Page, word, true);
                maskCanvas.DrawPath(geometry.Path(frame.Page, word), fill);
                if (stroke is not null) maskCanvas.DrawPath(geometry.Path(frame.Page, word), stroke);
                maskCanvas.RestoreToCount(saved);
            }
            maskCanvas.Flush();
        }
    }

    private void Emoji(SKCanvas canvas, CaptionEmojiLayout emoji, CaptionFrame frame, double scale, CaptionResources data, CancellationToken ct)
    {
        var size = checked((int)CaptionMath.RoundHalfUp(emoji.Size * frame.PageScale * scale));
        if (size <= 0) return;
        var center = canvas.TotalMatrix.MapPoint((float)(emoji.X + emoji.Size / 2), (float)(emoji.Y + emoji.Size / 2));
        var left = CaptionMath.RoundHalfUp(center.X - size / 2.0);
        var top = CaptionMath.RoundHalfUp(center.Y - size / 2.0);
        var source = CaptionEmojiImages.Source(data, emoji.Codepoints);
        var image = emojiPixels.Resize(source, size, ct);
        var saved = canvas.Save(); canvas.ResetMatrix();
        canvas.DrawImage(image, left, top);
        canvas.RestoreToCount(saved);
    }
}
