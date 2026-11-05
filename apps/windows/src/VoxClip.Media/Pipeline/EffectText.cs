using HarfBuzzSharp;
using SkiaSharp;

namespace VoxClip.Media.Pipeline;

/// <summary>One line of effect text, shaped: glyph ids, pen positions from its origin, and its advance width, in pixels.</summary>
internal sealed record EffectTextLine(string Text, ushort[] Glyphs, SKPoint[] Positions, float Width);

/// <summary>Text layout for Ask Claude's overlays from the bundled font file's own tables (HarfBuzz: advances and kerning, hhea
/// ascent and descent, OS/2 cap height), so a title or lower third sets the same on every Skia backend. Skia's own text
/// measurement depends on its font manager: Windows' DirectWrite measured a title about 20% narrower than macOS's Core Text
/// while drawing the same glyphs. Lines draw as positioned glyph runs, so what is measured is what is drawn.</summary>
internal sealed class EffectTextFont : IDisposable
{
    private readonly Blob blob;
    private readonly Face face;
    private readonly HarfBuzzSharp.Font font;
    private readonly object gate = new();

    private EffectTextFont(string path, SKTypeface typeface)
    {
        blob = Blob.FromFile(path);
        face = new Face(blob, 0);
        UnitsPerEm = face.UnitsPerEm;
        font = new HarfBuzzSharp.Font(face);
        font.SetScale(UnitsPerEm, UnitsPerEm);
        font.SetFunctionsOpenType();
        if (!font.TryGetHorizontalFontExtents(out var extents)) throw new InvalidOperationException("The font has no horizontal extents.");
        Ascender = extents.Ascender;
        Descender = -extents.Descender;
        CapHeight = font.OpenTypeMetrics.TryGetPosition(OpenTypeMetricsTag.CapHeight, out var cap) ? cap : Ascender * 0.7;
        Typeface = typeface;
    }

    /// <summary>The font's design units per em.</summary>
    internal int UnitsPerEm { get; }
    /// <summary>hhea ascender, design units, positive up.</summary>
    internal double Ascender { get; }
    /// <summary>hhea descender, design units, positive down.</summary>
    internal double Descender { get; }
    /// <summary>OS/2 cap height, design units.</summary>
    internal double CapHeight { get; }
    /// <summary>The Skia typeface of the same file, for drawing the glyphs.</summary>
    internal SKTypeface Typeface { get; }

    /// <summary>The font at <paramref name="path"/>, or null when it is missing or unreadable.</summary>
    internal static EffectTextFont? Load(string path)
    {
        if (!File.Exists(path)) return null;
        var typeface = SKTypeface.FromFile(path);
        if (typeface is null) return null;
        try { return new(path, typeface); }
        catch (Exception exception) when (exception is IOException or InvalidOperationException or ArgumentException)
        {
            typeface.Dispose();
            return null;
        }
    }

    /// <summary><paramref name="text"/> shaped at <paramref name="size"/> pixels.</summary>
    internal EffectTextLine Shape(string text, float size)
    {
        lock (gate)
        {
            using var buffer = new HarfBuzzSharp.Buffer();
            buffer.AddUtf32(text.EnumerateRunes().Select(rune => (uint)rune.Value).ToArray());
            buffer.GuessSegmentProperties();
            buffer.Direction = Direction.LeftToRight;
            font.Shape(buffer);
            var infos = buffer.GlyphInfos;
            var positions = buffer.GlyphPositions;
            var scale = size / UnitsPerEm;
            var glyphs = new ushort[infos.Length];
            var points = new SKPoint[infos.Length];
            long pen = 0;
            for (var index = 0; index < infos.Length; index++)
            {
                glyphs[index] = (ushort)infos[index].Codepoint;
                points[index] = new((pen + positions[index].XOffset) * scale, -positions[index].YOffset * scale);
                pen += positions[index].XAdvance;
            }
            return new(text, glyphs, points, pen * scale);
        }
    }

    /// <summary>The advance width of <paramref name="text"/> at <paramref name="size"/> pixels.</summary>
    internal float Width(string text, float size) => Shape(text, size).Width;

    /// <summary>The baseline that centres a line's ascent and descent on <paramref name="middle"/> (top-left y). Core Text's optical
    /// line bounds (Mac EffectFrames) span the font's ascent and descent vertically.</summary>
    internal float Baseline(float middle, float size) => middle + (float)((Ascender - Descender) / 2 * size / UnitsPerEm);

    /// <summary>The cap height at <paramref name="size"/> pixels.</summary>
    internal float CapHeightAt(float size) => (float)(CapHeight * size / UnitsPerEm);

