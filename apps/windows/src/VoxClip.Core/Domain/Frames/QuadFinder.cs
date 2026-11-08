using VoxClip.Core.Domain.Captions;
using VoxClip.Core.Domain.Effects;

namespace VoxClip.Core.Domain.Frames;

/// <summary>The quad finder's settings in one place. The first six are the Mac's <c>VNDetectRectanglesRequest</c> settings
/// (<c>AppleFrameVision</c>), named after Vision's properties; the rest are how Windows finds the quads (ADR-R48 Windows, W4).</summary>
public static class QuadFinderSettings
{
    /// <summary>Vision's <c>maximumObservations</c>: at most this many quads, the most confident first.</summary>
    public const int MaximumObservations = 6;
    /// <summary>Vision's <c>minimumAspectRatio</c>: the short side over the long side (the mean of each pair of opposite sides).</summary>
    public const double MinimumAspectRatio = 0.3;
    /// <summary>Vision's <c>maximumAspectRatio</c>.</summary>
    public const double MaximumAspectRatio = 1;
    /// <summary>Vision's <c>minimumSize</c>: the quad's short side over the frame's short side.</summary>
    public const double MinimumSize = 0.1;
    /// <summary>Vision's <c>minimumConfidence</c>. Here the confidence is edge support: the mean, over the four sides, of the
    /// share of points along the side with an edge across it within <see cref="SupportReach"/> pixels.</summary>
    public const double MinimumConfidence = 0.6;
    /// <summary>Vision's <c>quadratureTolerance</c>, degrees: every corner within this of a right angle.</summary>
    public const double QuadratureTolerance = 25;

    /// <summary>Quads are found on the grey frame scaled (box-averaged) to this many pixels on its long side; a smaller frame is
    /// used as it is.</summary>
    public const int WorkingLongSide = 640;
    /// <summary>A pixel is an edge when its Sobel magnitude (|gx| + |gy|, on the 3×3-binomial-smoothed 0–255 grey) is at least
    /// this: a sharp step of about 16 grey levels. A soft gradient stays well under it.</summary>
    public const int EdgeThreshold = 48;
    /// <summary>The grey levels whose regions (above and below each) give candidate outlines, besides the edge pixels' own
    /// regions: a screen brighter or darker than what is around it by at least 32 levels has a level between.</summary>
    public static IReadOnlyList<int> Levels { get; } = [32, 64, 96, 128, 160, 192, 224];
    /// <summary>How far across a side, in pixels either way, an edge counts as supporting it.</summary>
    public const int SupportReach = 2;
    /// <summary>An edge supports a side only when its gradient points within 45° of the side's normal.</summary>
    public const double SupportDirection = 0.5;
    /// <summary>The outline's convex hull must fill at least this share of the quad around it, so an ellipse (π/4) or a
    /// rounded blob is no quad.</summary>
    public const double MinimumFill = 0.9;
    /// <summary>Quads whose bounding boxes' edges are all within this many pixels of each other are one outline found twice
    /// (at two grey levels, or as edges and as a region); the more confident stays. A screen inside its bezel is further in.</summary>
    public const int DuplicateReach = 4;
    /// <summary>At most this many outlines per region map are looked at, the largest first.</summary>
    public const int MaximumCandidates = 48;
}

/// <summary>A convex quadrilateral found in a frame: its corners in picture space (normalized, top-left origin), clockwise from
/// the top-left one as seen, and its edge-support confidence, 0–1.</summary>
public sealed record FrameQuad(FramePoint TopLeft, FramePoint TopRight, FramePoint BottomRight, FramePoint BottomLeft, double Confidence)
{
    /// <summary>The corners' bounding box in picture space, clamped to the frame: what the Mac passes from Vision's
    /// <c>boundingBox</c> to <c>FrameScreens.detect</c>.</summary>
    public ClipEffectRect BoundingBox
    {
        get
        {
            var left = Math.Min(Math.Min(TopLeft.X, TopRight.X), Math.Min(BottomRight.X, BottomLeft.X));
            var right = Math.Max(Math.Max(TopLeft.X, TopRight.X), Math.Max(BottomRight.X, BottomLeft.X));
            var top = Math.Min(Math.Min(TopLeft.Y, TopRight.Y), Math.Min(BottomRight.Y, BottomLeft.Y));
            var bottom = Math.Max(Math.Max(TopLeft.Y, TopRight.Y), Math.Max(BottomRight.Y, BottomLeft.Y));
            return FrameRect.Clamped(new(left, top, right - left, bottom - top));
        }
    }
}

