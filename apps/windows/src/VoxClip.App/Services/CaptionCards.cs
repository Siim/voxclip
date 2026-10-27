using System.Collections.Frozen;
using System.Globalization;
using System.Text;
using System.Text.Json;
using SkiaSharp;
using VoxClip.Core.Domain.Captions;
using VoxClip.Core.Domain.Editing;
using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Services.Settings;
using VoxClip.Media.Captions;

namespace VoxClip.App.Services;

/// <summary>Where a caption card is drawn; each surface has its own text box and size range (design §5.4.3).</summary>
public enum CardSurface { Home, Sidebar, ClipRow }

/// <summary>Where a card's words come from (design §5.4.2).</summary>
public enum CardSource { None, Transcript, Title }

/// <summary>A card's words and its key word, which gets the style's active-word or emphasis treatment.</summary>
public sealed record CardText(IReadOnlyList<string> Words, int KeyIndex, CardSource Source)
{
    /// <summary>No words: the take was never transcribed or every word in scope is cut.</summary>
    public static CardText None { get; } = new([], 0, CardSource.None);
}

/// <summary>One take's or clip's caption card, ready to draw at any size: its words in the project's own caption style.
/// <see cref="Key"/> covers everything the drawing depends on except the surface and pixel size.</summary>
public sealed record CaptionCard(string Key, CardText Text, string StyleId, string Overrides, string? Language);

/// <summary>An opaque card bitmap: premultiplied BGRA, top-left origin, <c>Width × 4</c> bytes per row.</summary>
public sealed record CardBitmap(byte[] Pixels, int Width, int Height);

/// <summary>Caption cards (design §5.4): with no frame to show, a media stand-in shows the opening caption page of the take
/// or clip in the project's own caption style. Cards are drawn by the export caption renderer (HarfBuzz layout and
/// <see cref="SkiaCaptionRasterizer"/>), never as UI text, onto stage black or the style's dark preview backdrop. They need
/// only the project file and the bundled caption resources, and are kept in memory only, in an 8 MB LRU.</summary>
internal sealed class CaptionCards(string sharedRoot)
{
    private const long CacheBytes = 8L << 20;
    private const double WordSeconds = 0.4;
    private static readonly FrozenSet<string> EnglishFillers = new[] { "so", "okay", "ok", "well", "yeah", "like" }.ToFrozenSet(StringComparer.Ordinal);
    private readonly Lazy<Library> library = new(() => Library.Load(sharedRoot));
    private readonly SemaphoreSlim renders = new(2);
    private readonly object sync = new();
    private readonly Dictionary<string, LinkedListNode<(string Key, CardBitmap Bitmap)>> cached = new(StringComparer.Ordinal);
    private readonly LinkedList<(string Key, CardBitmap Bitmap)> recency = new();
    private long cachedBytes;

    /// <summary>The card for the edited take (<paramref name="clipId"/> null) or one of its clips. A project with captions
    /// off, or an unknown style, uses <paramref name="defaultStyleId"/>.</summary>
    internal CaptionCard Card(Project project, string? clipId, string title, bool wordsVisible, string defaultStyleId)
    {
        var styles = library.Value.Styles;
        var style = styles.Find(project.Captions.StyleId) ?? styles.Find(defaultStyleId) ?? styles.Styles.FirstOrDefault();
        if (style is null) return new("", CardText.None, "", "{}", null);
        var own = style.Id == project.Captions.StyleId && project.Captions.Overrides.ValueKind == JsonValueKind.Object;
        var overrides = own ? project.Captions.Overrides.GetRawText() : "{}";
        var language = Language(project.Transcript?.Language);
        var text = Text(project, clipId, title, wordsVisible, style, library.Value.Stopwords.GetValueOrDefault(language ?? ""));
        var key = string.Join('\u001F', style.Id, overrides, language ?? "", text.Source, text.KeyIndex.ToString(CultureInfo.InvariantCulture), string.Join('\u001E', text.Words));
        return new(key, text, style.Id, overrides, language);
    }

