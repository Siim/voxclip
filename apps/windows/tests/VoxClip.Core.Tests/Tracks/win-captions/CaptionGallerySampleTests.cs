using System.Text.Json;
using VoxClip.Core.Domain.Captions;
using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Services.Settings;
using VoxClip.Tests.Support;
using Xunit;

namespace VoxClip.Core.Tests.Tracks.WinCaptions;

public sealed class CaptionGallerySampleTests
{
    private static Dictionary<string, Project> Projects(JsonElement root)
        => root.GetProperty("projects").EnumerateObject().ToDictionary(entry => entry.Name, entry => ProjectSerialization.Deserialize(entry.Value.GetRawText()));

    private static CaptionGallerySample Sample(JsonElement item, Dictionary<string, Project> projects, CaptionStyleLibrary library, CaptionResources resources)
    {
        var id = item.GetProperty("id").GetString()!;
        var style = library.Find(item.GetProperty("style").GetString()!) ?? throw new InvalidDataException(id + ": unknown style");
        var scope = item.GetProperty("scope").ValueKind == JsonValueKind.Null ? CaptionCardScope.FullTake : CaptionCardScope.Clip(item.GetProperty("scope").GetString()!);
        return CaptionGallerySample.Create(projects[item.GetProperty("project").GetString()!], scope, item.GetProperty("playhead").GetDouble(), style,
            item.GetProperty("wordsVisible").GetBoolean(), resources);
    }

    [Fact]
    public void EveryCaptionGallerySampleFixture()
    {
        using var fixture = FixtureLoader.ReadJson("fixtures/captions/gallery-samples.json");
        var root = fixture.RootElement;
        Assert.Equal("voxclip-caption-gallery/1", root.GetProperty("fixture").GetString());
        var resources = CaptionResources.Load(FixtureLoader.SharedRoot);
        var library = CaptionStyleLibrary.Load(FixtureLoader.SharedRoot);
        var projects = Projects(root);
        var cases = root.GetProperty("cases").EnumerateArray().ToArray();
        Assert.True(cases.Length >= 86, cases.Length.ToString());
        Assert.Equal(19, cases.Select(item => item.GetProperty("style").GetString()).Distinct().Count());
        Assert.Equal(new[] { "page", "preview" }, cases.Select(item => item.GetProperty("expected").GetProperty("source").GetString()).Distinct().Order());
        var failures = new List<string>();
        foreach (var item in cases)
        {
            var id = item.GetProperty("id").GetString()!;
            void Check(bool ok, string what) { if (!ok) failures.Add(id + ": " + what); }
            var sample = Sample(item, projects, library, resources);
            var expected = item.GetProperty("expected");
            Check(sample.Source.ToString().ToLowerInvariant() == expected.GetProperty("source").GetString(), "source " + sample.Source);
            var words = expected.GetProperty("words").EnumerateArray().ToArray();
            Check(words.Length == sample.Words.Count, "word count " + sample.Words.Count);
            foreach (var (actual, wanted) in sample.Words.Zip(words))
            {
                Check(actual.Id == wanted.GetProperty("id").GetString() && actual.Text == wanted.GetProperty("text").GetString(), "word " + actual.Id + " " + actual.Text);
                Check(actual.Start == wanted.GetProperty("start").GetDouble() && actual.End == wanted.GetProperty("end").GetDouble(),
                    "word time " + actual.Id);
            }
            Check(sample.Duration == expected.GetProperty("duration").GetDouble(), "duration " + sample.Duration);
            Check(sample.Time == expected.GetProperty("time").GetDouble(), "time " + sample.Time);
        }
        Assert.True(failures.Count == 0, string.Join(Environment.NewLine, failures));
    }

