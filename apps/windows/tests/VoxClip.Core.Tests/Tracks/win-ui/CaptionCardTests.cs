#if WIN_UI_TESTS
using VoxClip.App.Services;
using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Services.Settings;
using Xunit;

namespace VoxClip.Ui.Tests;

/// <summary>Caption cards, design §5.4.2–5.4.3: the opening caption page in the project's own style, drawn by the export
/// caption renderer. Words come from the two shared demo fixtures.</summary>
public sealed class CaptionCardTests
{
    private static readonly string Shared = SharedRoot();
    private static readonly CaptionStyleLibrary Styles = CaptionStyleLibrary.Load(Shared);
    private static readonly CaptionCards Cards = new(Shared);

    private static string SharedRoot()
    {
        for (var directory = new DirectoryInfo(AppContext.BaseDirectory); directory is not null; directory = directory.Parent)
            if (File.Exists(Path.Combine(directory.FullName, "shared", "caption-styles", "stopwords.json"))) return Path.Combine(directory.FullName, "shared");
        throw new DirectoryNotFoundException("Shared caption resources not found.");
    }

    private static IReadOnlySet<string> Stopwords(string language)
    {
        using var document = System.Text.Json.JsonDocument.Parse(File.ReadAllText(Path.Combine(Shared, "caption-styles", "stopwords.json")));
        return document.RootElement.GetProperty("languages").GetProperty(language).EnumerateArray().Select(item => item.GetString()!).ToHashSet(StringComparer.Ordinal);
    }

    private static CardText Text(Project project, string styleId, string? clipId = null, bool wordsVisible = true, string? language = "en")
        => CaptionCards.Text(project, clipId, project.Title ?? "", wordsVisible, Styles.Find(styleId)!, language is null ? null : Stopwords(language));

    [Fact]
    public void TheCardSkipsLeadingFillersAndTrimsTrailingStopwords()
    {
        // "So um, today we ship uh the clipper. Thanks": "um," and "uh" are cut, "ship" is corrected to "shipped".
        var take = HomeViewModelTests.Fixture("interview-take.voxclip");
        Assert.Equal(new[] { "today", "we", "shipped" }, Text(take, "box-highlight").Words);
        Assert.Equal(0, Text(take, "box-highlight").KeyIndex);
        // One-word styles give one word.
        Assert.Equal(new[] { "today" }, Text(take, "vox-bold").Words);
        Assert.Equal(CardSource.Transcript, Text(take, "vox-bold").Source);
    }

    [Fact]
    public void ALanguageWithNoStopwordListUsesTheFirstPageAsItIs()
    {
        var take = HomeViewModelTests.Fixture("interview-take.voxclip");
        var french = take with { Transcript = take.Transcript! with { Language = "fr" } };
        Assert.Equal(new[] { "So", "today", "we", "shipped" }, Text(french, "box-highlight", language: null).Words);
    }

    [Fact]
    public void TheKeyWordIsTheFirstNumberThenTheFirstContentWord()
    {
        var longTake = HomeViewModelTests.Fixture("clip-from-long-take.voxclip");
        // The first caption page breaks after the sentence "Tere!".
        Assert.Equal(new[] { "Tere!" }, Text(longTake, "karaoke", language: "et").Words);
        var clip = Text(longTake, "karaoke", longTake.Edits.Clips[0].Id, language: "et");
        Assert.Equal(new[] { "See", "on", "tegelikult", "palju" }, clip.Words);
        Assert.Equal(3, clip.KeyIndex);
        var title = Text(HomeViewModelTests.Fixture("interview-take.voxclip"), "vox-bold", wordsVisible: false);
        Assert.Equal(new CardText(title.Words, 2, CardSource.Title), title);
        Assert.Equal(new[] { "Interview", "take", "3" }, title.Words);
    }

    [Fact]
    public void NoTranscriptOrEveryWordCutMeansNoCard()
    {
        var take = HomeViewModelTests.Fixture("interview-take.voxclip");
        Assert.Equal(CardText.None, Text(take with { Transcript = null }, "vox-bold"));
        Assert.Equal(CardText.None, Text(take with { Transcript = null }, "vox-bold", wordsVisible: false));
        var allCut = take with { Edits = take.Edits with { CutWordIds = take.Transcript!.Words.Select(word => word.Id).ToArray() } };
        Assert.Equal(CardText.None, Text(allCut, "vox-bold"));
        Assert.Equal(CardText.None, Text(take, "vox-bold", "no-such-clip"));
    }

