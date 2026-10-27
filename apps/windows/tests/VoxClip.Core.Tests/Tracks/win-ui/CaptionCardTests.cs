#if WIN_UI_TESTS
using System.Text.Json;
using VoxClip.App.Services;
using VoxClip.Core.Domain.Captions;
using VoxClip.Core.Domain.Shared;
using Xunit;

namespace VoxClip.Ui.Tests;

/// <summary>Caption cards, design §5.4.2–5.4.3: Core's CaptionCardText in the project's own style, drawn by the export
/// caption renderer. The words and the drawn moment are Core's; these tests check that the App asks Core for the right
/// card and draws it on the right surface.</summary>
public sealed class CaptionCardTests
{
    private static readonly string Shared = SharedRoot();
    private static readonly CaptionCards Cards = new(Shared);

    private static string SharedRoot()
    {
        for (var directory = new DirectoryInfo(AppContext.BaseDirectory); directory is not null; directory = directory.Parent)
            if (File.Exists(Path.Combine(directory.FullName, "shared", "caption-styles", "stopwords.json"))) return Path.Combine(directory.FullName, "shared");
        throw new DirectoryNotFoundException("Shared caption resources not found.");
    }

    private static CaptionCard Card(Project project, string styleId, string? clipId = null, bool wordsVisible = true) =>
        Cards.Card(project with { Captions = project.Captions with { StyleId = styleId } }, clipId, wordsVisible, "vox-highlight");

    /// <summary>Every shared card case, made through the App: the same words, key word, line limit and drawn moment as Core.</summary>
    [Fact]
    public void CardsAreCoresCaptionCardText()
    {
        using var fixture = JsonDocument.Parse(File.ReadAllText(Path.Combine(Shared, "fixtures", "captions", "cards.json")));
        var root = fixture.RootElement;
        var projects = root.GetProperty("projects").EnumerateObject().ToDictionary(entry => entry.Name, entry => ProjectSerialization.Deserialize(entry.Value.GetRawText()));
        var failures = new List<string>();
        foreach (var item in root.GetProperty("cases").EnumerateArray())
        {
            var id = item.GetProperty("id").GetString()!;
            var scope = item.GetProperty("scope").ValueKind == JsonValueKind.Null ? null : item.GetProperty("scope").GetString();
            var card = Card(projects[item.GetProperty("project").GetString()!], item.GetProperty("style").GetString()!, scope, item.GetProperty("wordsVisible").GetBoolean());
            var expected = item.GetProperty("expected");
            var words = expected.GetProperty("words").EnumerateArray().Select(word => (word.GetProperty("id").GetString()!, word.GetProperty("display").GetString()!));
            if (!words.SequenceEqual(card.Text.Words.Select(word => (word.Id, word.Display)))) failures.Add($"{id}: words {string.Join(' ', card.Text.Words.Select(word => word.Display))}");
            if (card.Text.KeyIndex != expected.GetProperty("keyIndex").GetInt32()) failures.Add($"{id}: key {card.Text.KeyIndex}");
            if (card.Text.StyleMaxLines != expected.GetProperty("styleMaxLines").GetInt32()) failures.Add($"{id}: lines {card.Text.StyleMaxLines}");
            if (Math.Abs(card.Text.Time - expected.GetProperty("layout").GetProperty("time").GetDouble()) > 1e-9) failures.Add($"{id}: time {card.Text.Time}");
            if (card.StyleId != item.GetProperty("style").GetString()) failures.Add($"{id}: style {card.StyleId}");
        }
        Assert.True(failures.Count == 0, string.Join(Environment.NewLine, failures));
    }

    [Fact]
    public void TheLongTakesKaraokeCardIsTheSharedOne()
    {
        var longTake = HomeViewModelTests.Fixture("clip-from-long-take.voxclip");
        var take = Card(longTake, "karaoke");
        Assert.Equal((CaptionCardSource.Transcript, 0), (take.Text.Source, take.Text.KeyIndex));
        Assert.Equal(["TERE"], take.Text.Words.Select(word => word.Display));
        var clip = Card(longTake, "karaoke", longTake.Edits.Clips[0].Id);
        Assert.Equal(3, clip.Text.KeyIndex);
        Assert.Equal(["SEE", "ON", "TEGELIKULT", "PALJU"], clip.Text.Words.Select(word => word.Display));
    }

    [Fact]
    public void CaptionsOffUseTheDefaultStyleThenHighlight()
    {
        var take = HomeViewModelTests.Fixture("interview-take.voxclip");
        Assert.Equal("vox-bold", Cards.Card(take, null, true, "box-highlight").StyleId);
        var off = take with { Captions = take.Captions with { StyleId = "off" } };
        Assert.Equal("box-highlight", Cards.Card(off, null, true, "box-highlight").StyleId);
        Assert.Equal("vox-highlight", Cards.Card(off, null, true, "off").StyleId);
    }

    [Fact]
    public void TheKeyFollowsEverythingTheDrawingReads()
    {
        var take = HomeViewModelTests.Fixture("interview-take.voxclip");
        var own = Cards.Card(take, null, true, "vox-highlight");
        Assert.Equal(own.Key, Cards.Card(take, null, true, "vox-highlight").Key);
        Assert.NotEqual(own.Key, Cards.Card(take, null, false, "vox-highlight").Key);
        Assert.NotEqual(own.Key, Card(take, "box-highlight").Key);
        Assert.Equal(CaptionCardText.None, Cards.Card(take with { Transcript = null }, null, true, "vox-highlight").Text);
    }

