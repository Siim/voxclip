using System.Globalization;
using System.Text;
using VoxClip.Core.Domain.Shared;

namespace VoxClip.Core.Domain.Captions;

internal static class CaptionLayoutBuilder
{
    internal static async Task<CaptionTrack> BuildAsync(CaptionLayoutRequest request, IGlyphShaper shaper, IProgress<double>? progress,
        CancellationToken ct, CaptionData data)
    {
        ct.ThrowIfCancellationRequested();
        ArgumentNullException.ThrowIfNull(shaper);
        if (request.Frame.Width <= 0 || request.Frame.Height <= 0 || !double.IsFinite(request.Duration) || request.Duration < 0) throw new ArgumentException("Invalid caption output geometry or duration.");
        var hints = request.WordHints;
        if (hints is not null && hints.Count != request.Words.Count) throw new ArgumentException("Caption word hints must match source words.", nameof(request));
        var style = CaptionStyleResolver.Resolve(request, data, out var overridesRejected);
        if (request.Captions.StyleId == "off") return new(style, request.Frame, [], [], request.Duration) { OverridesRejected = overridesRejected };
        var font = data.Fonts[style.Font.File];
        var language = CaptionTextRules.Language(request.Language);
        var emphasis = style.Emphasis ?? new();
        var emojiOptions = style.Emoji ?? new();
        var reference = style.Font.SizeRef switch { CaptionFontSizeRefValue.Height => request.Frame.Height, CaptionFontSizeRefValue.Width => request.Frame.Width, _ => Math.Min(request.Frame.Width, request.Frame.Height) };
        var font64 = Math.Max(1, CaptionMath.RoundHalfUp(style.Font.SizeSh * reference * style.Font.SizeScale * 64));
        var size = font64 / 64.0;
        var safe = CaptionStyleResolver.Safe(request.Frame);
        var pagePadding = style.Box is { Scope: CaptionBoxScopeValue.Page or CaptionBoxScopeValue.Line } box ? box.PaddingXEm * size : 0;
        var limit = Math.Min(style.Layout.MaxLineWidthW * request.Frame.Width, safe.Width - 2 * pagePadding);
        var limit64 = checked((long)Math.Floor(limit * 64));
        bool Fits(long units) => checked(units * font64) <= checked(limit64 * font.UnitsPerEm);
        var gap = style.Font.WordSpacingEm is { } spacing ? CaptionMath.RoundHalfUp(spacing * font.UnitsPerEm) : font.SpaceAdvance + CaptionMath.RoundHalfUp(style.Font.LetterSpacingEm * font.UnitsPerEm);
        var words = new List<MeasuredCaptionWord>();
        var dropped = new List<(int SourceIndex, string Text, string Reason)>();
        for (var sourceIndex = 0; sourceIndex < request.Words.Count; sourceIndex++)
        {
            ct.ThrowIfCancellationRequested();
            var word = request.Words[sourceIndex];
            if (!double.IsFinite(word.Start) || !double.IsFinite(word.End) || word.Start < 0 || word.End <= word.Start || sourceIndex > 0 && word.Start < request.Words[sourceIndex - 1].Start) throw new ArgumentException("Caption words must have valid ordered times.");
            var text = CaptionTextRules.Normalize(word.Text, style.Text, language, data);
            var measured = await MeasureAsync(text, style.Font.File, 1, style, data, shaper, request.Language ?? "und", ct).ConfigureAwait(false);
            if (measured is null)
            {
                dropped.Add((sourceIndex, word.Text, text.Length == 0 ? "empty" : "no-glyphs"));
                continue;
            }
            var letters = measured.Text.EnumerateRunes().Count(CaptionTextRules.Alnum);
            var key = CaptionTextRules.Key(measured.Text, language, data);
            var stopword = data.Stopwords.TryGetProperty(language, out var stopwords) && stopwords.EnumerateArray().Any(item => item.GetString() == key);
            var points = (measured.Text.EnumerateRunes().Any(CaptionTextRules.Digit) ? 300 : 0) + (letters >= 6 ? 100 : 0) + (stopword ? 0 : 100) + Math.Min(letters, 99);
            var manual = hints?[sourceIndex].Emphasis;
            var candidate = emphasis.Source != CaptionEmphasisSourceValue.None && (manual == true || manual is null && emphasis.Source is CaptionEmphasisSourceValue.Rule or CaptionEmphasisSourceValue.Llm && points >= CaptionMath.RoundHalfUp(emphasis.MinScore * 100));
            var emphatic = candidate ? await MeasureAsync(measured.Text, emphasis.FontFile ?? style.Font.File, emphasis.Scale, style, data, shaper, request.Language ?? "und", ct).ConfigureAwait(false) : null;
            words.Add(new(sourceIndex, word.Id, word.Text, measured.Text, word.Start, word.End, measured.Units, measured.Clusters, measured.Runs,
                points, candidate, emphatic?.Units, emphatic?.Runs, measured.Dropped));
            progress?.Report((sourceIndex + 1.0) / Math.Max(1, request.Words.Count));
        }
        bool PageFits(IReadOnlyList<int> indices)
        {
            var widths = indices.Select(index => Math.Max(words[index].Units, words[index].EmphasisUnits ?? words[index].Units)).ToArray();
            var lines = Break(widths, gap, Fits, style.Layout.Balance == CaptionLayoutBalanceValue.Balanced);
            return lines.Count <= style.Layout.MaxLines && (indices.Count == 1 || lines.All(line => Fits(Units(widths, gap, line))));
        }
        var groups = Group(words, style.Layout, PageFits);
        var pages = new List<CaptionPage>();
        var paletteIndex = 0;
        string? previousEmoji = null;
        for (var pageIndex = 0; pageIndex < groups.Count; pageIndex++)
        {
            ct.ThrowIfCancellationRequested();
            var indices = groups[pageIndex];
            var manual = indices.Where(index => emphasis.Source != CaptionEmphasisSourceValue.None && hints?[words[index].SourceIndex].Emphasis == true).ToArray();
            var selected = manual.Concat(indices.Where(index => words[index].EmphasisCandidate && hints?[words[index].SourceIndex].Emphasis is null)
                .OrderByDescending(index => words[index].EmphasisPoints).ThenBy(index => index).Take(Math.Max(0, emphasis.MaxPerPage - manual.Length))).Order().ToArray();
            var emphasised = selected.Select(index => new CaptionEmphasisedWord(index, emphasis.Palette is { Count: > 0 } palette ? palette[paletteIndex++ % palette.Count] : null)).ToArray();
            (int Word, string Codepoints)? emoji = null;
            if (emojiOptions.Enabled)
            {
                foreach (var index in indices) if (hints?[words[index].SourceIndex].Emoji is { Length: > 0 } codepoints) { emoji = (index, codepoints); break; }
                if (emoji is null && emojiOptions.MaxPerPage >= 1 && emojiOptions.Source is CaptionEmojiSourceValue.Rule or CaptionEmojiSourceValue.Llm)
                    foreach (var index in indices)
                    {
                        var codepoints = EmojiFor(CaptionTextRules.Key(words[index].Text, language, data), language, data);
                        if (codepoints is not null && codepoints != previousEmoji) { emoji = (index, codepoints); break; }
                    }
            }
            previousEmoji = emoji?.Codepoints;
            var widths = indices.Select(index => selected.Contains(index) ? words[index].EmphasisUnits ?? words[index].Units : words[index].Units).ToArray();
            var lines = Break(widths, gap, Fits, style.Layout.Balance == CaptionLayoutBalanceValue.Balanced);
            var shrunk = indices.Count == 1 && !Fits(widths[0]);
            var page64 = shrunk ? Math.Max((long)Math.Ceiling(font64 * style.Layout.MinShrink), Math.Min(font64, limit64 * font.UnitsPerEm / widths[0])) : font64;
            var start = words[indices[0]].Start;
            var end = words[indices[^1]].End + style.Layout.HoldGapSec;
            var next = pageIndex + 1 < groups.Count ? words[groups[pageIndex + 1][0]].Start : double.PositiveInfinity;
            end = Math.Min(end, next);
            if (end - start < style.Layout.MinPageSec) end = Math.Min(start + style.Layout.MinPageSec, next);
            end = Math.Min(end, request.Duration);
            pages.Add(Place(pageIndex, indices, start, end, page64, shrunk, widths, lines, gap, style, font, request.Frame, safe, emphasised, emoji));
        }
        progress?.Report(1);
        return new(style, request.Frame, words.ToArray(), pages.ToArray(), request.Duration)
        { Dropped = dropped.ToArray(), OverridesRejected = overridesRejected, FontPx64 = font64, LimitPx64 = limit64, LimitPx = limit,
          GapUnits = gap, SafeRect = safe, SafeInsets = CaptionStyleResolver.SafeInsets(request.Frame) };
    }

