using System.Globalization;
using System.Text.Json;
using VoxClip.Core.Domain.Editing;
using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Domain.VoiceLab;

namespace VoxClip.Core.Domain.Captions;

/// <summary>The part of a take a caption card shows: the full take or one stored clip; design §5.4.2.</summary>
public sealed record CaptionCardScope(string? ClipId)
{
    /// <summary>The edited full take, as Home tiles and the Full take row show it.</summary>
    public static CaptionCardScope FullTake { get; } = new((string?)null);
    /// <summary>One stored clip, as its clip row shows it.</summary>
    public static CaptionCardScope Clip(string id) => new(id);
}

/// <summary>Where a caption card's words come from; design §5.4.2. None means there is no card (stage black).</summary>
public enum CaptionCardSource
{
    /// <summary>The scope's opening caption page.</summary>
    Transcript,
    /// <summary>The project title, while Settings hides transcript words.</summary>
    Title,
    /// <summary>No transcript, or no captionable word in the scope.</summary>
    None
}

/// <summary>The surfaces that draw caption cards; design §5.4.3.</summary>
public enum CaptionCardSurface
{
    /// <summary>Home tile.</summary>
    HomeTile,
    /// <summary>The 64×36 chip in the Captions header.</summary>
    HeaderChip,
    /// <summary>Full take and Recent thumbnails in the sidebar.</summary>
    Sidebar,
    /// <summary>Clip row thumbnail.</summary>
    ClipRow
}

/// <summary>Line limit and plate rule of each caption card surface; design §5.4.3.</summary>
public static class CaptionCardSurfaces
{
    /// <summary>Lines the surface allows; a style with fewer lines keeps its own limit.</summary>
    public static int LineLimit(this CaptionCardSurface surface) => surface == CaptionCardSurface.HeaderChip ? 1 : 2;
    /// <summary>Boxes, pills and plates are drawn on Home tiles and the header chip, never at sidebar sizes.</summary>
    public static bool DrawsPlates(this CaptionCardSurface surface) => surface is CaptionCardSurface.HomeTile or CaptionCardSurface.HeaderChip;
}

/// <summary>One word of a caption card; design §5.4.2. Id is the caption word id, or "title-{i}" for the i-th title word.
/// Text is what the caption layout takes (the corrected word or the title word, no transform). Display is the word after
/// the style's case and punctuation and the bundled-font cascade (captions §3.1 and §4.4). Weak marks a filler or a
/// stopword of the transcript language; trailing weak words are trimmed.</summary>
public sealed record CaptionCardWord(string Id, string Text, string Display, bool Weak);