/// <summary>Screens, slides and other rectangles in a frame, the Windows stand-in for Vision's <c>VNDetectRectanglesRequest</c>
/// (ADR-R48 Windows, W4). Pure and deterministic: integer image maths, then IEEE doubles for the corner checks.
/// <list type="number">
/// <item>The frame becomes grey, box-averaged to <see cref="QuadFinderSettings.WorkingLongSide"/>, then smoothed (3×3 binomial).</item>
/// <item>Sobel gives each pixel's gradient; strong ones are edges.</item>
/// <item>Outlines: the 4-connected regions of the edge pixels, and of the pixels above and below each of
/// <see cref="QuadFinderSettings.Levels"/>. Each region's outer contour (its rows' extreme pixel edges) gives a convex hull.</item>
/// <item>The hull is simplified to the quad around it (<see cref="Enclosing"/>).</item>
/// <item>The quad is kept when it passes Vision's settings and the hull fills <see cref="QuadFinderSettings.MinimumFill"/> of it.</item>
/// </list>
/// One instance per decoding lane: it reuses its buffers and is not thread-safe.</summary>
public sealed class QuadFinder
{
    private const byte Ignored = 255;
    private int width;
    private int height;
    private byte[] grey = [];
    private byte[] smooth = [];
    private short[] gradientX = [];
    private short[] gradientY = [];
    private byte[] classes = [];
    private int[] labels = [];
    private int[] parent = [];
    private int[] sums = [];
    private int[] counts = [];
    private int[] rowMin = [];
    private int[] rowMax = [];
    private long[] points = [];
    private int[] regionBoxes = [];
    private int[] slots = [];
    private int[] compact = [];

    /// <summary>The quads in a premultiplied BGRA frame (as <c>CurrentFrames</c> decodes it, upright), grey = (77 R + 150 G +
    /// 29 B + 128) / 256.</summary>
    public IReadOnlyList<FrameQuad> Find(PixelBuffer frame)
    {
        ArgumentNullException.ThrowIfNull(frame);
        if (frame.Width <= 0 || frame.Height <= 0 || frame.Stride < frame.Width * 4 || frame.Pixels.Length < (long)frame.Stride * (frame.Height - 1) + frame.Width * 4)
            throw new ArgumentException("The frame is not BGRA pixels of its size.", nameof(frame));
        Prepare(frame.Width, frame.Height);
        var source = frame.Pixels.Span;
        for (var y = 0; y < frame.Height; y++)
        {
            var row = source.Slice(y * frame.Stride, frame.Width * 4);
            var target = y * height / frame.Height * width;
            for (var x = 0; x < frame.Width; x++)
            {
                var luma = (77 * row[x * 4 + 2] + 150 * row[x * 4 + 1] + 29 * row[x * 4] + 128) >> 8;
                var index = target + x * width / frame.Width;
                sums[index] += luma;
                counts[index]++;
            }
        }
        return Run();
    }

    /// <summary>The quads in a grey frame of <paramref name="frameWidth"/> × <paramref name="frameHeight"/> bytes, rows packed.</summary>
    public IReadOnlyList<FrameQuad> Find(ReadOnlySpan<byte> frame, int frameWidth, int frameHeight)
    {
        if (frameWidth <= 0 || frameHeight <= 0 || frame.Length != (long)frameWidth * frameHeight)
            throw new ArgumentException("The frame is not grey pixels of its size.", nameof(frame));
        Prepare(frameWidth, frameHeight);
        for (var y = 0; y < frameHeight; y++)
        {
            var target = y * height / frameHeight * width;
            for (var x = 0; x < frameWidth; x++)
            {
                var index = target + x * width / frameWidth;
                sums[index] += frame[y * frameWidth + x];
                counts[index]++;
            }
        }
        return Run();
    }

