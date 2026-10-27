using System.Text.Json;
using VoxClip.Core.Domain.Captions;
using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Services.Settings;
using VoxClip.Tests.Support;
using Xunit;

namespace VoxClip.Core.Tests.Tracks.WinCaptions;

public sealed class CaptionCardTests
{
    private static string Camel<T>(T value) where T : struct, Enum
    {
        var name = value.ToString();
        return char.ToLowerInvariant(name[0]) + name[1..];
    }

    [Fact]
    public void EveryCaptionCardFixture()
    {
        using var fixture = FixtureLoader.ReadJson("fixtures/captions/cards.json");
        var root = fixture.RootElement;
        Assert.Equal("voxclip-caption-cards/1", root.GetProperty("fixture").GetString());
        Assert.Equal(CaptionCardText.MaxWords, root.GetProperty("maxWords").GetInt32());
        var surfaces = root.GetProperty("surfaces").EnumerateArray().ToArray();
        Assert.Equal(Enum.GetValues<CaptionCardSurface>().Select(Camel), surfaces.Select(entry => entry.GetProperty("surface").GetString()));
        foreach (var (surface, entry) in Enum.GetValues<CaptionCardSurface>().Zip(surfaces))
        {
            Assert.Equal(entry.GetProperty("lines").GetInt32(), surface.LineLimit());
            Assert.Equal(entry.GetProperty("plates").GetBoolean(), surface.DrawsPlates());
        }
        var resources = CaptionResources.Load(FixtureLoader.SharedRoot);
        var library = CaptionStyleLibrary.Load(FixtureLoader.SharedRoot);
        var projects = root.GetProperty("projects").EnumerateObject().ToDictionary(entry => entry.Name, entry => ProjectSerialization.Deserialize(entry.Value.GetRawText()));
        var cases = root.GetProperty("cases").EnumerateArray().ToArray();
        Assert.True(cases.Length >= 50);
        var failures = new List<string>();
        foreach (var item in cases)
        {
            var id = item.GetProperty("id").GetString()!;
            void Check(bool ok, string what) { if (!ok) failures.Add(id + ": " + what); }
            var style = library.Find(item.GetProperty("style").GetString()!) ?? throw new InvalidDataException(id + ": unknown style");
            var scope = item.GetProperty("scope").ValueKind == JsonValueKind.Null ? CaptionCardScope.FullTake : CaptionCardScope.Clip(item.GetProperty("scope").GetString()!);
            var card = CaptionCardText.Create(projects[item.GetProperty("project").GetString()!], scope, style, item.GetProperty("wordsVisible").GetBoolean(), resources);
            var expected = item.GetProperty("expected");
            Check(Camel(card.Source) == expected.GetProperty("source").GetString(), "source " + card.Source);
            var words = expected.GetProperty("words").EnumerateArray()
                .Select(word => (word.GetProperty("id").GetString()!, word.GetProperty("text").GetString()!, word.GetProperty("display").GetString()!, word.GetProperty("weak").GetBoolean()));
            Check(words.SequenceEqual(card.Words.Select(word => (word.Id, word.Text, word.Display, word.Weak))), "words " + string.Join(' ', card.Words.Select(word => word.Display)));
            Check(card.KeyIndex == expected.GetProperty("keyIndex").GetInt32(), "keyIndex " + card.KeyIndex);
            Check(card.StyleMaxLines == expected.GetProperty("styleMaxLines").GetInt32(), "styleMaxLines " + card.StyleMaxLines);
            Check(card.DrawsAtLastWord == expected.GetProperty("drawsAtLastWord").GetBoolean(), "drawsAtLastWord");
            Check(card.HoldGapSec == expected.GetProperty("holdGapSec").GetDouble(), "holdGapSec " + card.HoldGapSec);
            foreach (var surface in Enum.GetValues<CaptionCardSurface>())
                Check(card.MaxLines(surface) == expected.GetProperty("maxLines").GetProperty(Camel(surface)).GetInt32(), "maxLines " + surface);
            var layout = expected.GetProperty("layout");
            var layoutWords = layout.GetProperty("words").EnumerateArray().ToArray();
            Check(layoutWords.Length == card.LayoutWords.Count && layoutWords.Length == card.LayoutHints.Count, "layout word count");
            foreach (var (actual, hint, wanted) in card.LayoutWords.Zip(card.LayoutHints, layoutWords))
            {
                Check(actual.Id == wanted.GetProperty("id").GetString() && actual.Text == wanted.GetProperty("text").GetString(), "layout word " + actual.Id);
                Check(Math.Abs(actual.Start - wanted.GetProperty("start").GetDouble()) <= 1e-9 && Math.Abs(actual.End - wanted.GetProperty("end").GetDouble()) <= 1e-9, "layout time " + actual.Id);
                Check(hint.Emphasis == wanted.GetProperty("emphasis").GetBoolean(), "emphasis " + actual.Id);
            }
            Check(Math.Abs(card.Duration - layout.GetProperty("duration").GetDouble()) <= 1e-9 && Math.Abs(card.Time - layout.GetProperty("time").GetDouble()) <= 1e-9, "duration or time");
            var drops = new List<CaptionCardText>();
            for (var current = card.DroppingLastWord(); current is not null; current = current.DroppingLastWord()) drops.Add(current);
            var wantedDrops = expected.GetProperty("drops").EnumerateArray().ToArray();
            Check(drops.Count == wantedDrops.Length, "drop count " + drops.Count);
            foreach (var (drop, wanted) in drops.Zip(wantedDrops))
            {
                Check(drop.Words.Select(word => word.Id).SequenceEqual(wanted.GetProperty("words").EnumerateArray().Select(word => word.GetString()!)), "drop words");
                Check(drop.KeyIndex == wanted.GetProperty("keyIndex").GetInt32() && Math.Abs(drop.Time - wanted.GetProperty("time").GetDouble()) <= 1e-9, "drop key or time");
            }
        }
        Assert.True(failures.Count == 0, string.Join(Environment.NewLine, failures));
    }