    internal static string? EmojiFor(string key, string language, CaptionData data)
    {
        if (!data.Emoji.TryGetProperty(language, out var table)) return null;
        if (table.TryGetProperty(key, out var exact)) return exact.GetString();
        return table.EnumerateObject().Where(property => property.Name.EndsWith('*') && property.Name.Length >= 4 && key.StartsWith(property.Name[..^1], StringComparison.Ordinal))
            .OrderByDescending(property => property.Name.Length).ThenBy(property => property.Name, StringComparer.Ordinal).Select(property => property.Value.GetString()).FirstOrDefault();
    }

    private sealed record Measurement(string Text, int Clusters, long Units, IReadOnlyList<ShapedRun> Runs, IReadOnlyList<string> Dropped);

    private static async Task<Measurement?> MeasureAsync(string text, string primary, double scale, CaptionStyle style, CaptionData data, IGlyphShaper shaper, string language, CancellationToken ct)
    {
        var reference = data.Fonts[style.Font.File];
        var cascade = new[] { primary }.Concat(style.Font.FallbackFiles).Append(data.NotoFor(data.Fonts[primary].Weight)).Distinct().ToArray();
        var runs = new List<(string File, StringBuilder Text, List<int> ClusterOf)>();
        var kept = new StringBuilder();
        var dropped = new List<string>();
        var clusterIndex = 0;
        var elements = StringInfo.GetTextElementEnumerator(text);
        while (elements.MoveNext())
        {
            var cluster = elements.GetTextElement();
            var scalars = cluster.EnumerateRunes().ToArray();
            static bool Ignorable(Rune rune) => rune.Value is 8204 or 8205 or >= 65024 and <= 65039;
            var core = scalars.Where(rune => !Ignorable(rune)).ToArray();
            if (core.Length == 0) { dropped.Add(cluster); continue; }
            var file = cascade.FirstOrDefault(file => core.All(rune => data.Fonts[file].Covers(rune.Value))) ?? cascade.FirstOrDefault(file => data.Fonts[file].Covers(core[0].Value));
            if (file is null) { dropped.Add(cluster); continue; }
            var remaining = scalars.Where(rune => Ignorable(rune) || data.Fonts[file].Covers(rune.Value)).ToArray();
            if (runs.Count == 0 || runs[^1].File != file) runs.Add((file, new(), []));
            foreach (var rune in remaining) { runs[^1].Text.Append(rune.ToString()); runs[^1].ClusterOf.Add(clusterIndex); kept.Append(rune.ToString()); }
            clusterIndex++;
        }
        if (runs.Count == 0) return null;
        var shaped = new List<ShapedRun>();
        long units = 0;
        var glyphCount = 0;
        foreach (var run in runs)
        {
            var font = data.Fonts[run.File];
            var features = style.Font.Features;
            var request = new ShapingRequest(run.File, run.Text.ToString(), font.UnitsPerEm, features.Kern, features.Liga, features.Calt);
            var output = await (shaper is ICaptionResourceShaper linguistic ? linguistic.ShapeAsync(request, language, ct) : shaper.ShapeAsync(request, ct)).ConfigureAwait(false);
            if (output.Advances.Count != output.Glyphs.Count || output.Offsets.Count != output.Glyphs.Count || output.Clusters.Count != output.Glyphs.Count || output.UnitsPerEm != font.UnitsPerEm) throw new InvalidDataException("Invalid caption glyph shaping result.");
            units += RunUnits(output, reference.UnitsPerEm);
            glyphCount += output.Glyphs.Count;
            shaped.Add(output with { Clusters = output.Clusters.Select(index => run.ClusterOf[index]).ToArray() });
        }
        if (glyphCount == 0) return null;
        units += (glyphCount - 1) * CaptionMath.RoundHalfUp(style.Font.LetterSpacingEm * reference.UnitsPerEm);
        return new(kept.ToString(), clusterIndex, scale == 1 ? units : CaptionMath.RoundHalfUp(units * scale), shaped.ToArray(), dropped.ToArray());
    }

