using System.Collections.Concurrent;
using System.Runtime.InteropServices;
using SkiaSharp;
using VoxClip.Core.Domain.Captions;

namespace VoxClip.Media.Captions;

internal static class CaptionEmojiImages
{
    private static readonly ConcurrentDictionary<(string Root, string Codepoints), byte[]> Sources = new();

    internal static byte[] Source(CaptionResources data, string codepoints)
    {
        if (codepoints.Length == 0 || codepoints.Any(character => character is not (>= '0' and <= '9' or >= 'a' and <= 'f' or '_'))) throw new ArgumentException("Invalid bundled emoji name.", nameof(codepoints));
        return Sources.GetOrAdd((data.Root, codepoints), key =>
        {
            using var codec = SKCodec.Create(Path.Combine(key.Root, "fonts", "noto-emoji", "png128", $"emoji_u{key.Codepoints}.png")) ?? throw new InvalidDataException("Bundled caption emoji is missing.");
            if (codec.Info.Width != 128 || codec.Info.Height != 128) throw new InvalidDataException("Invalid caption emoji dimensions.");
            var pixels = new byte[128 * 128 * 4];
            unsafe
            {
                fixed (byte* pointer = pixels)
                    if (codec.GetPixels(new SKImageInfo(128, 128, SKColorType.Bgra8888, SKAlphaType.Unpremul), (IntPtr)pointer) != SKCodecResult.Success) throw new InvalidDataException("Invalid caption emoji PNG.");
            }
            for (var offset = 0; offset < pixels.Length; offset += 4)
                for (var channel = 0; channel < 3; channel++) pixels[offset + channel] = (byte)((pixels[offset + channel] * pixels[offset + 3] + 127) / 255);
            return pixels;
        });
    }

    internal static byte[] Resize(byte[] source, int size, CancellationToken ct)
    {
        var target = new byte[checked(size * size * 4)];
        Resize(source, size, target, ct);
        return target;
    }

    internal static void Resize(ReadOnlySpan<byte> source, int size, Span<byte> target, CancellationToken ct)
    {
        var ratio = 128.0 / size;
        for (var row = 0; row < size; row++)
        {
            ct.ThrowIfCancellationRequested();
            for (var column = 0; column < size; column++)
            {
                var output = (row * size + column) * 4;
                if (size <= 128)
                {
                    var left = column * ratio; var right = (column + 1) * ratio;
                    var top = row * ratio; var bottom = (row + 1) * ratio;
                    for (var channel = 0; channel < 4; channel++)
                    {
                        var sum = 0.0;
                        for (var sourceY = (int)Math.Floor(top); sourceY < Math.Min(128, Math.Ceiling(bottom)); sourceY++)
                            for (var sourceX = (int)Math.Floor(left); sourceX < Math.Min(128, Math.Ceiling(right)); sourceX++)
                                sum += source[(sourceY * 128 + sourceX) * 4 + channel] * (Math.Min(sourceX + 1, right) - Math.Max(sourceX, left)) * (Math.Min(sourceY + 1, bottom) - Math.Max(sourceY, top));
                        target[output + channel] = (byte)Math.Clamp(CaptionMath.RoundHalfUp(sum / (ratio * ratio)), 0, 255);
                    }
                }
                else
                {
                    var sourceX = Math.Clamp((column + 0.5) * ratio - 0.5, 0, 127);
                    var sourceY = Math.Clamp((row + 0.5) * ratio - 0.5, 0, 127);
                    var left = (int)Math.Floor(sourceX); var top = (int)Math.Floor(sourceY);
                    var right = Math.Min(127, left + 1); var bottom = Math.Min(127, top + 1);
                    var weightX = sourceX - left; var weightY = sourceY - top;
                    for (var channel = 0; channel < 4; channel++)
                    {
                        var upper = source[(top * 128 + left) * 4 + channel] * (1 - weightX) + source[(top * 128 + right) * 4 + channel] * weightX;
                        var lower = source[(bottom * 128 + left) * 4 + channel] * (1 - weightX) + source[(bottom * 128 + right) * 4 + channel] * weightX;
                        target[output + channel] = (byte)Math.Clamp(CaptionMath.RoundHalfUp(upper * (1 - weightY) + lower * weightY), 0, 255);
                    }
                }
            }
        }
    }
}

internal sealed class CaptionEmojiBuffer
{
    private byte[] pixels = [];
    private GCHandle pin;
    private byte[]? source;
    private int size;
    internal SKBitmap Bitmap { get; } = new();
    private SKImage? image;
    private readonly (int Size, SKImage? Image)[] images = new (int, SKImage?)[32];
    private int nextImage;

    internal SKImage Resize(byte[] requestedSource, int requestedSize, CancellationToken ct)
    {
        if (ReferenceEquals(source, requestedSource) && size == requestedSize) return image!;
        source = null;
        size = 0;
        var length = checked(requestedSize * requestedSize * 4);
        if (pixels.Length < length)
        {
            ClearImages();
            image = null;
            Bitmap.Reset();
            if (pin.IsAllocated) pin.Free();
            pixels = new byte[length];
            pin = GCHandle.Alloc(pixels, GCHandleType.Pinned);
        }
        CaptionEmojiImages.Resize(requestedSource, requestedSize, pixels, ct);
        image = null;
        for (var index = 0; index < images.Length; index++)
            if (images[index].Size == requestedSize) { image = images[index].Image; break; }
        if (image is null)
        {
            if (!Bitmap.InstallPixels(new SKImageInfo(requestedSize, requestedSize, SKColorType.Bgra8888, SKAlphaType.Premul), pin.AddrOfPinnedObject(), requestedSize * 4))
                throw new InvalidOperationException("Could not wrap caption emoji pixels.");
            using var pixmap = Bitmap.PeekPixels();
            image = SKImage.FromPixels(pixmap) ?? throw new InvalidOperationException("Could not wrap caption emoji image.");
            images[nextImage].Image?.Dispose();
            images[nextImage] = (requestedSize, image);
            nextImage = (nextImage + 1) % images.Length;
        }
        source = requestedSource;
        size = requestedSize;
        return image;
    }

    ~CaptionEmojiBuffer()
    {
        ClearImages();
        Bitmap.Dispose();
        if (pin.IsAllocated) pin.Free();
    }

    private void ClearImages()
    {
        for (var index = 0; index < images.Length; index++)
        {
            images[index].Image?.Dispose();
            images[index] = default;
        }
        nextImage = 0;
    }
}
