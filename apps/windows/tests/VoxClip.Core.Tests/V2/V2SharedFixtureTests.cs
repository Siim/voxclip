using System.Text.Json;
using System.Text.Json.Nodes;
using VoxClip.Core.Domain.Editing;
using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Domain.Transcript;
using VoxClip.Core.Domain.VoiceLab;
using VoxClip.Tests.Support;
using Xunit;

namespace VoxClip.Core.Tests.V2;

/// <summary>WC1 replays exactly the same reference values as Swift, without floating-point tolerances.</summary>
public sealed class V2SharedFixtureTests
{
    private static double Number(JsonElement value) => value.ValueKind == JsonValueKind.String
        ? value.GetString() switch { "NaN" => double.NaN, "Infinity" => double.PositiveInfinity, _ => double.NegativeInfinity } : value.GetDouble();
    private static TimeRange Range(JsonElement value) => new(Number(value[0]), Number(value[1]));
    private static double[] Pair(TimeRange value) => [value.Start, value.End];
    private static int[] Indices(Range value) => [value.Start.Value, value.End.Value];
    private static TimelineAxis Axis(string value) => value == "edited" ? TimelineAxis.Edited : TimelineAxis.Source;
    private static TimedWord Word(JsonElement row, int index) => new($"w{index}", row[0].GetString()!, WordKind.Word,
        Number(row[1]), Number(row[2]), null, null, null, row[3].ValueKind == JsonValueKind.Null ? null : row[3].GetString(), TimingSource.Native);

    [Theory]
    [InlineData("paragraphs.json", "voxclip.v2.paragraphs.v1", 27)]
    [InlineData("timeline-cases.json", "voxclip.v2.timeline.v1", 44)]
    public void Replay(string filename, string schema, int count)
    {
        using var document = FixtureLoader.ReadJson("fixtures/v2/" + filename);
        var root = document.RootElement;
        Assert.Equal(new[] { "caseCount", "cases", "schema" }, root.EnumerateObject().Select(p => p.Name).Order().ToArray());
        Assert.Equal(schema, root.GetProperty("schema").GetString());
        Assert.Equal(count, root.GetProperty("caseCount").GetInt32());
        Assert.Equal(count, root.GetProperty("cases").GetArrayLength());
        foreach (var item in root.GetProperty("cases").EnumerateArray())
        {
            object actual = filename == "paragraphs.json"
                ? TranscriptParagraphs.Split(item.GetProperty("words").EnumerateArray().Select(Word).ToArray()).Select(Indices).ToArray()
                : Timeline(item);
            var expected = JsonNode.Parse(item.GetProperty("expected").GetRawText());
            Assert.True(JsonNode.DeepEquals(expected, JsonSerializer.SerializeToNode(actual)), item.GetProperty("id").GetString());
        }
    }

    private static object Timeline(JsonElement item)
    {
        var input = item.GetProperty("input");
        switch (item.GetProperty("kind").GetString())
        {
            case "pieces":
                var rate = Number(input.GetProperty("rate"));
                var raw = input.GetProperty("raw").EnumerateArray().ToArray();
                TimelinePieces pieces;
                if (input.GetProperty("mode").GetString() == "legacy")
                {
                    var kept = raw.Select(row => new MediaInterval(row[0].GetInt64(), row[1].GetInt64())).ToArray();
                    pieces = new(new RenderTimeline.Legacy(new(rate, kept.LastOrDefault().EndSample, [], kept, 0, [])));
                }
                else
                {
                    var voice = raw.Select(row => new VoiceLabOutputPiece(row[4].GetString() == "ai" ? VoiceLabOutputPieceKind.Synth : VoiceLabOutputPieceKind.Source,
                        row[0].GetInt64(), row[1].GetInt64(), row[2].GetInt64(), row[3].GetInt64(), null, null, null)).ToArray();
                    pieces = new(new RenderTimeline.VoiceLab(new(rate, 1000, voice, [], VoiceLabOutputScope.Full)));
                }
                return new { pieces = pieces.Pieces.Select(p => new { source = Pair(p.Source), edited = Pair(p.Edited), kind = p.Kind == TimelinePieceKind.Ai ? "ai" : "kept" }),
                    editedDuration = pieces.EditedDuration, sourceSpan = pieces.SourceSpan is { } span ? Pair(span) : null, seams = pieces.Seams,
                    overlaps = input.GetProperty("queries").EnumerateArray().Select(q => Indices(pieces.Indices(new(Number(q[1]), Number(q[2])), Axis(q[0].GetString()!)))),
                    gaps = pieces.Gaps(Range(input.GetProperty("span")), Number(input.GetProperty("minimum"))).Select(Pair) };
            case "ruler":
                var scale = Number(input.GetProperty("scale"));
                return new { major = TimelineRuler.MajorStep(scale), minor = TimelineRuler.MinorStep(scale),
                    ticks = TimelineRuler.Ticks(Range(input.GetProperty("visible")), scale).Select(t => new { time = t.Time, major = t.Major }) };
            case "timecode":
                var seconds = Number(input.GetProperty("seconds")); var fps = input.GetProperty("fps").GetInt32();
                var text = SMPTETimecode.Format(seconds, fps);
                return new Dictionary<string, object> { ["frame"] = SMPTETimecode.Frame(seconds, fps), ["dimPrefix"] = text.DimPrefix,
                    ["value"] = text.Value, ["string"] = SMPTETimecode.String(seconds, fps) };
            case "captions":
                var pages = input.GetProperty("pages").EnumerateArray().Select(p => new TimelineCaptions.Page(Range(p.GetProperty("edited")), Range(p.GetProperty("source")), p.GetProperty("text").GetString()!)).ToArray();
                var removed = input.GetProperty("removed").EnumerateArray().Select(Range).ToArray();
                var cues = TimelineCaptions.Cues(pages, Axis(input.GetProperty("axis").GetString()!), removed);
                return new { cues = cues.Select(c => new { range = Pair(c.Range), text = c.Text, cuts = c.Cuts.Select(Pair) }),
                    indices = Indices(TimelineCaptions.Indices(cues, Range(input.GetProperty("query")))) };
            default: throw new InvalidDataException("Unknown v2 fixture kind");
        }
    }
}
