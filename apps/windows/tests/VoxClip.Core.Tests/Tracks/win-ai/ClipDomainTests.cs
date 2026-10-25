using System.Text.Json.Nodes;
using VoxClip.Core.Domain.Editing;
using VoxClip.Core.Domain.Clips;
using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Services.LLM;
using Xunit;
using static VoxClip.Core.Tests.Tracks.WinAi.AiTestSupport;

namespace VoxClip.Core.Tests.Tracks.WinAi;

[Trait("Track", "win-ai")]
public sealed class ClipDomainTests
{
    [Fact]
    public void AppleSchemaNamesIncludeEveryObjectArrayAndEnumPath()
    {
        var request = Catalog().TestRequest(ConnectorId.AppleFoundation) with
        {
            SchemaName = "root",
            Schema = JsonNode.Parse("""
                {"type":"object","properties":{"nested":{"type":"object","properties":{"items":{"type":"array","items":{"type":"object","properties":{"kind":{"type":"string","enum":["yes","no"]},"value":{"type":"number"}}}}}}}}
                """)!.AsObject()
        };
        var root = FoundationRequest.Logical(request, 27, null)["schema"]!["root"]!;
        Assert.Equal("root", root["name"]!.GetValue<string>());
        var nested = root["properties"]![0]!["schema"]!;
        Assert.Equal("root_nested", nested["name"]!.GetValue<string>());
        var item = nested["properties"]![0]!["schema"]!["arrayOf"]!;
        Assert.Equal("root_nested_items_item", item["name"]!.GetValue<string>());
        Assert.Equal("root_nested_items_item_kind", item["properties"]![0]!["schema"]!["name"]!.GetValue<string>());
        Assert.Null(item["properties"]![1]!["schema"]!["name"]);
    }

    [Theory]
    [InlineData(0.05, "0.1")]
    [InlineData(0.15, "0.1")]
    [InlineData(0.25, "0.3")]
    [InlineData(0.35, "0.3")]
    [InlineData(0.45, "0.5")]
    [InlineData(1.25, "1.3")]
    [InlineData(1.45, "1.4")]
    [InlineData(2.05, "2.0")]
    [InlineData(2.25, "2.3")]
    [InlineData(9.95, "9.9")]
    [InlineData(99.95, "100.0")]
    [InlineData(1.2499999999999998, "1.2")]
    [InlineData(1.2500000000000002, "1.3")]
    public void JsFixedRoundingUsesExactBinaryValue(double value, string expected) => Assert.Equal(expected, EditingFormat.ToFixed1(value));

    [Theory]
    [InlineData(0, "0:00")]
    [InlineData(5.9, "0:05")]
    [InlineData(70, "1:10")]
    [InlineData(200, "3:20")]
    [InlineData(4523.7, "75:23")]
    public void TimeNeverWrapsMinutes(double seconds, string expected) => Assert.Equal(expected, ClipText.Time(seconds));

    [Fact]
    public void TranscriptIncludesEventsCutsCorrectionsAndExactSentenceRules()
    {
        TimedWord[] words = [Word(0, "works.\"", 0, 1.6), Word(1, "correct me", 3.85, 4), Word(2, "です。」", 4, 4.5), Word(3, "(laughs)", 4.5, 4.8, WordKind.Event), Word(4, "not shown", 4.8, 5, WordKind.UnlabeledSpeech)];
        Assert.Equal("[0-0] 0:00 works.\"\n(pause 2.3s)\n[1-4] 0:03 corrected です。」 (laughs) …", ClipValidation.FormatTranscript(words, new Dictionary<string, string> { ["w1"] = "corrected", ["w3"] = "ignore event correction" }));
        var entries = Enumerable.Range(0, 43).Select(index => new ClipWord(index * 2, "w", index, index + 0.9)).ToArray();
        var lines = ClipText.Lines(entries);
        Assert.Equal(80, lines[0].Line.LastIndex);
        Assert.Equal(82, lines[1].Line.FirstIndex);
        Assert.Equal(41, lines[0].LastPosition - lines[0].FirstPosition + 1);
    }

    [Fact]
    public void JsTrimAndUtf16LimitsPreserveSurrogatePairs()
    {
        Assert.Equal("keep", ClipText.Trim("\ufeff\u00a0keep\u3000"));
        Assert.Equal("\u0085keep\u0085", ClipText.Trim("\u0085keep\u0085"));
        Assert.Equal("a", ClipText.Limit("a😀z", 2));
        Assert.Equal("a😀", ClipText.Limit("a😀z", 3));
    }

