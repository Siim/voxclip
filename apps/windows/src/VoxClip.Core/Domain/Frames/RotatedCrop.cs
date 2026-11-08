namespace VoxClip.Core.Domain.Frames;

/// <summary>A landmark of the face mesh: x and y in pixels, z in the same pixel scale (smaller is nearer the camera).</summary>
/// <param name="X">Pixels right.</param>
/// <param name="Y">Pixels down.</param>
/// <param name="Z">Depth, in the same units.</param>
public readonly record struct MeshPoint(double X, double Y, double Z);

/// <summary>The square, roll-aligned crop the face mesh reads (ADR-R48, Windows; MediaPipe's own detector-to-mesh recipe): a square of
/// <see cref="Expansion"/> × the detector box's long side around the box's centre, turned by the roll of the eye line, resampled to
/// <see cref="Size"/> pixels. The crop is upright, so its x axis runs along the eye line. Pure: the frame's pixels come in, the
/// mesh's tensor goes out, and <see cref="ToFrame(MeshPoint)"/> maps mesh landmarks back.</summary>
/// <remarks>Crop pixel (u, v) and frame pixel (x, y) are continuous coordinates with pixel corners on whole numbers:
/// (x, y) = centre + k·R·(u − n/2, v − n/2), with k = side / n and R the rotation whose first column is the eye line's unit vector.
/// The unit vector comes from the eye points by division by their distance, never from sin and cos of the roll, so the
/// transform is the same on every platform.</remarks>
public sealed record RotatedCrop
{
    /// <summary>The mesh's input side, pixels.</summary>
    public const int Size = 256;
    /// <summary>The crop's side over the detector box's long side.</summary>
    public const double Expansion = 1.5;

    /// <summary>The eye line's angle, radians, atan2(dy, dx) from the first eye point to the second in frame pixels (y down):
    /// positive when the second eye (on the picture's right) sits lower.</summary>
    public double Roll { get; }
    /// <summary>The crop's centre in frame pixels.</summary>
    public FramePoint Centre { get; }
    /// <summary>The crop's side in frame pixels.</summary>
    public double Side { get; }
    /// <summary>The crop's side in crop pixels.</summary>
    public int CropSize { get; }
    /// <summary>The eye line's unit vector, x part.</summary>
    public double Cos { get; }
    /// <summary>The eye line's unit vector, y part.</summary>
    public double Sin { get; }

    private RotatedCrop(double roll, FramePoint centre, double side, int cropSize, double cos, double sin)
    {
        Roll = roll;
        Centre = centre;
        Side = side;
        CropSize = cropSize;
        Cos = cos;
        Sin = sin;
    }

    /// <summary>Frame pixels per crop pixel.</summary>
    public double PixelScale => Side / CropSize;

    /// <summary>The crop for <paramref name="face"/>, found in detector pixels, cut from a frame <paramref name="scale"/> times larger
    /// (frame pixels per detector pixel, e.g. 2 for a 1,280 px frame and a 640 px detector input). Null when the eye points coincide,
    /// the box is empty or a number is not finite.</summary>
    public static RotatedCrop? FromFace(YuNetFace face, double scale, int cropSize = Size, double expansion = Expansion)
    {
        if (face.Points.Count != 5 || !(scale > 0) || !double.IsFinite(scale) || cropSize <= 0 || !(expansion > 0)) return null;
        var dx = (face.Points[1].X - face.Points[0].X) * scale;
        var dy = (face.Points[1].Y - face.Points[0].Y) * scale;
        var length = Math.Sqrt(dx * dx + dy * dy);
        var side = Math.Max(face.Width, face.Height) * expansion * scale;
        var centre = new FramePoint((face.X + face.Width / 2) * scale, (face.Y + face.Height / 2) * scale);
        if (!(length > 0) || !double.IsFinite(length) || !(side > 0) || !double.IsFinite(side) || !double.IsFinite(centre.X) || !double.IsFinite(centre.Y))
            return null;
        return new RotatedCrop(Math.Atan2(dy, dx), centre, side, cropSize, dx / length, dy / length);
    }

