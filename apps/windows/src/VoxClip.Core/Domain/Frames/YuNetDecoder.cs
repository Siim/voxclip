using VoxClip.Core.Domain.Effects;

namespace VoxClip.Core.Domain.Frames;

/// <summary>A point in pixels, top-left origin.</summary>
/// <param name="X">Pixels right.</param>
/// <param name="Y">Pixels down.</param>
public readonly record struct FramePoint(double X, double Y);

/// <summary>One face YuNet found, in the detector input's pixels.</summary>
/// <param name="X">The box's left edge.</param>
/// <param name="Y">The box's top edge.</param>
/// <param name="Width">The box's width.</param>
/// <param name="Height">The box's height.</param>
/// <param name="Points">The five points in YuNet's order: the eye on the picture's left (the subject's right eye), the other eye, the
/// nose tip, then the mouth corners in the same order.</param>
/// <param name="Score">√(cls·obj), 0–1.</param>
public sealed record YuNetFace(double X, double Y, double Width, double Height, IReadOnlyList<FramePoint> Points, double Score)
{
    /// <summary>The box's area in pixels.</summary>
    public double Area => Width * Height;

    /// <summary>The box in picture space (0–1, top-left origin) for a picture of <paramref name="contentWidth"/> ×
    /// <paramref name="contentHeight"/> input pixels (the scaled frame without the padding), clamped to the picture.</summary>
    public ClipEffectRect PictureRect(double contentWidth, double contentHeight)
    {
        var left = Math.Clamp(X / contentWidth, 0, 1);
        var top = Math.Clamp(Y / contentHeight, 0, 1);
        var right = Math.Clamp((X + Width) / contentWidth, 0, 1);
        var bottom = Math.Clamp((Y + Height) / contentHeight, 0, 1);
        return new ClipEffectRect(left, top, right - left, bottom - top);
    }
}

/// <summary>The detector input for one frame: the frame scaled so its long side is <see cref="YuNetDecoder.LongSide"/>, then padded
/// right and down to multiples of 32.</summary>
/// <param name="Width">The padded input width.</param>
/// <param name="Height">The padded input height.</param>
/// <param name="ContentWidth">The scaled frame's width inside it.</param>
/// <param name="ContentHeight">The scaled frame's height inside it.</param>
/// <param name="Scale">Input pixels per frame pixel.</param>
public readonly record struct YuNetInput(int Width, int Height, int ContentWidth, int ContentHeight, double Scale);

/// <summary>Turns YuNet's raw outputs into faces, as OpenCV's <c>FaceDetectorYN</c> does (ADR-R48, Windows): for each stride 8, 16 and
/// 32 a <c>cls</c>, <c>obj</c>, <c>bbox</c> (4 per cell) and <c>kps</c> (10 per cell) output over the input's grid, the score
/// √(clamp(cls)·clamp(obj)), boxes from the cell offset and the exponential of the log size, then a greedy NMS. Pure; the model
/// itself runs elsewhere (W3). Unlike OpenCV, boxes stay in doubles (OpenCV's NMS truncates them to whole pixels).</summary>
public static class YuNetDecoder
{
    /// <summary>The strides of the three output levels.</summary>
    public static readonly IReadOnlyList<int> Strides = [8, 16, 32];
    /// <summary>A face scoring below this is dropped.</summary>
    public const double ScoreThreshold = 0.6;
    /// <summary>A face overlapping a better one by more than this IoU is dropped.</summary>
    public const double NmsThreshold = 0.3;
    /// <summary>The detector input's long side (pixels) before padding.</summary>
    public const int LongSide = 640;
    /// <summary>The input's sides are padded up to a multiple of this.</summary>
    public const int Alignment = 32;

    /// <summary>The output tensor's name, e.g. <c>cls_8</c>.</summary>
    public static string OutputName(string kind, int stride) => kind + "_" + stride.ToString(System.Globalization.CultureInfo.InvariantCulture);

    /// <summary>The detector input for a frame of <paramref name="frameWidth"/> × <paramref name="frameHeight"/> pixels: scaled so
    /// the long side is <paramref name="longSide"/> (sides rounded half away from zero, at least 1), padded to multiples of 32.</summary>
    public static YuNetInput Input(int frameWidth, int frameHeight, int longSide = LongSide)
    {
        if (frameWidth <= 0 || frameHeight <= 0 || longSide <= 0) throw new ArgumentOutOfRangeException(nameof(frameWidth), "The frame has no pixels.");
        var scale = (double)longSide / Math.Max(frameWidth, frameHeight);
        var width = Math.Max(1, (int)Math.Round(frameWidth * scale, MidpointRounding.AwayFromZero));
        var height = Math.Max(1, (int)Math.Round(frameHeight * scale, MidpointRounding.AwayFromZero));
        static int Pad(int side) => (side + Alignment - 1) / Alignment * Alignment;
        return new YuNetInput(Pad(width), Pad(height), width, height, scale);
    }

