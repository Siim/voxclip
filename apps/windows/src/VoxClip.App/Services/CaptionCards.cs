using System.Collections.Frozen;
using System.Globalization;
using System.Text.Json;
using SkiaSharp;
using VoxClip.Core.Domain.Captions;
using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Services.Settings;
using VoxClip.Media.Captions;

namespace VoxClip.App.Services;

/// <summary>One take's or clip's caption card, ready to draw at any size: Core's <see cref="CaptionCardText"/> for the scope,
/// made in <see cref="StyleId"/> with the project's caption overrides. <see cref="Key"/> covers everything the drawing
/// depends on except the surface and pixel size.</summary>
public sealed record CaptionCard(string Key, CaptionCardText Text, string StyleId, string Overrides, string? Language);

/// <summary>An opaque card bitmap: premultiplied BGRA, top-left origin, <c>Width × 4</c> bytes per row.</summary>
public sealed record CardBitmap(byte[] Pixels, int Width, int Height);

/// <summary>Caption cards (design §5.4): with no frame to show, a media stand-in shows the scope's opening caption page in
/// the project's own caption style. Core's <see cref="CaptionCardText"/> decides the words, the key word, the line limit,
/// the drop order and the drawn moment; this class only draws them, with the export caption renderer (HarfBuzz layout and
/// <see cref="SkiaCaptionRasterizer"/>), never as UI text, onto stage black or the style's dark preview backdrop. Cards need
/// only the project file and the bundled caption resources, and are kept in memory only, in an 8 MB LRU.</summary>
internal sealed class CaptionCards(string sharedRoot)
{
    private const long CacheBytes = 8L << 20;
    /// <summary>Highlight, the card style when the project's captions and the default style are both off (design §5.4.2).</summary>
    private const string FallbackStyleId = "vox-highlight";
    private readonly Lazy<Library> library = new(() => Library.Load(sharedRoot));
    private readonly SemaphoreSlim renders = new(2);
    private readonly object sync = new();
    private readonly Dictionary<string, LinkedListNode<(string Key, CardBitmap Bitmap)>> cached = new(StringComparer.Ordinal);
    private readonly LinkedList<(string Key, CardBitmap Bitmap)> recency = new();
    private long cachedBytes;

    /// <summary>The card for the edited take (<paramref name="clipId"/> null) or one stored clip, in the project's caption
    /// style; with captions off, or a style this build doesn't bundle, in <paramref name="defaultStyleId"/>, then Highlight.
    /// <paramref name="wordsVisible"/> is <c>general.showPlaceholderWords</c>.</summary>
    internal CaptionCard Card(Project project, string? clipId, bool wordsVisible, string defaultStyleId)
    {
        var resources = library.Value;
        var style = resources.Styles.Find(project.Captions.StyleId) ?? resources.Styles.Find(defaultStyleId) ?? resources.Styles.Find(FallbackStyleId);
        if (style is null) return new("", CaptionCardText.None, "", "{}", null);
        var text = CaptionCardText.Create(project, clipId is null ? CaptionCardScope.FullTake : CaptionCardScope.Clip(clipId), style, wordsVisible, resources.Shaper.Resources);
        // Core applies the project's overrides to whichever style the card uses, so the drawing does too.
        var overrides = project.Captions.Overrides.ValueKind == JsonValueKind.Object ? project.Captions.Overrides.GetRawText() : "{}";
        var language = project.Transcript?.Language;
        var key = string.Join('\u001F', style.Id, overrides, language ?? "", text.Source, text.KeyIndex.ToString(CultureInfo.InvariantCulture),
            text.StyleMaxLines.ToString(CultureInfo.InvariantCulture), text.Time.ToString("R", CultureInfo.InvariantCulture),
            string.Join('\u001E', text.Words.Select(word => word.Id + '\u001D' + word.Text)));
        return new(key, text, style.Id, overrides, language);
    }