    /// <summary>The working size for a frame, and buffers for it.</summary>
    private void Prepare(int frameWidth, int frameHeight)
    {
        var longSide = Math.Max(frameWidth, frameHeight);
        int w = frameWidth, h = frameHeight;
        if (longSide > QuadFinderSettings.WorkingLongSide)
        {
            w = Math.Max(1, (int)(((long)frameWidth * QuadFinderSettings.WorkingLongSide + longSide / 2) / longSide));
            h = Math.Max(1, (int)(((long)frameHeight * QuadFinderSettings.WorkingLongSide + longSide / 2) / longSide));
        }
        if (w != width || h != height)
        {
            width = w;
            height = h;
            var size = w * h;
            grey = new byte[size];
            smooth = new byte[size];
            gradientX = new short[size];
            gradientY = new short[size];
            classes = new byte[size];
            labels = new int[size];
            parent = new int[size + 1];
            sums = new int[size];
            counts = new int[size];
            rowMin = new int[QuadFinderSettings.MaximumCandidates * h];
            rowMax = new int[QuadFinderSettings.MaximumCandidates * h];
            points = new long[4 * h];
        }
        Array.Clear(sums);
        Array.Clear(counts);
    }

    private IReadOnlyList<FrameQuad> Run()
    {
        var size = width * height;
        for (var index = 0; index < size; index++)
            grey[index] = (byte)(counts[index] == 0 ? 0 : (sums[index] + counts[index] / 2) / counts[index]);
        if (width < 3 || height < 3) return [];
        Smooth();
        Gradients();
        var found = new List<Candidate>();
        // The edge pixels' own regions: an outline drawn by the frame's edges.
        for (var index = 0; index < size; index++) classes[index] = IsEdge(index) ? (byte)1 : Ignored;
        Outlines(found);
        foreach (var level in QuadFinderSettings.Levels)
        {
            for (var index = 0; index < size; index++) classes[index] = smooth[index] >= level ? (byte)1 : (byte)0;
            Outlines(found);
        }
        // The most confident first; then the larger, then the top-left, so the order never depends on how it was found.
        found.Sort((a, b) =>
        {
            var order = b.Confidence.CompareTo(a.Confidence);
            if (order == 0) order = b.Area.CompareTo(a.Area);
            if (order == 0) order = a.Box.Y.CompareTo(b.Box.Y);
            if (order == 0) order = a.Box.X.CompareTo(b.Box.X);
            return order;
        });
        var kept = new List<Candidate>();
        foreach (var candidate in found)
        {
            if (kept.Count == QuadFinderSettings.MaximumObservations) break;
            if (kept.Any(other => Same(other.Box, candidate.Box))) continue;
            kept.Add(candidate);
        }
        return kept.Select(Normalised).ToArray();
    }

    private static bool Same(ClipEffectRect a, ClipEffectRect b) =>
        Math.Abs(a.X - b.X) <= QuadFinderSettings.DuplicateReach && Math.Abs(a.Y - b.Y) <= QuadFinderSettings.DuplicateReach
        && Math.Abs(a.X + a.Width - b.X - b.Width) <= QuadFinderSettings.DuplicateReach
        && Math.Abs(a.Y + a.Height - b.Y - b.Height) <= QuadFinderSettings.DuplicateReach;

    private bool IsEdge(int index) => Math.Abs(gradientX[index]) + Math.Abs(gradientY[index]) >= QuadFinderSettings.EdgeThreshold;

