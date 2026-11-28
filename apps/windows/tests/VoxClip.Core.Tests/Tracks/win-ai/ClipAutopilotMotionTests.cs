using System.Text.Json.Nodes;
using VoxClip.Core.Domain.Autopilot;
using VoxClip.Core.Domain.Clips;
using VoxClip.Core.Domain.Editing;
using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Services.LLM;
using Xunit;
using static VoxClip.Core.Tests.Tracks.WinAi.ClipAutopilotTests;

namespace VoxClip.Core.Tests.Tracks.WinAi;

public sealed class ClipAutopilotMotionTests
{
    private static JsonObject Zoom(int first = 13, int last = 15, string direction = "zoomIn", double scale = 1.2) =>
        new() { ["word"] = first, ["untilWord"] = last, ["scale"] = scale, ["reason"] = "the contrast", ["direction"] = direction };

    private static JsonObject WithZooms(params JsonObject[] zooms)
    {
        var reply = Reply("valid-clip");
        reply["zooms"] = new JsonArray(zooms);
        return reply;
    }

    [Fact]
    public void OnlyClipRequestsOptIntoTheSharedDirectionAndStrictSchemasRequireIt()
    {
        var service = Service();
        var request = service.Request(new(Transcript(), Edits(), new ClipAutopilotMode.Clip(new(0, 29))), ConnectorId.Codex);
        Assert.Contains("0.6 to 6 seconds", request.System, StringComparison.Ordinal);
        Assert.Contains("at least 5 seconds apart", request.System, StringComparison.Ordinal);
        Assert.Contains("Return an empty list", request.System, StringComparison.Ordinal);
        var item = request.Schema["properties"]!["zooms"]!["items"]!;
        Assert.Equal(["zoomIn", "zoomOut"], item["properties"]!["direction"]!["enum"]!.AsArray().Select(value => value!.GetValue<string>()));
        Assert.DoesNotContain(item["required"]!.AsArray(), value => value!.GetValue<string>() == "direction");
        var strict = LlmConnector.HttpStructuredSchema(request.Schema)["properties"]!["zooms"]!["items"]!;
        Assert.Contains(strict["required"]!.AsArray(), value => value!.GetValue<string>() == "direction");
        var legacy = Zoom();
        legacy.Remove("direction");
        var raw = new RawCompletion(null, Sendable(WithZooms(legacy, Zoom(), Zoom(direction: "sideways"))), "fixture", new StopKind.Complete(), null, null);
        var checkedReply = LlmOutput.Validate(raw, request.Schema);
        Assert.Equal(1, checkedReply.DroppedByKey["zooms"]);
        Assert.Equal(2, checkedReply.Object!["zooms"]!.AsArray().Count);

        var (document, hash) = ClipAutopilotPrompt.ReadShared(Root, ClipAutopilotPrompt.Path);
        document.Remove("directionalZooms");
        var original = new ClipAutopilotPrompt(document, hash, ClipLookLibrary.Load(Root));
        Assert.Equal(14, original.PromptVersion);
        Assert.Contains("from 1.05 to 1.35", original.System, StringComparison.Ordinal);
        Assert.Null(original.Schema["properties"]!["zooms"]!["items"]!["properties"]!["direction"]);
        var series = service.Request(new(Transcript(), Edits(), new ClipAutopilotMode.Series(null)), ConnectorId.Codex);
        Assert.Equal(original.MomentsSystem, series.System);
        Assert.True(JsonNode.DeepEquals(original.MomentsSchema, series.Schema));
    }

    [Theory]
    [InlineData("direction", "\"ZoomIn\"")]
    [InlineData("direction", "null")]
    [InlineData("untilWord", null)]
    [InlineData("untilWord", "12")]
    [InlineData("untilWord", "30")]
    [InlineData("untilWord", "16")]
    [InlineData("untilWord", "13")]
    [InlineData("word", "16")]
    [InlineData("scale", "1.049")]
    [InlineData("scale", "1.201")]
    [InlineData("scale", "1e9999")]
    [InlineData("reason", "\"  \"")]
    public void InvalidDirectionalValuesAreDroppedWithoutSnapOrClamp(string field, string? json)
    {
        var zoom = Zoom();
        if (json is null) zoom.Remove(field);
        else zoom[field] = JsonNode.Parse(json);
        var plan = Assert.IsType<ClipAutopilotPlan>(ClipAutopilotValidator.Plan(WithZooms(zoom), Context(new(0, 29))));
        Assert.Empty(plan.Zooms);
        Assert.Contains(plan.Repairs, repair => repair.Field == "zooms[0]" && repair.Dropped);
    }