    /// <summary>Draw <paramref name="card"/> for <paramref name="surface"/> at <paramref name="width"/> × <paramref name="height"/>
    /// device pixels: its words, or only the style's backdrop when it has none. Null when no caption style is bundled.</summary>
    internal async Task<CardBitmap?> RenderAsync(CaptionCard card, CaptionCardSurface surface, int width, int height, CancellationToken ct)
    {
        if (width < 1 || height < 1 || card.StyleId.Length == 0) return null;
        var key = string.Create(CultureInfo.InvariantCulture, $"{card.Key}\n{surface}\n{width}x{height}");
        lock (sync)
        {
            if (cached.TryGetValue(key, out var hit))
            {
                recency.Remove(hit);
                recency.AddFirst(hit);
                return hit.Value.Bitmap;
            }
        }
        await renders.WaitAsync(ct).ConfigureAwait(false);
        try
        {
            var bitmap = await Task.Run(() => DrawAsync(card, surface, width, height, ct), ct).ConfigureAwait(false);
            if (bitmap is not null) Remember(key, bitmap);
            return bitmap;
        }
        finally { renders.Release(); }
    }

    private async Task<CardBitmap?> DrawAsync(CaptionCard card, CaptionCardSurface surface, int width, int height, CancellationToken ct)
    {
        var resources = library.Value;
        if (resources.Styles.Find(card.StyleId) is not { } style) return null;
        var declared = resources.Backgrounds.GetValueOrDefault(style.Id);
        var text = card.Text;
        if (text.Words.Count == 0) return Compose(width, height, Backdrop(style, declared), null);
        var frame = new PixelSize(width, height);
        // The first layout resolves the project's overrides and the surface's aspect, so a clip row reads the style's 9:16
        // caption height. The card then sets its own size, position and plates on that resolved style and lays out again
        // with no overrides left to apply.
        var captions = new ProjectCaptions(card.StyleId, Parse(card.Overrides), null, new Dictionary<string, CaptionPosition>());
        var resolved = (await CaptionEngine.BuildAsync(new(style, captions, frame, text.LayoutWords, card.Language, text.Duration) { WordHints = text.LayoutHints },
            resources.Shaper, null, ct).ConfigureAwait(false)).Style;
        var backdrop = Backdrop(resolved, declared);
        var fit = Fit.For(surface, resolved, width, height, Math.Max(1, text.MaxLines(surface)));
        var restyled = Restyle(resolved, fit, frame, backdrop);
        var plain = new ProjectCaptions(card.StyleId, default, null, new Dictionary<string, CaptionPosition>());
        var reference = resolved.Font.SizeRef switch { CaptionFontSizeRefValue.Height => height, CaptionFontSizeRefValue.Width => width, _ => Math.Min(width, height) };
        for (var attempt = text; ;)
        {
            var words = attempt;
            Task<CaptionTrack> Layout(double px) => CaptionEngine.BuildAsync(new(restyled with
            {
                Font = restyled.Font with { SizeSh = px / reference, SizeScale = 1 },
                Layout = restyled.Layout with { MaxWords = words.Words.Count }
            }, plain, frame, words.LayoutWords, card.Language, words.Duration) { WordHints = words.LayoutHints }, resources.Shaper, null, ct);
            bool Fits(CaptionTrack track) => track.Pages.Count == 1 && track.Pages[0].Words.Count == track.Words.Count && !track.Pages[0].Shrunk
                && track.Pages[0].Visual.Width <= fit.BoxWidth + 0.5 && track.Pages[0].Visual.Height <= fit.BoxHeight + 0.5;
            // The largest size on the half-pixel grid that fits the text box within the line limit (design §5.4.3).
            var steps = (int)Math.Floor((fit.MaxPx - fit.MinPx) / fit.StepPx + 1e-9);
            var best = await Layout(fit.MaxPx - steps * fit.StepPx).ConfigureAwait(false);
            var shorter = words.DroppingLastWord();
            if (Fits(best) || shorter is null)
            {
                for (int low = 0, high = steps; low < high;)
                {
                    var middle = (low + high) / 2;
                    var track = await Layout(fit.MaxPx - middle * fit.StepPx).ConfigureAwait(false);
                    if (Fits(track)) { best = track; high = middle; }
                    else low = middle + 1;
                }
                if (!Fits(best)) best = await Layout(fit.MinPx).ConfigureAwait(false);
                if (best.Pages.Count == 0) return Compose(width, height, backdrop, null);
                // Core's drawn moment: the key word active, or a reveal style's last word (design §5.4.2). A card never animates.
                var overlay = await resources.Rasterizer.RenderAsync(new(best, words.Time, ReduceMotion: true, Scale: 1), ct).ConfigureAwait(false);
                return Compose(width, height, backdrop, overlay);
            }
            // Nothing fits at the smallest size: Core's next shorter card drops the last word and any weak words before it.
            // Never an ellipsis.
            attempt = shorter;
        }
    }