    [Fact]
    public async Task HomeCardsSetTheWordsCentredOnStageBlack()
    {
        var take = HomeViewModelTests.Fixture("interview-take.voxclip");
        var card = Card(take, "box-highlight");
        var bitmap = await Cards.RenderAsync(card, CaptionCardSurface.HomeTile, 452, 254, TestContext.Current.CancellationToken);
        Assert.NotNull(bitmap);
        Assert.Equal(452 * 254 * 4, bitmap.Pixels.Length);
        // Stage black outside the 352 × 142 text box, the words inside it.
        Assert.Equal((0, 0, 0), Pixel(bitmap, 4, 4));
        Assert.Equal((0, 0, 0), Pixel(bitmap, 40, 127));
        Assert.Equal((0, 0, 0), Pixel(bitmap, 226, 20));
        Assert.True(Lit(bitmap, 50, 56, 402, 198) > 2000, "The card set no words.");
        Assert.Same(bitmap, await Cards.RenderAsync(card, CaptionCardSurface.HomeTile, 452, 254, TestContext.Current.CancellationToken));
    }

    [Fact]
    public async Task DarkPreviewBackgroundsVignetteToStageBlack()
    {
        var take = HomeViewModelTests.Fixture("interview-take.voxclip");
        var card = Cards.Card(take with { Transcript = null }, null, true, "vox-highlight");
        Assert.Equal(CaptionCardText.None, card.Text);
        // vox-bold declares #3A3C45: the backdrop alone, for the transcribing tile's three dots.
        var bitmap = await Cards.RenderAsync(card, CaptionCardSurface.HomeTile, 452, 254, TestContext.Current.CancellationToken);
        Assert.NotNull(bitmap);
        var (r, g, b) = Pixel(bitmap, 226, 117);
        Assert.InRange(r, 0x34, 0x3A);
        Assert.InRange(g, 0x36, 0x3C);
        Assert.InRange(b, 0x3F, 0x45);
        // A 78% × 92% ellipse at 50%, 46%: half the colour at 42% of its radius, nearly stage black in the corners.
        Assert.InRange(Pixel(bitmap, 0, 0).R, 0, 16);
        Assert.InRange(Pixel(bitmap, 226, 253).R, 1, r - 10);
    }

    /// <summary>Karaoke fills up to and including the key word (design §5.4.2): at Core's drawn moment "TERE" is in the accent.</summary>
    [Fact]
    public async Task KaraokeCardsFillTheKeyWord()
    {
        var card = Card(HomeViewModelTests.Fixture("clip-from-long-take.voxclip"), "karaoke");
        var bitmap = await Cards.RenderAsync(card, CaptionCardSurface.HomeTile, 452, 254, TestContext.Current.CancellationToken);
        Assert.NotNull(bitmap);
        // Karaoke's accent is #FFE14D; its future words are white.
        var (accent, white) = (Count(bitmap, (r, g, b) => r > 200 && g > 180 && b < 140), Count(bitmap, (r, g, b) => r > 200 && g > 200 && b > 200));
        Assert.True(accent > 1000 && accent > 8 * white, $"accent {accent}, white {white}");
    }

    [Fact]
    public async Task SidebarCardsDropPlatesAndWordsThatDoNotFit()
    {
        var take = HomeViewModelTests.Fixture("interview-take.voxclip");
        var card = Card(take, "pill");
        // Thumbnails at 200%: 32 × 18 and 27 × 48.
        var bitmap = await Cards.RenderAsync(card, CaptionCardSurface.Sidebar, 64, 36, TestContext.Current.CancellationToken);
        Assert.NotNull(bitmap);
        // No white pill plate: the brightest pixels are white text on black, a small share of the thumbnail.
        Assert.InRange(Lit(bitmap, 0, 0, 64, 36), 1, 64 * 36 / 2);
        var clipRow = await Cards.RenderAsync(card, CaptionCardSurface.ClipRow, 54, 96, TestContext.Current.CancellationToken);
        Assert.NotNull(clipRow);
        Assert.Equal(0, Lit(clipRow, 0, 0, 54, 48));
        Assert.True(Lit(clipRow, 0, 48, 54, 96) > 0, "The clip row set no words below the middle.");
    }

    /// <summary>At sidebar sizes a boxed key word takes its box colour as its text colour, as the style resolves it (Box
    /// highlight's #7C3AED lightened to #B793F5), with no plate behind it.</summary>
    [Fact]
    public async Task SidebarCardsSetTheBoxedWordInItsBoxColour()
    {
        var card = Card(HomeViewModelTests.Fixture("interview-take.voxclip"), "box-highlight");
        var bitmap = await Cards.RenderAsync(card, CaptionCardSurface.Sidebar, 128, 72, TestContext.Current.CancellationToken);
        Assert.NotNull(bitmap);
        var violet = Count(bitmap, (r, g, b) => Math.Abs(r - 0xB7) <= 14 && Math.Abs(g - 0x93) <= 14 && Math.Abs(b - 0xF5) <= 14);
        Assert.InRange(violet, 1, 128 * 72 / 4);
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

    private static int Count(CardBitmap bitmap, Func<int, int, int, bool> match)
    {
        var count = 0;
        for (var y = 0; y < bitmap.Height; y++)
            for (var x = 0; x < bitmap.Width; x++)
                if (Pixel(bitmap, x, y) is var (r, g, b) && match(r, g, b)) count++;
        return count;
    }
}
#endif
