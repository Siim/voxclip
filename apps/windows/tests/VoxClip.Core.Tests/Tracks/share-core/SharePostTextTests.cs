using System.Globalization;
using System.Text;
using System.Text.Json;
using VoxClip.Core.Domain.Share;
using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Services.Share;
using VoxClip.Tests.Support;
using Xunit;

namespace VoxClip.Core.Tests.Tracks.ShareCore;

/// <summary>Replays shared/fixtures/share/cases.json; publishing §2.1 and voice-lab §11.3.</summary>
public sealed class SharePostTextTests
{
    private static JsonElement Fixture()
    {
        using var document = FixtureLoader.ReadJson(Path.Combine("fixtures", "share", "cases.json"));
        return document.RootElement.Clone();
    }

    private static string? Text(JsonElement item, string name) => item.GetProperty(name).GetString();

    /// <summary>Run-length [scalars per text element, count] of the NFC text, the fixture's cluster encoding.</summary>
    private static string ClusterRuns(string text)
    {
        var runs = new List<(int Size, int Count)>();
        var nfc = text.Normalize(NormalizationForm.FormC);
        for (var offset = 0; offset < nfc.Length;)
        {
            var length = StringInfo.GetNextTextElementLength(nfc.AsSpan(offset));
            var size = 0;
            foreach (var _ in nfc.AsSpan(offset, length).EnumerateRunes()) size++;
            if (runs.Count > 0 && runs[^1].Size == size) runs[^1] = (size, runs[^1].Count + 1); else runs.Add((size, 1));
            offset += length;
        }
        return string.Join(",", runs.Select(run => $"{run.Size}x{run.Count}"));
    }

    private static string ClusterRuns(JsonElement runs) => string.Join(",", runs.EnumerateArray().Select(run => $"{run[0].GetInt32()}x{run[1].GetInt32()}"));

    [Fact]
    public void SharedDataLoadsTheRules()
    {
        var rules = ShareTextRulesLoader.Load(FixtureLoader.SharedRoot);
        SharePostText.Preflight();
        Assert.Equal((280, 3000, 2048), (SharePostText.Limit(ShareDestination.X), SharePostText.Limit(ShareDestination.LinkedIn), SharePostText.Limit(ShareDestination.VoxConvo)));
        Assert.Equal(("…", 23, 100, 200), (rules.Ellipsis, rules.UrlLength, rules.Scale, rules.DefaultWeight));
        Assert.Equal(81, rules.EmojiRangeCount);
        Assert.True(rules.HasTld("ee") && rules.IsTrailing('…'));
        // The real file with one value changed, so each guard rejects it rather than the parser.
        var json = File.ReadAllText(Path.Combine(FixtureLoader.SharedRoot, "data", "share-text.json"));
        // The cut needs one ellipsis scalar among trailing punctuation that stands alone: not a combining mark, a Hangul vowel NFC
        // composes, or a pictograph that joins a ZWJ sequence.
        var ellipsis = "\"ellipsis\": \"\\u2026\"";
        foreach (var (original, replacement) in new[] { ("\"shareTextVersion\": 1,", "\"shareTextVersion\": 2,"),
            ("\"ranges\": [[8986, 8987], [9193, 9196]", "\"ranges\": [[8986, 9193], [9193, 9196]"), (ellipsis, "\"ellipsis\": \"...\""),
            (ellipsis, "\"ellipsis\": \"~\""), (")]}>", ")]}>\\u0301"), (")]}>", ")]}>\\u1161"), (")]}>", ")]}>\\u203c") })
        {
            Assert.Contains(original, json, StringComparison.Ordinal);
            Assert.Throws<FormatException>(() => ShareTextRules.Parse(json.Replace(original, replacement, StringComparison.Ordinal)));
        }
        var root = Directory.CreateTempSubdirectory("voxclip-share-");
        try
        {
            Assert.Equal(VoxClipErrorCode.SharedResourcesMissing, Assert.Throws<VoxClipException>(() => ShareTextRulesLoader.Load(root.FullName)).Code);
            Directory.CreateDirectory(Path.Combine(root.FullName, "data"));
            File.WriteAllText(Path.Combine(root.FullName, "data", "share-text.json"), "{");
            Assert.Equal(VoxClipErrorCode.SharedResourcesMissing, Assert.Throws<VoxClipException>(() => ShareTextRulesLoader.Load(root.FullName)).Code);
        }
        finally { root.Delete(true); }
    }