    [Fact]
    public void OnePreparedCaptionGalleryPagesGivesTheSampleAtEveryPlayhead()
    {
        using var fixture = FixtureLoader.ReadJson("fixtures/captions/gallery-samples.json");
        var root = fixture.RootElement;
        var resources = CaptionResources.Load(FixtureLoader.SharedRoot);
        var library = CaptionStyleLibrary.Load(FixtureLoader.SharedRoot);
        var projects = Projects(root);
        var prepared = new Dictionary<string, CaptionGalleryPages>();
        var failures = new List<string>();
        var reused = 0;
        foreach (var item in root.GetProperty("cases").EnumerateArray())
        {
            var id = item.GetProperty("id").GetString()!;
            var scope = item.GetProperty("scope").ValueKind == JsonValueKind.Null ? null : item.GetProperty("scope").GetString();
            var key = string.Join('|', item.GetProperty("project").GetString(), scope, item.GetProperty("style").GetString(), item.GetProperty("wordsVisible").GetBoolean());
            if (prepared.TryGetValue(key, out var pages)) reused++;
            else prepared[key] = pages = new CaptionGalleryPages(projects[item.GetProperty("project").GetString()!],
                scope is null ? CaptionCardScope.FullTake : CaptionCardScope.Clip(scope), library.Find(item.GetProperty("style").GetString()!)!,
                item.GetProperty("wordsVisible").GetBoolean(), resources);
            var sample = pages.Sample(item.GetProperty("playhead").GetDouble());
            var expected = item.GetProperty("expected");
            if (sample.Source.ToString().ToLowerInvariant() != expected.GetProperty("source").GetString()
                || !sample.Words.Select(word => word.Id).SequenceEqual(expected.GetProperty("words").EnumerateArray().Select(word => word.GetProperty("id").GetString()))
                || sample.Time != expected.GetProperty("time").GetDouble()) failures.Add(id);
        }
        Assert.True(failures.Count == 0, string.Join(Environment.NewLine, failures));
        Assert.True(reused >= 30, reused.ToString());
    }

    [Fact]
    public async Task EveryGallerySampleIsDrawnWithItsWordActiveAtTheTileTime()
    {
        using var fixture = FixtureLoader.ReadJson("fixtures/captions/gallery-samples.json");
        var root = fixture.RootElement;
        var resources = CaptionResources.Load(FixtureLoader.SharedRoot);
        var library = CaptionStyleLibrary.Load(FixtureLoader.SharedRoot);
        var projects = Projects(root);
        var failures = new List<string>();
        foreach (var item in root.GetProperty("cases").EnumerateArray())
        {
            var id = item.GetProperty("id").GetString()!;
            var project = projects[item.GetProperty("project").GetString()!];
            var style = library.Find(item.GetProperty("style").GetString()!)!;
            var sample = Sample(item, projects, library, resources);
            var settings = project.Captions with { StyleId = style.Id, Overrides = style.Id == project.Captions.StyleId ? project.Captions.Overrides : default };
            var language = sample.Source == CaptionGallerySampleSource.Preview ? "en" : project.Transcript?.Language;
            var request = new CaptionLayoutRequest(style, settings, CaptionCardText.ExportFrame(project), sample.Words, language, sample.Duration);
            var track = await CaptionEngine.BuildAsync(request, new CaptionCardTests.FixedAdvanceShaper(), null, TestContext.Current.CancellationToken);
            if (id.StartsWith("selected-line-", StringComparison.Ordinal)) Assert.True(track.Pages.Count > 1, id);
            if (track.Words.Count != sample.Words.Count) { failures.Add(id + ": words dropped"); continue; }
            // The tile time lies inside word a, which has started while the next word has not: the active word (§8.2).
            var anchor = (int)Math.Floor(sample.Time / 0.4);
            foreach (var reduceMotion in new[] { true, false })
            {
                var frame = CaptionEvaluator.Evaluate(track, sample.Time, reduceMotion);
                if (frame is null) failures.Add($"{id}: no page at {sample.Time}");
                else if (frame.ActiveWord != anchor) failures.Add($"{id}: word {frame.ActiveWord} active at {sample.Time}, not {anchor}");
            }
        }
        Assert.True(failures.Count == 0, string.Join(Environment.NewLine, failures));
    }

    [Fact]
    public void APlayheadThatIsNotFiniteCountsAsTheStartOfTheScope()
    {
        using var fixture = FixtureLoader.ReadJson("fixtures/captions/gallery-samples.json");
        var project = Projects(fixture.RootElement)["interview-take"];
        var resources = CaptionResources.Load(FixtureLoader.SharedRoot);
        var library = CaptionStyleLibrary.Load(FixtureLoader.SharedRoot);
        foreach (var id in new[] { "karaoke", "vox-highlight", "typewriter" })
        {
            var style = library.Find(id)!;
            var start = CaptionGallerySample.Create(project, CaptionCardScope.FullTake, 0, style, true, resources);
            foreach (var playhead in new[] { double.NaN, double.PositiveInfinity, double.NegativeInfinity })
            {
                var sample = CaptionGallerySample.Create(project, CaptionCardScope.FullTake, playhead, style, true, resources);
                Assert.Equal(start.Source, sample.Source);
                Assert.Equal(start.Words, sample.Words);
                Assert.Equal(start.Time, sample.Time);
            }
        }
    }