    [Fact]
    public void CardsUseTheProjectStyleOrTheDefault()
    {
        var take = HomeViewModelTests.Fixture("interview-take.voxclip");
        var own = Cards.Card(take, null, "Interview take 3", true, "vox-highlight");
        Assert.Equal("vox-bold", own.StyleId);
        Assert.Equal("en", own.Language);
        var off = Cards.Card(take with { Captions = take.Captions with { StyleId = "off" } }, null, "Interview take 3", true, "vox-highlight");
        Assert.Equal("vox-highlight", off.StyleId);
        Assert.NotEqual(own.Key, off.Key);
        Assert.Equal(own.Key, Cards.Card(take, null, "Interview take 3", true, "vox-highlight").Key);
        Assert.NotEqual(own.Key, Cards.Card(take, null, "Interview take 3", false, "vox-highlight").Key);
    }

    [Fact]
    public async Task HomeCardsSetTheWordsCentredOnStageBlack()
    {
        var take = HomeViewModelTests.Fixture("interview-take.voxclip");
        var card = Cards.Card(take with { Captions = take.Captions with { StyleId = "box-highlight" } }, null, "Interview take 3", true, "vox-highlight");
        var bitmap = await Cards.RenderAsync(card, CardSurface.Home, 452, 254, TestContext.Current.CancellationToken);
        Assert.NotNull(bitmap);
        Assert.Equal(452 * 254 * 4, bitmap.Pixels.Length);
        // Stage black outside the 352 × 142 text box, the words inside it.
        Assert.Equal((0, 0, 0), Pixel(bitmap, 4, 4));
        Assert.Equal((0, 0, 0), Pixel(bitmap, 40, 127));
        Assert.Equal((0, 0, 0), Pixel(bitmap, 226, 20));
        Assert.True(Lit(bitmap, 50, 56, 402, 198) > 2000, "The card set no words.");
        Assert.Same(bitmap, await Cards.RenderAsync(card, CardSurface.Home, 452, 254, TestContext.Current.CancellationToken));
    }

    [Fact]
    public async Task DarkPreviewBackgroundsVignetteToStageBlack()
    {
        var take = HomeViewModelTests.Fixture("interview-take.voxclip");
        var card = Cards.Card(take with { Transcript = null }, null, "Interview take 3", true, "vox-highlight");
        Assert.Equal(CardText.None, card.Text);
        // vox-bold declares #3A3C45: the backdrop alone, for the transcribing tile's three dots.
        var bitmap = await Cards.RenderAsync(card, CardSurface.Home, 452, 254, TestContext.Current.CancellationToken);
        Assert.NotNull(bitmap);
        var (r, g, b) = Pixel(bitmap, 226, 117);
        Assert.InRange(r, 0x34, 0x3A);
        Assert.InRange(g, 0x36, 0x3C);
        Assert.InRange(b, 0x3F, 0x45);
        // A 78% × 92% ellipse at 50%, 46%: half the colour at 42% of its radius, nearly stage black in the corners.
        Assert.InRange(Pixel(bitmap, 0, 0).R, 0, 16);
        Assert.InRange(Pixel(bitmap, 226, 253).R, 1, r - 10);
    }

    [Fact]
    public async Task SidebarCardsDropPlatesAndWordsThatDoNotFit()
    {
        var take = HomeViewModelTests.Fixture("interview-take.voxclip");
        var card = Cards.Card(take with { Captions = take.Captions with { StyleId = "pill" } }, null, "Interview take 3", true, "vox-highlight");
        // Thumbnails at 200%: 32 × 18 and 27 × 48.
        var bitmap = await Cards.RenderAsync(card, CardSurface.Sidebar, 64, 36, TestContext.Current.CancellationToken);
        Assert.NotNull(bitmap);
        // No white pill plate: the brightest pixels are white text on black, a small share of the thumbnail.
        Assert.InRange(Lit(bitmap, 0, 0, 64, 36), 1, 64 * 36 / 2);
        var clipRow = await Cards.RenderAsync(card, CardSurface.ClipRow, 54, 96, TestContext.Current.CancellationToken);
        Assert.NotNull(clipRow);
        Assert.Equal(0, Lit(clipRow, 0, 0, 54, 48));
        Assert.True(Lit(clipRow, 0, 48, 54, 96) > 0, "The clip row set no words below the middle.");
    }

    private static (int R, int G, int B) Pixel(CardBitmap bitmap, int x, int y)
    {
        var index = (y * bitmap.Width + x) * 4;
        return (bitmap.Pixels[index + 2], bitmap.Pixels[index + 1], bitmap.Pixels[index]);
    }

    private static int Lit(CardBitmap bitmap, int left, int top, int right, int bottom)
    {
        var count = 0;
        for (var y = top; y < bottom; y++)
            for (var x = left; x < right; x++)
                if (Pixel(bitmap, x, y) is var (r, g, b) && r + g + b > 300) count++;
        return count;
    }
}
#endif