    /// <summary>The faces kept after the threshold and NMS, best score first (ties in grid order: stride 8 first, rows then columns).
    /// <paramref name="outputs"/> holds the twelve outputs by name (<see cref="OutputName"/>); throws
    /// <see cref="ArgumentException"/> when the input size is not a multiple of 32 or an output is missing or the wrong length.</summary>
    public static IReadOnlyList<YuNetFace> Decode(IReadOnlyDictionary<string, float[]> outputs, int inputWidth, int inputHeight,
        double scoreThreshold = ScoreThreshold, double nmsThreshold = NmsThreshold)
    {
        if (inputWidth <= 0 || inputHeight <= 0 || inputWidth % Alignment != 0 || inputHeight % Alignment != 0)
            throw new ArgumentException("The detector input must be a positive multiple of 32 on each side.");
        var candidates = new List<YuNetFace>();
        foreach (var stride in Strides)
        {
            var columns = inputWidth / stride;
            var rows = inputHeight / stride;
            var cells = columns * rows;
            var cls = Output(outputs, "cls", stride, cells);
            var obj = Output(outputs, "obj", stride, cells);
            var bbox = Output(outputs, "bbox", stride, cells * 4);
            var kps = Output(outputs, "kps", stride, cells * 10);
            for (var row = 0; row < rows; row++)
            {
                for (var column = 0; column < columns; column++)
                {
                    var cell = row * columns + column;
                    var score = Math.Sqrt(Math.Clamp((double)cls[cell], 0, 1) * Math.Clamp((double)obj[cell], 0, 1));
                    if (!(score >= scoreThreshold)) continue;
                    var centreX = (column + (double)bbox[cell * 4]) * stride;
                    var centreY = (row + (double)bbox[cell * 4 + 1]) * stride;
                    var width = Math.Exp(bbox[cell * 4 + 2]) * stride;
                    var height = Math.Exp(bbox[cell * 4 + 3]) * stride;
                    var points = new FramePoint[5];
                    for (var point = 0; point < 5; point++)
                        points[point] = new FramePoint((kps[cell * 10 + point * 2] + (double)column) * stride, (kps[cell * 10 + point * 2 + 1] + (double)row) * stride);
                    var face = new YuNetFace(centreX - width / 2, centreY - height / 2, width, height, Array.AsReadOnly(points), score);
                    if (double.IsFinite(face.X) && double.IsFinite(face.Y) && double.IsFinite(width) && double.IsFinite(height) &&
                        points.All(item => double.IsFinite(item.X) && double.IsFinite(item.Y))) candidates.Add(face);
                }
            }
        }
        var ordered = candidates.Select((face, index) => (face, index)).OrderByDescending(item => item.face.Score).ThenBy(item => item.index)
            .Select(item => item.face);
        var kept = new List<YuNetFace>();
        foreach (var face in ordered)
            if (kept.All(other => Iou(face, other) <= nmsThreshold)) kept.Add(face);
        return kept.AsReadOnly();
    }

    /// <summary>The face with the largest box; the first (best scoring) of equals; null for none.</summary>
    public static YuNetFace? Largest(IReadOnlyList<YuNetFace> faces)
    {
        YuNetFace? largest = null;
        foreach (var face in faces)
            if (largest is null || face.Area > largest.Area) largest = face;
        return largest;
    }

    /// <summary>The intersection over union of two boxes; 0 when either is empty.</summary>
    public static double Iou(YuNetFace a, YuNetFace b)
    {
        var width = Math.Min(a.X + a.Width, b.X + b.Width) - Math.Max(a.X, b.X);
        var height = Math.Min(a.Y + a.Height, b.Y + b.Height) - Math.Max(a.Y, b.Y);
        var intersection = Math.Max(0, width) * Math.Max(0, height);
        var union = a.Area + b.Area - intersection;
        return union > 0 && a.Width > 0 && a.Height > 0 && b.Width > 0 && b.Height > 0 ? intersection / union : 0;
    }

    private static float[] Output(IReadOnlyDictionary<string, float[]> outputs, string kind, int stride, int length)
    {
        var name = OutputName(kind, stride);
        if (!outputs.TryGetValue(name, out var values) || values.Length != length)
            throw new ArgumentException($"YuNet output {name} is missing or not {length} values long.");
        return values;
    }
}