    internal static long RunUnits(ShapedRun run, int reference)
    {
        var sum = run.Advances.Sum();
        return reference == run.UnitsPerEm ? sum : (2 * sum * reference + run.UnitsPerEm) / (2 * run.UnitsPerEm);
    }

    internal static IReadOnlyList<IReadOnlyList<int>> Group(IReadOnlyList<MeasuredCaptionWord> words, CaptionLayout layout, Func<IReadOnlyList<int>, bool> fits)
    {
        var pages = new List<IReadOnlyList<int>>();
        var current = new List<int>();
        for (var index = 0; index < words.Count; index++)
        {
            if (current.Count > 0)
            {
                var previous = words[current[^1]];
                if (current.Count >= layout.MaxWords || layout.BreakOnSentence && CaptionTextRules.Ends(previous.Raw, true)
                    || layout.BreakOnComma && current.Count >= 2 && CaptionTextRules.Ends(previous.Raw, false)
                    || layout.BreakOnGapSec is { } gap && words[index].Start - previous.End >= gap
                    || layout.MaxPageSec is { } duration && words[index].End - words[current[0]].Start > duration || !fits(current.Append(index).ToArray()))
                { pages.Add(current.ToArray()); current.Clear(); }
            }
            current.Add(index);
        }
        if (current.Count > 0) pages.Add(current.ToArray());
        return pages.ToArray();
    }