    [Fact]
    public void FinalizerMatchesRankArrivalLengthAndNormalizationVectors()
    {
        RawClip[] candidates = [new("  Strong opener  ", " r1 ", 8.6, 0, 20), new("Best", "r2", 9, 10, 30), new("Duplicate", "r3", 7, 10, 30), new("Too short", "r4", 10, 50, 55),
            new("Out of range", "r5", 10, 40, 130), new("Reversed", "r6", 10, 60, 59), new("Clamped score", "r7", 12, 60, 99), new("Fractional", "r8", 10, 5.5, 30),
            new(new string('T', 130), new string('R', 310), 6, 20, 45), new("Low score", "r10", -3.5, 70, 90), new("Too long", "r11", 9, 0, 99), new("Tie A", "r12", 6, 30, 50)];
        var result = Finalize(candidates, ClipPreset.Best);
        Assert.Equal(new[] { "Strong opener", "Best", new string('T', 120), "Tie A", "Clamped score" }, result.Clips.Select(clip => clip.Title));
        Assert.Equal(new[] { 9, 9, 6, 6, 10 }, result.Clips.Select(clip => clip.Score));
        Assert.Equal(300, result.Clips[2].Reason.Length);
        Assert.Equal(7, result.DroppedItems);
    }

    [Fact]
    public void TopicOverlapIsInclusiveAndQuotesKeepEarlierTies()
    {
        RawClip[] topics = [new("A", "a", 7, 0, 30), new("B", "b", 8, 30, 60), new("C", "c", 6, 61, 99), new("D", "d", 9, 70, 90), new("E", "e", 5, 0, 20)];
        Assert.Equal(new[] { "E", "B", "D" }, Finalize(topics, ClipPreset.Topics).Clips.Select(clip => clip.Title));
        var quotes = Enumerable.Range(0, 8).Select(index => new RawClip("Q" + index, "q", index % 2 == 0 ? 7 : 8, 12 * index, 12 * index + 5)).ToArray();
        Assert.Equal(new[] { "Q0", "Q1", "Q2", "Q3", "Q5", "Q7" }, Finalize(quotes, ClipPreset.Quotes).Clips.Select(clip => clip.Title));
    }

    [Theory]
    [InlineData(7, 14, 6, 15)]
    [InlineData(2, 9, 0, 10)]
    [InlineData(12, 14, 11, 15)]
    [InlineData(30, 40, 30, 40)]
    [InlineData(17, 17, 17, 18)]
    [InlineData(15, 15, 15, 15)]
    public void SnappingHasAsymmetricTiesAndReversalGuard(int start, int end, int expectedStart, int expectedEnd)
    {
        var starts = new[] { 0, 6, 11, 13, 16, 17, 19, 60, 66 };
        var ends = new[] { 5, 10, 12, 15, 16, 18, 59, 65, 66 };
        Assert.Equal((expectedStart, expectedEnd), ClipText.Snap(start, end, starts.Zip(ends, (first, last) => new TranscriptLine(first, last, 0, 0, "")).ToArray()));
    }

    [Fact]
    public void MostlyCutAndWindowDeDupOnlyFilterWhenApplicable()
    {
        RawClip[] candidates = [new("A", "", 8, 10, 30), new("B", "", 8, 12, 32), new("C", "", 7, 40, 60)];
        Assert.Equal(new[] { "A", "B", "C" }, Finalize(candidates, ClipPreset.Best).Clips.Select(clip => clip.Title));
        Assert.Equal(new[] { "A", "C" }, Finalize(candidates, ClipPreset.Best, windows: 2).Clips.Select(clip => clip.Title));
        RawClip[] cutCandidates = [new("cut", "", 9, 0, 20), new("keep", "", 9, 30, 50)];
        var cuts = Enumerable.Range(0, 11).Concat(Enumerable.Range(30, 10)).Select(index => "w" + index).ToHashSet();
        Assert.Equal("keep", Assert.Single(Finalize(cutCandidates, ClipPreset.Best, cuts).Clips).Title);
        Assert.Empty(Finalize([new("nan", "", double.NaN, 0, 20), new("infinite", "", 7, 0, double.PositiveInfinity)], ClipPreset.Best).Clips);
    }

    [Fact]
    public void WindowsUseAbsoluteNumbersAndBoundedContext()
    {
        var words = Enumerable.Range(0, 20000).Select(index => Word(index, "w" + index + (index % 15 == 14 ? "." : ""), 0.3 * index, 0.3 * index + 0.25)).ToArray();
        var prompts = new ClipPrompts(Catalog());
        var lines = ClipText.Lines(ClipText.Entries(words, new Dictionary<string, string>()));
        var windows = prompts.Windows(lines, ClipPreset.Best, "", words[^1].End, 128000, 16000);
        Assert.Equal(new[] { (0, 7994), (7800, 15794), (15600, 19999) }, windows.Select(window => (window.Lines[0].Line.FirstIndex, window.Lines[^1].Line.LastIndex)));
        Assert.Equal(3, prompts.WindowClips(ClipPreset.Best, windows.Count));
        var small = prompts.Windows(lines, ClipPreset.Best, "", words[^1].End, 8192, 1500);
        Assert.All(small, window => Assert.True(window.EstimatedTokens <= window.Budget));
        Assert.All(small.SelectMany(window => window.Lines), line => Assert.Contains(line, lines));
        Assert.Throws<LlmException>(() => prompts.Windows(lines, ClipPreset.Best, "", words[^1].End, 1024, 1500));
        var tighten = ClipWindowing.Pack(lines, 50000, 2000, 0);
        Assert.All(tighten.Zip(tighten.Skip(1)), pair => Assert.Equal(pair.First.Lines[^1].Line.LastIndex + 1, pair.Second.Lines[0].Line.FirstIndex));
    }

