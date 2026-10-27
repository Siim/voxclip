using System.Globalization;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Domain.Transcript;
using VoxClip.Core.Domain.VoiceLab;
using VoxClip.Tests.Support;
using Xunit;

namespace VoxClip.Core.Tests.Tracks.VoiceLabPatch;

public sealed class VoiceLabWordDiffTests
{
    public static TheoryData<JsonElement> DiffCases => Load("word-diff-cases.json", 129);
    public static TheoryData<JsonElement> LengthCases => Load("length-budget-cases.json", 53);

    static TheoryData<JsonElement> Load(string file, int count)
    {
        using var document = FixtureLoader.ReadJson("fixtures/voice-lab/" + file);
        Assert.Equal(count, document.RootElement.GetProperty("caseCount").GetInt32());
        var rows = document.RootElement.GetProperty("cases").EnumerateArray().ToArray();
        Assert.Equal(count, rows.Length);
        TheoryData<JsonElement> result = [];
        foreach (var row in rows) result.Add(Expand(row));
        return result;
    }

    static JsonElement Expand(JsonElement row)
    {
        if (!row.TryGetProperty("sourceRepeat", out var source)) return row.Clone();
        var expanded = JsonNode.Parse(row.GetRawText())!.AsObject();
        double step = source.GetProperty("timingStep").GetDouble();
        double halfStep = step / 2;
        JsonArray words = [];
        for (int index = 0; index < source.GetProperty("count").GetInt32(); index++)
        {
            double position = index;
            double start = position * step;
            double end = start + halfStep;
            words.Add(new JsonArray(source.GetProperty("idPrefix").GetString() + index.ToString(CultureInfo.InvariantCulture),
                source.GetProperty("token").GetString(), start, end, "word"));
        }
        expanded["source"] = words;
        var fresh = row.GetProperty("newTextRepeat");
        expanded["newText"] = string.Join(" ", Enumerable.Repeat(fresh.GetProperty("token").GetString()!, fresh.GetProperty("count").GetInt32()));
        if (row.GetProperty("expected").TryGetProperty("repeatedOps", out var pattern))
        {
            JsonArray ops = [];
            for (int index = 0; index < pattern.GetProperty("count").GetInt32(); index++)
                ops.Add(new JsonArray(pattern.GetProperty("kind").GetString(),
                    pattern.GetProperty("idPrefix").GetString() + index.ToString(CultureInfo.InvariantCulture),
                    pattern.GetProperty("sourceToken").GetString(), pattern.GetProperty("newToken").GetString()));
            expanded["expected"]!["ops"] = ops;
        }
        return JsonSerializer.Deserialize<JsonElement>(expanded.ToJsonString());
    }

