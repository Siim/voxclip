using System.Text.Json;
using System.Text.Json.Nodes;
using VoxClip.Cli;
using VoxClip.Core.Domain.Autopilot;
using VoxClip.Core.Domain.Effects;
using VoxClip.Core.Domain.Frames;
using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Services.LLM;
using VoxClip.Tests.Support;
using Xunit;
using Picture = VoxClip.Core.Domain.Frames.ClipPicture;

namespace VoxClip.Media.Tests.Frames;

/// <summary><c>voxclip-cli autopilot</c>'s <c>frames</c> and <c>picture</c> objects (ADR-R48 part 2, W6): every case of
/// shared/fixtures/clip-frames/autopilot-picture-cases.json, which tools/fixtures/clip-frames/generate_autopilot_picture.py writes from the
/// Mac's <c>framesJSON</c> and <c>pictureJSON</c>, rebuilt through the Windows CLI's own JSON code. Keys and values are exact; the order of
/// keys is not compared (the Mac prints its JSON sorted).</summary>
public sealed class CliAutopilotFramesVectorTests
{
    private const string FixturePath = "fixtures/clip-frames/autopilot-picture-cases.json";
    private static readonly Lazy<JsonObject> Vectors = new(() => JsonNode.Parse(FixtureLoader.ReadText(FixturePath))!.AsObject());
    private static IEnumerable<JsonObject> Cases => Vectors.Value["cases"]!.AsArray().Select(item => item!.AsObject());
    public static TheoryData<string> Ids => new(Cases.Select(item => item["id"]!.GetValue<string>()));

    private static double Number(JsonNode? node) => node!.GetValue<double>();
    private static string? Text(JsonNode? node) => node?.GetValue<string>();

    private static ClipEffectRect Rect(JsonNode? node) => new(Number(node!["x"]), Number(node["y"]), Number(node["width"]), Number(node["height"]));

    /// <summary>The frames a request carried, as <see cref="ClipAutopilotFrames"/>: its candidates, its sheet's frame count, its images
    /// and their tokens.</summary>
    private static ClipAutopilotFrames Sent(JsonObject sent)
    {
        var count = sent["frames"]!.GetValue<int>();
        var images = sent["images"]!.GetValue<bool>();
        var frames = Enumerable.Range(1, count).Select(index => new FrameSheetFrame(index, new FrameObservation(index), [0xFF, 0xD8], 320, 180)).ToArray();
        return new ClipAutopilotFrames("summary", images ? frames.Select(frame => frame.Image).ToArray() : [],
            sent["blur"]!.AsArray().Select(item => new ClipAutopilotFrames.BlurCandidate(Text(item!["id"])!, Number(item["start"]), Number(item["end"]), Rect(item["rect"]), item["frames"]!.GetValue<int>())).ToArray(),
            sent["cover"]!.AsArray().Select(item => new ClipAutopilotFrames.CoverCandidate(Text(item!["id"])!, item["frame"]!.GetValue<int>(), Number(item["time"]), Number(item["score"]))).ToArray(),
            sent["imageTokens"]!.GetValue<int>()) { Frames = frames };
    }

    private static ClipAutopilotPlan Plan(JsonNode? reply) => new()
    {
        StartWord = 0, EndWord = 1, Title = "t", Hook = "", PostText = "", Score = 7, Verdict = ClipAutopilotVerdict.Post,
        CaptionChoice = new("vox-bold", new("Roboto", 900), ClipAutopilotCaptionCase.Upper, 3),
        Frames = reply is null ? null : new(
            reply["blur"]!.AsArray().Select(item => new ClipAutopilotPlan.FrameChoices.Blur(Text(item!["id"])!, item["blur"]!.GetValue<bool>(), Text(item["reason"])!)).ToArray(),
            reply["cover"] is { } cover ? new(Text(cover["id"])!, Text(cover["reason"])!, cover["fallback"]!.GetValue<bool>()) : null)
    };

    private static Picture.Decisions Decisions(JsonObject decisions, ClipAutopilotFrames frames)
    {
        var opening = decisions["opening"] is { } moved
            ? new Picture.Opening(Number(moved["leadIn"]), null, Number(moved["earlier"]), Number(moved["start"]), Number(moved["chosen"]), null, Text(moved["reason"])!)
            : null;
        var crop = decisions["crop"] is { } centre ? new Picture.Crop(Number(centre["centerX"]), Number(centre["centerY"]), null, ExportAspect.Portrait) : null;
        var blurs = decisions["blurs"]!.AsArray().Select(item =>
        {
            var id = Text(item!["id"])!;
            var blurred = item["blurred"]!.GetValue<bool>();
            return new Picture.Blur(frames.BlurCandidateFor(id)!, Picture.BlurEffectId("clip", id), blurred, blurred, new(id, blurred, Text(item["reason"]) ?? ""));
        }).ToArray();
        var cover = decisions["cover"] is { } chosen
            ? new Picture.Cover(frames.CoverCandidateFor(Text(chosen["id"])!)!, chosen["named"]!.GetValue<bool>(), Text(chosen["reason"]), null)
            : null;
        return new(opening, crop, blurs, cover);
    }

