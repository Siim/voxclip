using System.Security.Cryptography;
using SkiaSharp;
using VoxClip.Core.Domain.Captions;
using VoxClip.Core.Domain.ContextDemo;
using VoxClip.Core.Domain.Shared;
using VoxClip.Media.Ffmpeg;

namespace VoxClip.Media.Pipeline;

/// <summary>Where the composer reads a screen recording's frames: the frame at a time in the asset, and the asset's own rotation.</summary>
internal interface IContextDemoFrames : IDisposable
{
    (PixelBuffer Frame, int Rotation) Read(string assetId, double sourceTime, CancellationToken ct);
}

/// <summary>A render's screen recordings (doc/spec/context-demo.md, Mac ContextDemoCompositionAssets): each asset is checked (a
/// regular file, no links on its canonical path, its byte size, an MP4 brand, its SHA-256 and its pixel size) while it is copied into
/// a private snapshot that the render holds until it releases it, then decoded from there. A missing or changed file stops the
/// render with <see cref="ContextDemoRendering.AssetMessage"/>; no black or older frame stands in for it.</summary>
internal sealed class ContextDemoFrames : IContextDemoFrames
{
    internal const long MaximumBytes = 64 * 1024 * 1024;
    private static readonly string[] Brands = ["isom", "iso2", "mp41", "mp42", "avc1", "M4V "];
    private readonly string directory;
    private readonly Dictionary<string, VideoDecoder> decoders = new(StringComparer.Ordinal);
    private readonly Dictionary<string, int> rotations = new(StringComparer.Ordinal);
    private readonly Lock gate = new();

    private ContextDemoFrames(string directory) => this.directory = directory;

    private static VoxClipException Unavailable() => new(VoxClipErrorCode.ExportFailed, ContextDemoRendering.AssetMessage);

    /// <summary>Checks that every asset <paramref name="layers"/> shows is on disk at its canonical path with its recorded size: the
    /// cheap check an export makes before it writes anything.</summary>
    internal static void RequirePresent(ContextDemoRenderLayers layers)
    {
        foreach (var asset in layers.Input.Assets)
        {
            var path = layers.AssetPath(asset);
            RequireNoLinks(layers.DataRoot, path);
            var file = new FileInfo(path);
            if (!file.Exists || file.Length != asset.ByteSize || asset.ByteSize is <= 0 or > MaximumBytes) throw Unavailable();
        }
    }

    private static void RequireNoLinks(string root, string path)
    {
        var current = new DirectoryInfo(Path.GetFullPath(root));
        foreach (var part in Path.GetRelativePath(current.FullName, Path.GetFullPath(path)).Split(Path.DirectorySeparatorChar))
        {
            if (part is "" or "." or "..") throw Unavailable();
            var next = Path.Combine(current.FullName, part);
            FileSystemInfo entry = Directory.Exists(next) ? new DirectoryInfo(next) : new FileInfo(next);
            if (entry.Exists && (entry.LinkTarget is not null || entry.Attributes.HasFlag(FileAttributes.ReparsePoint))) throw Unavailable();
            current = new DirectoryInfo(next);
        }
    }

    /// <summary>Copies and checks each asset of <paramref name="layers"/>, then opens its decoder.</summary>
    internal static ContextDemoFrames Open(ContextDemoRenderLayers layers, CancellationToken ct)
    {
        RequirePresent(layers);
        var directory = Directory.CreateTempSubdirectory("voxclip-context-demo-").FullName;
        var frames = new ContextDemoFrames(directory);
        try
        {
            foreach (var asset in layers.Input.Assets)
            {
                ct.ThrowIfCancellationRequested();
                var copy = Path.Combine(directory, asset.Id + ".mp4");
                Snapshot(asset, layers.AssetPath(asset), copy, ct);
                var decoder = new VideoDecoder(copy, hardware: false);
                frames.decoders[asset.Id] = decoder;
                if (decoder.Width != asset.PixelWidth || decoder.Height != asset.PixelHeight) throw Unavailable();
                frames.rotations[asset.Id] = decoder.RotationDegrees;
            }
            return frames;
        }
        catch
        {
            frames.Dispose();
            throw;
        }
    }

