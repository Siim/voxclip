using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text.Json;
using SkiaSharp;
using VoxClip.Core.Domain.Captions;
using Xunit;

namespace VoxClip.Media.Tests.Captions;

internal static class CaptionImageComparison
{
    internal sealed record Image(int Width, int Height, byte[] Rgba);
    internal sealed record Result(bool Passed, double Mean = 0, int Over32 = 0, int Max = 0, double SsimAlpha = 1, int Pixels = 0, string? Error = null);
    private static readonly double[] Window = GaussianWindow();

    internal static Result Compare(Image first, Image second)
    {
        if (first.Width != second.Width || first.Height != second.Height) return new(false, Error: "Image sizes differ.");
        var left = first.Width; var top = first.Height; var right = -1; var bottom = -1;
        var inFirst = false; var inSecond = false;
        long total = 0;
        var region = 0; var over = 0; var maximum = 0;
        for (var row = 0; row < first.Height; row++)
            for (var column = 0; column < first.Width; column++)
            {
                var offset = (row * first.Width + column) * 4;
                var firstAlpha = first.Rgba[offset + 3]; var secondAlpha = second.Rgba[offset + 3];
                inFirst |= firstAlpha > 0; inSecond |= secondAlpha > 0;
                if (firstAlpha == 0 && secondAlpha == 0) continue;
                region++;
                left = Math.Min(left, column); right = Math.Max(right, column);
                top = Math.Min(top, row); bottom = Math.Max(bottom, row);
                var largest = 0;
                for (var channel = 0; channel < 4; channel++)
                {
                    var delta = Math.Abs(Premultiply(first.Rgba[offset + channel], firstAlpha, channel) - Premultiply(second.Rgba[offset + channel], secondAlpha, channel));
                    total += delta; largest = Math.Max(largest, delta);
                }
                if (largest > 32) over++;
                maximum = Math.Max(maximum, largest);
            }
        if (!inFirst && !inSecond) return new(true);
        if (inFirst != inSecond) return new(false, Error: "One image is empty.");
        var mean = total / (4.0 * region);
        var ssim = Ssim(first, second, Math.Max(0, left - 8), Math.Max(0, top - 8), Math.Min(first.Width, right + 9), Math.Min(first.Height, bottom + 9));
        return new(mean <= 4.5 && over <= Math.Max(0.02 * region, 96) && maximum <= 128 && (ssim >= 0.98 || maximum <= 2), mean, over, maximum, ssim, region);
    }

    private static int Premultiply(byte color, byte alpha, int channel) => channel == 3 ? alpha : (2 * color * alpha + 255) / 510;

    private static double[] GaussianWindow()
    {
        var weights = Enumerable.Range(-5, 11).Select(offset => Math.Exp(-offset * offset / (2 * 1.5 * 1.5))).ToArray();
        var sum = weights.Sum();
        for (var index = 0; index < weights.Length; index++) weights[index] /= sum;
        return weights;
    }

