using System.Runtime.InteropServices;
using VoxClip.Core.Domain.Captions;
using VoxClip.Core.Domain.Clips;
using VoxClip.Core.Domain.ContextDemo;
using VoxClip.Core.Domain.Shared;
using SkiaSharp;

namespace VoxClip.Media.Pipeline;

/// <summary>A clip's picture controls in the shared frame composer (design §6.9; Mac ClipPicture), so preview and export draw the
/// same frame: the flip and quarter turns on the oriented source before the frame's crop, and the grade on the finished frame
/// before effects and captions.</summary>
internal static class ClipPicture
{
    /// <summary>The size of <paramref name="width"/> × <paramref name="height"/> after the controls' quarter turn.</summary>
    internal static (int Width, int Height) OrientedSize(int width, int height, ProjectClipControls? controls)
        => controls?.IsQuarterTurn() == true ? (height, width) : (width, height);

    /// <summary>True when the controls move pixels (a flip or a turn).</summary>
    internal static bool Orients(ProjectClipControls? controls) => controls is not null && (controls.FlipHorizontal || controls.RotationDegrees != 0);

    /// <summary>Mirrors left to right, then turns clockwise, into <paramref name="target"/> (tightly packed, <see cref="OrientedSize"/>).</summary>
    internal static void Orient(PixelBuffer source, Span<byte> target, ProjectClipControls controls, CancellationToken ct)
    {
        var (width, height) = OrientedSize(source.Width, source.Height, controls);
        var output = MemoryMarshal.Cast<byte, uint>(target[..checked(width * height * 4)]);
        var input = source.Pixels.Span;
        var flip = controls.FlipHorizontal;
        var degrees = controls.RotationDegrees;
        for (var row = 0; row < source.Height; row++)
        {
            ct.ThrowIfCancellationRequested();
            var line = MemoryMarshal.Cast<byte, uint>(input.Slice(row * source.Stride, source.Width * 4));
            for (var column = 0; column < source.Width; column++)
            {
                var x = flip ? source.Width - 1 - column : column;
                var (outputColumn, outputRow) = degrees switch
                {
                    90 => (source.Height - 1 - row, x),
                    180 => (source.Width - 1 - x, source.Height - 1 - row),
                    270 => (row, source.Width - 1 - x),
                    _ => (x, row)
                };
                output[outputRow * width + outputColumn] = line[column];
            }
        }
    }

    /// <summary>Grades <paramref name="frame"/> (BGRA) in place, applying adjustments to the base look before writing bytes.</summary>
    internal static void Grade(PixelBuffer frame, ClipLook look, ClipColorAdjustments? adjustments, CancellationToken ct)
    {
        var recipe = new ClipLookRecipe(look);
        var after = adjustments is null ? null : new ClipLookRecipe(adjustments);
        if (after is { IsIdentity: true }) after = null;
        if (recipe.IsIdentity && after is not null)
        {
            recipe = after;
            after = null;
        }
        if (recipe.IsIdentity) return;
        // Per-channel contributions: table[row * 3 + column][value] = matrix[row][column] × value / 255.
        var tables = new float[9][];
        for (var row = 0; row < 3; row++)
            for (var column = 0; column < 3; column++)
            {
                var table = new float[256];
                for (var value = 0; value < 256; value++) table[value] = (float)(recipe.Matrix[row][column] * value / 255.0);
                tables[row * 3 + column] = table;
            }
        var bias = recipe.Bias.Select(value => (float)value).ToArray();
        var curve = recipe.Curve?.Select(value => (float)value).ToArray();
        var afterMatrix = after?.Matrix.Select(row => row.Select(value => (float)value).ToArray()).ToArray();
        var afterBias = after?.Bias.Select(value => (float)value).ToArray();
        var memory = frame.Pixels;
        var stride = frame.Stride;
        var width = frame.Width;
        Parallel.For(0, frame.Height, new ParallelOptions { CancellationToken = ct }, row =>
        {
            var line = memory.Span.Slice(row * stride, width * 4);
            Span<float> result = stackalloc float[3];
            for (var column = 0; column < width; column++)
            {
                var offset = column * 4;
                int blue = line[offset], green = line[offset + 1], red = line[offset + 2];
                for (var channel = 0; channel < 3; channel++)
                {
                    var value = bias[channel] + tables[channel * 3][red] + tables[channel * 3 + 1][green] + tables[channel * 3 + 2][blue];
                    if (curve is not null)
                    {
                        value = Math.Clamp(value, 0, 1);
                        var squared = value * value;
                        value = curve[0] + curve[1] * value + curve[2] * squared + curve[3] * squared * value;
                    }
                    result[channel] = value;
                }
                if (afterMatrix is not null && afterBias is not null)
                {
                    for (var channel = 0; channel < 3; channel++)
                    {
                        var coefficients = afterMatrix[channel];
                        line[offset + 2 - channel] = Encode(afterBias[channel] + coefficients[0] * result[0] + coefficients[1] * result[1] + coefficients[2] * result[2]);
                    }
                }
                else
                {
                    line[offset + 2] = Encode(result[0]);
                    line[offset + 1] = Encode(result[1]);
                    line[offset] = Encode(result[2]);
                }
            }
        });

        static byte Encode(float value) => (byte)MathF.Round(Math.Clamp(value, 0, 1) * 255, MidpointRounding.AwayFromZero);
    }

    /// <summary>A motion cue's crop of the finished frame, scaled back to fill it (Mac CompositionFrameGeometry.fill with Lanczos;
    /// Mitchell cubic here, bilinear in preview). The identity leaves the frame untouched.</summary>
    internal static void Motion(PixelBuffer frame, MotionCropTransform motion, bool forPreview, CancellationToken ct)
    {
        if (motion.Scale <= 1) return;
        ct.ThrowIfCancellationRequested();
        var crop = motion.Crop(frame.Width, frame.Height);
        var info = new SKImageInfo(frame.Width, frame.Height, SKColorType.Bgra8888, SKAlphaType.Premul);
        using var copy = SKImage.FromPixelCopy(info, frame.Pixels.Span[..(frame.Stride * frame.Height)], frame.Stride)
            ?? throw new InvalidOperationException("Could not copy the frame for its motion.");
        using var pin = frame.Pixels.Pin();
        unsafe
        {
            using var surface = SKSurface.Create(info, (IntPtr)pin.Pointer, frame.Stride) ?? throw new InvalidOperationException("Could not wrap the frame for its motion.");
            var sampling = forPreview ? new SKSamplingOptions(SKFilterMode.Linear, SKMipmapMode.None) : new SKSamplingOptions(SKCubicResampler.Mitchell);
            surface.Canvas.DrawImage(copy, new SKRect((float)crop.X, (float)crop.Y, (float)(crop.X + crop.Width), (float)(crop.Y + crop.Height)),
                new SKRect(0, 0, frame.Width, frame.Height), sampling, null);
            surface.Canvas.Flush();
        }
    }
}