    [Fact]
    public async Task EveryCardShowsItsKeyWordAtItsDrawnMoment()
    {
        using var fixture = FixtureLoader.ReadJson("fixtures/captions/cards.json");
        var root = fixture.RootElement;
        var resources = CaptionResources.Load(FixtureLoader.SharedRoot);
        var library = CaptionStyleLibrary.Load(FixtureLoader.SharedRoot);
        var projects = root.GetProperty("projects").EnumerateObject().ToDictionary(entry => entry.Name, entry => ProjectSerialization.Deserialize(entry.Value.GetRawText()));
        var failures = new List<string>();
        var drawnCards = 0;
        foreach (var item in root.GetProperty("cases").EnumerateArray())
        {
            var id = item.GetProperty("id").GetString()!;
            var project = projects[item.GetProperty("project").GetString()!];
            var style = library.Find(item.GetProperty("style").GetString()!) ?? throw new InvalidDataException(id + ": unknown style");
            var scope = item.GetProperty("scope").ValueKind == JsonValueKind.Null ? CaptionCardScope.FullTake : CaptionCardScope.Clip(item.GetProperty("scope").GetString()!);
            for (var card = CaptionCardText.Create(project, scope, style, item.GetProperty("wordsVisible").GetBoolean(), resources);
                 card is { Words.Count: > 0 }; card = card.DroppingLastWord())
            {
                var label = $"{id} ({card.Words.Count} words)";
                var request = new CaptionLayoutRequest(style, project.Captions with { StyleId = style.Id }, CaptionCardText.ExportFrame(project),
                    card.LayoutWords, project.Transcript!.Language, card.Duration) { WordHints = card.LayoutHints };
                var track = await CaptionEngine.BuildAsync(request, new FixedAdvanceShaper(), null, TestContext.Current.CancellationToken);
                if (track.Words.Count != card.Words.Count) { failures.Add(label + ": words dropped"); continue; }
                foreach (var reduceMotion in new[] { false, true })
                {
                    var frame = CaptionEvaluator.Evaluate(track, card.Time, reduceMotion);
                    if (frame is null) failures.Add($"{label}: no page at {card.Time}");
                    else if (card.DrawsAtLastWord)
                    {
                        var drawn = frame.Words.Where(word => word.Visible && (word.VisibleClusters is null || word.VisibleClusters == track.Words[word.Word].Clusters))
                            .Select(word => word.Word).Order();
                        if (!drawn.SequenceEqual(Enumerable.Range(0, card.Words.Count))) failures.Add($"{label}: not every word drawn at {card.Time}");
                    }
                    else if (frame.ActiveWord != card.KeyIndex) failures.Add($"{label}: word {frame.ActiveWord} active at {card.Time}, not {card.KeyIndex}");
                }
                drawnCards++;
            }
        }
        Assert.True(failures.Count == 0, string.Join(Environment.NewLine, failures));
        Assert.True(drawnCards > 40, drawnCards.ToString());
    }