    private static double Ssim(Image first, Image second, int left, int top, int right, int bottom)
    {
        var width = Math.Max(11, right - left); var height = Math.Max(11, bottom - top);
        var alphaFirst = new double[width * height]; var alphaSecond = new double[width * height];
        var squareFirst = new double[width * height]; var squareSecond = new double[width * height]; var product = new double[width * height];
        for (var row = 0; row < bottom - top; row++)
            for (var column = 0; column < right - left; column++)
            {
                var source = ((row + top) * first.Width + column + left) * 4 + 3;
                var offset = row * width + column;
                var valueFirst = (double)first.Rgba[source]; var valueSecond = (double)second.Rgba[source];
                alphaFirst[offset] = valueFirst; alphaSecond[offset] = valueSecond;
                squareFirst[offset] = valueFirst * valueFirst; squareSecond[offset] = valueSecond * valueSecond; product[offset] = valueFirst * valueSecond;
            }
        var meanFirst = Filter(alphaFirst, width, height); var meanSecond = Filter(alphaSecond, width, height);
        var varianceFirst = Filter(squareFirst, width, height); var varianceSecond = Filter(squareSecond, width, height); var covariance = Filter(product, width, height);
        const double firstConstant = 0.01 * 255 * (0.01 * 255);
        const double secondConstant = 0.03 * 255 * (0.03 * 255);
        var total = 0.0;
        for (var index = 0; index < meanFirst.Length; index++)
        {
            var firstMean = meanFirst[index]; var secondMean = meanSecond[index];
            var firstVariance = varianceFirst[index] - firstMean * firstMean;
            var secondVariance = varianceSecond[index] - secondMean * secondMean;
            var crossVariance = covariance[index] - firstMean * secondMean;
            total += (2 * firstMean * secondMean + firstConstant) * (2 * crossVariance + secondConstant)
                / ((firstMean * firstMean + secondMean * secondMean + firstConstant) * (firstVariance + secondVariance + secondConstant));
        }
        return total / meanFirst.Length;
    }

    private static double[] Filter(double[] values, int width, int height)
    {
        var outputWidth = width - 10;
        var horizontal = new double[outputWidth * height];
        for (var row = 0; row < height; row++)
            for (var column = 0; column < outputWidth; column++)
                for (var kernel = 0; kernel < 11; kernel++) horizontal[row * outputWidth + column] += Window[kernel] * values[row * width + column + kernel];
        var result = new double[outputWidth * (height - 10)];
        for (var row = 0; row < height - 10; row++)
            for (var column = 0; column < outputWidth; column++)
                for (var kernel = 0; kernel < 11; kernel++) result[row * outputWidth + column] += Window[kernel] * horizontal[(row + kernel) * outputWidth + column];
        return result;
    }

    internal static Image ReadPng(string path)
    {
        using var codec = SKCodec.Create(path) ?? throw new InvalidDataException($"Invalid golden PNG: {path}");
        var info = new SKImageInfo(codec.Info.Width, codec.Info.Height, SKColorType.Rgba8888, SKAlphaType.Unpremul);
        var rgba = new byte[info.BytesSize];
        var pin = GCHandle.Alloc(rgba, GCHandleType.Pinned);
        try { Assert.Equal(SKCodecResult.Success, codec.GetPixels(info, pin.AddrOfPinnedObject())); }
        finally { pin.Free(); }
        return new(info.Width, info.Height, rgba);
    }

    internal static Image FromPixels(PixelBuffer pixels)
    {
        var bytes = pixels.Pixels.ToArray();
        var rgba = new byte[pixels.Width * pixels.Height * 4];
        var source = GCHandle.Alloc(bytes, GCHandleType.Pinned); var target = GCHandle.Alloc(rgba, GCHandleType.Pinned);
        try
        {
            using var pixmap = new SKPixmap(new SKImageInfo(pixels.Width, pixels.Height, SKColorType.Bgra8888, SKAlphaType.Premul), source.AddrOfPinnedObject(), pixels.Stride);
            Assert.True(pixmap.ReadPixels(new SKImageInfo(pixels.Width, pixels.Height, SKColorType.Rgba8888, SKAlphaType.Unpremul), target.AddrOfPinnedObject(), pixels.Width * 4));
        }
        finally { source.Free(); target.Free(); }
        return new(pixels.Width, pixels.Height, rgba);
    }