    /// <summary>The grey smoothed by [1 2 1]ᵀ[1 2 1] / 16, edges repeated.</summary>
    private void Smooth()
    {
        for (var y = 0; y < height; y++)
        {
            var up = Math.Max(0, y - 1) * width;
            var row = y * width;
            var down = Math.Min(height - 1, y + 1) * width;
            for (var x = 0; x < width; x++)
            {
                var left = Math.Max(0, x - 1);
                var right = Math.Min(width - 1, x + 1);
                var total = grey[up + left] + 2 * grey[up + x] + grey[up + right]
                    + 2 * (grey[row + left] + 2 * grey[row + x] + grey[row + right])
                    + grey[down + left] + 2 * grey[down + x] + grey[down + right];
                smooth[row + x] = (byte)((total + 8) >> 4);
            }
        }
    }

    /// <summary>Sobel on the smoothed grey; 0 on the frame's outer pixels.</summary>
    private void Gradients()
    {
        Array.Clear(gradientX);
        Array.Clear(gradientY);
        for (var y = 1; y < height - 1; y++)
        {
            for (var x = 1; x < width - 1; x++)
            {
                var i = y * width + x;
                int a = smooth[i - width - 1], b = smooth[i - width], c = smooth[i - width + 1];
                int d = smooth[i - 1], f = smooth[i + 1];
                int g = smooth[i + width - 1], h = smooth[i + width], k = smooth[i + width + 1];
                gradientX[i] = (short)(c + 2 * f + k - a - 2 * d - g);
                gradientY[i] = (short)(g + 2 * h + k - a - 2 * b - c);
            }
        }
    }

    /// <summary>Labels the 4-connected regions of equal class (except <see cref="Ignored"/>) and adds the quads of the largest
    /// ones big enough to hold one.</summary>
    private void Outlines(List<Candidate> found)
    {
        var count = Label();
        if (count == 0) return;
        var minimumSide = QuadFinderSettings.MinimumSize * Math.Min(width, height);
        // Region bounding boxes: left, top, right, bottom per label.
        if (regionBoxes.Length < count * 4) regionBoxes = new int[Math.Max(count * 4, 1024)];
        var boxes = regionBoxes;
        for (var label = 0; label < count; label++)
        {
            boxes[label * 4] = int.MaxValue;
            boxes[label * 4 + 1] = int.MaxValue;
            boxes[label * 4 + 2] = -1;
            boxes[label * 4 + 3] = -1;
        }
        for (var y = 0; y < height; y++)
        {
            for (var x = 0; x < width; x++)
            {
                var label = labels[y * width + x] - 1;
                if (label < 0) continue;
                var at = label * 4;
                if (x < boxes[at]) boxes[at] = x;
                if (y < boxes[at + 1]) boxes[at + 1] = y;
                if (x > boxes[at + 2]) boxes[at + 2] = x;
                if (y > boxes[at + 3]) boxes[at + 3] = y;
            }
        }
        var chosen = new List<(int Label, long Area)>();
        for (var label = 0; label < count; label++)
        {
            var at = label * 4;
            int boxWidth = boxes[at + 2] - boxes[at] + 1, boxHeight = boxes[at + 3] - boxes[at + 1] + 1;
            if (boxWidth + 2 < minimumSide || boxHeight + 2 < minimumSide) continue;
            chosen.Add((label, (long)boxWidth * boxHeight));
        }
        if (chosen.Count == 0) return;
        chosen.Sort((a, b) => a.Area != b.Area ? b.Area.CompareTo(a.Area) : a.Label.CompareTo(b.Label));
        if (chosen.Count > QuadFinderSettings.MaximumCandidates) chosen.RemoveRange(QuadFinderSettings.MaximumCandidates, chosen.Count - QuadFinderSettings.MaximumCandidates);
        if (slots.Length < count) slots = new int[Math.Max(count, 256)];
        var slot = slots;
        Array.Fill(slot, -1, 0, count);
        for (var index = 0; index < chosen.Count; index++) slot[chosen[index].Label] = index;
        Array.Fill(rowMin, int.MaxValue, 0, chosen.Count * height);
        Array.Fill(rowMax, -1, 0, chosen.Count * height);
        for (var y = 0; y < height; y++)
        {
            for (var x = 0; x < width; x++)
            {
                var label = labels[y * width + x] - 1;
                if (label < 0 || slot[label] < 0) continue;
                var at = slot[label] * height + y;
                if (x < rowMin[at]) rowMin[at] = x;
                if (x > rowMax[at]) rowMax[at] = x;
            }
        }
        for (var index = 0; index < chosen.Count; index++)
            if (Quad(index) is { } candidate) found.Add(candidate);
    }

