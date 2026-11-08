using System.Text.Json.Nodes;
using VoxClip.Core.Domain.Captions;
using VoxClip.Core.Domain.ExportChecks;
using VoxClip.Core.Domain.Loudness;
using VoxClip.Core.Domain.Shared;
using VoxClip.Tests.Support;
using Xunit;

namespace VoxClip.Core.Tests.Tracks.ExportChecks;

/// <summary>The export self-check's rules (ADR-R49) replayed from shared/fixtures/export-check/check-cases.json, which
/// tools/fixtures/export-check/generate_check_cases.py writes, and the numbers file beside it (number-check-cases.json,
/// <c>SpokenNumbers</c>). The macOS Core replays the same files.</summary>
public sealed class ExportCheckReplayTests
{
    const string Path = "fixtures/export-check/check-cases.json";
    const string NumbersPath = "fixtures/export-check/number-check-cases.json";

    static JsonObject Document(string path) => JsonNode.Parse(FixtureLoader.ReadText(path))!.AsObject();

    static double Number(JsonNode? node) => node!.GetValue<double>();
    static string? Text(JsonNode? node) => node?.GetValue<string>();

    internal static ExportCheckInput Input(JsonNode value)
    {
        static ExportCheckTrack? Track(JsonNode? node) => node is null ? null : new(Number(node["start"]), Number(node["end"]));
        var expected = value["expected"]!.AsArray().Select(word => new ExportCheckWord(Text(word!["text"])!, Number(word["start"]), Number(word["end"]),
            word["optional"]?.GetValue<bool>() == true, Text(word["phrase"]))).ToArray();
        var heard = value["heard"] is JsonArray words
            ? words.Select(word => new ExportCheckHeard(Text(word!["text"])!, Number(word["start"]), Number(word["end"]))).ToArray() : null;
        var phrases = value["phrases"]!.AsArray().Select(phrase => new ExportCheckPhrase(Text(phrase!["id"])!, Number(phrase["start"]), Number(phrase["end"]))).ToArray();
        var measured = value["loudness"];
        var loudness = measured is null ? null : new ExportCheckLoudness(Text(measured["setting"]) switch
        {
            "social" => ExportLoudness.Social, "off" => ExportLoudness.Off, var other => throw new InvalidDataException(other),
        }, measured["integratedLufs"]?.GetValue<double>(), measured["truePeakDbtp"]?.GetValue<double>());
        var boxes = value["boxes"]!.AsArray().Select(box =>
        {
            var rect = box!["rect"]!;
            var kind = Text(box["kind"]) switch { "caption" => ExportCheckBoxKind.Caption, "title" => ExportCheckBoxKind.Title, var other => throw new InvalidDataException(other) };
            return new ExportCheckBox(kind, Number(box["time"]), new(Number(rect["x"]), Number(rect["y"]), Number(rect["width"]), Number(rect["height"])));
        }).ToArray();
        var frame = new PixelSize((int)Number(value["frame"]!["width"]), (int)Number(value["frame"]!["height"]));
        return new(expected, heard, Track(value["video"]), Track(value["audio"]), Number(value["frameSeconds"]), loudness, frame)
        {
            Cuts = value["cuts"]!.AsArray().Select(Number).ToArray(), Phrases = phrases, Boxes = boxes,
        };
    }