    [Fact]
    public void RequestsLoadEveryPresetFromTheSharedSource()
    {
        var prompts = new ClipPrompts(Catalog());
        foreach (var preset in Enum.GetValues<ClipPreset>())
        {
            var instruction = prompts.Instruction(preset, prompts.Instructions("  Funny bits  "), 200.5);
            var presetInstruction = prompts.Preset(preset)["instruction"]!.GetValue<string>();
            Assert.Equal("The recording is 3:20 long.\n" + (presetInstruction.Length > 0 ? presetInstruction + "\nAlso: " : "") + "Funny bits", instruction);
        }
        Assert.Equal("The recording is 3:20 long.\nFind the 3 to 5 strongest moments. Each clip should be 20 to 60 seconds long.", prompts.Instruction(ClipPreset.Best, "", 200.5));
    }

    [Theory]
    [InlineData("So, we went to the store.", "w41,w42,w46,w47", true)]
    [InlineData("so WE went to the store", "w41,w42,w46,w47", true)]
    [InlineData("", "w40,w41,w42,w43,w44,w45,w46,w47,w48,w49", true)]
    [InlineData("store", "w40,w41,w42,w43,w44,w45,w46,w47,w48", false)]
    public void TightenAlignsFromTheRightAndMarksLargeCutsForReview(string keep, string ids, bool selected)
    {
        var words = Words(50);
        var texts = new[] { "So,", "um,", "we", "we", "went", "to", "the", "uh", "the", "store." };
        var entries = texts.Select((text, index) => new ClipWord(40 + index, text, index, index + 0.8)).ToArray();
        var result = TightenVerifier.Verify(new JsonArray(new JsonObject { ["line"] = "[40-49]", ["keep"] = keep, ["kind"] = "filler" }), entries, words, new ClipPrompts(Catalog()).Tighten);
        var proposal = Assert.Single(result.Proposals);
        Assert.Equal(ids.Split(','), proposal.CutWordIds);
        Assert.Equal(selected, proposal.Preselected);
    }

    [Fact]
    public void TightenRejectsSubstitutionsUnknownLinesDuplicatesAndSplitCorrections()
    {
        var words = Words(64);
        var entries = new[] { new ClipWord(50, "going to", 0, 1), new ClipWord(51, "win.", 1, 2) };
        var edits = JsonNode.Parse("[{\"line\":\"[50-51]\",\"keep\":\"going win\",\"kind\":\"filler\"},{\"line\":\"[99-120]\",\"keep\":\"\",\"kind\":\"filler\"},{\"line\":\"[50-51]\",\"keep\":\"win\",\"kind\":\"filler\"}]")!.AsArray();
        var result = TightenVerifier.Verify(edits, entries, words, new ClipPrompts(Catalog()).Tighten);
        Assert.Empty(result.Proposals); Assert.Equal(3, result.RejectedCount);
        var substitutions = JsonNode.Parse("[{\"line\":\"[50-51]\",\"keep\":\"going shop\",\"kind\":\"detour\"}]")!.AsArray();
        Assert.Equal(1, TightenVerifier.Verify(substitutions, entries, words, new ClipPrompts(Catalog()).Tighten).RejectedCount);
    }

    [Fact]
    public void TightenPunctuationFollowsNearestTokenAndScopeOmitsExistingCuts()
    {
        var words = Words(64);
        var entries = new[] { new ClipWord(60, "Well", 0, 1), new ClipWord(61, "—", 1, 2), new ClipWord(62, "um", 2, 3), new ClipWord(63, "yes.", 3, 4) };
        var edit = new JsonArray(new JsonObject { ["line"] = "[60-63]", ["keep"] = "Well yes.", ["kind"] = "filler" });
        Assert.Equal(new[] { "w62" }, Assert.Single(TightenVerifier.Verify(edit, entries, words, new ClipPrompts(Catalog()).Tighten).Proposals).CutWordIds);
        var filtered = TightenVerifier.Entries(words, new Dictionary<string, string>(), new HashSet<string> { "w61" }, 60, 63);
        Assert.Equal(new[] { 60, 62, 63 }, filtered.Select(word => word.Index));
        Assert.Equal("w61", words[61].Text);
    }

    private static FinalizeClipsResult Finalize(IReadOnlyList<RawClip> candidates, ClipPreset preset, IReadOnlySet<string>? cuts = null, int windows = 1) =>
        ClipValidation.FinalizeClips(new(candidates, Words(100), new ClipPrompts(Catalog()).Rules(preset), [], cuts ?? new HashSet<string>(), windows, false));
}