    /// <summary>Two-pass union-find labelling; labels are 1… in raster order of first pixel, 0 for ignored pixels.</summary>
    private int Label()
    {
        var next = 0;
        parent[0] = 0;
        for (var y = 0; y < height; y++)
        {
            for (var x = 0; x < width; x++)
            {
                var i = y * width + x;
                var kind = classes[i];
                if (kind == Ignored)
                {
                    labels[i] = 0;
                    continue;
                }
                var left = x > 0 && classes[i - 1] == kind ? labels[i - 1] : 0;
                var up = y > 0 && classes[i - width] == kind ? labels[i - width] : 0;
                if (left == 0 && up == 0)
                {
                    next++;
                    parent[next] = next;
                    labels[i] = next;
                }
                else if (left != 0 && up != 0)
                {
                    int a = Root(left), b = Root(up);
                    if (a != b)
                    {
                        if (a < b) parent[b] = a;
                        else parent[a] = b;
                    }
                    labels[i] = Math.Min(a, b);
                }
                else labels[i] = left != 0 ? left : up;
            }
        }
        // Roots become compact labels 1…count, in the order their regions start.
        if (compact.Length < next + 1) compact = new int[Math.Max(next + 1, 1024)];
        compact[0] = 0;
        var count = 0;
        for (var label = 1; label <= next; label++)
        {
            var root = Root(label);
            if (root == label) compact[label] = ++count;
        }
        for (var label = 1; label <= next; label++) compact[label] = compact[Root(label)];
        for (var i = 0; i < width * height; i++) labels[i] = compact[labels[i]];
        return count;
    }

    private int Root(int label)
    {
        while (parent[label] != label)
        {
            parent[label] = parent[parent[label]];
            label = parent[label];
        }
        return label;
    }

    /// <summary>The quad of one chosen region, or null when it is none: the convex hull of its rows' outer pixel corners,
    /// simplified to the four-cornered polygon around it and checked against Vision's settings.</summary>
    private Candidate? Quad(int slotIndex)
    {
        var used = 0;
        for (var y = 0; y < height; y++)
        {
            var at = slotIndex * height + y;
            if (rowMax[at] < 0) continue;
            long left = rowMin[at], right = rowMax[at] + 1L;
            points[used++] = (left << 20) | (long)y;
            points[used++] = (left << 20) | (y + 1L);
            points[used++] = (right << 20) | (long)y;
            points[used++] = (right << 20) | (y + 1L);
        }
        var hull = Hull(points.AsSpan(0, used));
        if (hull.Count < 4) return null;
        var hullArea = Area(hull) / 2.0;
        if (Enclosing(hull) is not { } corners) return null;
        var quadArea = Area(corners);
        if (!(hullArea > 0) || hullArea < QuadFinderSettings.MinimumFill * quadArea) return null;
        if (!Rectangular(corners)) return null;
        double first = (Length(corners[0], corners[1]) + Length(corners[2], corners[3])) / 2;
        double second = (Length(corners[1], corners[2]) + Length(corners[3], corners[0])) / 2;
        var shortSide = Math.Min(first, second);
        var aspect = shortSide / Math.Max(first, second);
        if (aspect < QuadFinderSettings.MinimumAspectRatio || aspect > QuadFinderSettings.MaximumAspectRatio) return null;
        if (shortSide < QuadFinderSettings.MinimumSize * Math.Min(width, height)) return null;
        var confidence = 0.0;
        for (var side = 0; side < 4; side++) confidence += Support(corners[side], corners[(side + 1) % 4]);
        confidence /= 4;
        if (confidence < QuadFinderSettings.MinimumConfidence) return null;
        var minimumX = corners.Min(point => point.X);
        var minimumY = corners.Min(point => point.Y);
        var box = new ClipEffectRect(minimumX, minimumY, corners.Max(point => point.X) - minimumX, corners.Max(point => point.Y) - minimumY);
        return new(corners, confidence, quadArea, box);
    }