    [Fact]
    public void AFailedLoadIsKeptForTheProcess()
    {
        // As the Mac keeps its Result: a process that failed the preflight never loads mid-session or reads the root again.
        var root = Directory.CreateTempSubdirectory("voxclip-share-");
        try
        {
            var loads = 0;
            var cache = ShareTextRulesLoader.CreateCache(() => { loads++; return ShareTextRulesLoader.Load(root.FullName); });
            Assert.Equal(VoxClipErrorCode.SharedResourcesMissing, Assert.Throws<VoxClipException>(() => cache.Value).Code);
            Directory.CreateDirectory(Path.Combine(root.FullName, "data"));
            File.Copy(Path.Combine(FixtureLoader.SharedRoot, "data", "share-text.json"), Path.Combine(root.FullName, "data", "share-text.json"));
            Assert.Equal(VoxClipErrorCode.SharedResourcesMissing, Assert.Throws<VoxClipException>(() => cache.Value).Code);
            Assert.Equal(1, loads);
            // The next process finds the file.
            Assert.Equal(81, ShareTextRulesLoader.CreateCache(() => ShareTextRulesLoader.Load(root.FullName)).Value.EmojiRangeCount);
        }
        finally { root.Delete(true); }
    }

    [Fact]
    public void EveryCaseMatchesOnThisPlatform()
    {
        var cases = Fixture().GetProperty("cases").EnumerateArray().ToArray();
        Assert.Equal(76, cases.Length);
        var failures = new List<string>();
        void Check<T>(string name, string field, T expected, T actual)
        {
            if (!EqualityComparer<T>.Default.Equals(expected, actual)) failures.Add($"{name} {field}: expected {expected}, got {actual}");
        }
        foreach (var item in cases)
        {
            var name = Text(item, "name")!;
            var text = Text(item, "text")!;
            var line = Text(item, "line");
            Check(name, "clusters", ClusterRuns(item.GetProperty("clusters")), ClusterRuns(text));
            Check(name, "xWeight", item.GetProperty("xWeight").GetInt32(), SharePostText.XWeight(text));
            Check(name, "linkedInLength", item.GetProperty("linkedInLength").GetInt32(), SharePostText.LinkedInLength(text));
            Check(name, "voxConvoLength", item.GetProperty("voxConvoLength").GetInt32(), SharePostText.VoxConvoLength(text));
            Check(name, "composerX", Text(item, "composerX"), SharePostText.ComposerText(text, ShareDestination.X, line));
            Check(name, "composerVoxConvo", Text(item, "composerVoxConvo"), SharePostText.ComposerText(text, ShareDestination.VoxConvo, line));
            Check(name, "linkedIn", text, SharePostText.ComposerText(text, ShareDestination.LinkedIn, line));
            if (line is null) { Check(name, "fieldText", text, SharePostText.FieldText(text, null)); continue; }
            Check(name, "present", item.GetProperty("present").GetBoolean(), ShareDisclosure.IsPresent(text, line));
            Check(name, "fieldText", Text(item, "fieldText"), SharePostText.FieldText(text, line));
        }
        Assert.Empty(failures);
    }

    [Fact]
    public void TruncatedTextKeepsTheLineLastAndFitsTheLimit()
    {
        foreach (var item in Fixture().GetProperty("cases").EnumerateArray())
        {
            var text = Text(item, "text")!;
            var line = Text(item, "line");
            var present = item.TryGetProperty("present", out var value) && value.GetBoolean();
            foreach (var (destination, output) in new[] { (ShareDestination.X, Text(item, "composerX")!), (ShareDestination.VoxConvo, Text(item, "composerVoxConvo")!) })
            {
                if (output == text) continue;
                var measure = destination == ShareDestination.X ? SharePostText.XWeight(output) : SharePostText.VoxConvoLength(output);
                Assert.True(measure <= SharePostText.Limit(destination), $"{Text(item, "name")} {destination}");
                if (line is not null && present) Assert.True(output == line || output.EndsWith("\n\n" + line, StringComparison.Ordinal), $"{Text(item, "name")} {destination}");
            }
            if (line is not null && !present && Text(item, "fieldText") is { } field)
                Assert.True(SharePostText.LinkedInLength(field) <= 3000 && (field == line || field.EndsWith("\n\n" + line, StringComparison.Ordinal)), $"{Text(item, "name")} fieldText");
        }
    }