/// <summary>The words a media stand-in shows when there is no frame: the scope's opening caption page in the project's
/// caption style, or the project title while Settings hides transcript words; design §5.4.2. Pure: no I/O and no
/// rendering. The apps draw it with their caption renderer and fit it to the surface (§5.4.3). KeyIndex is the first
/// number, otherwise the first word that is not weak, otherwise the first word. StyleMaxLines is the resolved style's
/// layout.maxLines (0 with no card). DrawsAtLastWord is true when the style's reveal hides the words after the active
/// one (word or char). HoldGapSec is the resolved style's layout.holdGapSec, how long a page stays after its last word
/// (0 with no card).</summary>
public sealed record CaptionCardText(CaptionCardSource Source, IReadOnlyList<CaptionCardWord> Words, int KeyIndex, int StyleMaxLines,
    bool DrawsAtLastWord, double HoldGapSec)
{
    /// <summary>Words per card page, whatever the style allows.</summary>
    public const int MaxWords = 4;

    /// <summary>No card: the surface shows stage black.</summary>
    public static CaptionCardText None { get; } = new(CaptionCardSource.None, [], 0, 0, false, 0);

    /// <summary>The most lines the card may use on a surface.</summary>
    public int MaxLines(CaptionCardSurface surface) => Math.Min(surface.LineLimit(), StyleMaxLines);

    /// <summary>The card as caption input at a fixed moment, like a gallery tile (captions §15.3): word i spans [0.4 i, 0.4 i + 0.35].</summary>
    public IReadOnlyList<CaptionWord> LayoutWords => Words.Select((word, index) => new CaptionWord(word.Id, word.Text, index * 0.4, index * 0.4 + 0.35)).ToArray();

    /// <summary>Hints for LayoutWords: only the key word is emphasised, so it takes the style's emphasis.</summary>
    public IReadOnlyList<CaptionWordHints> LayoutHints => Words.Select((_, index) => new CaptionWordHints(index == KeyIndex)).ToArray();

    /// <summary>The caption track duration for LayoutWords.</summary>
    public double Duration => Words.Count == 0 ? 0 : Words.Count * 0.4 + 0.5;

    /// <summary>When to draw LayoutWords (design §5.4.2): 0.35 × 0.98 into the key word, as a gallery tile is drawn (captions
    /// §15.3). The key word is then the active word, and the page is still visible for styles that hold nothing after their
    /// last word (Bold, Highlight). With DrawsAtLastWord the card is drawn in its last word instead, at that word's end while
    /// the page holds after it, so a long Typewriter word shows its last character.</summary>
    public double Time => Words.Count == 0 ? 0
        : (DrawsAtLastWord ? Words.Count - 1 : KeyIndex) * 0.4 + (DrawsAtLastWord && HoldGapSec > 0 ? 0.35 : 0.35 * 0.98);

    /// <summary>The fit's next shorter card (§5.4.3): the last word goes, then any weak words before it, keeping one word.
    /// Null when one word is left.</summary>
    public CaptionCardText? DroppingLastWord()
    {
        if (Words.Count <= 1) return null;
        var shorter = Words.Take(Words.Count - 1).ToList();
        while (shorter.Count > 1 && shorter[^1].Weak) shorter.RemoveAt(shorter.Count - 1);
        return this with { Words = shorter.ToArray(), KeyIndex = KeyIndexOf(shorter) };
    }

    /// <summary>The card for a scope of the project in style, the library style the project uses (the caller picks one when
    /// captions are off). The project's caption overrides apply; wordsVisible is Settings → General → "Show transcript
    /// words on placeholders".</summary>
    public static CaptionCardText Create(Project project, CaptionCardScope scope, CaptionStyle style, bool wordsVisible, CaptionResources resources)
    {
        ArgumentNullException.ThrowIfNull(project);
        ArgumentNullException.ThrowIfNull(scope);
        ArgumentNullException.ThrowIfNull(style);
        ArgumentNullException.ThrowIfNull(resources);
        if (ScopeWords.Create(project, scope, style, project.Captions.Overrides, resources) is not { Words.Count: > 0 } copy) return None;
        var words = copy.Words.ToList();
        var layout = copy.Style.Layout with { MaxWords = Math.Min(copy.Style.Layout.MaxWords, MaxWords) };
        var source = CaptionCardSource.Transcript;
        if (!wordsVisible)
        {
            source = CaptionCardSource.Title;
            words = CaptionTextRules.Raw(project.Title ?? "").Split(' ', StringSplitOptions.RemoveEmptyEntries)
                .Select((token, index) => copy.Entry("title-" + index.ToString(CultureInfo.InvariantCulture), token, 0, 0)).OfType<Candidate>().ToList();
            if (words.Count == 0) return None;
            layout = layout with { BreakOnGapSec = null, MaxPageSec = null };
        }
        if (copy.Stopwords is not null)
        {
            var lead = words.FindIndex(word => !EditingAlgorithms.IsFillerText(word.Text));
            if (lead > 0) words.RemoveRange(0, lead);
        }
        var pages = CaptionLayoutBuilder.Group(words.Count, layout, index => words[index].Raw, index => words[index].Start, index => words[index].End, _ => true);
        var page = pages[0].ToList();
        if (copy.Stopwords is not null)
        {
            page = (pages.FirstOrDefault(candidate => candidate.Any(index => !copy.Weak(words[index]))) ?? pages[0]).ToList();
            while (page.Count > 1 && copy.Weak(words[page[^1]])) page.RemoveAt(page.Count - 1);
        }
        return copy.Card(source, page.Select(index => words[index]).ToArray());
    }

    internal sealed record Candidate(string Id, string Text, string Raw, string Display, double Start, double End);

    /// <summary>The scope's caption copy (editing §7.6) in the resolved style: the library style with the supplied overrides
    /// at the export frame, and only the words that normalisation and the bundled-font cascade leave a glyph (captions §3.1
    /// and §4.4). Caption cards and gallery samples (captions §15.2) both start from it. Duration is the scope's edited
    /// duration, which ends the last caption page (captions §8.1). Stopwords is null when the transcript language has none,
    /// and then no word is weak.</summary>
    internal sealed class ScopeWords
    {
        private readonly CaptionData data;

        private ScopeWords(CaptionStyle style, string language, double duration, HashSet<string>? stopwords, CaptionData data)
        {
            Style = style; Language = language; Duration = duration; Stopwords = stopwords; this.data = data;
        }

        internal CaptionStyle Style { get; }
        internal string Language { get; }
        internal double Duration { get; }
        internal HashSet<string>? Stopwords { get; }
        internal IReadOnlyList<Candidate> Words { get; private set; } = [];

        /// <summary>Null with no transcript, or when the style or the scope's plan cannot be built.</summary>
        internal static ScopeWords? Create(Project project, CaptionCardScope scope, CaptionStyle style, JsonElement overrides, CaptionResources resources)
        {
            if (project.Transcript is not { } transcript) return null;
            var data = resources.Data;
            CaptionStyle resolved;
            VoiceLabOutputPlan plan;
            try
            {
                resolved = CaptionStyleResolver.Resolve(new CaptionLayoutRequest(style, project.Captions with { Overrides = overrides }, ExportFrame(project), [], transcript.Language, 0), data, out _);
                plan = VoiceLabOutputPlanner.Build(project, scope.ClipId is { } id ? VoiceLabOutputScope.Clip(id) : VoiceLabOutputScope.Full);
            }
            catch (Exception exception) when (exception is not OperationCanceledException) { return null; }
            var language = CaptionTextRules.Language(transcript.Language);
            var stopwords = data.Stopwords.TryGetProperty(language, out var list)
                ? list.EnumerateArray().Select(item => item.GetString()!).ToHashSet(StringComparer.Ordinal) : null;
            var copy = new ScopeWords(resolved, language, plan.Duration, stopwords, data);
            copy.Words = plan.Captions.Select(word => copy.Entry(word.Id, word.Text, word.Start, word.End)).OfType<Candidate>().ToArray();
            return copy;
        }

        /// <summary>The word as a caption page holds it, or null when nothing of it is drawn.</summary>
        internal Candidate? Entry(string id, string text, double start, double end)
        {
            var normalised = CaptionTextRules.Normalize(text, Style.Text, Language, data);
            if (normalised.Length == 0) return null;
            var cascade = CaptionLayoutBuilder.Cascade(normalised, Style.Font.File, Style, data);
            return cascade.Runs.Count == 0 ? null : new(id, text, CaptionTextRules.Raw(text), cascade.Kept, start, end);
        }

        /// <summary>A filler or a stopword of the transcript language (design §5.4.2).</summary>
        internal bool Weak(Candidate word) => Stopwords is not null
            && (EditingAlgorithms.IsFillerText(word.Text) || Stopwords.Contains(CaptionTextRules.Key(word.Display, Language, data)));

        /// <summary>The card of words in this style, with its key word and drawn moment (design §5.4.2).</summary>
        internal CaptionCardText Card(CaptionCardSource source, IReadOnlyList<Candidate> words)
        {
            var card = words.Select(word => new CaptionCardWord(word.Id, word.Text, word.Display, Weak(word))).ToArray();
            var reveal = Style.Reveal?.Unit ?? CaptionRevealUnitValue.Page;
            return new(source, card, KeyIndexOf(card), Style.Layout.MaxLines, reveal is CaptionRevealUnitValue.Word or CaptionRevealUnitValue.Char,
                Style.Layout.HoldGapSec);
        }
    }

    private static int KeyIndexOf(IReadOnlyList<CaptionCardWord> words)
    {
        for (var index = 0; index < words.Count; index++) if (words[index].Display.EnumerateRunes().Any(CaptionTextRules.Digit)) return index;
        for (var index = 0; index < words.Count; index++) if (!words[index].Weak) return index;
        return 0;
    }

    /// <summary>The project's export frame (architecture §4.1), which picks the style's aspect overrides.</summary>
    internal static PixelSize ExportFrame(Project project)
    {
        var video = project.Media.Source.Video;
        var source = video is null ? new PixelSize(1920, 1080)
            : video.RotationDegrees is 90 or 270 ? new PixelSize(video.Height, video.Width) : new PixelSize(video.Width, video.Height);
        return source.Width > 0 && source.Height > 0 ? ExportPresets.OutputSize(source, project.Export.Aspect) : new PixelSize(1920, 1080);
    }
}