    [Fact]
    public void ThePreviewSampleUsesProgressOneWhenAStyleHasNone()
    {
        var style = CaptionStyleLibrary.Load(FixtureLoader.SharedRoot).Find("active-pop")!;
        Assert.Equal(1, style.Preview.Progress);
        var sample = CaptionGallerySample.Preview(style);
        Assert.Equal(CaptionGallerySampleSource.Preview, sample.Source);
        Assert.Equal(new[] { "This", "changes", "everything" }, sample.Words.Select(word => word.Text));
        Assert.Equal(new[] { "preview-0", "preview-1", "preview-2" }, sample.Words.Select(word => word.Id));
        Assert.Equal(0.4 + 0.35 * 0.98, sample.Time, 12);
        Assert.Equal(1.7, sample.Duration, 12);
        var last = CaptionGallerySample.Preview(style with { Preview = style.Preview with { ActiveWord = 15 } });
        Assert.Equal(0.8 + 0.35 * 0.98, last.Time, 12);
    }

    [Fact]
    public void BinaryGalleryLookupAgreesWithALinearReferenceOnALongTake()
    {
        using var fixture = FixtureLoader.ReadJson("fixtures/captions/gallery-samples.json");
        var project = Projects(fixture.RootElement)["interview-take"];
        var transcript = project.Transcript!;
        var texts = new[] { "So", "bright", "12", "ideas", "travel", "far", "in", "the" };
        var longWords = Enumerable.Range(0, 2304).Select(index =>
        {
            var start = 0.2 + index * 0.45 + (index / 9) * 0.8;
            return transcript.Words[0] with { Id = "long-" + index, Text = texts[index % texts.Length] + (index % 13 == 12 ? "." : ""),
                Start = start, End = start + 0.3, RawStart = null, RawEnd = null };
        }).ToArray();
        var duration = longWords[^1].End + 0.5;
        project = project with
        {
            Transcript = transcript with { Words = longWords, DurationSeconds = duration },
            Media = project.Media with { Source = project.Media.Source with { DurationSeconds = duration } },
            Edits = project.Edits with { CutWordIds = [], CutPauseIds = [], Corrections = new Dictionary<string, string>(), Clips = [], ActiveClipId = null },
            Captions = project.Captions with { Overrides = default }
        };
        var resources = CaptionResources.Load(FixtureLoader.SharedRoot);
        var library = CaptionStyleLibrary.Load(FixtureLoader.SharedRoot);
        foreach (var id in new[] { "vox-highlight", "karaoke", "typewriter" })
        {
            var style = library.Find(id)!;
            var copy = CaptionCardText.ScopeWords.Create(project, CaptionCardScope.FullTake, style, default, resources)!;
            Assert.Equal(2304, copy.Words.Count);
            var words = copy.Words;
            var layout = copy.Style.Layout;
            var groups = CaptionLayoutBuilder.Group(words.Count, layout, index => words[index].Raw, index => words[index].Start, index => words[index].End, _ => true);
            var reference = groups.Select((group, index) =>
            {
                var page = group.Select(position => words[position]).ToArray();
                var next = index + 1 < groups.Count ? words[groups[index + 1][0]].Start : double.PositiveInfinity;
                var end = CaptionLayoutBuilder.PageEnd(page[0].Start, page[^1].End, next, layout, copy.Duration);
                return (Start: page[0].Start, End: end, Words: page, KeyTime: copy.Card(CaptionCardSource.Transcript, page).Time);
            }).ToArray();
            var probes = new List<double> { -1, 0, duration, duration + 1 };
            foreach (var page in reference) probes.AddRange([Math.BitDecrement(page.Start), page.Start, Math.BitIncrement(page.Start),
                Math.BitDecrement(page.End), page.End, Math.BitIncrement(page.End)]);
            for (var index = 0; index < words.Count; index += 31) probes.AddRange([words[index].Start, words[index].End]);
            var prepared = new CaptionGalleryPages(project, CaptionCardScope.FullTake, style, true, resources);
            foreach (var time in probes)
            {
                var visible = Array.FindIndex(reference, page => page.Start <= time && time < page.End);
                var next = Array.FindIndex(reference, page => page.Start > time);
                var page = reference[visible >= 0 ? visible : next >= 0 ? next : reference.Length - 1];
                var expectedTime = page.KeyTime;
                var active = Array.FindLastIndex(page.Words, word => word.Start <= time);
                if (visible >= 0 && active >= 0 && time < page.Words[active].End) expectedTime = active * 0.4 + 0.35 * 0.98;
                var actual = prepared.Sample(time);
                Assert.Equal(CaptionGallerySampleSource.Page, actual.Source);
                Assert.Equal(page.Words.Select(word => word.Id), actual.Words.Select(word => word.Id));
                Assert.True(actual.Time == expectedTime, $"{id} at {time}: {actual.Time} != {expectedTime}");
            }
        }
    }

}