    private static void Snapshot(ContextDemoAsset asset, string path, string destination, CancellationToken ct)
    {
        using var input = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read, 1 << 16, FileOptions.SequentialScan);
        if (input.Length != asset.ByteSize) throw Unavailable();
        using var output = new FileStream(destination, FileMode.CreateNew, FileAccess.Write, FileShare.None);
        using var hash = IncrementalHash.CreateHash(HashAlgorithmName.SHA256);
        var buffer = new byte[1 << 20];
        long count = 0;
        int read;
        while ((read = input.Read(buffer, 0, buffer.Length)) > 0)
        {
            ct.ThrowIfCancellationRequested();
            if (count == 0 && (read < 16 || System.Text.Encoding.ASCII.GetString(buffer, 4, 4) != "ftyp" ||
                !Brands.Contains(System.Text.Encoding.ASCII.GetString(buffer, 8, 4)))) throw Unavailable();
            count += read;
            if (count > asset.ByteSize) throw Unavailable();
            hash.AppendData(buffer, 0, read);
            output.Write(buffer, 0, read);
        }
        if (count != asset.ByteSize || Convert.ToHexStringLower(hash.GetHashAndReset()) != asset.Sha256) throw Unavailable();
    }

    public (PixelBuffer Frame, int Rotation) Read(string assetId, double sourceTime, CancellationToken ct)
    {
        lock (gate)
        {
            if (!decoders.TryGetValue(assetId, out var decoder)) throw Unavailable();
            var frame = decoder.ReadAt(Math.Max(0, sourceTime), false, ct);
            // A copy: the decoder reuses its buffer on the next read.
            return (new PixelBuffer(frame.Pixels.ToArray(), frame.Width, frame.Height, frame.Stride), rotations[assetId]);
        }
    }

    public void Dispose()
    {
        lock (gate)
        {
            foreach (var decoder in decoders.Values) decoder.Dispose();
            decoders.Clear();
        }
        try { Directory.Delete(directory, true); } catch (IOException) { } catch (UnauthorizedAccessException) { }
    }
}

/// <summary>A screen recording over the clip's frame (Mac FrameCompositor's demo layer): upright by the recording's own rotation only,
/// never the clip's flip or turn (a mirrored or sideways screen would be unreadable, design §6.9), centre-cropped to fill the frame like
/// any shape. Export samples with Mitchell, preview bilinear.</summary>
internal static class ContextDemoPicture
{
    internal static void Fill(PixelBuffer frame, int rotation, PixelBuffer output, bool forPreview, CancellationToken ct)
    {
        ct.ThrowIfCancellationRequested();
        rotation = ((rotation % 360) + 360) % 360;
        var quarter = rotation is 90 or 270;
        int orientedWidth = quarter ? frame.Height : frame.Width, orientedHeight = quarter ? frame.Width : frame.Height;
        var info = new SKImageInfo(frame.Width, frame.Height, SKColorType.Bgra8888, SKAlphaType.Premul);
        using var image = SKImage.FromPixelCopy(info, frame.Pixels.Span[..(frame.Stride * frame.Height)], frame.Stride)
            ?? throw new InvalidOperationException("Could not read the screen recording's frame.");
        var crop = ExportPresets.CenterCrop(new(orientedWidth, orientedHeight), new(output.Width, output.Height));
        using var pin = output.Pixels.Pin();
        unsafe
        {
            var target = new SKImageInfo(output.Width, output.Height, SKColorType.Bgra8888, SKAlphaType.Premul);
            using var surface = SKSurface.Create(target, (IntPtr)pin.Pointer, output.Stride) ?? throw new InvalidOperationException("Could not wrap the frame.");
            var canvas = surface.Canvas;
            canvas.Clear(SKColors.Black);
            // Output ← crop of the oriented picture ← the frame turned about its centre.
            canvas.Scale((float)(output.Width / crop.Width), (float)(output.Height / crop.Height));
            canvas.Translate((float)-crop.X, (float)-crop.Y);
            canvas.Translate(orientedWidth / 2f, orientedHeight / 2f);
            canvas.RotateDegrees(rotation);
            canvas.Translate(-frame.Width / 2f, -frame.Height / 2f);
            var sampling = forPreview ? new SKSamplingOptions(SKFilterMode.Linear, SKMipmapMode.None) : new SKSamplingOptions(SKCubicResampler.Mitchell);
            canvas.DrawImage(image, 0, 0, sampling);
            canvas.Flush();
        }
    }
}