    private static ExportAspect Shape(string shape) => CliAutopilotFrames.Shape(shape);

    /// <summary>The same JSON: an object's keys as a set and each value, an array item by item, numbers as doubles exactly.</summary>
    private static void Same(JsonNode? expected, JsonNode? actual, string where)
    {
        if (expected is null) { Assert.True(actual is null, where + ": expected null, got " + actual?.ToJsonString()); return; }
        Assert.True(actual is not null, where + ": expected " + expected.ToJsonString() + ", got null");
        switch (expected)
        {
            case JsonObject expectedObject:
                var actualObject = Assert.IsType<JsonObject>(actual);
                Assert.Equal(expectedObject.Select(pair => pair.Key).Order(StringComparer.Ordinal), actualObject.Select(pair => pair.Key).Order(StringComparer.Ordinal));
                foreach (var (key, value) in expectedObject) Same(value, actualObject[key], where + "." + key);
                break;
            case JsonArray expectedArray:
                var actualArray = Assert.IsType<JsonArray>(actual);
                Assert.Equal(expectedArray.Count, actualArray.Count);
                for (var index = 0; index < expectedArray.Count; index++) Same(expectedArray[index], actualArray[index], $"{where}[{index}]");
                break;
            default:
                var kind = expected.GetValueKind();
                Assert.Equal(kind is JsonValueKind.True or JsonValueKind.False ? "bool" : kind.ToString(),
                    actual!.GetValueKind() is JsonValueKind.True or JsonValueKind.False ? "bool" : actual.GetValueKind().ToString());
                if (kind == JsonValueKind.Number) Assert.True(AsDouble(expected) == AsDouble(actual), $"{where}: {expected.ToJsonString()} != {actual.ToJsonString()}");
                else if (kind == JsonValueKind.String) Assert.Equal(expected.GetValue<string>(), actual.GetValue<string>());
                else if (kind is JsonValueKind.True or JsonValueKind.False) Assert.Equal(expected.GetValue<bool>(), actual.GetValue<bool>());
                break;
        }
    }

    /// <summary>A JSON number as a double, however the node holds it (an int, a double, a parsed element).</summary>
    private static double AsDouble(JsonNode node) => double.Parse(node.ToJsonString(), System.Globalization.CultureInfo.InvariantCulture);

    [Fact]
    public void TheFileHasItsSchemaKeysAndCount()
    {
        var root = Vectors.Value;
        Assert.Equal(["schema", "description", "caseCount", "cases"], root.Select(pair => pair.Key));
        Assert.Equal("voxclip-autopilot-picture-cases/1", root["schema"]!.GetValue<string>());
        Assert.Equal(7, root["caseCount"]!.GetValue<int>());
        Assert.Equal(7, Cases.Count());
        Assert.All(Cases, item => Assert.Equal(["id", "note", "sent", "reply", "decisions", "shapes", "faceFound", "frames", "picture"], item.Select(pair => pair.Key)));
    }

    [Theory]
    [MemberData(nameof(Ids))]
    public void EachCaseIsTheMacsFramesAndPicture(string id)
    {
        var item = Cases.Single(row => row["id"]!.GetValue<string>() == id);
        var frames = Sent(item["sent"]!.AsObject());
        var plan = Plan(item["reply"]);
        Same(item["frames"], CliAutopilotFrames.FramesJson(frames, plan), id + ".frames");
        var face = new FrameFace(new ClipEffectRect(0.3, 0.2, 0.2, 0.36), 0.6, 0.3, 0.3, 0, 0);
        IReadOnlyList<FrameObservation> sentences = item["faceFound"]!.GetValue<bool>() ? [new FrameObservation(1) { FaceCount = 1, Face = face }] : [new FrameObservation(1)];
        var shapes = item["shapes"]!.AsArray().Select(shape => Shape(shape!.GetValue<string>())).ToArray();
        Same(item["picture"], CliAutopilotFrames.PictureJson(Decisions(item["decisions"]!.AsObject(), frames), sentences, shapes), id + ".picture");
    }
}