    /// <summary>Where <paramref name="result"/> differs from <paramref name="expect"/>: the status, the reason, each item's kind, time,
    /// words, band, phrase and value, and the result's own numbers. Numbers compare within 1e-9.</summary>
    static List<string> Differences(ExportCheckResult result, JsonNode expect)
    {
        var found = new List<string>();
        void Near(JsonNode? wanted, double? actual, string what)
        {
            if (wanted is null) { if (actual is not null) found.Add($"{what}: {actual} where none was expected"); return; }
            if (actual is not { } value || Math.Abs(wanted.GetValue<double>() - value) >= 1e-9) found.Add($"{what}: {actual} against {wanted}");
        }
        if (ExportCheck.Name(result.Status) != Text(expect["status"])) found.Add($"status {result.Status} against {expect["status"]}");
        if (result.Reason != Text(expect["reason"])) found.Add($"reason {result.Reason}");
        Near(expect["matched"], result.Matched, "matched");
        Near(expect["total"], result.Total, "total");
        Near(expect["unverified"], result.Unverified, "unverified");
        Near(expect["integratedLufs"], result.IntegratedLufs, "integratedLufs");
        Near(expect["truePeakDbtp"], result.TruePeakDbtp, "truePeakDbtp");
        Near(expect["startOffset"], result.StartOffset, "startOffset");
        Near(expect["endOffset"], result.EndOffset, "endOffset");
        var items = expect["items"]!.AsArray();
        if (items.Count != result.Items.Count) { found.Add($"{result.Items.Count} items against {items.Count}: {string.Join(", ", result.Items)}"); return found; }
        for (var index = 0; index < items.Count; index++)
        {
            var (item, wanted) = (result.Items[index], items[index]!);
            if (ExportCheck.Name(item.Kind) != Text(wanted["kind"])) found.Add($"item {index} kind {item.Kind}");
            Near(wanted["time"], item.Time, $"item {index} time");
            Near(wanted["value"], item.Value, $"item {index} value");
            Near(wanted["limit"], item.Limit, $"item {index} limit");
            if (item.Expected != Text(wanted["expected"])) found.Add($"item {index} expected {item.Expected}");
            if (item.Heard != Text(wanted["heard"])) found.Add($"item {index} heard {item.Heard}");
            if ((item.Band is { } band ? CaptionSafeZones.Name(band) : null) != Text(wanted["band"])) found.Add($"item {index} band {item.Band}");
            if (item.Phrase != Text(wanted["phrase"])) found.Add($"item {index} phrase {item.Phrase}");
            if (item.Reason != Text(wanted["reason"])) found.Add($"item {index} reason {item.Reason}");
            Near(wanted["count"], item.Count, $"item {index} count");
        }
        return found;
    }

    [Fact]
    public void TheFileHasItsSchemaKeysCountsAndConstants()
    {
        var document = Document(Path);
        Assert.Equal(new[] { "schema", "description", "constants", "caseCount", "counts", "cases" }, document.Select(pair => pair.Key));
        Assert.Equal("voxclip-export-check-cases/1", Text(document["schema"]));
        var cases = document["cases"]!.AsArray();
        Assert.Equal(32, document["caseCount"]!.GetValue<int>());
        Assert.Equal(32, cases.Count);
        var counts = document["counts"]!.AsObject();
        Assert.Equal(new[] { "words", "sync", "loudness", "captions" }, counts.Select(pair => pair.Key));
        Assert.Equal(new[] { 11, 7, 7, 7 }, counts.Select(pair => pair.Value!.GetValue<int>()));
        foreach (var (check, count) in counts) Assert.Equal(count!.GetValue<int>(), cases.Count(entry => Text(entry!["check"]) == check));
        Assert.Equal(Enum.GetValues<ExportCheckKind>().Select(ExportCheck.Name), counts.Select(pair => pair.Key));
        // The constants the file was derived with are the engine's.
        var constants = document["constants"]!;
        Assert.Equal(ExportCheck.MatchFloor, Number(constants["matchFloor"]));
        Assert.Equal(ExportCheck.PhraseToleranceSeconds, Number(constants["phraseToleranceSeconds"]));
        Assert.Equal(ExportCheck.TargetLufs, Number(constants["targetLufs"]));
        Assert.Equal(ExportCheck.LoudnessToleranceLu, Number(constants["loudnessToleranceLu"]));
        Assert.Equal(ExportCheck.CeilingDbtp, Number(constants["ceilingDbtp"]));
        Assert.Equal(ExportCheck.TruePeakToleranceDb, Number(constants["truePeakToleranceDb"]));
        var bands = constants["bands"]!.AsObject();
        Assert.Equal(new[] { "portrait", "square", "landscape" }, bands.Select(pair => pair.Key));
        foreach (var (aspect, edges) in bands)
        {
            var expected = CaptionSafeZones.Bands(aspect);
            Assert.Equal(edges!.AsObject().Select(pair => pair.Key), expected.Select(band => CaptionSafeZones.Name(band.Edge)));
            foreach (var band in expected) Assert.Equal(Number(edges[CaptionSafeZones.Name(band.Edge)]), band.Fraction);
        }
        foreach (var entry in cases) Assert.Equal(new[] { "id", "check", "derivation", "input", "expect" }, entry!.AsObject().Select(pair => pair.Key));
    }