    [Fact]
    public void SpaceFreeCaptionsCutQuickly()
    {
        // 3,000 scalars without White_Space: only the first-word fallback cuts them. A word with '.' or ':' was scanned from the
        // longest cut down, about 0.2 s in a Release build; one pass weighs every cut now.
        var japanese = string.Concat(Enumerable.Repeat("今日はVoxClipで動画を編集しました。YouTubeとXに投稿！", 90));
        foreach (var caption in new[] { japanese[..3000], ("今日は12:30に" + japanese)[..3000], ("VoxClip1.0で" + japanese)[..3000],
            string.Concat(Enumerable.Repeat("_a", 1500)), "a." + new string('a', 2998), string.Concat(Enumerable.Repeat("a.", 1500)), "data:" + new string('A', 2995) })
        {
            Assert.Equal(3000, SharePostText.LinkedInLength(caption));
            var clock = System.Diagnostics.Stopwatch.StartNew();
            var text = SharePostText.ComposerText(caption, ShareDestination.X, null);
            clock.Stop();
            Assert.True(SharePostText.XWeight(text) <= 280 && text.EndsWith('…'));
            Assert.True(clock.Elapsed < TimeSpan.FromSeconds(1), clock.Elapsed.ToString());
        }
    }

    [Fact]
    public void XFirstWordCutsMatchTheLongestFirstScan()
    {
        // Random space-free words, many with a URL that comes and goes as the cut grows; the definition scans every cut from the
        // longest down, each measured whole.
        var rules = ShareTextRulesLoader.Current;
        static string C(params int[] scalars) => string.Concat(scalars.Select(char.ConvertFromUtf32));
        string[] heavy = ["日本", C(0x1F642), "x", "aa", "見"];
        string[] pool = ["日本", "a", "b", "co", "com", "ee", "info", ".", ".", ":", "/", "//", "https://", "Http://", "voxconvo", "-", "@", "_", "8080",
            "80", ")", "!", ".,", C(0x2026), C(0x201D), C(0x1F642), C(0x1F1EA, 0x1F1EA), C(0x1F1EA), C(0x1F44D, 0x1F3FD), C(0x600), C(0x301), C(0xFE0F),
            C(0x200D), "x", "1.0", ".com", ":443/", "www.", "a.co_", "?q=1"];
        string[] urls = ["https://", "_voxconvo.com/", "_voxconvo.com:8080", "_a.co", "(www.voxconvo.ee/", C(0x600) + "http://"];
        var random = new Random(11);
        T Pick<T>(T[] items) => items[random.Next(items.Length)];
        var failures = new List<string>();
        int cuts = 0, cutsWithUrl = 0;
        for (var count = 0; count < 120; count++)
        {
            var withUrl = random.Next(2) == 0;
            var weight = Pick(withUrl ? new[] { 150, 200, 240, 255 } : new[] { 180, 230, 260, 275 });
            var word = new StringBuilder();
            while (rules.XWeight(word.ToString()) < weight) word.Append(Pick(heavy));
            if (withUrl)
            {
                word.Append(Pick(urls));
                for (var piece = Pick(new[] { 0, 3, 10, 40 }); piece > 0; piece--) word.Append(Pick(pool));
                word.Insert(word.Length, Pick(new[] { ")", "!.", C(0x2026), ".,", ")]" }), Pick(new[] { 5, 20, 60 }));
            }
            else for (var piece = Pick(new[] { 10, 30, 60, 120 }); piece > 0; piece--) word.Append(Pick(pool));
            var line = Pick(new string?[] { null, null, "Line." });
            var lead = Pick(new[] { "", " ", "\n", " " + C(0x301) });
            var caption = lead + word + (line is null ? "" : "\n\n" + line);
            var text = rules.ComposerText(caption, ShareDestination.X, line);
            var expected = rules.XWeight(caption) <= rules.XLimit ? caption : LongestFirstCut((lead + word).Normalize(NormalizationForm.FormC), line, rules);
            if (text != expected) failures.Add(string.Join(" ", caption.EnumerateRunes().Select(rune => rune.Value.ToString("X", CultureInfo.InvariantCulture))));
            if (text != caption) cuts++;
            if (text != caption && rules.UrlRanges(text.Normalize(NormalizationForm.FormC)).Count > 0) cutsWithUrl++;
        }
        Assert.Empty(failures);
        Assert.True(cuts >= 50 && cutsWithUrl >= 15, $"{cuts} cuts, {cutsWithUrl} with a URL");
    }

