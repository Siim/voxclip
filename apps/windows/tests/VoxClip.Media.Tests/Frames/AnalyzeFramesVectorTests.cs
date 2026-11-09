using System.Text.Json.Nodes;
using VoxClip.Cli;
using VoxClip.Core.Domain.Frames;
using VoxClip.Core.Domain.Shared;
using VoxClip.Tests.Support;
using Xunit;

namespace VoxClip.Media.Tests.Frames;

/// <summary>Replays shared/fixtures/clip-frames/analyze-frames-cli-cases.json (ADR-R48, W5): the CLI's report on fabricated analyses
/// prints the Mac's bytes, and each number is Swift's text. The Mac's <c>CLIAnalyzeFramesVectorTests</c> replays the same file.</summary>
public sealed class AnalyzeFramesVectorTests
{
    private const string VectorPath = "fixtures/clip-frames/analyze-frames-cli-cases.json";

    private static JsonObject Vectors() => JsonNode.Parse(FixtureLoader.ReadText(VectorPath))!.AsObject();

    [Fact]
    public void TheVectorsHaveTheirKeysAndCounts()
    {
        var vectors = Vectors();
        Assert.Equal(["caseCount", "counts", "description", "numbers", "reports", "schema", "version"], vectors.Select(pair => pair.Key).Order(StringComparer.Ordinal));
        Assert.Equal("voxclip-analyze-frames-cli-cases/1", vectors["schema"]!.GetValue<string>());
        var reports = vectors["reports"]!.AsArray();
        var numbers = vectors["numbers"]!.AsArray();
        Assert.Equal((reports.Count, numbers.Count), (vectors["counts"]!["reports"]!.GetValue<int>(), vectors["counts"]!["numbers"]!.GetValue<int>()));
        Assert.Equal(reports.Count + numbers.Count, vectors["caseCount"]!.GetValue<int>());
        Assert.All(reports, report => Assert.Equal(["analysis", "clip", "id", "json", "note", "sheet", "video", "videoPass", "words"],
            report!.AsObject().Select(pair => pair.Key).Order(StringComparer.Ordinal)));
    }

    /// <summary>The CLI's report on each fabricated analysis prints the Mac's bytes exactly.</summary>
    [Fact]
    public void TheReportPrintsTheMacsBytesForEveryVector()
    {
        var vectors = Vectors();
        var version = vectors["version"]!.GetValue<string>();
        foreach (var report in vectors["reports"]!.AsArray().Select(node => node!.AsObject()))
        {
            var id = report["id"]!.GetValue<string>();
            var words = report["words"]!.AsArray().Select(item => FrameFixtures.Word(item!["id"]!.GetValue<string>(), item["text"]!.GetValue<string>(),
                item["start"]!.GetValue<double>(), item["end"]!.GetValue<double>())).ToArray();
            var range = report["clip"]!.AsObject();
            var clip = FrameClip.Make(words, range["first"]!.GetValue<int>(), range["last"]!.GetValue<int>(),
                range["cut"]!.AsArray().Select(cut => cut!.GetValue<string>()).ToHashSet())!;
            var analysis = FrameJson.ReadAnalysis(report["analysis"]) ?? throw new InvalidDataException(id + ": unreadable analysis");
            var sheet = new FrameSheet(report["sheet"]!.AsArray().Select(item => new FrameSheetFrame(item!["index"]!.GetValue<int>(),
                analysis.Sentences[item["sentence"]!.GetValue<int>()], new byte[item["bytes"]!.GetValue<int>()], item["width"]!.GetValue<int>(), item["height"]!.GetValue<int>())));
            var video = report["video"] is JsonObject facts
                ? new VideoTrackInfo(facts["width"]!.GetValue<int>(), facts["height"]!.GetValue<int>(), 30, facts["rotationDegrees"]!.GetValue<int>()) : null;
            var pass = report["videoPass"]?.DeepClone().AsObject();
            var baseline = pass is not null ? (pass["pitchBaseline"] is JsonValue value ? value.GetValue<double>() : null) : analysis.PitchBaseline;
            var fields = CliAnalyzeFrames.Report(analysis, clip, video, sheet, baseline, pass);
            fields["ok"] = true; fields["command"] = "analyze-frames"; fields["version"] = version;
            Assert.True(report["json"]!.GetValue<string>() == FrameJson.MacText(fields) + "\n", id + ":\n" + FrameJson.MacText(fields));
        }
    }

    /// <summary>Swift's Double text, one number at a time.</summary>
    [Fact]
    public void NumbersAreWrittenAsSwiftWritesThem()
    {
        foreach (var number in Vectors()["numbers"]!.AsArray())
            Assert.Equal(number!["text"]!.GetValue<string>(), FrameJson.SwiftNumber(number["value"]!.GetValue<double>()));
        Assert.Equal("{\"a\":[1,\"x/y\\n\\\"\"],\"b\":null,\"c\":true}",
            FrameJson.MacText(new JsonObject { ["c"] = true, ["a"] = new JsonArray(1, "x/y\n\""), ["b"] = null }));
    }
}