    [Fact]
    public void DirectionalPhrasesCannotCrossCutsOrTightenedPauses()
    {
        var reply = WithZooms(Zoom(7, 10), Zoom(5, 8), Zoom(17, 23), Zoom(25, 29), Zoom(15, 17));
        var context = Context(new(0, 29), Edits(cut: ["w22"], cutPauses: ["pause-after-w26"]));
        var plan = Assert.IsType<ClipAutopilotPlan>(ClipAutopilotValidator.Plan(reply, context));
        Assert.Equal(15, Assert.Single(plan.Zooms).Word);
        Assert.Equal(4, plan.Repairs.Count(repair => repair.Dropped && repair.Field.StartsWith("zooms[", StringComparison.Ordinal)));
    }

    [Fact]
    public void ReplyOrderWinsSpacingAndOverlapThenAcceptedCuesSortBySourceStart()
    {
        var plan = Assert.IsType<ClipAutopilotPlan>(ClipAutopilotValidator.Plan(
            WithZooms(Zoom(27, 29, "zoomOut"), Zoom(2, 6, scale: 1.05), Zoom(17, 19), Zoom(3, 6)), Context(new(0, 29))));
        Assert.Equal([2, 27], plan.Zooms.Select(zoom => zoom.Word));
        Assert.Contains(plan.Repairs, repair => repair.Field == "zooms[2]" && repair.Dropped);
        Assert.Contains(plan.Repairs, repair => repair.Field == "zooms[3]" && repair.Dropped);
    }

    [Fact]
    public void FiveSecondsBetweenStartsIsAllowedButCannotExcuseAnOverlap()
    {
        var context = Context(new(0, 29));
        var words = context.Words.ToArray();
        words[15] = words[15] with { Start = words[2].Start + 5 };
        context = context with { Words = words };
        var separated = Assert.IsType<ClipAutopilotPlan>(ClipAutopilotValidator.Plan(WithZooms(Zoom(2, 6), Zoom(15, 17)), context));
        Assert.Equal([2, 15], separated.Zooms.Select(zoom => zoom.Word));

        var reply = WithZooms(Zoom(2, 15), Zoom(15, 17));
        reply["cuts"] = new JsonArray();
        reply["pauseCuts"] = new JsonArray();
        var overlapping = Assert.IsType<ClipAutopilotPlan>(ClipAutopilotValidator.Plan(reply, context));
        Assert.Equal(2, Assert.Single(overlapping.Zooms).Word);
        Assert.Contains(overlapping.Repairs, repair => repair.Field == "zooms[1]" && repair.Dropped);
    }

    [Fact]
    public void BothDirectionsUseTheSharedZoomCountCap()
    {
        var (document, hash) = ClipAutopilotPrompt.ReadShared(Root, ClipAutopilotPrompt.Path);
        document["limits"]!["maxZooms"] = 1;
        var context = Context(new(0, 29)) with { Prompt = new(document, hash, ClipLookLibrary.Load(Root)) };
        var plan = Assert.IsType<ClipAutopilotPlan>(ClipAutopilotValidator.Plan(WithZooms(Zoom(27, 29, "zoomOut"), Zoom(2, 6)), context));
        Assert.Equal(27, Assert.Single(plan.Zooms).Word);
        Assert.Contains(plan.Repairs, repair => repair.Field == "zooms[1]" && repair.Dropped && repair.Detail == "more than 1 zooms");
    }

    [Theory]
    [InlineData(1, 1.5999999995, true)]
    [InlineData(1, 1.59999, false)]
    [InlineData(1, 7.0000000005, true)]
    [InlineData(1, 7.00001, false)]
    [InlineData(-1, 1, false)]
    [InlineData(double.NaN, 2, false)]
    [InlineData(1, double.PositiveInfinity, false)]
    public void SourceDurationUsesTheSharedBoundsAndTolerance(double start, double end, bool accepted)
    {
        var context = Context(new(0, 29));
        var words = context.Words.ToArray();
        words[13] = words[13] with { Start = start, End = end };
        var plan = Assert.IsType<ClipAutopilotPlan>(ClipAutopilotValidator.Plan(WithZooms(Zoom(13, 13)), context with { Words = words }));
        Assert.Equal(accepted, plan.Zooms.Count == 1);
    }