    [Theory]
    [MemberData(nameof(DiffCases))]
    public void SharedWordDiffVector(JsonElement vector)
    {
        var source = Words(vector.GetProperty("source"));
        string text = vector.GetProperty("newText").GetString()!;
        var expected = vector.GetProperty("expected");
        if (expected.TryGetProperty("error", out _))
        {
            var error = Assert.Throws<VoiceLabWordDiffException>(() => VoiceLabWordDiff.Diff(source, text));
            Assert.Equal(VoiceLabWordDiffErrorCode.TokenLimit, error.Code);
            Assert.Equal(expected.GetProperty("side").GetString() == "source" ? VoiceLabDiffSide.Source : VoiceLabDiffSide.NewText, error.Side);
            Assert.Equal(expected.GetProperty("count").GetInt32(), error.Count);
            Assert.Equal(expected.GetProperty("limit").GetInt32(), error.Limit);
            return;
        }
        var result = VoiceLabWordDiff.Diff(source, text);
        var ops = expected.GetProperty("ops").EnumerateArray().ToArray();
        Assert.Equal(ops.Length, result.Ops.Count);
        bool inserted = false;
        for (int index = 0; index < ops.Length; index++)
        {
            var op = result.Ops[index];
            Assert.Equal(ops[index][0].GetString(), Name(op.Kind));
            Assert.Equal(ops[index][1].GetString(), op.SourceWordId);
            Assert.Equal(ops[index][2].GetString(), op.SourceToken);
            Assert.Equal(ops[index][3].GetString(), op.NewToken);
            if (op.Kind == VoiceLabDiffOpKind.Equal) inserted = false;
            if (op.Kind == VoiceLabDiffOpKind.Delete) Assert.False(inserted);
            if (op.Kind == VoiceLabDiffOpKind.Insert) inserted = true;
        }
        var hunks = expected.GetProperty("hunks").EnumerateArray().ToArray();
        Assert.Equal(hunks.Length, result.Hunks.Count);
        for (int index = 0; index < hunks.Length; index++)
        {
            var hunk = result.Hunks[index];
            var target = hunks[index];
            Assert.Equal(target.GetProperty("kind").GetString(), Name(hunk.Kind));
            Assert.Equal(Strings(target, "sourceWordIds"), hunk.SourceWordIds);
            Assert.Equal(Strings(target, "newTokens"), hunk.NewTokens);
            Assert.Equal(Strings(target, "correctedTexts"), hunk.CorrectedTexts);
            Assert.Equal(Strings(target, "absorbedItemIds"), hunk.AbsorbedItemIds);
            Assert.Equal(Strings(target, "bridgeWordIds"), hunk.BridgeWordIds);
            Assert.Equal(target.GetProperty("sourceStartIndex").GetInt32(), hunk.SourceStartIndex);
            Assert.Equal(target.GetProperty("sourceEndIndex").GetInt32(), hunk.SourceEndIndex);
            Assert.Equal(NullableNumber(target.GetProperty("anchorSeconds")), hunk.AnchorSeconds);
        }
        int wordItems = vector.GetProperty("transcriptWordItems").GetInt32();
        int events = vector.GetProperty("transcriptEvents").GetInt32();
        var transcript = Enumerable.Range(0, wordItems).Select(index => Word("t" + index, "word", index, index + .5))
            .Concat(Enumerable.Range(0, events).Select(index => Word("e" + index, "noise", 0, .1, WordKind.Event))).ToArray();
        var budget = VoiceLabPatchBudget.Evaluate(result, transcript);
        var targetBudget = expected.GetProperty("budget");
        Assert.Equal(targetBudget.GetProperty("voiceTokenCount").GetInt32(), budget.VoiceTokenCount);
        Assert.Equal(targetBudget.GetProperty("wordItems").GetInt32(), budget.WordItems);
        Assert.Equal(targetBudget.GetProperty("flag").GetString(), Name(budget.Flag));
        Assert.Equal(targetBudget.GetProperty("copy").GetString(), budget.Copy);
        var texts = vector.GetProperty("patchTexts").EnumerateArray().Select(text => text.GetString()).ToArray();
        var meters = result.Hunks.Where(hunk => hunk.Kind == VoiceLabDiffHunkKind.Voice)
            .Select((hunk, index) => VoiceLabFitMeter.Measure(texts[index] ?? string.Join(" ", hunk.NewTokens), Window(), .4, .4, 10,
                string.Join(" ", hunk.NewTokens))).ToArray();
        var catalog = VoiceLabPriceCatalog.Parse(Encoding.UTF8.GetBytes(FixtureLoader.ReadText("catalog/voice-lab.json")));
        var summary = VoiceLabDiffSummary.Make(result, meters, catalog, "eleven_v3", 3, patchTexts: texts);
        var header = expected.GetProperty("summary");
        Assert.Equal(header.GetProperty("cutCount").GetInt32(), summary.CutCount);
        Assert.Equal(header.GetProperty("revoicedPhrases").GetInt32(), summary.RevoicedPhrases);
        Assert.Equal(header.GetProperty("estimateSeconds").GetDouble(), summary.EstimateSeconds);
        Assert.Equal(NullableNumber(header.GetProperty("costUnits")), summary.CostEstimate?.Units);
        string? usd = header.GetProperty("usd").GetString();
        Assert.Equal(usd is null ? (decimal?)null : decimal.Parse(usd, CultureInfo.InvariantCulture), summary.CostEstimate?.Usd);
        Assert.Equal(header.GetProperty("copy").GetString(), summary.Copy);
        var noPrice = VoiceLabDiffSummary.Make(result, meters);
        Assert.Null(noPrice.CostEstimate);
        var unknown = VoiceLabDiffSummary.Make(result, meters, catalog, "not-listed", patchTexts: texts);
        Assert.Null(unknown.CostEstimate?.Usd);
        Assert.Equal(noPrice.Copy, unknown.Copy);
        Assert.Equal(noPrice.Copy + (summary.CostEstimate?.Usd is decimal cost ? " · " + VoiceLabCostPresentation.Format(cost) : ""), summary.Copy);
    }