    internal static long Units(IReadOnlyList<long> widths, long gap, IReadOnlyList<int> indices) => indices.Sum(index => widths[index]) + gap * (indices.Count - 1);

    internal static IReadOnlyList<IReadOnlyList<int>> Break(IReadOnlyList<long> widths, long gap, Func<long, bool> fits, bool balanced)
    {
        if (widths.Count == 0) return [];
        var greedy = new List<IReadOnlyList<int>>();
        var current = new List<int> { 0 };
        var width = widths[0];
        for (var index = 1; index < widths.Count; index++)
        {
            if (fits(width + gap + widths[index])) { current.Add(index); width += gap + widths[index]; }
            else { greedy.Add(current.ToArray()); current = [index]; width = widths[index]; }
        }
        greedy.Add(current.ToArray());
        if (!balanced || greedy.Count is < 2 or > 3 || greedy.Any(line => !fits(Units(widths, gap, line)))) return greedy.ToArray();
        var best = greedy.ToArray();
        long bestWidth = long.MaxValue;
        for (var first = 1; first < widths.Count; first++)
        {
            for (var second = greedy.Count == 2 ? widths.Count : first + 1; second <= widths.Count; second++)
            {
                if (greedy.Count == 3 && second == widths.Count) continue;
                var candidate = greedy.Count == 2
                    ? new IReadOnlyList<int>[] { Enumerable.Range(0, first).ToArray(), Enumerable.Range(first, widths.Count - first).ToArray() }
                    : [Enumerable.Range(0, first).ToArray(), Enumerable.Range(first, second - first).ToArray(), Enumerable.Range(second, widths.Count - second).ToArray()];
                var lineWidths = candidate.Select(line => Units(widths, gap, line)).ToArray();
                if (lineWidths.All(fits) && lineWidths.Max() < bestWidth) { best = candidate; bestWidth = lineWidths.Max(); }
            }
        }
        return best;
    }

    internal static double Shift(double low, double high, double safeLow, double safeHigh) => high - low > safeHigh - safeLow ? (safeLow + safeHigh) / 2 - (low + high) / 2 : low < safeLow ? safeLow - low : high > safeHigh ? safeHigh - high : 0;