    /// <summary>The card's words (design §5.4.2): the first caption page of the scope, laid out over the edit plan so cut
    /// words and pauses are out and corrections are in, at the style's own words per page capped at 4. Leading fillers are
    /// skipped, pages of only fillers or stopwords are skipped and trailing stopwords are trimmed; a language with no
    /// stopword list uses its first page as it is. The key word is the first number, otherwise the first content word. With
    /// words hidden, the title stands in under the same key rule. This one function stands in for the shared Core
    /// <c>CaptionCardText</c> (track opus-media-standins) and is replaced by it when that lands.</summary>
    internal static CardText Text(Project project, string? clipId, string title, bool wordsVisible, CaptionStyle style, IReadOnlySet<string>? stopwords)
    {
        IReadOnlyList<CaptionWord> words;
        try { words = KeptWords(project, clipId); }
        catch (Exception exception) when (exception is ArgumentException or InvalidOperationException or KeyNotFoundException or IndexOutOfRangeException)
        {
            // An edit list that no longer matches its transcript draws no card; the editor reports it when the project opens.
            return CardText.None;
        }
        if (words.Count == 0) return CardText.None;
        var language = Language(project.Transcript?.Language);
        bool Stop(string word) => IsStop(word, language, stopwords);
        if (!wordsVisible)
        {
            var titleWords = title.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries).Take(8).ToArray();
            return titleWords.Length == 0 ? CardText.None : new(titleWords, KeyIndex(titleWords, Stop), CardSource.Title);
        }
        var lead = 0;
        while (lead < words.Count - 1 && IsFiller(words[lead].Text, language)) lead++;
        var window = words.Skip(lead).Take(48).ToArray();
        var measured = window.Select((word, index) => new MeasuredCaptionWord(index, word.Id, word.Text, word.Text, word.Start, word.End, 0, 0, [], 0, false, null, null, null)).ToArray();
        var pages = CaptionEngine.PageWords(measured, style.Layout with { MaxWords = Math.Clamp(style.Layout.MaxWords, 1, 4) });
        foreach (var page in pages)
        {
            var texts = page.Select(index => window[index].Text).ToList();
            if (stopwords is not null && texts.All(Stop)) continue;
            while (texts.Count > 1 && Stop(texts[^1])) texts.RemoveAt(texts.Count - 1);
            return new(texts, KeyIndex(texts, Stop), CardSource.Transcript);
        }
        var first = pages[0].Select(index => window[index].Text).ToArray();
        return new(first, KeyIndex(first, Stop), CardSource.Transcript);
    }

    /// <summary>Draw <paramref name="card"/> for <paramref name="surface"/> at <paramref name="width"/> × <paramref name="height"/>
    /// device pixels: its words, or only the style's backdrop when it has none. Null when no caption style is bundled.</summary>
    internal async Task<CardBitmap?> RenderAsync(CaptionCard card, CardSurface surface, int width, int height, CancellationToken ct)
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

    private async Task<CardBitmap?> DrawAsync(CaptionCard card, CardSurface surface, int width, int height, CancellationToken ct)
    {
        var resources = library.Value;
        if (resources.Styles.Find(card.StyleId) is not { } style) return null;
        var declared = resources.Backgrounds.GetValueOrDefault(style.Id);
        if (card.Text.Words.Count == 0) return Compose(width, height, Backdrop(style, declared), null);
        var frame = new PixelSize(width, height);
        var stopwords = resources.Stopwords.GetValueOrDefault(card.Language ?? "");
        bool Stop(string word) => IsStop(word, card.Language, stopwords);
        var words = card.Text.Words.ToList();
        // The first layout resolves the project's overrides and the surface's aspect. The card then sets its own size,
        // position and plates on that resolved style and lays out again with no overrides left to apply.
        var captions = new ProjectCaptions(card.StyleId, Parse(card.Overrides), null, new Dictionary<string, CaptionPosition>());
        var resolved = (await CaptionEngine.BuildAsync(Request(style, captions, frame, words, card.Language, card.Text.KeyIndex), resources.Shaper, null, ct).ConfigureAwait(false)).Style;
        var backdrop = Backdrop(resolved, declared);
        var fit = Fit.For(surface, resolved, width, height);
        var restyled = Restyle(resolved, fit, frame, backdrop is null);
        var plain = new ProjectCaptions(card.StyleId, default, null, new Dictionary<string, CaptionPosition>());
        var reference = resolved.Font.SizeRef switch { CaptionFontSizeRefValue.Height => height, CaptionFontSizeRefValue.Width => width, _ => Math.Min(width, height) };
        while (true)
        {
            var keyIndex = KeyIndex(words, Stop);
            Task<CaptionTrack> Layout(double px) => CaptionEngine.BuildAsync(Request(restyled with
            {
                Font = restyled.Font with { SizeSh = px / reference, SizeScale = 1 },
                Layout = restyled.Layout with { MaxWords = words.Count }
            }, plain, frame, words, card.Language, keyIndex), resources.Shaper, null, ct);
            bool Fits(CaptionTrack track) => track.Pages.Count == 1 && track.Pages[0].Words.Count == track.Words.Count && !track.Pages[0].Shrunk
                && track.Pages[0].Visual.Width <= fit.BoxWidth + 0.5 && track.Pages[0].Visual.Height <= fit.BoxHeight + 0.5;
            // The largest size on the half-pixel grid that fits the text box within the line limit (design §5.4.3).
            var steps = (int)Math.Floor((fit.MaxPx - fit.MinPx) / fit.StepPx + 1e-9);
            var best = await Layout(fit.MaxPx - steps * fit.StepPx).ConfigureAwait(false);
            if (Fits(best) || words.Count == 1)
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
                var overlay = await resources.Rasterizer.RenderAsync(new(best, keyIndex * WordSeconds + 0.3, ReduceMotion: true, Scale: 1), ct).ConfigureAwait(false);
                return Compose(width, height, backdrop, overlay);
            }
            // Nothing fits at the smallest size: drop words from the end with any trailing stopwords. Never an ellipsis.
            words.RemoveAt(words.Count - 1);
            while (words.Count > 1 && Stop(words[^1])) words.RemoveAt(words.Count - 1);
        }
    }

    /// <summary>A surface's text box and size range in device pixels (design §5.4.3), scaled from the Windows sizes.</summary>
    private sealed record Fit(double BoxWidth, double BoxHeight, double Y, double MaxPx, double MinPx, double StepPx, int Lines, bool Plates)
    {
        internal static Fit For(CardSurface surface, CaptionStyle style, int width, int height)
        {
            var lines = Math.Clamp(style.Layout.MaxLines, 1, 2);
            switch (surface)
            {
                case CardSurface.Home:
                    var home = width / 226.0;
                    return new(176 * home, 71 * home, 0.5, 24 * home, 13 * home, 0.5 * home, lines, true);
                case CardSurface.ClipRow:
                    // Like a tiny 9:16 export frame: at the style's caption height, clamped to 0.60–0.78.
                    var clip = width / 27.0;
                    return new(width - 4 * clip, 15 * clip, Math.Clamp(style.Position.Y, 0.60, 0.78), 9 * clip, 4 * clip, 0.5 * clip, lines, false);
                default:
                    var row = height / 18.0;
                    return new(width - 4 * row, height - 4 * row, 0.5, 10 * row, 4 * row, 0.5 * row, lines, false);
            }
        }
    }

    /// <summary>The card's copy of a resolved style: centred in its text box, revealed whole, with no motion. At sidebar
    /// sizes plates are not drawn, a boxed key word takes its box colour and dark text meant for a light plate turns white.
    /// On stage black, near-black strokes and shadows are not drawn: they would only paint black on black.</summary>
    private static CaptionStyle Restyle(CaptionStyle style, Fit fit, PixelSize frame, bool onBlack)
    {
        var fill = !fit.Plates && style.Box is not null && style.Fill is SolidPaint solid && Luminance(solid.Color, style) < 0.05 ? new SolidPaint("#FFFFFF") : style.Fill;
        CaptionWordState? Unboxed(CaptionWordState? state) => state?.Box is { } box ? state with { Box = null, Fill = new SolidPaint(Legible(box.Color, style)) } : state;
        return style with
        {
            Aspects = null,
            Reveal = null,
            Animation = null,
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

    private static IReadOnlyList<CaptionWord> KeptWords(Project project, string? clipId)
    {
        if (project.Transcript is null || EditingEngine.FromProject(project) is not { } state) return [];
        if (clipId is not null && state.Clips.All(clip => clip.Id != clipId)) return [];
        state = state with { ActiveClipId = clipId };
        var duration = project.Media.Source.DurationSeconds;
        var plan = EditingEngine.BuildEditPlan(EditingEngine.BuildSegments(state, duration), duration, 48000, state.PauseKeepSeconds);
        return EditingEngine.CaptionWords(state, plan);
    }

    private static CaptionLayoutRequest Request(CaptionStyle style, ProjectCaptions captions, PixelSize frame, IReadOnlyList<string> words, string? language, int keyIndex) =>
        new(style, captions, frame, words.Select((text, index) => new CaptionWord($"card-{index}", text, index * WordSeconds, index * WordSeconds + 0.35)).ToArray(),
            language, words.Count * WordSeconds + 1)
        { WordHints = words.Select((_, index) => new CaptionWordHints(Emphasis: index == keyIndex)).ToArray() };

    private static JsonElement Parse(string json)
    {
        using var document = JsonDocument.Parse(json);
        return document.RootElement.Clone();
    }

    /// <summary>"en-US" → "en"; null when the transcript names no language.</summary>
    internal static string? Language(string? tag) => string.IsNullOrWhiteSpace(tag) ? null : tag.Split('-', '_')[0].Trim().ToLowerInvariant();

    private static int KeyIndex(IReadOnlyList<string> words, Func<string, bool> stop)
    {
        for (var index = 0; index < words.Count; index++) if (words[index].Any(char.IsDigit)) return index;
        for (var index = 0; index < words.Count; index++) if (!stop(words[index])) return index;
        return 0;
    }

    private static bool IsStop(string word, string? language, IReadOnlySet<string>? stopwords)
    {
        if (stopwords is null) return false;
        var key = Normalize(word);
        return stopwords.Contains(key) || IsFiller(word, language) || key.Length < 2 && !key.Any(char.IsDigit);
    }

    private static bool IsFiller(string word, string? language) => EditingAlgorithms.IsFillerText(word.Trim()) || language == "en" && EnglishFillers.Contains(Normalize(word));

    private static string Normalize(string word)
    {
        var builder = new StringBuilder(word.Length);
        foreach (var character in word.ToLowerInvariant()) if (char.IsLetterOrDigit(character)) builder.Append(character);
        return builder.ToString();
    }

    /// <summary>WCAG relative luminance of a caption colour, ignoring its alpha.</summary>
    private static double Luminance(string color, CaptionStyle style)
    {
        var (r, g, b, _) = CaptionMath.ParseColor(color, style);
        static double Linear(byte value) => value / 255.0 <= 0.03928 ? value / 255.0 / 12.92 : Math.Pow((value / 255.0 + 0.055) / 1.055, 2.4);
        return 0.2126 * Linear(r) + 0.7152 * Linear(g) + 0.0722 * Linear(b);
    }

    /// <summary>A box colour used as text on black: dark colours move 45% toward white (violet #7C3AED reads as #B793F5).</summary>
    private static string Legible(string color, CaptionStyle style)
    {
        var (r, g, b, _) = CaptionMath.ParseColor(color, style);
        if (Luminance(color, style) >= 0.18) return string.Create(CultureInfo.InvariantCulture, $"#{r:X2}{g:X2}{b:X2}");
        static byte Lift(byte value) => (byte)Math.Round(value + (255 - value) * 0.45);
        return string.Create(CultureInfo.InvariantCulture, $"#{Lift(r):X2}{Lift(g):X2}{Lift(b):X2}");
    }

    private sealed record Library(CaptionStyleLibrary Styles, FrozenDictionary<string, string> Backgrounds, FrozenDictionary<string, FrozenSet<string>> Stopwords,
        HarfBuzzGlyphShaper Shaper, SkiaCaptionRasterizer Rasterizer)
    {
        /// <summary>The bundled styles, the preview backgrounds their files declare (the decoded style fills in a default)
        /// and the stopword lists by language.</summary>
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
            var stopwords = new Dictionary<string, FrozenSet<string>>(StringComparer.Ordinal);
            using (var document = JsonDocument.Parse(File.ReadAllText(Path.Combine(root, "caption-styles", "stopwords.json"))))
                foreach (var language in document.RootElement.GetProperty("languages").EnumerateObject())
                    stopwords[language.Name] = language.Value.EnumerateArray().Select(item => item.GetString() ?? "").ToFrozenSet(StringComparer.Ordinal);
            return new(CaptionStyleLibrary.Load(root), backgrounds.ToFrozenDictionary(StringComparer.Ordinal), stopwords.ToFrozenDictionary(StringComparer.Ordinal),
                new HarfBuzzGlyphShaper(root), new SkiaCaptionRasterizer(root));
        }
    }
}