    [Fact]
    public void DirectionalAndLegacyPlansRoundTripWithTheirOwnCurvesAndIds()
    {
        var legacy = Zoom(13, 15, scale: 2);
        legacy.Remove("direction");
        var plan = Assert.IsType<ClipAutopilotPlan>(ClipAutopilotValidator.Plan(
            WithZooms(Zoom(2, 6), legacy, Zoom(27, 29, "zoomOut")), Context(new(0, 29)))) with
        {
            Corrections = [new(4, "idea", "concept", "the recording says concept")]
        };
        var json = plan.ToJson();
        Assert.Equal("zoomIn", json["zooms"]![0]!["direction"]!.GetValue<string>());
        Assert.False(json["zooms"]![1]!.AsObject().ContainsKey("direction"));
        var saved = ClipAutopilotPlan.FromJson(json);
        Assert.Equal(plan.Zooms, saved.Zooms);
        json["zooms"]![0]!["direction"] = "sideways";
        Assert.Throws<VoxClipException>(() => ClipAutopilotPlan.FromJson(json));

        var operations = ClipAutopilotMapping.Operations(saved, "c1", Project(), ClipAutopilotFonts.Load(Root));
        var zooms = operations.Where(operation => operation.Decision == ClipAutopilotDecision.Zoom).ToArray();
        Assert.Equal("“the big concept is simple.” · the contrast", zooms[0].Reason);
        Assert.Equal("the contrast", zooms[1].Reason);
        var cues = zooms.Select(operation => Assert.IsType<ClipAutopilotAction.Motion>(operation.Action).Cue).ToArray();
        Assert.Equal(("c1-zoom-2-6", 0.6, 1.9), (cues[0].Id, cues[0].SourceStart, cues[0].SourceEnd));
        Assert.Equal("c1-zoom-1", cues[1].Id);
        Assert.Equal(("c1-zoom-27-29", 10.4, 11.3), (cues[2].Id, cues[2].SourceStart, cues[2].SourceEnd));
        Assert.Equal([(0, 1), (0.28, 1.2), (0.70, 1.2), (1, 1)], cues[0].Keyframes.Select(frame => (frame.Progress, frame.Scale)));
        Assert.Equal([(0, 1.35), (1, 1.35)], cues[1].Keyframes.Select(frame => (frame.Progress, frame.Scale)));
        Assert.Equal([(0, 1.2), (0.18, 1.2), (1, 1)], cues[2].Keyframes.Select(frame => (frame.Progress, frame.Scale)));
        Assert.All(cues.SelectMany(cue => cue.Keyframes), frame => Assert.Equal((0.5, 0.5), (frame.AnchorX, frame.AnchorY)));
    }

    [Fact]
    public void ReviewQuoteTruncatesAtAGraphemeBoundary()
    {
        const string letter = "e\u0301";
        var plan = Assert.IsType<ClipAutopilotPlan>(ClipAutopilotValidator.Plan(WithZooms(Zoom()), Context(new(0, 29)))) with
        {
            Corrections = [new(13, "sleep", string.Concat(Enumerable.Repeat(letter, 100)), "fixture")]
        };
        var operation = Assert.Single(ClipAutopilotMapping.Operations(plan, "c1", Project(), ClipAutopilotFonts.Load(Root)),
            operation => operation.Decision == ClipAutopilotDecision.Zoom);
        Assert.Equal("“" + string.Concat(Enumerable.Repeat(letter, 95)) + "…” · the contrast", operation.Reason);
    }

    [Fact]
    public void ApplyingACueDeclinesIdentityOverlapAndCutsWithoutChangingExistingWork()
    {
        var plan = Assert.IsType<ClipAutopilotPlan>(ClipAutopilotValidator.Plan(WithZooms(Zoom()), Context(new(0, 29))));
        var project = Project();
        var operation = Assert.Single(ClipAutopilotMapping.Operations(plan, "c1", project, ClipAutopilotFonts.Load(Root)),
            operation => operation.Decision == ClipAutopilotDecision.Zoom);
        var cue = Assert.IsType<ClipAutopilotAction.Motion>(operation.Action).Cue;
        var saved = Assert.IsType<Project>(ClipAutopilotMapping.AddingMotionCue(cue, project));
        Assert.Equal(4, saved.SchemaVersion);
        Assert.Equal(cue, Assert.Single(saved.MotionCues));
        Assert.Null(ClipAutopilotMapping.AddingMotionCue(cue with { SourceStart = 0.6, SourceEnd = 1.9 }, saved));
        Assert.Null(ClipAutopilotMapping.AddingMotionCue(cue with { Id = "overlap" }, saved));
        Assert.Null(ClipAutopilotMapping.AddingMotionCue(cue with { ClipID = "unknown" }, project));
        Assert.Null(ClipAutopilotMapping.AddingMotionCue(cue with { SourceStart = 1.4, SourceEnd = 3.6 }, Project(cutPauses: ["pause-after-w6"])));

        var cut = new ClipAutopilotOperation("manual-cut", ClipAutopilotDecision.Cut, new ClipAutopilotAction.Edit(new EditOperation.SetWordCuts(["w14"], true)), "");
        var (after, pending) = ClipAutopilotMapping.Apply([cut, operation], project);
        Assert.Contains("w14", after.Edits.CutWordIds);
        Assert.Empty(after.MotionCues);
        Assert.Equal(operation, Assert.Single(pending));
    }
}
