using System.Text.Json.Nodes;
using VoxClip.Core.Domain.Autopilot;
using VoxClip.Core.Domain.Effects;
using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Services.LLM;
using Xunit;
using static VoxClip.Core.Tests.Tracks.WinAi.ClipAutopilotTests;

namespace VoxClip.Core.Tests.Tracks.WinAi;

/// <summary>The planner's frames (prompt version 8, ADR-R48, ai.md §19.6), twin of the Mac <c>ClipAutopilotFramesTests</c>: it replays
/// shared/fixtures/autopilot/plan-frames-cases.json. Windows has no frame analyzer yet, so the frames come from the fixture.</summary>
[Trait("Track", "win-ai")]
public sealed class ClipAutopilotFramesTests
{
    private static JsonObject Frames() => Fixture("plan-frames-cases.json");
    private static JsonObject V2() => Fixture("plan-v2-cases.json");

    private static LlmImage Image(int index) => new($"Frame {index}", "image/jpeg", Enumerable.Repeat((byte)index, 8).ToArray(), 320, 180);

    /// <summary>The fixture's frames as a request would carry them.</summary>
    internal static ClipAutopilotFrames Sheet(bool images)
    {
        var value = Frames()["frames"]!;
        var blur = value["blur"]!.AsArray().Select(item =>
        {
            var box = item!["rect"]!.AsArray().Select(cell => cell!.GetValue<double>()).ToArray();
            return new ClipAutopilotFrames.BlurCandidate(item["id"]!.GetValue<string>(), item["start"]!.GetValue<double>(), item["end"]!.GetValue<double>(),
                new ClipEffectRect(box[0], box[1], box[2], box[3]), item["frames"]!.GetValue<int>());
        }).ToArray();
        var cover = value["cover"]!.AsArray().Select(item => new ClipAutopilotFrames.CoverCandidate(item!["id"]!.GetValue<string>(), item["frame"]!.GetValue<int>(),
            item["time"]!.GetValue<double>(), 0.5)).ToArray();
        return new(value["summary"]!.GetValue<string>(), images ? Enumerable.Range(1, 5).Select(Image).ToArray() : [], blur, cover, images ? 385 : 0);
    }

    [Fact]
    public void VectorsPinTheCurrentPrompt()
    {
        var prompt = ClipAutopilotPrompt.Load(Root);
        var fixture = Frames();
        Assert.Equal(9, prompt.PromptVersion);
        Assert.Equal("voxclip-autopilot-frames/1", fixture["schema"]!.GetValue<string>());
        Assert.Equal(prompt.Sha256, fixture["sources"]!["shared/prompts/clip-autopilot.json"]!.GetValue<string>());
        Assert.Contains("frames.blur", prompt.System, StringComparison.Ordinal);
        // The shared prompt (version 9) tells the AI the frames were measured, and the opening and 9:16 decided, on this computer.
        Assert.Contains("one per sentence, as this computer measured them", prompt.System, StringComparison.Ordinal);
        Assert.Contains("follows the face are decided on this computer;", prompt.System, StringComparison.Ordinal);
        Assert.DoesNotContain("this Mac", prompt.System, StringComparison.Ordinal);
        Assert.Contains(prompt.Schema["required"]!.AsArray(), key => key!.GetValue<string>() == "frames");
        Assert.Equal(6, fixture["cases"]!.AsArray().Count);
    }

    [Fact]
    public void TheBlockCarriesTheSummaryAlwaysAndNamesTheImagesOnlyWhenTheyGo()
    {
        var prompt = ClipAutopilotPrompt.Load(Root);
        Assert.Equal(Frames()["block"]!.GetValue<string>(), ClipAutopilotRequestBuilder.FramesBlock(Sheet(images: false), prompt));
        Assert.Equal(Frames()["blockWithImages"]!.GetValue<string>(), ClipAutopilotRequestBuilder.FramesBlock(Sheet(images: true), prompt));
        var empty = new ClipAutopilotFrames("", [], [], [], 0);
        Assert.Equal("\n\nFrames measured on this computer: none could be read.\nScreens to judge for blur:\n- none\nCover candidates:\n- none",
            ClipAutopilotRequestBuilder.FramesBlock(empty, prompt));
    }