    /// <summary>The crop-to-frame affine (a, b, c, d, e, f): x = a·u + b·v + c, y = d·u + e·v + f.</summary>
    public (double A, double B, double C, double D, double E, double F) CropToFrame
    {
        get
        {
            var k = PixelScale;
            var origin = ToFrame(0, 0);
            return (k * Cos, -(k * Sin), origin.X, k * Sin, k * Cos, origin.Y);
        }
    }

    /// <summary>The frame-to-crop affine (a, b, c, d, e, f): u = a·x + b·y + c, v = d·x + e·y + f.</summary>
    public (double A, double B, double C, double D, double E, double F) FrameToCrop
    {
        get
        {
            var k = PixelScale;
            var origin = ToCrop(0, 0);
            return (Cos / k, Sin / k, origin.X, -Sin / k, Cos / k, origin.Y);
        }
    }

    /// <summary>A crop point in frame pixels.</summary>
    public FramePoint ToFrame(double u, double v)
    {
        var k = PixelScale;
        var half = CropSize / 2.0;
        var du = u - half;
        var dv = v - half;
        return new FramePoint(Centre.X + k * (Cos * du - Sin * dv), Centre.Y + k * (Sin * du + Cos * dv));
    }

    /// <summary>A frame point in crop pixels.</summary>
    public FramePoint ToCrop(double x, double y)
    {
        var k = PixelScale;
        var half = CropSize / 2.0;
        var dx = x - Centre.X;
        var dy = y - Centre.Y;
        return new FramePoint(half + (Cos * dx + Sin * dy) / k, half + (Cos * dy - Sin * dx) / k);
    }

    /// <summary>A mesh landmark (crop pixels) in frame pixels; z is scaled like x and y.</summary>
    public MeshPoint ToFrame(MeshPoint point)
    {
        var mapped = ToFrame(point.X, point.Y);
        return new MeshPoint(mapped.X, mapped.Y, point.Z * PixelScale);
    }

    /// <summary>The mesh's input: the crop resampled from an RGB frame (3 bytes per pixel, rows <paramref name="rowBytes"/> apart),
    /// bilinear at each crop pixel's centre, edges repeated, as <see cref="CropSize"/>² × 3 values in 0–1 (NHWC, RGB).</summary>
    public float[] Sample(ReadOnlySpan<byte> rgb, int width, int height, int rowBytes)
    {
        if (width <= 0 || height <= 0 || rowBytes < width * 3 || rgb.Length < (long)rowBytes * (height - 1) + width * 3)
            throw new ArgumentException("The frame buffer is smaller than its size.");
        var output = new float[CropSize * CropSize * 3];
        for (var v = 0; v < CropSize; v++)
        {
            for (var u = 0; u < CropSize; u++)
            {
                var point = ToFrame(u + 0.5, v + 0.5);
                var x = point.X - 0.5;
                var y = point.Y - 0.5;
                var left = Math.Floor(x);
                var top = Math.Floor(y);
                var fx = x - left;
                var fy = y - top;
                var x0 = Clamp(left, width);
                var x1 = Clamp(left + 1, width);
                var y0 = Clamp(top, height);
                var y1 = Clamp(top + 1, height);
                for (var channel = 0; channel < 3; channel++)
                {
                    double topLeft = rgb[y0 * rowBytes + x0 * 3 + channel], topRight = rgb[y0 * rowBytes + x1 * 3 + channel];
                    double bottomLeft = rgb[y1 * rowBytes + x0 * 3 + channel], bottomRight = rgb[y1 * rowBytes + x1 * 3 + channel];
                    var upper = topLeft + (topRight - topLeft) * fx;
                    var lower = bottomLeft + (bottomRight - bottomLeft) * fx;
                    output[(v * CropSize + u) * 3 + channel] = (float)((upper + (lower - upper) * fy) / 255);
                }
            }
        }
        return output;
    }

    private static int Clamp(double index, int count) => index <= 0 || double.IsNaN(index) ? 0 : index >= count - 1 ? count - 1 : (int)index;
}