    /// <summary>Draws <paramref name="line"/> with its origin at (<paramref name="x"/>, <paramref name="baseline"/>).</summary>
    internal void Draw(SKCanvas canvas, EffectTextLine line, float size, float x, float baseline, SKPaint paint)
    {
        if (line.Glyphs.Length == 0) return;
        using var skFont = new SKFont(Typeface, size) { Edging = SKFontEdging.Antialias, Subpixel = true };
        using var builder = new SKTextBlobBuilder();
        builder.AddPositionedRun(line.Glyphs, skFont, line.Positions);
        using var blob = builder.Build();
        if (blob is not null) canvas.DrawText(blob, x, baseline, paint);
    }

    public void Dispose()
    {
        font.Dispose(); face.Dispose(); blob.Dispose(); Typeface.Dispose();
    }
}

/// <summary>How a title sets (Mac EffectFrames.titleLayout): its lines at one size and the box around them, in output pixels,
/// top-left origin.</summary>
internal sealed record EffectTitleLayout(IReadOnlyList<EffectTextLine> Lines, float Size, float PadX, float PadY, float LineHeight, SKRectI Box)
{
    /// <summary>The lines' texts.</summary>
    internal IEnumerable<string> Texts => Lines.Select(line => line.Text);
    /// <summary>The widest line's advance width.</summary>
    internal float TextWidth => Lines.Max(line => line.Width);

    /// <summary>The most lines a title wraps into.</summary>
    internal const int MaximumLines = 3;

    private static float Rounded(double value) => (float)Math.Round(value, MidpointRounding.AwayFromZero);

    /// <summary>A title in Roboto Black: one line at 7.5% of the frame's short side when it fits 92% of the frame's width; a longer
    /// one (a hook, design §6.7) wraps into balanced lines, at most three, shrinking to 5% of the short side before it would need
    /// a fourth. The box keeps the single line's edge nearest the frame's edge (its top at the top, its bottom at the bottom)
    /// and grows inwards.</summary>
    internal static EffectTitleLayout Make(EffectTextFont font, string text, string position, int width, int height)
    {
        var shortSide = Math.Min(width, height);
        var largest = Rounded(shortSide * 0.075);
        var smallest = Math.Max(1, Rounded(shortSide * 0.05));
        var size = largest;
        var padX = size * 0.45f;
        var limit = width * 0.92f - padX * 2;
        var widths = new Dictionary<(string, float), float>();
        float Measure(string value) => widths.TryGetValue((value, size), out var cached) ? cached : widths[(value, size)] = font.Width(value, size);
        IReadOnlyList<string> texts = [text];
        if (Measure(text) > limit)
        {
            var words = text.Split(' ', StringSplitOptions.RemoveEmptyEntries);
            string Join(int start, int end) => string.Join(' ', words[start..end]);
            // Greedy lines no wider than the limit; a single word wider than it gets a line of its own and doesn't fit.
            (List<string> Lines, bool Fits) Wrap(float lineLimit)
            {
                var result = new List<string>();
                var start = 0;
                var fits = true;
                while (start < words.Length)
                {
                    var end = start + 1;
                    while (end < words.Length && Measure(Join(start, end + 1)) <= lineLimit) end++;
                    if (Measure(Join(start, end)) > lineLimit) fits = false;
                    result.Add(Join(start, end));
                    start = end;
                }
                return (result, fits);
            }
            var wrapped = Wrap(limit);
            while (!(wrapped.Fits && wrapped.Lines.Count <= MaximumLines) && size > smallest)
            {
                size = Math.Max(smallest, Rounded(size * 0.94));
                padX = size * 0.45f;
                limit = width * 0.92f - padX * 2;
                wrapped = Wrap(limit);
            }
            // Balanced: the narrowest width that still sets the same number of lines.
            float low = limit / wrapped.Lines.Count, high = limit;
            for (var step = 0; step < 12; step++)
            {
                var middle = (low + high) / 2;
                var trial = Wrap(middle);
                if (trial.Fits && trial.Lines.Count <= wrapped.Lines.Count) high = middle; else low = middle;
            }
            texts = Wrap(high).Lines;
        }
        var lines = texts.Select(line => font.Shape(line, size)).ToArray();
        var padY = size * 0.28f;
        var lineHeight = size * 1.25f;
        var boxWidth = Math.Min(width * 0.92f, lines.Max(line => line.Width) + padX * 2);
        var single = lineHeight + padY * 2;
        var boxHeight = lineHeight * lines.Length + padY * 2;
        var top = position switch
        {
            "center" => height / 2f - boxHeight / 2,
            "bottom" => height * 0.76f + single / 2 - boxHeight,
            _ => height * 0.14f - single / 2
        };
        var left = (width - boxWidth) / 2;
        var box = new SKRectI((int)Math.Floor(left), (int)Math.Floor(top), (int)Math.Ceiling(left + boxWidth), (int)Math.Ceiling(top + boxHeight));
        return new(lines, size, padX, padY, lineHeight, box);
    }
}