    /// <summary>Composer rule 5 for a body that is one word after leading White_Space: every cut from the longest down, each measured
    /// whole, as publishing §2.1 defines it.</summary>
    private static string LongestFirstCut(string body, string? line, ShareTextRules rules)
    {
        var tail = line is null ? "" : "\n\n" + line;
        var ends = new List<int> { 0 };
        for (var offset = 0; offset < body.Length;) ends.Add(offset += StringInfo.GetNextTextElementLength(body.AsSpan(offset)));
        for (var index = ends.Count - 1; index >= 0; index--)
        {
            if (ends[index] >= body.Length) continue;
            var text = ShareDisclosure.TrimEnd(body[..ends[index]]) + rules.Ellipsis + tail;
            if (rules.XWeight(text) <= rules.XLimit) return text;
        }
        return line ?? rules.Ellipsis;
    }

    [Fact]
    public void CaptionsCapAt3000Scalars()
    {
        // share.captions holds 3,000 Unicode scalars on both platforms; an emoji is one scalar but two UTF-16 units.
        var emoji = char.ConvertFromUtf32(0x1F642);
        Assert.Equal(string.Concat(Enumerable.Repeat(emoji, 3000)), SharePostText.CapCaption(string.Concat(Enumerable.Repeat(emoji, 3001))));
        var mixed = SharePostText.CapCaption("a" + string.Concat(Enumerable.Repeat(emoji, 3001)));
        Assert.Equal((3000, 5999), (SharePostText.LinkedInLength(mixed), mixed.Length));
        var exact = string.Concat(Enumerable.Repeat("a" + (char)0x301, 1500));
        Assert.Equal(exact, SharePostText.CapCaption(exact));
        Assert.Equal(exact, SharePostText.CapCaption(exact + "b"));
        // Scalars, not clusters, as ProjectValidation counts them: a combining mark past the cap is dropped.
        Assert.Equal(new string('a', 2999) + "e", SharePostText.CapCaption(new string('a', 2999) + "e" + (char)0x301));
        // A lone surrogate counts as one, as LinkedInLength counts it.
        Assert.Equal((char)0xD800 + new string('a', 2999), SharePostText.CapCaption((char)0xD800 + new string('a', 3000)));
        Assert.Equal("", SharePostText.CapCaption(""));
    }

    [Fact]
    public void DefaultCaptions()
    {
        var items = Fixture().GetProperty("defaultCaptions").EnumerateArray().ToArray();
        Assert.Equal(12, items.Length);
        foreach (var item in items)
        {
            var words = item.GetProperty("words").EnumerateArray().Select(word => word.GetString()!).ToArray();
            Assert.Equal(Text(item, "expected"), SharePostText.DefaultCaption(Text(item, "title"), words));
        }
    }

    [Fact]
    public void DisclosureCopyIsVerbatim()
    {
        Assert.Equal("Your post no longer says the video contains AI-modified parts.", ShareDisclosure.RemovedWarning);
        Assert.Equal(("Share anyway", "Restore line"), (ShareDisclosure.ShareAnyway, ShareDisclosure.RestoreLine));
        Assert.Equal("Turn on 'Made with AI' in the post's content disclosure before posting.", ShareDisclosure.XMadeWithAiTip);
        Assert.True(ShareDisclosure.IsPresent("Caption", " \n "));
        Assert.Equal("Line.", SharePostText.FieldText("", "Line."));
        Assert.Equal("Caption\n\nLine.", SharePostText.FieldText("Caption \n", "Line."));
    }

    [Fact]
    public void LoneSurrogatesCountAsReplacementCharacters()
    {
        // A Swift string holds a lone surrogate as U+FFFD, so C# reads it the same way instead of failing in NFC.
        Assert.Equal(4, SharePostText.XWeight("a\uD800b"));
        Assert.Equal("a�", SharePostText.ComposerText("a\uD800" + new string(' ', 3000), ShareDestination.VoxConvo, null));
        Assert.False(ShareDisclosure.IsPresent("\uDC00", "Line."));
        Assert.Equal("a�\n\nLine.", SharePostText.FieldText("a\uD800", "Line."));
    }
}