    /// <summary>The hull simplified to four corners: the edge whose removal adds the least area goes, its two neighbours extended
    /// to meet, until four edges remain. So a rounded corner's short edges go and the straight sides meet where the corner would
    /// be, as Vision reports a rounded phone. Null when no edge can go (its neighbours never meet ahead of it).</summary>
    internal static (double X, double Y)[]? Enclosing(IReadOnlyList<(long X, long Y)> hull)
    {
        var corners = hull.Select(point => (X: (double)point.X, Y: (double)point.Y)).ToList();
        while (corners.Count > 4)
        {
            var best = -1;
            var smallest = double.PositiveInfinity;
            (double X, double Y) meeting = default;
            for (var index = 0; index < corners.Count; index++)
            {
                var before = corners[(index + corners.Count - 1) % corners.Count];
                var start = corners[index];
                var end = corners[(index + 1) % corners.Count];
                var after = corners[(index + 2) % corners.Count];
                double inX = start.X - before.X, inY = start.Y - before.Y, outX = after.X - end.X, outY = after.Y - end.Y;
                double edgeX = end.X - start.X, edgeY = end.Y - start.Y;
                var turn = inX * outY - inY * outX;
                if (turn == 0) continue;
                var along = (edgeX * outY - edgeY * outX) / turn;
                var back = (inX * edgeY - inY * edgeX) / turn;
                if (!(along >= 0) || !(back >= 0)) continue;
                (double X, double Y) point = (start.X + along * inX, start.Y + along * inY);
                var added = Math.Abs((point.X - start.X) * edgeY - (point.Y - start.Y) * edgeX) / 2;
                if (added < smallest)
                {
                    smallest = added;
                    best = index;
                    meeting = point;
                }
            }
            if (best < 0) return null;
            corners[best] = meeting;
            corners.RemoveAt((best + 1) % corners.Count);
        }
        return corners.ToArray();
    }

    /// <summary>The polygon's area.</summary>
    private static double Area(IReadOnlyList<(double X, double Y)> polygon)
    {
        var total = 0.0;
        for (var index = 0; index < polygon.Count; index++)
        {
            var a = polygon[index];
            var b = polygon[(index + 1) % polygon.Count];
            total += a.X * b.Y - b.X * a.Y;
        }
        return Math.Abs(total) / 2;
    }

    /// <summary>Every corner within <see cref="QuadFinderSettings.QuadratureTolerance"/> of a right angle (the hull's corners are
    /// convex, so |cos| ≤ sin(tolerance) is enough).</summary>
    internal static bool Rectangular(IReadOnlyList<(double X, double Y)> corners)
    {
        var limit = Math.Sin(QuadFinderSettings.QuadratureTolerance * Math.PI / 180);
        for (var index = 0; index < 4; index++)
        {
            var at = corners[index];
            var previous = corners[(index + 3) % 4];
            var next = corners[(index + 1) % 4];
            double ax = previous.X - at.X, ay = previous.Y - at.Y, bx = next.X - at.X, by = next.Y - at.Y;
            var lengths = Math.Sqrt(ax * ax + ay * ay) * Math.Sqrt(bx * bx + by * by);
            if (!(lengths > 0) || Math.Abs(ax * bx + ay * by) > limit * lengths) return false;
        }
        return true;
    }