    [Fact]
    public void TheNumbersFileHasItsSchemaKeysAndCount()
    {
        var document = Document(NumbersPath);
        Assert.Equal(new[] { "schema", "description", "constants", "caseCount", "counts", "cases" }, document.Select(pair => pair.Key));
        Assert.Equal("voxclip-export-check-number-cases/1", Text(document["schema"]));
        var cases = document["cases"]!.AsArray();
        Assert.Equal(4, document["caseCount"]!.GetValue<int>());
        Assert.Equal(4, cases.Count);
        Assert.Equal(new[] { "words" }, document["counts"]!.AsObject().Select(pair => pair.Key));
        Assert.Equal(4, document["counts"]!["words"]!.GetValue<int>());
        Assert.Equal(new[] { "matchFloor" }, document["constants"]!.AsObject().Select(pair => pair.Key));
        Assert.Equal(ExportCheck.MatchFloor, Number(document["constants"]!["matchFloor"]));
    }

    [Theory]
    [InlineData(Path, 32)]
    [InlineData(NumbersPath, 4)]
    public void EveryCaseReplays(string path, int count)
    {
        var cases = Document(path)["cases"]!.AsArray();
        Assert.Equal(count, cases.Count);
        var failures = new List<string>();
        foreach (var entry in cases)
        {
            var id = Text(entry!["id"])!;
            var check = Enum.GetValues<ExportCheckKind>().Single(kind => ExportCheck.Name(kind) == Text(entry["check"]));
            var report = ExportCheck.Run(Input(entry["input"]!));
            Assert.Equal(Enum.GetValues<ExportCheckKind>(), report.Results.Select(result => result.Check));
            var found = Differences(report[check]!, entry["expect"]!);
            if (found.Count > 0) failures.Add($"{id}: {string.Join("; ", found)}");
            Assert.Equal(!report.Results.Any(result => result.Status == ExportCheckStatus.Warning), report.Passed);
        }
        Assert.True(failures.Count == 0, string.Join("\n", failures));
    }

    [Fact]
    public void TheResultJsonCarriesTheMacKeys()
    {
        var result = new ExportCheckResult(ExportCheckKind.Captions, ExportCheckStatus.Warning)
        {
            Items = [new(ExportCheckItemKind.CaptionBand, 1.5) { Value = 0.04, Limit = 0.22, Band = CaptionSafeZones.Edge.Bottom, Count = 3 }],
        };
        Assert.Equal("""{"check":"captions","status":"warning","items":[{"kind":"captionBand","time":1.5,"value":0.04,"limit":0.22,"band":"bottom","count":3}]}""",
            result.ToJson().ToJsonString());
        var words = new ExportCheckResult(ExportCheckKind.Words, ExportCheckStatus.Skipped) { Reason = ExportCheck.NoLocalEngine };
        Assert.Equal("""{"check":"words","status":"skipped","reason":"No local transcription model","items":[]}""", words.ToJson().ToJsonString());
    }

    [Fact]
    public void TheBandsFollowTheCaptionResolversAspectClass()
    {
        Assert.Equal(["top", "bottom"], CaptionSafeZones.Bands(new PixelSize(1080, 1920)).Select(band => CaptionSafeZones.Name(band.Edge)));
        Assert.Equal([0.12], CaptionSafeZones.Bands(new PixelSize(1080, 1080)).Select(band => band.Fraction));
        Assert.Equal([0.10], CaptionSafeZones.Bands(new PixelSize(1920, 1080)).Select(band => band.Fraction));
        // 4:5 is the resolver's portrait class; a frame within a tenth of square is its square class.
        Assert.Equal([0.12, 0.22], CaptionSafeZones.Bands(new PixelSize(1080, 1350)).Select(band => band.Fraction));
        Assert.Equal([0.12], CaptionSafeZones.Bands(new PixelSize(1080, 1200)).Select(band => band.Fraction));
        var bottom = CaptionSafeZones.Bands("portrait")[1];
        Assert.Equal(0.05, CaptionSafeZones.Overlap(new(0.1, 0.7, 0.8, 0.13), bottom), 12);
        Assert.Equal(0, CaptionSafeZones.Overlap(new(0.1, 0.7, 0.8, 0.0), bottom));
        Assert.Equal(0, CaptionSafeZones.Overlap(new(0.1, 0.5, 0.8, 0.2), bottom));
    }
}
