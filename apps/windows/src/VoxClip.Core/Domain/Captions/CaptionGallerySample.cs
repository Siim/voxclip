using System.Globalization;
using VoxClip.Core.Domain.Editing;
using VoxClip.Core.Domain.Shared;

namespace VoxClip.Core.Domain.Captions;

/// <summary>Where a gallery tile's sample words come from; captions §15.2.</summary>
public enum CaptionGallerySampleSource
{
    /// <summary>The scope's caption page at the playhead.</summary>
    Page,
    /// <summary>The style's preview.text: the scope has no caption words, or Settings hides transcript words.</summary>
    Preview
}

/// <summary>What a caption gallery tile draws: one caption state at a fixed moment (captions §15.2–15.3, design §6.1). Pure:
/// no I/O and no rendering. The apps lay Words out over Duration with the export renderer, in the style the tile shows, and
/// draw them at Time under Reduce Motion. Word i spans [0.4 i, 0.4 i + 0.35]. The text is as stored (the corrected word, no
/// transform) and the words carry no hints, so the style's own emphasis rule applies as it does in export.</summary>
public sealed record CaptionGallerySample(CaptionGallerySampleSource Source, IReadOnlyList<CaptionWord> Words, double Time)
{
    /// <summary>The caption track duration for Words.</summary>
    public double Duration => Words.Count * 0.4 + 0.5;

    /// <summary>The tile sample of style, a library style, for a scope of the project at playhead, in the scope's edited time
    /// (captions §15.3). The words are the page the export would show (§6.1 paging with project overrides only for the selected tile, without the
    /// §6.2 fit, which needs glyph widths): the page at the playhead, the next page in a gap or before the first page, and
    /// the last page after it. Inside a word the tile is drawn in that word; otherwise at the caption card's key word and
    /// drawn moment (design §5.4.2). preview.text stands in when the scope has no caption words or wordsVisible (Settings →
    /// General → "Show transcript words on placeholders") is off; a tile never shows the project title. To follow a moving
    /// playhead, keep a CaptionGalleryPages instead.</summary>
    public static CaptionGallerySample Create(Project project, CaptionCardScope scope, double playhead, CaptionStyle style, bool wordsVisible,
        CaptionResources resources) => new CaptionGalleryPages(project, scope, style, wordsVisible, resources).Sample(playhead);

    /// <summary>The style's own sample: preview.text, split at spaces, drawn Progress (1 when absent) into word
    /// min(ActiveWord, n − 1), capped at 0.98 of it; captions §15.3.</summary>
    public static CaptionGallerySample Preview(CaptionStyle style)
    {
        ArgumentNullException.ThrowIfNull(style);
        var words = style.Preview.Text.Split(' ', StringSplitOptions.RemoveEmptyEntries)
            .Select((text, index) => new CaptionWord("preview-" + index.ToString(CultureInfo.InvariantCulture), text, index * 0.4, index * 0.4 + 0.35)).ToArray();
        var active = Math.Max(0, Math.Min(style.Preview.ActiveWord, words.Length - 1));
        return new(CaptionGallerySampleSource.Preview, words, active * 0.4 + 0.35 * Math.Min(style.Preview.Progress, 0.98));
    }
}

/// <summary>One library style's caption pages over a scope, prepared once so that each playhead is a lookup (captions §15.3).
/// Preparing plans the scope and normalises every caption word, so keep the instance while the project's transcript, edits
/// and captions, the scope, the style and the Settings switch stay the same, and call Sample as the playhead moves.</summary>
public sealed class CaptionGalleryPages
{
    /// <summary>A page's §8.1 interval on the scope's edited timeline, its sample, its words' edited times and the caption
    /// card's drawn moment for it (design §5.4.2).</summary>
    private sealed record Page(double Start, double End, IReadOnlyList<CaptionWord> Sample, double[] WordStarts, double[] WordEnds, double KeyTime);

    private readonly CaptionGallerySample preview;
    private readonly Page[] pages = [];

    /// <summary>Prepare the pages of style over a scope of the project.</summary>
    public CaptionGalleryPages(Project project, CaptionCardScope scope, CaptionStyle style, bool wordsVisible, CaptionResources resources)
    {
        ArgumentNullException.ThrowIfNull(project);
        ArgumentNullException.ThrowIfNull(scope);
        ArgumentNullException.ThrowIfNull(style);
        ArgumentNullException.ThrowIfNull(resources);
        preview = CaptionGallerySample.Preview(style);
        var overrides = style.Id == project.Captions.StyleId ? project.Captions.Overrides : default;
        if (!wordsVisible || CaptionCardText.ScopeWords.Create(project, scope, style, overrides, resources) is not { Words.Count: > 0 } copy) return;
        var words = copy.Words;
        var layout = copy.Style.Layout;
        var groups = CaptionLayoutBuilder.Group(words.Count, layout, index => words[index].Raw, index => words[index].Start, index => words[index].End, _ => true);
        pages = groups.Select((group, index) =>
        {
            var page = group.Select(position => words[position]).ToArray();
            var next = index + 1 < groups.Count ? words[groups[index + 1][0]].Start : double.PositiveInfinity;
            var end = CaptionLayoutBuilder.PageEnd(page[0].Start, page[^1].End, next, layout, copy.Duration);
            var sample = page.Select((word, position) => new CaptionWord(word.Id, word.Text, position * 0.4, position * 0.4 + 0.35)).ToArray();
            return new Page(page[0].Start, end, sample, page.Select(word => word.Start).ToArray(), page.Select(word => word.End).ToArray(),
                copy.Card(CaptionCardSource.Transcript, page).Time);
        }).ToArray();
    }

    /// <summary>The tile sample at playhead, in the scope's edited time; a playhead that is not finite counts as 0.</summary>
    public CaptionGallerySample Sample(double playhead)
    {
        if (pages.Length == 0) return preview;
        var time = double.IsFinite(playhead) ? playhead : 0;
        // Upper bound of the starts: one binary search gives both the visible and the following page (§8.2).
        var lower = 0;
        var upper = pages.Length;
        while (lower < upper)
        {
            var middle = lower + (upper - lower) / 2;
            if (pages[middle].Start <= time) lower = middle + 1;
            else upper = middle;
        }
        var visible = lower > 0 && time < pages[lower - 1].End;
        var current = pages[visible ? lower - 1 : Math.Min(lower, pages.Length - 1)];
        // §8.2: the active word is the page's last word that has started; the playhead is inside it until it ends.
        var active = Array.FindLastIndex(current.WordStarts, start => start <= time);
        if (visible && active >= 0 && time < current.WordEnds[active]) return new(CaptionGallerySampleSource.Page, current.Sample, active * 0.4 + 0.35 * 0.98);
        return new(CaptionGallerySampleSource.Page, current.Sample, current.KeyTime);
    }
}