    /// <summary>The share of points along a side, one per pixel of its length, with an edge across it within
    /// <see cref="QuadFinderSettings.SupportReach"/> pixels: an edge pixel whose gradient points within 45° of the side's
    /// normal.</summary>
    private double Support((double X, double Y) from, (double X, double Y) to)
    {
        double dx = to.X - from.X, dy = to.Y - from.Y;
        var length = Math.Sqrt(dx * dx + dy * dy);
        if (!(length > 0)) return 0;
        double normalX = -dy / length, normalY = dx / length;
        var samples = Math.Max(4, (int)length);
        var supported = 0;
        for (var sample = 0; sample < samples; sample++)
        {
            var t = (sample + 0.5) / samples;
            double x = from.X + t * dx, y = from.Y + t * dy;
            for (var step = -QuadFinderSettings.SupportReach; step <= QuadFinderSettings.SupportReach; step++)
            {
                var px = (int)Math.Floor(x + step * normalX);
                var py = (int)Math.Floor(y + step * normalY);
                if (px < 0 || py < 0 || px >= width || py >= height) continue;
                var i = py * width + px;
                if (!IsEdge(i)) continue;
                double gx = gradientX[i], gy = gradientY[i];
                var across = gx * normalX + gy * normalY;
                if (across * across < QuadFinderSettings.SupportDirection * (gx * gx + gy * gy)) continue;
                supported++;
                break;
            }
        }
        return (double)supported / samples;
    }

    /// <summary>The convex hull of packed (x &lt;&lt; 20 | y) points, without collinear points, in the order (y down) top-left
    /// → … clockwise as seen (Andrew's monotone chain).</summary>
    private static List<(long X, long Y)> Hull(Span<long> packed)
    {
        packed.Sort();
        var hull = new List<(long X, long Y)>(16);
        for (var pass = 0; pass < 2; pass++)
        {
            var start = hull.Count;
            for (var step = 0; step < packed.Length; step++)
            {
                var value = packed[pass == 0 ? step : packed.Length - 1 - step];
                (long X, long Y) point = (value >> 20, value & 0xFFFFF);
                while (hull.Count >= start + 2 && Cross(hull[^2], hull[^1], point) <= 0) hull.RemoveAt(hull.Count - 1);
                hull.Add(point);
            }
            hull.RemoveAt(hull.Count - 1);
        }
        return hull;
    }

    private static long Cross((long X, long Y) o, (long X, long Y) a, (long X, long Y) b) =>
        (a.X - o.X) * (b.Y - o.Y) - (a.Y - o.Y) * (b.X - o.X);

    /// <summary>Twice the polygon's area.</summary>
    private static long Area(List<(long X, long Y)> polygon)
    {
        long total = 0;
        for (var index = 0; index < polygon.Count; index++)
        {
            var a = polygon[index];
            var b = polygon[(index + 1) % polygon.Count];
            total += a.X * b.Y - b.X * a.Y;
        }
        return Math.Abs(total);
    }

    private static double Length((double X, double Y) a, (double X, double Y) b) => Math.Sqrt((a.X - b.X) * (a.X - b.X) + (a.Y - b.Y) * (a.Y - b.Y));

    /// <summary>The quad in picture space, corners clockwise as seen from the one nearest the top-left.</summary>
    private FrameQuad Normalised(Candidate candidate)
    {
        var corners = candidate.Corners;
        var start = 0;
        for (var index = 1; index < 4; index++)
            if (corners[index].X + corners[index].Y < corners[start].X + corners[start].Y) start = index;
        // The hull runs clockwise as seen with y down; Point(i) walks it from the top-left corner.
        FramePoint Point(int offset)
        {
            var corner = corners[(start + offset) % 4];
            return new(corner.X / width, corner.Y / height);
        }
        var clockwise = IsClockwise(corners);
        return clockwise
            ? new(Point(0), Point(1), Point(2), Point(3), candidate.Confidence)
            : new(Point(0), Point(3), Point(2), Point(1), candidate.Confidence);
    }

    /// <summary>Clockwise as seen (y down): the shoelace sum is positive.</summary>
    private static bool IsClockwise(IReadOnlyList<(double X, double Y)> corners)
    {
        var total = 0.0;
        for (var index = 0; index < 4; index++)
        {
            var a = corners[index];
            var b = corners[(index + 1) % 4];
            total += a.X * b.Y - b.X * a.Y;
        }
        return total > 0;
    }

    private sealed record Candidate((double X, double Y)[] Corners, double Confidence, double Area, ClipEffectRect Box);
}