    [Fact]
    public void MediaStandInPrecedenceMatchesTheSharedCases()
    {
        using var fixture = FixtureLoader.ReadJson("fixtures/captions/cards.json");
        var statuses = new Dictionary<string, MediaStatus>
        {
            ["none"] = new MediaStatus.None(), ["loading"] = new MediaStatus.Loading(), ["missing"] = new MediaStatus.Missing(),
            ["unreadable"] = new MediaStatus.Unreadable(), ["transcribing"] = new MediaStatus.Transcribing(0.42, MediaTranscriptionStage.Transcribing),
            ["demo"] = new MediaStatus.Demo(), ["audioOnly"] = new MediaStatus.AudioOnly(),
        };
        var words = new CaptionCardText(CaptionCardSource.Transcript, [new("w1", "Coffee", "COFFEE", false)], 0, 2, false, 0);
        var cases = fixture.RootElement.GetProperty("standIns").EnumerateArray().ToArray();
        Assert.Equal(56, cases.Length);
        Assert.Equal(statuses.Keys.Order(), cases.Select(item => item.GetProperty("status").GetString()!).Distinct().Order());
        foreach (var item in cases)
        {
            var card = item.GetProperty("hasWords").GetBoolean() ? words : CaptionCardText.None;
            var actual = MediaStandIn.Resolve(statuses[item.GetProperty("status").GetString()!], item.GetProperty("hasFrame").GetBoolean(), card,
                "vox-highlight", item.GetProperty("holding").GetBoolean());
            MediaStandIn expected = item.GetProperty("standIn").GetString() switch
            {
                "frame" => new MediaStandIn.Frame(),
                "card" => new MediaStandIn.Card(card, "vox-highlight"),
                _ => new MediaStandIn.Black(),
            };
            Assert.True(expected == actual, item.GetRawText());
        }
    }

    /// <summary>One half-em glyph per UTF-16 unit, so card layouts page and time without HarfBuzz.</summary>
    internal sealed class FixedAdvanceShaper : IGlyphShaper
    {
        public Task<ShapedRun> ShapeAsync(ShapingRequest request, CancellationToken ct)
        {
            var count = request.Text.Length;
            return Task.FromResult(new ShapedRun(request.FontFile, request.Text, request.UnitsPerEm, Enumerable.Repeat(1u, count).ToArray(),
                Enumerable.Repeat((long)request.UnitsPerEm / 2, count).ToArray(), new GlyphOffset[count], Enumerable.Range(0, count).ToArray()));
        }
    }

    [Fact]
    public void AnEmptyCardHasNoLinesNoLayoutAndNoShorterCard()
    {
        Assert.Equal(0, CaptionCardText.None.MaxLines(CaptionCardSurface.HomeTile));
        Assert.Empty(CaptionCardText.None.LayoutWords);
        Assert.Null(CaptionCardText.None.DroppingLastWord());
        Assert.Equal(0, CaptionCardText.None.Time);
    }
}