    [Theory]
    [MemberData(nameof(LengthCases))]
    public void SharedLengthBudgetVector(JsonElement vector)
    {
        var expected = vector.GetProperty("expected");
        if (expected.TryGetProperty("error", out var code))
        {
            var error = Assert.Throws<VoiceLabLengthBudgetException>(() => ReplayLength(vector));
            Assert.Equal(code.GetString(), Name(error.Code));
        }
        else ReplayLength(vector);
    }

    static void ReplayLength(JsonElement vector)
    {
        var input = vector.GetProperty("input");
        var expected = vector.GetProperty("expected");
        switch (vector.GetProperty("kind").GetString())
        {
            case "rate":
                var candidates = input.GetProperty("candidates").EnumerateArray()
                    .Select(row => new VoiceLabRateCandidate(row[0].GetString()!, row[1].GetDouble(), row[2].GetDouble())).ToArray();
                var rate = VoiceLabLengthBudget.Rate(Words(input.GetProperty("transcript")), input.GetProperty("pauseThresholdSeconds").GetDouble(), candidates);
                Assert.Equal(expected.GetProperty("charactersPerSecond").GetDouble(), rate.CharactersPerSecond);
                Assert.Equal(expected.GetProperty("source").GetString(), Name(rate.Source));
                Assert.Equal(expected.GetProperty("textLength").GetInt32(), rate.TextLength);
                Assert.Equal(expected.GetProperty("voicedSeconds").GetDouble(), rate.VoicedSeconds);
                break;
            case "fullTake":
                CheckRange(VoiceLabLengthBudget.FullTake(Words(input.GetProperty("transcript")), input.GetProperty("rate").GetDouble()), expected);
                break;
            default:
                var raw = input.GetProperty("window");
                var window = Window(raw[0].GetDouble(), raw[1].GetDouble(), Kind(raw[2].GetString()!), Kind(raw[3].GetString()!));
                double? incoming = NullableNumber(raw[4]);
                double? outgoing = NullableNumber(raw[5]);
                double charactersPerSecond = input.GetProperty("rate").GetDouble();
                var range = VoiceLabLengthBudget.Calculate(window, incoming, outgoing, input.GetProperty("bridgeLength").GetInt32(), charactersPerSecond);
                CheckRange(range, expected.GetProperty("budget"));
                var meter = VoiceLabFitMeter.Measure(input.GetProperty("text").GetString()!, window, incoming, outgoing,
                    charactersPerSecond, input.GetProperty("newWords").GetString()!, input.GetProperty("multipleHunks").GetBoolean());
                var target = expected.GetProperty("meter");
                Assert.Equal(target.GetProperty("estimateSeconds").GetDouble(), meter.EstimateSeconds);
                Assert.Equal(target.GetProperty("gapSeconds").GetDouble(), meter.GapSeconds);
                Assert.Equal(target.GetProperty("lowerBoundSeconds").GetDouble(), meter.LowerBoundSeconds);
                Assert.Equal(target.GetProperty("upperBoundSeconds").GetDouble(), meter.UpperBoundSeconds);
                Assert.Equal(target.GetProperty("verdict").GetString(), Name(meter.Verdict));
                Assert.Equal(target.GetProperty("copy").GetString(), meter.Copy);
                break;
        }
    }

    [Fact]
    public void PassageResolvesBridgesAndRejectsInvalidInputs()
    {
        TimedWord[] transcript = [Word("w0", "õ ä 12", 0, 1)];
        var window = Window() with { LeftBridgeWordIds = ["w0"] };
        var range = VoiceLabLengthBudget.Passage(window, transcript, .4, .4, 10);
        Assert.Equal(4, range.BridgeLength);
        Assert.Equal(VoiceLabLengthBudget.Calculate(window, .4, .4, 4, 10), range);
        Assert.Throws<VoiceLabLengthBudgetException>(() => VoiceLabLengthBudget.Passage(window, [], .4, .4, 10));
        Assert.Throws<VoiceLabLengthBudgetException>(() => VoiceLabLengthBudget.Estimate("word", double.PositiveInfinity));
        Assert.Throws<VoiceLabLengthBudgetException>(() => VoiceLabFitMeter.Measure("word", window, double.NaN, .4, 10, "word"));
    }