    [Fact]
    public void TheRequestCarriesTheSummaryForEveryConnectorAndImagesOnlyWhenGiven()
    {
        var service = Service();
        var input = new ClipAutopilotRequest(Transcript(V2(), 75), Edits(), new ClipAutopilotMode.Clip(new(0, 29)));
        var plain = service.Request(input, ConnectorId.Anthropic);
        var text = service.Request(input, ConnectorId.Ollama, Sheet(images: false));
        var images = service.Request(input, ConnectorId.Anthropic, Sheet(images: true));
        Assert.DoesNotContain("Frames measured", plain.Instruction, StringComparison.Ordinal);
        Assert.Empty(plain.Images);
        Assert.Contains(Frames()["block"]!.GetValue<string>(), text.Instruction, StringComparison.Ordinal);
        Assert.Empty(text.Images);
        Assert.Contains("The images are those frames", images.Instruction, StringComparison.Ordinal);
        Assert.Equal(5, images.Images.Count);
        Assert.StartsWith(plain.Instruction, text.Instruction, StringComparison.Ordinal);
        // The frames come before the tone line.
        var toneLine = service.Request(input with { Tone = new ClipAutopilotTone.AsSaid() }, ConnectorId.Ollama).Instruction[plain.Instruction.Length..];
        var toned = service.Request(input with { Tone = new ClipAutopilotTone.AsSaid() }, ConnectorId.Ollama, Sheet(images: false));
        Assert.Equal(plain.Instruction + Frames()["block"]!.GetValue<string>() + toneLine, toned.Instruction);
        // The moments stage of a series never carries frames.
        var series = service.Request(input with { Mode = new ClipAutopilotMode.Series(null) }, ConnectorId.Anthropic, Sheet(images: true));
        Assert.Empty(series.Images);
        Assert.DoesNotContain("Frames measured", series.Instruction, StringComparison.Ordinal);
    }

    [Theory]
    [InlineData("blur-one-keep-one")]
    [InlineData("ids-read-ignoring-case-and-space")]
    [InlineData("unknown-and-repeated-blur-ids-are-ignored")]
    [InlineData("unknown-cover-falls-back-to-the-local-best")]
    [InlineData("empty-cover-falls-back")]
    [InlineData("old-reply-without-frames")]
    public void ReplyFramesAreCheckedAgainstTheCandidates(string id)
    {
        var vector = Case(Frames(), id);
        var reply = Case(V2(), "corrections")["reply"]!.DeepClone().AsObject();
        reply.Remove("frames");
        if (vector["reply"] is { } frames) reply["frames"] = frames.DeepClone();
        var context = Context(Transcript(V2(), 75), new(0, 29)) with { Frames = Sheet(images: true) };
        var plan = ClipAutopilotValidator.Plan(reply, context)!;
        var expect = vector["expect"]!;
        var choices = plan.Frames!;
        Assert.Equal(expect["blur"]!.AsArray().Select(item => (item![0]!.GetValue<string>(), item[1]!.GetValue<bool>())), choices.BlurChoices.Select(item => (item.Id, item.Blurred)));
        Assert.Equal((expect["cover"]![0]!.GetValue<string>(), expect["cover"]![1]!.GetValue<bool>()), (choices.CoverChoice?.Id ?? "", choices.CoverChoice?.Fallback ?? false));
        Assert.Equal(expect["repairs"]!.AsArray().Select(item => (item![0]!.GetValue<string>(), item[1]!.GetValue<string>())),
            plan.Repairs.Where(repair => repair.Field.StartsWith("frames", StringComparison.Ordinal)).Select(repair => (repair.Field, repair.Action)));
    }

    [Fact]
    public void WithoutFramesInTheRequestThePlanHasNone()
    {
        var reply = Case(V2(), "corrections")["reply"]!.DeepClone().AsObject();
        reply["frames"] = new JsonObject { ["blur"] = new JsonArray(), ["cover"] = new JsonObject { ["id"] = "C1", ["reason"] = "" } };
        var plan = ClipAutopilotValidator.Plan(reply, Context(Transcript(V2(), 75), new(0, 29)))!;
        Assert.Null(plan.Frames);
        Assert.Equal(4, plan.Version);
    }

    [Fact]
    public void PlanVersionFourIsReadAndFiveRefused()
    {
        var plan = new ClipAutopilotPlan
        {
            StartWord = 0, EndWord = 3, Title = "T", Hook = "H", CaptionChoice = new("vox-bold", new("Roboto", 900), ClipAutopilotCaptionCase.Upper, 3),
            PostText = "P", Score = 7, Verdict = ClipAutopilotVerdict.Post,
            Frames = new([new("B1", true, "names")], new("C2", "smile"))
        };
        var json = plan.ToJson();
        var read = ClipAutopilotPlan.FromJson(json);
        Assert.Equal(plan.Frames, read.Frames);
        Assert.Equal(json.ToJsonString(), read.ToJson().ToJsonString());
        json["version"] = 5;
        Assert.Throws<VoxClipException>(() => ClipAutopilotPlan.FromJson(json));
        json["version"] = 3;
        json.Remove("frames");
        Assert.Null(ClipAutopilotPlan.FromJson(json).Frames);
    }
}