    private static CaptionPage Place(int index, IReadOnlyList<int> words, double start, double end, long font64, bool shrunk, IReadOnlyList<long> widths,
        IReadOnlyList<IReadOnlyList<int>> lines, long gap, CaptionStyle style, CaptionFontInfo font, PixelSize frame, RectD safe,
        IReadOnlyList<CaptionEmphasisedWord> emphasised, (int Word, string Codepoints)? emoji)
    {
        var size = font64 / 64.0;
        double Pixels(long units) => units * size / font.UnitsPerEm;
        var lineUnits = lines.Select(line => Units(widths, gap, line)).ToArray();
        var lineWidths = lineUnits.Select(Pixels).ToArray();
        var blockWidth = lineWidths.Max();
        var lineHeight = style.Font.LineHeightEm * size;
        var pitch = lineHeight + style.Layout.LineGapEm * size;
        var blockHeight = lineHeight + (lines.Count - 1) * pitch;
        var padded = style.Box is { Scope: CaptionBoxScopeValue.Page or CaptionBoxScopeValue.Line };
        var padX = padded ? style.Box!.PaddingXEm * size : 0;
        var padY = padded ? style.Box!.PaddingYEm * size : 0;
        var visualWidth = blockWidth + 2 * padX;
        var visualHeight = blockHeight + 2 * padY;
        var position = style.Position;
        var visualX = position.X * frame.Width - (position.AnchorX == CaptionStylePositionAnchorXValue.Left ? 0 : position.AnchorX == CaptionStylePositionAnchorXValue.Right ? visualWidth : visualWidth / 2);
        var visualY = position.Y * frame.Height - (position.AnchorY == CaptionStylePositionAnchorYValue.Top ? 0 : position.AnchorY == CaptionStylePositionAnchorYValue.Bottom ? visualHeight : visualHeight / 2);
        var emojiOptions = style.Emoji ?? new();
        var emojiSize = emoji is null ? 0 : CaptionMath.RoundHalfUp(emojiOptions.SizeEm * size);
        var clampTop = emoji is null ? visualY : visualY - emojiOptions.GapEm * size - emojiSize;
        var clampLeft = emoji is null ? visualX : Math.Min(visualX, visualX + visualWidth / 2 - emojiSize / 2.0);
        var clampRight = emoji is null ? visualX + visualWidth : Math.Max(visualX + visualWidth, visualX + visualWidth / 2 + emojiSize / 2.0);
        var shift = new PointD(Shift(clampLeft, clampRight, safe.X, safe.X + safe.Width), Shift(clampTop, visualY + visualHeight, safe.Y, safe.Y + safe.Height));
        var blockX = CaptionMath.RoundHalfUp(visualX + shift.X + padX);
        var blockY = CaptionMath.RoundHalfUp(visualY + shift.Y + padY);
        var cap = (double)font.CapHeight / font.UnitsPerEm * size;
        var outputLines = new List<CaptionLine>();
        var rectangles = new List<CaptionWordRect>();
        for (var lineIndex = 0; lineIndex < lines.Count; lineIndex++)
        {
            var top = blockY + lineIndex * pitch;
            var baseline = top + lineHeight / 2 + cap / 2;
            var lineWidth = lineWidths[lineIndex];
            var lineX = style.Layout.Align switch { CaptionLayoutAlignValue.Left => blockX, CaptionLayoutAlignValue.Right => blockX + blockWidth - lineWidth, _ => blockX + (blockWidth - lineWidth) / 2 };
            long prefix = 0;
            foreach (var local in lines[lineIndex])
            {
                var wordX = lineX + Pixels(prefix);
                var wordWidth = Pixels(widths[local]);
                rectangles.Add(new(words[local], lineIndex, wordX, top, wordWidth, lineHeight, baseline, wordX + wordWidth / 2, baseline - cap / 2));
                prefix += widths[local] + gap;
            }
            outputLines.Add(new(lines[lineIndex].Select(local => words[local]).ToArray(), lineUnits[lineIndex], lineX, top, baseline, lineWidth));
        }
        var visual = new RectD(blockX - padX, blockY - padY, visualWidth, visualHeight);
        var boxes = new List<CaptionBoxLayout>();
        if (style.Box is { } box)
        {
            CaptionBoxLayout Box(string kind, int? word, double left, double top, double width, double height) => new(kind, word, left, top, width, height, Radius(box.Pill, box.RadiusEm, width, height, size));
            if (box.Scope == CaptionBoxScopeValue.Page) boxes.Add(Box("page", null, visual.X, visual.Y, visual.Width, visual.Height));
            if (box.Scope == CaptionBoxScopeValue.Line) foreach (var line in outputLines) boxes.Add(Box("line", null, line.X - padX, line.Top - padY, line.Width + 2 * padX, lineHeight + 2 * padY));
            if (box.Scope == CaptionBoxScopeValue.Word) foreach (var rect in rectangles) boxes.Add(Box("word", rect.Word, rect.X - box.PaddingXEm * size, rect.Y - box.PaddingYEm * size, rect.W + 2 * box.PaddingXEm * size, rect.H + 2 * box.PaddingYEm * size));
        }
        var emojiRect = emoji is { } choice ? new CaptionEmojiLayout(choice.Word, choice.Codepoints,
            CaptionMath.RoundHalfUp(blockX - padX + visualWidth / 2 - emojiSize / 2.0), CaptionMath.RoundHalfUp(blockY - padY - emojiOptions.GapEm * size - emojiSize), emojiSize) : null;
        return new(index, words, start, end, font64, size, shrunk, outputLines.ToArray(), rectangles.ToArray(), new(blockX, blockY, blockWidth, blockHeight), visual, boxes.ToArray(), emphasised, emojiRect, shift)
        { LetterSpacingPx = CaptionMath.RoundHalfUp(style.Font.LetterSpacingEm * font.UnitsPerEm) * size / font.UnitsPerEm };
    }

    internal static double Radius(bool pill, double radiusEm, double width, double height, double size) => pill ? height / 2 : Math.Min(radiusEm * size, Math.Min(width / 2, height / 2));
}