    internal static void WritePng(Image image, string path)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        var pin = GCHandle.Alloc(image.Rgba, GCHandleType.Pinned);
        try
        {
            using var bitmap = new SKBitmap();
            Assert.True(bitmap.InstallPixels(new SKImageInfo(image.Width, image.Height, SKColorType.Rgba8888, SKAlphaType.Unpremul), pin.AddrOfPinnedObject(), image.Width * 4));
            using var native = SKImage.FromBitmap(bitmap);
            using var encoded = native.Encode(SKEncodedImageFormat.Png, 100);
            File.WriteAllBytes(path, encoded.ToArray());
        }
        finally { pin.Free(); }
    }

    internal static Image Diff(Image first, Image second)
    {
        var rgba = new byte[first.Rgba.Length];
        for (var offset = 0; offset < rgba.Length; offset += 4)
        {
            var largest = 0;
            for (var channel = 0; channel < 4; channel++) largest = Math.Max(largest,
                Math.Abs(Premultiply(first.Rgba[offset + channel], first.Rgba[offset + 3], channel) - Premultiply(second.Rgba[offset + channel], second.Rgba[offset + 3], channel)));
            var value = (byte)Math.Min(255, largest * 4);
            rgba[offset] = value; rgba[offset + 1] = value; rgba[offset + 2] = value; rgba[offset + 3] = 255;
        }
        return new(first.Width, first.Height, rgba);
    }

    internal static Image Place(Image crop, int width, int height, int left, int top)
    {
        Assert.InRange(left, 0, width - crop.Width); Assert.InRange(top, 0, height - crop.Height);
        var rgba = new byte[width * height * 4];
        for (var row = 0; row < crop.Height; row++) crop.Rgba.AsSpan(row * crop.Width * 4, crop.Width * 4).CopyTo(rgba.AsSpan(((row + top) * width + left) * 4));
        return new(width, height, rgba);
    }

    internal static void AssertGolden(PixelBuffer pixels, string goldenRoot, string folder, string file, int? sample, string? style, double time)
    {
        var indexPath = Path.Combine(goldenRoot, folder + ".json");
        Assert.True(File.Exists(indexPath), $"Missing golden index: {indexPath}");
        using var index = JsonDocument.Parse(File.ReadAllText(indexPath));
        var entry = Assert.Single(index.RootElement.GetProperty("images").EnumerateArray(), item => item.GetProperty("file").GetString() == file);
        Assert.Equal(sample, entry.GetProperty("sample").ValueKind == JsonValueKind.Null ? (int?)null : entry.GetProperty("sample").GetInt32());
        Assert.Equal(style, entry.GetProperty("style").GetString());
        Assert.InRange(Math.Abs(time - entry.GetProperty("t").GetDouble()), 0, 1e-9);
        var path = Path.Combine(goldenRoot, folder, file);
        Assert.True(File.Exists(path), $"Missing golden image: {path}");
        Assert.Equal(entry.GetProperty("sha256").GetString(), Convert.ToHexStringLower(SHA256.HashData(File.ReadAllBytes(path))));
        var frame = entry.GetProperty("frame"); var crop = entry.GetProperty("crop");
        Assert.Equal(pixels.Width, frame.GetProperty("width").GetInt32()); Assert.Equal(pixels.Height, frame.GetProperty("height").GetInt32());
        var image = ReadPng(path);
        Assert.Equal(image.Width, crop.GetProperty("w").GetInt32()); Assert.Equal(image.Height, crop.GetProperty("h").GetInt32());
        var expected = Place(image, pixels.Width, pixels.Height, crop.GetProperty("x").GetInt32(), crop.GetProperty("y").GetInt32());
        var actual = FromPixels(pixels);
        var result = Compare(expected, actual);
        if (result.Passed) return;
        var outputRoot = CaptionFixtureSupport.GoldenRoot ?? Path.Combine(AppContext.BaseDirectory, "TestResults", "caption-diffs");
        var output = Path.Combine(outputRoot, folder, Path.GetFileNameWithoutExtension(file) + ".actual.png");
        WritePng(actual, output);
        var diff = Path.ChangeExtension(output, ".diff.png");
        WritePng(Diff(expected, actual), diff);
        Assert.Fail($"{folder}/{file}: {JsonSerializer.Serialize(result)}; diff: {diff}");
    }
}