    /// <summary>A surface's text box and size range in device pixels (design §5.4.3), scaled from the Windows sizes.</summary>
    private sealed record Fit(double BoxWidth, double BoxHeight, double Y, double MaxPx, double MinPx, double StepPx, int Lines, bool Plates)
    {
        internal static Fit For(CaptionCardSurface surface, CaptionStyle style, int width, int height, int lines)
        {
            var plates = surface.DrawsPlates();
            switch (surface)
            {
                case CaptionCardSurface.HomeTile:
                    var home = width / 226.0;
                    return new(176 * home, 71 * home, 0.5, 24 * home, 13 * home, 0.5 * home, lines, plates);
                case CaptionCardSurface.HeaderChip:
                    var chip = width / 64.0;
                    return new(58 * chip, 24 * chip, 0.5, 8 * chip, 5 * chip, 0.5 * chip, lines, plates);
                case CaptionCardSurface.ClipRow:
                    // Like a tiny 9:16 export frame: at the style's caption height, clamped to 0.60–0.78.
                    var clip = width / 27.0;
                    return new(width - 4 * clip, 15 * clip, Math.Clamp(style.Position.Y, 0.60, 0.78), 9 * clip, 4 * clip, 0.5 * clip, lines, plates);
                default:
                    var row = height / 18.0;
                    return new(width - 4 * row, height - 4 * row, 0.5, 10 * row, 4 * row, 0.5 * row, lines, plates);
            }
        }
    }

    /// <summary>The card's copy of a resolved style: centred in its text box with no page breaks. Reveal and motion stay as
    /// the style has them, because the card is the style's own frame at Core's drawn moment. At sidebar sizes plates are not
    /// drawn: a boxed word takes Core's contrast-adjusted box colour and dark text meant for a light plate turns white
    /// (design §5.4.3). On stage black, near-black strokes and shadows are not drawn: they would only paint black on black.</summary>
    private static CaptionStyle Restyle(CaptionStyle style, Fit fit, PixelSize frame, SKColor? backdrop)
    {
        var onBlack = backdrop is null;
        var background = backdrop ?? SKColors.Black;
        var fill = !fit.Plates && style.Box is not null && style.Fill is SolidPaint solid && Luminance(solid.Color, style) < 0.05 ? new SolidPaint("#FFFFFF") : style.Fill;
        CaptionWordState? Unboxed(CaptionWordState? state)
        {
            if (state?.Box is not { } box) return state;
            var (red, green, blue, _) = CaptionMath.ParseColor(box.Color, style);
            var color = CaptionCardColors.SidebarKeyText((red, green, blue), (background.Red, background.Green, background.Blue));
            return state with { Box = null, Fill = new SolidPaint($"#{color.R:X2}{color.G:X2}{color.B:X2}") };
        }
        return style with
        {
            Aspects = null,
            Position = style.Position with { X = 0.5, Y = fit.Y, AnchorX = CaptionStylePositionAnchorXValue.Center, AnchorY = CaptionStylePositionAnchorYValue.Center },
            Layout = style.Layout with { MaxLines = fit.Lines, MaxLineWidthW = fit.BoxWidth / frame.Width, BreakOnSentence = false, BreakOnComma = false, BreakOnGapSec = null, MaxPageSec = null },
            Fill = fill,
            Stroke = onBlack && style.Stroke is { } stroke && Luminance(stroke.Color, style) < 0.012 ? null : style.Stroke,
            Shadows = onBlack ? style.Shadows.Where(shadow => Luminance(shadow.Color, style) >= 0.012).ToArray() : style.Shadows,
            Box = fit.Plates ? style.Box : null,
            Words = fit.Plates || style.Words is null ? style.Words : style.Words with { Past = Unboxed(style.Words.Past), Active = Unboxed(style.Words.Active), Future = Unboxed(style.Words.Future) }
        };
    }

    /// <summary>The card backdrop (design §5.4.3): a dark declared preview background (relative luminance under 0.10), or
    /// #3A3C45 behind a near-black plate, vignetted to stage black; otherwise stage black itself (null).</summary>
    private static SKColor? Backdrop(CaptionStyle style, string? declared)
    {
        var color = declared is not null && Luminance(declared, style) < 0.10 ? declared
            : style.Box is { } box && Luminance(box.Color, style) < 0.012 ? "#3A3C45" : null;
        if (color is null) return null;
        var (r, g, b, _) = CaptionMath.ParseColor(color, style);
        return new SKColor(r, g, b);
    }