    [Fact]
    public void InvalidDiffInputsAreTyped()
    {
        TimedWord[] source = [Word("w", "old", 0, 1)];
        Assert.Equal(VoiceLabWordDiffErrorCode.InvalidInput,
            Assert.Throws<VoiceLabWordDiffException>(() => VoiceLabWordDiff.Diff(source.Concat(source).ToArray(), "new")).Code);
        Assert.Throws<VoiceLabWordDiffException>(() => VoiceLabWordDiff.Diff([Word("w", "old", double.NaN, 1)], "new"));
        var diff = VoiceLabWordDiff.Diff(source, "new");
        Assert.Throws<VoiceLabLengthBudgetException>(() => VoiceLabDiffSummary.Make(diff, []));
        const string text = "left new right";
        var meter = VoiceLabFitMeter.Measure(text, Window(), .4, .4, 10, "new", true);
        Assert.StartsWith("“new” · ", meter.Copy, StringComparison.Ordinal);
        var catalog = VoiceLabPriceCatalog.Parse(Encoding.UTF8.GetBytes(FixtureLoader.ReadText("catalog/voice-lab.json")));
        var summary = VoiceLabDiffSummary.Make(diff, [meter], catalog, "eleven_v3", patchTexts: [text]);
        Assert.Equal(14, summary.CostEstimate?.Units);
        Assert.Equal(meter.EstimateSeconds, summary.EstimateSeconds);
        Assert.Throws<VoiceLabLengthBudgetException>(() => VoiceLabDiffSummary.Make(diff, [meter], patchTexts: []));
    }

    static void CheckRange(VoiceLabLengthRange range, JsonElement expected)
    {
        Assert.Equal(expected.GetProperty("targetSeconds").GetDouble(), range.TargetSeconds);
        Assert.Equal(expected.GetProperty("edgePadSeconds").GetDouble(), range.EdgePadSeconds);
        Assert.Equal(expected.GetProperty("bridgeLength").GetInt32(), range.BridgeLength);
        Assert.Equal(expected.GetProperty("minChars").GetInt32(), range.MinChars);
        Assert.Equal(expected.GetProperty("maxChars").GetInt32(), range.MaxChars);
        Assert.Equal(expected.GetProperty("advisory").GetBoolean(), range.Advisory);
    }
    static TimedWord[] Words(JsonElement rows) => rows.EnumerateArray().Select(row => Word(row[0].GetString()!, row[1].GetString()!,
        row[2].GetDouble(), row[3].GetDouble(), row[4].GetString() switch { "event" => WordKind.Event, "unlabeledSpeech" => WordKind.UnlabeledSpeech, _ => WordKind.Word })).ToArray();
    static TimedWord Word(string id, string text, double start, double end, WordKind kind = WordKind.Word) =>
        new(id, text, kind, start, end, null, null, null, null, TimingSource.Native);
    static string[] Strings(JsonElement value, string property) => value.GetProperty(property).EnumerateArray().Select(item => item.GetString()!).ToArray();
    static double? NullableNumber(JsonElement value) => value.ValueKind == JsonValueKind.Null ? null : value.GetDouble();
    static string Name<T>(T value) where T : Enum => JsonNamingPolicy.CamelCase.ConvertName(value.ToString());
    static VoiceLabSeamKind Kind(string name) => name switch { "gap" => VoiceLabSeamKind.Gap, "hard" => VoiceLabSeamKind.Hard,
        "none" => VoiceLabSeamKind.None, _ => VoiceLabSeamKind.SynthToSynth };
    static VoiceLabWindow Window(double start = 0, double end = 2, VoiceLabSeamKind left = VoiceLabSeamKind.Gap, VoiceLabSeamKind right = VoiceLabSeamKind.Gap) =>
        new("w0", "w0", [], [], start, end, 0, 0, new(left, start, 0, 0), new(right, end, 0, 0));
}