    private static CardBitmap Compose(int width, int height, SKColor? backdrop, PixelBuffer? overlay)
    {
        using var target = new SKBitmap(new SKImageInfo(width, height, SKColorType.Bgra8888, SKAlphaType.Premul));
        using (var canvas = new SKCanvas(target))
        {
            canvas.Clear(SKColors.Black);
            if (backdrop is { } centre)
            {
                // A 78% × 92% ellipse at 50%, 46%, through half the colour at 42%, to stage black.
                var half = new SKColor((byte)(centre.Red / 2), (byte)(centre.Green / 2), (byte)(centre.Blue / 2));
                var matrix = SKMatrix.CreateScale(0.78f * width, 0.92f * height).PostConcat(SKMatrix.CreateTranslation(0.5f * width, 0.46f * height));
                using var shader = SKShader.CreateRadialGradient(new SKPoint(0, 0), 1, [centre, half, SKColors.Black], [0, 0.42f, 1], SKShaderTileMode.Clamp, matrix);
                using var paint = new SKPaint { Shader = shader };
                canvas.DrawRect(0, 0, width, height, paint);
            }
            if (overlay is not null && overlay.Width == width && overlay.Height == height)
            {
                using var layer = new SKBitmap(new SKImageInfo(width, height, SKColorType.Bgra8888, SKAlphaType.Premul));
                var pixels = layer.GetPixelSpan();
                for (var row = 0; row < height; row++)
                    overlay.Pixels.Span.Slice(row * overlay.Stride, width * 4).CopyTo(pixels.Slice(row * layer.RowBytes, width * 4));
                canvas.DrawBitmap(layer, 0, 0);
            }
        }
        var result = new byte[width * height * 4];
        var source = target.GetPixelSpan();
        for (var row = 0; row < height; row++) source.Slice(row * target.RowBytes, width * 4).CopyTo(result.AsSpan(row * width * 4));
        return new(result, width, height);
    }

    private void Remember(string key, CardBitmap bitmap)
    {
        lock (sync)
        {
            if (cached.ContainsKey(key)) return;
            cached[key] = recency.AddFirst((key, bitmap));
            cachedBytes += bitmap.Pixels.Length;
            while (cachedBytes > CacheBytes && recency.Last is { } oldest && oldest != recency.First)
            {
                recency.RemoveLast();
                cached.Remove(oldest.Value.Key);
                cachedBytes -= oldest.Value.Bitmap.Pixels.Length;
            }
        }
    }

    private static JsonElement Parse(string json)
    {
        using var document = JsonDocument.Parse(json);
        return document.RootElement.Clone();
    }

    /// <summary>WCAG relative luminance of a caption colour, ignoring its alpha.</summary>
    private static double Luminance(string color, CaptionStyle style)
    {
        var (r, g, b, _) = CaptionMath.ParseColor(color, style);
        static double Linear(byte value) => value / 255.0 <= 0.03928 ? value / 255.0 / 12.92 : Math.Pow((value / 255.0 + 0.055) / 1.055, 2.4);
        return 0.2126 * Linear(r) + 0.7152 * Linear(g) + 0.0722 * Linear(b);
    }

    private sealed record Library(CaptionStyleLibrary Styles, FrozenDictionary<string, string> Backgrounds, HarfBuzzGlyphShaper Shaper, SkiaCaptionRasterizer Rasterizer)
    {
        /// <summary>The bundled styles, the preview backgrounds their files declare (the decoded style fills in a default),
        /// and the renderer. The shaper's resource snapshot is the one Core makes the cards' words with.</summary>
        internal static Library Load(string root)
        {
            var backgrounds = new Dictionary<string, string>(StringComparer.Ordinal);
            foreach (var file in Directory.EnumerateFiles(Path.Combine(root, "caption-styles", "styles"), "*.json"))
            {
                using var document = JsonDocument.Parse(File.ReadAllText(file));
                var style = document.RootElement;
                if (style.TryGetProperty("id", out var id) && id.GetString() is { } styleId && style.TryGetProperty("preview", out var preview)
                    && preview.TryGetProperty("background", out var background) && background.GetString() is { } value)
                    backgrounds[styleId] = value;
            }
            return new(CaptionStyleLibrary.Load(root), backgrounds.ToFrozenDictionary(StringComparer.Ordinal), new HarfBuzzGlyphShaper(root), new SkiaCaptionRasterizer(root));
        }
    }
}
